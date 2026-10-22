#!/usr/bin/env python3
"""copy-path — herdr overlay that hints file paths in the last command's
output and copies the one you pick.

  copy-path.py open   plugin action: capture the focused pane, open the overlay
  copy-path.py        overlay pane: read, hint, copy, exit

Everything is decided from the pane's visible text (prompt shape, the dir the
prompt prints, regex rules), so it works the same inside an ssh session.
Settings: config.toml next to this file.
"""

import json
import os
import posixpath
import re
import select
import signal
import socket
import subprocess
import sys
import termios
import time
import tty
import unicodedata

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN_ID = os.environ.get("HERDR_PLUGIN_ID", "local.copy-path")
CTX_ENV = "COPY_PATH_CTX"

# ❯ (starship/pure/p10k), user@host:dir$ / user@host dir % / [user@host dir]$ /
# fish user@host ~/x>, a dir-first "~/x $" / "/x>" (optional "(venv) "),
# Kali/Parrot "└─$" / "└──╼ $", macOS bash "host:dir user$", robbyrussell
# "➜  dir git:(main) ✗", and dir-less "bash-5.2$".
MODE = r"(?:\(\S+\) ?)*"   # vi-mode "(INS) " (readline show-mode-in-prompt), "(venv) "
END = r"(?: |$)"          # pane.read drops the space after an empty prompt
PROMPT_REGEX = (r"❯ ?"
                rf"|^{MODE}\[?[\w.-]+@[\w.-]+[: ] ?\S*\s?[$#%>]\]? ?"
                rf"|^{MODE}[~/]\S*\s?[$#%>]{END}"
                rf"|^{MODE}└─+(?:╼ )?[$#] ?"
                rf"|^{MODE}[\w.-]+:\S+ [\w.-]+[$#]{END}"
                rf"|^{MODE}➜\s+\S+(?: git:\(\S+\))?(?: ✗)?{END}"
                rf"|^{MODE}(?:ba|z|k|da)?sh-[\d.]+[$#]{END}")
# Git Bash's "$" alone on the row under its user@HOST header: only a prompt under one.
BARE_PROMPT_REGEX = rf"^{MODE}[$#]{END}"
# dir in the input row's prompt text; the first (?P<dir>…) match wins
DIR_REGEX = [rf"^{MODE}[\w.-]+:(?P<dir>\S+) [\w.-]+[$#]",            # macOS bash: host:dir user$
             r":(?P<dir>~[^\s$#%]*|/[^\s$#%]*)[$#%]",           # bash: user@host:~/dir$
             r"[\w.-]+@[\w.-]+ (?P<dir>[^\s\]$#%>]+)\]?\s?[$#%>]",  # zsh/fish/fedora: user@host dir %
             rf"^{MODE}➜\s+(?P<dir>\S+)",                              # oh-my-zsh robbyrussell
             r"(?:^|[\s\[(])(?P<dir>~[^\s\])$#%>❯]*|/[^\s\])$#%>❯]*)"]   # any ~/ or / word: "~/x ❯"
# dir in the rows above an input row that has none (multi-line prompts)
HEADER_REGEX = [r"[-─]\[(?P<dir>[^\]]+)\]\s*$",                 # Kali/Parrot: ┌──(u㉿h)-[~/x]
                r"^\S+@\S+ (?:MINGW|MSYS|UCRT|CLANG)\S* (?P<dir>\S+)",   # Git Bash
                r"^(?:.* in )?(?P<dir>[~/]\S*)",                # starship/pure: "~/x via …", "root in host in ~"
                r"^(?P<dir>[^\s/~]\S*)(?: (?:on|via|is|took)\s|$)"]  # starship truncated: "a/proj on  main"
# A pane running one of these is on another machine: its prompt's ~ isn't ours.
REMOTE_COMMANDS = ["ssh", "mosh", "mosh-client", "autossh", "et", "telnet", "docker",
                   "podman", "kubectl", "lxc", "multipass", "vagrant", "tsh", "gcloud", "aws"]

DEFAULTS = {
    "scope": "output",
    "timeout_ms": 5000,
    "prompt_regex": PROMPT_REGEX,
    "bare_prompt_regex": BARE_PROMPT_REGEX,
    "prompt_height": 2,
    "use_ps1": False,
    "ps1_dir_regex": DIR_REGEX,
    "ps1_header_regex": HEADER_REGEX,
    "remote_commands": REMOTE_COMMANDS,
    "list_commands": ["ls", "ll", "la", "l", "eza", "exa", "lsd", "fd", "find"],
    "ignore_regex": r"^(\w+://|-|[\d.,:_/-]+$|[0-9a-f]{7,40}$)",
    "check_exists": False,
    "alphabet": "asdfghjklwertyuiopzxcvbnm",
    "style": {"hint_fg": "#1e1e2e", "hint_bg": "#f9e2af", "match_fg": "#f9e2af",
              "dim_fg": "#6c7086", "status_fg": "#cdd6f4", "status_bg": "#313244"},
}


def load_config(path=os.path.join(HERE, "config.toml")):
    cfg = json.loads(json.dumps(DEFAULTS))
    try:
        import tomllib
        with open(path, "rb") as f:
            user = tomllib.load(f)
    except FileNotFoundError:
        return cfg
    for key, value in user.items():
        if key == "style":
            cfg["style"].update(value)
        else:
            cfg[key] = value
    for key in ("ps1_dir_regex", "ps1_header_regex"):
        if isinstance(cfg[key], str):
            cfg[key] = [cfg[key]]
    return cfg


# ---------------------------------------------------------------------------
# herdr socket API


def call(method, params):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(os.environ["HERDR_SOCKET_PATH"])
        s.sendall((json.dumps({"id": "1", "method": method, "params": params}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    envelope = json.loads(buf)
    if "error" in envelope:
        err = envelope["error"]
        raise RuntimeError(f"{method}: {err.get('code')}: {err.get('message')}")
    return envelope["result"]


def log(message):
    state = os.environ.get("HERDR_PLUGIN_STATE_DIR")
    if state:
        with open(os.path.join(state, "copy-path.log"), "a") as f:
            f.write(f"{time.strftime('%F %T')} {message}\n")


def focused_pane_id():
    return json.loads(os.environ.get("HERDR_PLUGIN_CONTEXT_JSON", "{}")).get("focused_pane_id")


def is_remote(pane_id, cfg):
    """True when the pane's foreground is ssh/mosh/docker exec… (herdr only
    ever runs locally, so anything else is a local shell)."""
    try:
        procs = call("pane.process_info", {"pane_id": pane_id})["process_info"]["foreground_processes"]
    except Exception as e:
        log(f"process_info: {e}")
        return True   # unknown: don't trust the local cwd / $HOME
    return any(os.path.basename(p.get("argv0") or p.get("name") or "") in cfg["remote_commands"]
               for p in procs)


def open_overlay():
    """Plugin action: remember the source pane's rect (the overlay covers the
    whole tab), cwd and whether it is local, then open the overlay pane."""
    cfg = load_config()
    pane_id = focused_pane_id()
    layout = call("pane.layout", {"pane_id": pane_id})["layout"]
    area = layout["area"]
    if layout.get("zoomed"):
        rect = dict(area)
    else:
        rect = dict(next(p["rect"] for p in layout["panes"] if p["pane_id"] == pane_id))
    rect["x"] -= area["x"]
    rect["y"] -= area["y"]
    pane = call("pane.get", {"pane_id": pane_id})["pane"]
    ctx = {"pane_id": pane_id, "area": area, "rect": rect, "cwd": pane.get("cwd"),
           "agent": pane.get("agent"), "local": not is_remote(pane_id, cfg)}
    opened = call("plugin.pane.open", {"plugin_id": PLUGIN_ID, "entrypoint": "overlay",
                                       "env": {CTX_ENV: json.dumps(ctx)}})
    # herdr can keep the split-sized PTY until an explicit zoom
    call("pane.zoom", {"pane_id": opened["plugin_pane"]["pane"]["pane_id"], "mode": "on"})


# ---------------------------------------------------------------------------
# finding paths (pure: rows of text in, hits out)


# plain classes, not dataclasses: importing dataclasses costs ~10ms per prefix+f
class Region:
    def __init__(self, start, end, command="", dir=None, user=None):
        self.start = start      # first row of the output
        self.end = end          # one past the last row
        self.command = command  # command that produced it ("" = unknown)
        self.dir = dir          # dir shown in the prompt it ran under
        self.user = user        # user shown in that prompt (remote ~ of root is /root)


class Hit:
    def __init__(self, text, copy, spans=None, label=""):
        self.text = text            # as seen on screen
        self.copy = copy            # what gets copied
        self.spans = spans or []    # [(row, start, end)] char indices
        self.label = label


def prompt_text(rows, row, cfg):
    """The input row minus the command typed after the prompt (a path in the
    command is not the prompt's dir)."""
    m = re.search(cfg["prompt_regex"], rows[row]) or re.match(cfg["bare_prompt_regex"], rows[row])
    return rows[row][:m.end()] if m else rows[row]


def second_line(text):
    """A prompt's input row that is only a symbol ("❯", "(INS) ❌ 130 ❯", "└─$",
    "$"): the rest of the prompt (its dir) is on the rows above."""
    return not re.search(r"\w", re.sub(r"\(\S*\)|\d+", "", text))


def first_dir(patterns, text):
    for pattern in patterns:
        m = re.search(pattern, text)
        if m and m.group("dir"):
            return m.group("dir")
    return None


def header_dir(rows, row, cfg):
    """(row, dir) of the nearest prompt header above input row `row`, or None."""
    for r in range(row - 1, row - int(cfg["prompt_height"]), -1):
        if r >= 0:
            d = first_dir(cfg["ps1_header_regex"], rows[r])
            if d:
                return r, d
    return None


def prompt_dir(rows, row, cfg):
    """Dir printed by the prompt whose input row is `row`: the input row
    itself, else a header row above it (a multi-line prompt). It can be a
    full path (/x, ~/x) or only what the prompt shows ("proj", "~/.d/h")."""
    text = prompt_text(rows, row, cfg)
    d = first_dir(cfg["ps1_dir_regex"], text)
    if d or not second_line(text):
        return d
    header = header_dir(rows, row, cfg)
    return header[1] if header else None


USER_REGEX = re.compile(r"(?:^|[\s(\[])([\w.-]+)(?:@|㉿)[\w.-]+|^(\w[\w.-]*) in ")


def prompt_user(rows, row, cfg):
    for r in range(row, row - int(cfg["prompt_height"]), -1):
        m = r >= 0 and USER_REGEX.search(rows[r])
        if m:
            return m.group(1) or m.group(2)
    return None


def prompt_start(rows, row, cfg):
    """First row of the prompt block ending at input row `row`."""
    text = prompt_text(rows, row, cfg)
    if first_dir(cfg["ps1_dir_regex"], text) or not second_line(text):
        return row   # a self-contained "user@host dir $" / "bash-5.2$" prompt is one row
    header = header_dir(rows, row, cfg)
    if header:
        return header[0]
    return max(0, row - int(cfg["prompt_height"]) + 1)


def find_region(rows, cfg, whole_screen=False):
    """Rows holding the last command's output, plus that command and the dir
    its prompt showed. No prompt on screen → the whole screen."""
    content = [i for i, r in enumerate(rows) if r.strip()]
    if not content:
        return Region(0, 0)
    last_content = content[-1]
    prompt_re = re.compile(cfg["prompt_regex"])
    bare_re = re.compile(cfg["bare_prompt_regex"])

    def match(i):
        m = prompt_re.search(rows[i])
        if not m and bare_re.match(rows[i]) and "@" in rows[i - 1] and header_dir(rows, i, cfg):
            m = bare_re.match(rows[i])   # Git Bash: "user@HOST MINGW64 ~/x" above
        return m

    inputs = [i for i in range(len(rows)) if match(i)]
    if whole_screen or cfg["scope"] == "screen" or not inputs:
        return Region(0, last_content + 1)

    def region(start, end, row, cmd=True):
        return Region(start, end, rows[row][match(row).end():].strip() if cmd else "",
                      prompt_dir(rows, row, cfg), prompt_user(rows, row, cfg))

    last = inputs[-1]
    if last < last_content:
        # output after the last prompt: a command still running (tail -f, ssh login…)
        return region(last + 1, last_content + 1, last)
    end = prompt_start(rows, last, cfg)
    if len(inputs) < 2:
        # the previous prompt scrolled away: output from the top, current prompt's dir
        return region(0, end, last, cmd=False)
    prev = inputs[-2]
    return region(prev + 1, end, prev)


LONG_LS = re.compile(r"^[-bcdlpsDl][rwxsStT-]{9}[@+.]?\s")
PATH_CHARS = re.compile(r"^[\w.~@%+#/,=-]+$")
FILE_EXT = re.compile(r"^[\w@%+~-][\w.@%+~-]*\.[A-Za-z][A-Za-z0-9_]{0,9}$")
LINE_COL = re.compile(r":\d+(?=:|$)")


def display_width(text):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def tokens(rows, region, wrap_width=None):
    """Whitespace-separated tokens as (text, [(row, start, end)]). A token that
    runs into the right edge of a full row continues on the next row (a path
    the terminal wrapped)."""
    out = []
    carry = None
    for r in range(region.start, region.end):
        row = rows[r]
        found = list(re.finditer(r"\S+", row))
        for i, m in enumerate(found):
            text, spans = m.group(), [(r, m.start(), m.end())]
            if carry and i == 0 and m.start() == 0:
                text, spans = carry[0] + text, carry[1] + spans
            elif carry:
                out.append(carry)
            carry = None
            wraps = (wrap_width and i == len(found) - 1 and m.end() == len(row)
                     and display_width(row) >= wrap_width and r + 1 < region.end)
            if wraps:
                carry = (text, spans)
            else:
                out.append((text, spans))
        if carry and not found:
            out.append(carry)
            carry = None
    if carry:
        out.append(carry)
    return out


def trim(text, ls_context):
    """Strip quotes/brackets/punctuation, `key=`, `:line:col` and ls -F
    markers. Returns (lo, hi) of the path inside `text`."""
    lo, hi = 0, len(text)
    while lo < hi and text[lo] in "'\"([{<`":
        lo += 1
    while hi > lo and (text[hi - 1] in "'\")]}>`,;:" or   # "…", (x). x:
                       (text[hi - 1] == "." and hi - lo > 1 and text[hi - 2] not in "./")):
        hi -= 1
    if "=" in text[lo:hi]:
        lo = text.rindex("=", lo, hi) + 1
    m = LINE_COL.search(text, lo, hi)
    if m and m.start() > lo:
        hi = m.start()   # grep / compiler "path:12:3: …"
    if ls_context:
        while hi > lo and text[hi - 1] in "*@=|":
            hi -= 1
    return lo, hi


def slice_spans(spans, lo, hi):
    """Narrow [(row, start, end)] to the characters lo..hi of their joined text."""
    out, pos = [], 0
    for row, start, end in spans:
        a, b = max(lo, pos), min(hi, pos + end - start)
        if a < b:
            out.append((row, start + a - pos, start + b - pos))
        pos += end - start
    return out


def is_path(tok, bare_ok, cfg, exists_base=None):
    if not tok or not re.search(r"\w", tok) or not PATH_CHARS.match(tok):
        return False
    if re.search(cfg["ignore_regex"], tok):
        return False
    if "/" in tok and not tok.startswith(("/", "~", ".")) and \
            all(len(part) < 2 for part in tok.split("/")):
        return False   # "y/N", "a/b": prose, not paths
    if "/" in tok or FILE_EXT.match(tok) or bare_ok:
        return True
    return bool(exists_base) and os.path.exists(os.path.join(exists_base, tok))


def expand_home(path, home):
    if home and (path == "~" or path.startswith("~/")):
        return home + path[1:]
    return path


def absolute_dir(shown, local_cwd, home):
    """The dir the prompt showed, as a full path when it can be known.
    local_cwd is the shell's cwd for a local pane, None over ssh (where only
    the prompt's own text counts and an unknown ~ stays ~)."""
    if local_cwd is None:
        return expand_home(shown, home) if shown and shown.startswith(("/", "~")) else None
    if not shown:
        return local_cwd   # a prompt without a dir ("bash-5.2$"): the shell's cwd
    full = expand_home(shown, home)
    if full.startswith("/") and os.path.isdir(full):
        return posixpath.normpath(full)
    # only part of the path: starship's truncated "a/b/proj", fish's
    # "~/.d/herdr", "…/x", "[bob@box proj]$". The shell may have cd'd since
    # (`cd ..`, `cd sub`), so place it against the cwd and its parents.
    parts = [p for p in full.split("/") if p and p != "…"]
    if parts and parts[0].startswith("…"):
        parts[0] = parts[0][1:]
    cwd = local_cwd.rstrip("/").split("/")
    if not parts:
        return full if full.startswith("/") else None

    def fits(real):
        # every shown part is (fish: abbreviates) its real part, the last one whole
        if full.startswith("/") and len(real) != len(parts) + 1:
            return False
        tail = real[-len(parts):]
        return (len(real) > len(parts) and tail[-1] == parts[-1]
                and all(r.startswith(p) for r, p in zip(tail, parts)))

    for n in range(len(cwd), 1, -1):   # the cwd, then each parent
        if fits(cwd[:n]):
            return "/".join(cwd[:n])
    for i in range(len(cwd) - 1, 0, -1):   # a dir beside/below: anchor its first part
        if cwd[i] == parts[0]:
            candidate = "/".join(cwd[:i] + parts)
            if os.path.isdir(candidate):
                return candidate
    return full if full.startswith("/") else None


def resolve(tok, base, home, cfg):
    """What to copy: as seen, or (use_ps1) the full path under the prompt's dir."""
    if not cfg["use_ps1"]:
        return tok
    tok = expand_home(tok, home)
    if base and not tok.startswith(("/", "~")):
        slash = tok.endswith("/")
        tok = posixpath.normpath(posixpath.join(base, tok))
        if slash and not tok.endswith("/"):
            tok += "/"
    return tok


def find_paths(rows, region, cfg, local_cwd=None, wrap_width=None):
    """local_cwd: the pane's cwd when it is a local shell (not ssh…)."""
    home = os.path.expanduser("~") if local_cwd else ("/root" if region.user == "root" else None)
    base = absolute_dir(region.dir, local_cwd, home)
    exists_base = base if cfg["check_exists"] and local_cwd and base and os.path.isdir(base) else None
    words = region.command.split()
    ls_context = bool(words) and os.path.basename(words[0]) in cfg["list_commands"]
    row_dir = listed_dirs(rows, region, words) if ls_context else {}
    long_rows = {r for r in range(region.start, region.end) if LONG_LS.match(rows[r])}
    # ls -l: only each entry's name column is a bare name ("a -> b": a)
    name_tokens = {}
    if ls_context and long_rows:
        for r in long_rows:
            found = list(re.finditer(r"\S+", rows[r]))
            texts = [m.group() for m in found]
            idx = texts.index("->") - 1 if "->" in texts else len(texts) - 1
            name_tokens[r] = found[idx].start()

    hits = []
    for text, spans in tokens(rows, region, wrap_width):
        row, start = spans[0][0], spans[0][1]
        if long_rows:
            bare_ok = name_tokens.get(row) == start
        else:
            bare_ok = ls_context
        lo, hi = trim(text, ls_context)
        tok = text[lo:hi]
        if is_path(tok, bare_ok, cfg, exists_base):
            path, listed = tok, row_dir.get(row)
            if listed and "/" not in tok.rstrip("/") and tok != posixpath.basename(listed.rstrip("/")):
                path = posixpath.join(listed, tok)
            hits.append(Hit(tok, resolve(path, base, home, cfg), slice_spans(spans, lo, hi)))
    return hits


LS_HEADER = re.compile(r"^(\S.*):$")


def listed_dirs(rows, region, words):
    """Row → the dir an ls-style listing shows there: `ls DIR` (one plain
    argument), then each "DIR:" header of `ls A B`. fd/find print paths
    already relative to the cwd."""
    if os.path.basename(words[0]) in ("fd", "find"):
        return {}
    args = [w for w in words[1:] if not w.startswith("-")]
    current = args[0] if len(args) == 1 and not re.search(r"[*?\[{]", args[0]) else None
    out = {}
    for r in range(region.start, region.end):
        m = LS_HEADER.match(rows[r])
        if m:
            current = m.group(1)   # the header itself is relative to the prompt dir
            continue
        out[r] = current
    return out


def hint_labels(n, alphabet):
    """n prefix-free labels: single letters while they last, then pairs."""
    a = list(alphabet)
    if n <= len(a):
        return a[:n]
    p = 1
    while p < len(a) and (len(a) - p) + p * len(a) < n:
        p += 1
    singles, prefixes = a[:len(a) - p], a[len(a) - p:]
    return (singles + [x + y for x in prefixes for y in a])[:n]


def assign_labels(hits, alphabet):
    """One label per distinct copy text; the path nearest the prompt gets the
    first (easiest) letter. Hits past the label supply are dropped."""
    order = []
    for hit in sorted(hits, key=lambda h: (h.spans[-1][0], h.spans[-1][1]), reverse=True):
        if hit.copy not in order:
            order.append(hit.copy)
    labels = dict(zip(order, hint_labels(len(order), alphabet)))
    kept = []
    for hit in hits:
        if hit.copy in labels:
            hit.label = labels[hit.copy]
            kept.append(hit)
    return kept


# ---------------------------------------------------------------------------
# overlay


def sgr_color(value, ground):
    value = str(value)
    if value.startswith("#") and len(value) == 7:
        r, g, b = (int(value[i:i + 2], 16) for i in (1, 3, 5))
        return f"{ground}8;2;{r};{g};{b}"
    return f"{ground}8;5;{int(value)}"


class Overlay:
    def __init__(self, rows, region, hits, ctx, cfg):
        self.rows, self.region, self.hits, self.cfg = rows, region, hits, cfg
        self.rect, self.area = ctx["rect"], ctx["area"]
        self.typed = ""
        st = cfg["style"]
        self.s_dim = f"\x1b[{sgr_color(st['dim_fg'], 3)}m"
        self.s_match = f"\x1b[1;{sgr_color(st['match_fg'], 3)}m"
        self.s_hint = f"\x1b[1;{sgr_color(st['hint_fg'], 3)};{sgr_color(st['hint_bg'], 4)}m"
        self.s_status = f"\x1b[{sgr_color(st['status_fg'], 3)};{sgr_color(st['status_bg'], 4)}m"
        self.status_text = ""

    def live(self):
        return [h for h in self.hits if h.label.startswith(self.typed)]

    def styled_row(self, r):
        row = self.rows[r]
        base = "" if self.region.start <= r < self.region.end else self.s_dim
        styles = [base] * len(row)
        chars = list(row)
        for hit in self.live():
            for i, (hr, a, b) in enumerate(hit.spans):
                if hr != r:
                    continue
                for c in range(a, b):
                    styles[c] = self.s_match
                if i == 0:
                    for k, ch in enumerate(hit.label[:b - a]):
                        chars[a + k] = ch
                        styles[a + k] = self.s_hint
        out, cur = [], None
        for ch, style in zip(chars, styles):
            if style != cur:
                out.append("\x1b[0m" + style)
                cur = style
            out.append(ch)
        return "".join(out) + "\x1b[0m"

    def status_pos(self):
        """(row, col, width), 1-based, of free space outside the source pane."""
        rect, area = self.rect, self.area
        if rect["y"] + rect["height"] < area["height"]:
            return area["height"], 1, area["width"]
        if rect["y"] > 0:
            return 1, 1, area["width"]
        if rect["x"] > 0:
            return area["height"], 1, rect["x"]
        if rect["x"] + rect["width"] < area["width"]:
            right = rect["x"] + rect["width"]
            return area["height"], right + 1, area["width"] - right
        # full-tab pane: after the text on its last row, if there's room
        last = self.rows[rect["height"] - 1] if len(self.rows) >= rect["height"] else ""
        col = display_width(last) + 3
        return (rect["height"], col, rect["width"] - col) if rect["width"] - col >= 20 else None

    def draw(self):
        out = ["\x1b[H\x1b[2J"]
        for r in range(min(len(self.rows), self.rect["height"])):
            out.append(f"\x1b[{self.rect['y'] + r + 1};{self.rect['x'] + 1}H")
            out.append(self.styled_row(r))
        pos = self.status_pos()
        if pos and self.status_text:
            row, col, width = pos
            text = f" {self.status_text} "[:max(0, width)]
            out.append(f"\x1b[{row};{col}H{self.s_status}{text}\x1b[0m")
        sys.stdout.write("".join(out))
        sys.stdout.flush()

    def run(self, on_pick=None):
        """Hint loop → the picked Hit, or None (Esc, Ctrl-C, timeout).
        on_pick(hit) runs the moment a label completes; the overlay then exits."""
        fd = sys.stdin.fileno()
        saved = termios.tcgetattr(fd)
        wake_r, wake_w = os.pipe()

        def on_resize(*_):
            # herdr sizes the overlay a few times while opening it: just redraw
            os.write(wake_w, b"x")

        signal.signal(signal.SIGWINCH, on_resize)
        tty.setraw(fd)
        sys.stdout.write("\x1b[?1049h\x1b[?25l")
        timeout = self.cfg["timeout_ms"] / 1000
        try:
            self.draw()
            deadline = time.monotonic() + timeout
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    log("closed: timeout")
                    return None
                ready, _, _ = select.select([fd, wake_r], [], [], left)
                if wake_r in ready:
                    os.read(wake_r, 64)
                    self.draw()
                if fd not in ready:
                    continue
                data = os.read(fd, 64).decode(errors="ignore")
                deadline = time.monotonic() + timeout
                if data in ("\x1b", "\x03") or data == "\x1b\x1b":
                    log(f"closed: key {data!r}")
                    return None
                if data.startswith("\x1b"):
                    continue   # arrow keys etc.
                for ch in data:
                    if ch in ("\x7f", "\x08"):
                        self.typed = self.typed[:-1]
                        continue
                    ch = ch.lower()
                    if any(h.label.startswith(self.typed + ch) for h in self.hits):
                        self.typed += ch
                    picked = [h for h in self.hits if h.label == self.typed]
                    if picked:
                        if on_pick:
                            on_pick(picked[0])
                        return picked[0]
                self.update_status()
                self.draw()
        finally:
            sys.stdout.write("\x1b[0m\x1b[?25h\x1b[?1049l")
            sys.stdout.flush()
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)

    def update_status(self):
        n = len({h.copy for h in self.live()})
        where = self.region.dir or ""
        self.status_text = f"copy-path · {n} path{'s' * (n != 1)}" + \
            (f" · {where}" if where else "") + (f" · {self.typed}" if self.typed else "") + " · esc"


def copy_text(text):
    try:
        subprocess.run(["pbcopy"], input=text.encode(), check=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        import base64
        sys.stdout.write(f"\x1b]52;c;{base64.b64encode(text.encode()).decode()}\x07")
        sys.stdout.flush()


def toast(title):
    try:
        call("notification.show", {"title": title})
    except Exception as e:  # a toast is never worth failing the copy for
        log(f"toast: {e}")


def overlay():
    cfg = load_config()
    ctx = json.loads(os.environ.get(CTX_ENV) or "null")
    if not ctx:
        # opened without the action: whole terminal, focused pane
        cols, lines = os.get_terminal_size()
        full = {"x": 0, "y": 0, "width": cols, "height": lines}
        ctx = {"pane_id": focused_pane_id(), "area": full, "rect": full, "cwd": None, "agent": None, "local": False}
    read = call("pane.read", {"pane_id": ctx["pane_id"], "source": "visible",
                              "format": "text", "strip_ansi": True})["read"]["text"]
    rows = read.split("\n")[:ctx["rect"]["height"]]
    # an agent TUI (claude, opencode…) draws its own ❯: no shell prompts to go by
    region = find_region(rows, cfg, whole_screen=bool(ctx.get("agent")))
    # pane.read moves the wrap-pending last column to the next row
    wrap_width = max(1, ctx["rect"]["width"] - 1)
    local_cwd = ctx.get("cwd") if ctx.get("local") else None
    hits = assign_labels(find_paths(rows, region, cfg, local_cwd, wrap_width), cfg["alphabet"])
    log(f"pane={ctx['pane_id']} region={region.start}-{region.end} cmd={region.command!r} "
        f"dir={region.dir!r} local={bool(local_cwd)} hits={len(hits)}")
    if not hits:
        toast("copy-path: no paths in the last output")
        return
    ui = Overlay(rows, region, hits, ctx, cfg)
    ui.update_status()
    ui.run(on_pick=lambda hit: copy_text(hit.copy))


def main():
    try:
        if sys.argv[1:] == ["open"]:
            open_overlay()
        else:
            overlay()
    except Exception as e:
        log(f"error: {e!r}")
        print(f"copy-path: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
