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
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN_ID = os.environ.get("HERDR_PLUGIN_ID", "local.copy-path")
CTX_ENV = "COPY_PATH_CTX"

# ❯ (starship/pure), user@host:dir$ / user@host dir % / [user@host dir]$, or a
# dir-first "~/x $" / "/x>"; an optional "(venv) " prefix on the last two.
PROMPT_REGEX = (r"❯ ?"
                r"|^(?:\(\S+\) ?)?\[?[\w.-]+@[\w.-]+[: ] ?\S*\s?[$#%]\]? ?"
                r"|^(?:\(\S+\) ?)?[~/]\S*\s?[$#%>] ")
DIR_REGEX = [r"(?:^|\sin\s)(?P<dir>~[^\s$#%>]*|/[^\s$#%>]*)",
             r":(?P<dir>~[^\s$#%]*|/[^\s$#%]*)[$#%]",
             r"(?:^|[\s\[(])(?P<dir>~[^\s\])$#%>]*|/[^\s\])$#%>]*)"]

DEFAULTS = {
    "scope": "output",
    "timeout_ms": 5000,
    "flash_ms": 250,
    "prompt_regex": PROMPT_REGEX,
    "prompt_height": 2,
    "use_ps1": False,
    "ps1_dir_regex": DIR_REGEX,
    "expand_home": False,
    "list_commands": ["ls", "ll", "la", "l", "eza", "exa", "lsd", "fd", "find"],
    "ignore_regex": r"^(\w+://|-|[\d.,:_/-]+$|[0-9a-f]{7,40}$)",
    "cwd_fallback": False,
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
    if isinstance(cfg["ps1_dir_regex"], str):
        cfg["ps1_dir_regex"] = [cfg["ps1_dir_regex"]]
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


def open_overlay():
    """Plugin action: remember the source pane's rect (the overlay covers the
    whole tab) + cwd, then open the overlay pane."""
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
    ctx = {"pane_id": pane_id, "area": area, "rect": rect,
           "cwd": pane.get("cwd"), "agent": pane.get("agent")}
    opened = call("plugin.pane.open", {"plugin_id": PLUGIN_ID, "entrypoint": "overlay",
                                       "env": {CTX_ENV: json.dumps(ctx)}})
    # herdr can keep the split-sized PTY until an explicit zoom
    call("pane.zoom", {"pane_id": opened["plugin_pane"]["pane"]["pane_id"], "mode": "on"})


# ---------------------------------------------------------------------------
# finding paths (pure: rows of text in, hits out)


@dataclass
class Region:
    start: int          # first row of the output
    end: int            # one past the last row
    command: str = ""   # command that produced it ("" = unknown)
    dir: str | None = None   # dir shown in the prompt it ran under


@dataclass
class Hit:
    text: str                                   # as seen on screen
    copy: str                                   # what gets copied
    spans: list = field(default_factory=list)   # [(row, start, end)] char indices
    label: str = ""


def prompt_text(rows, row, cfg):
    """The input row minus the command typed after the prompt (a path in the
    command is not the prompt's dir)."""
    m = re.search(cfg["prompt_regex"], rows[row])
    return rows[row][:m.end()] if m else rows[row]


def prompt_dir(rows, row, cfg):
    """Dir printed by the prompt whose input row is `row`: the input row
    itself, else the rows above it (a multi-line prompt)."""
    block = [row] + [r for r in range(row - 1, row - int(cfg["prompt_height"]), -1) if r >= 0]
    for r in block:
        text = prompt_text(rows, r, cfg) if r == row else rows[r]
        for pattern in cfg["ps1_dir_regex"]:
            m = re.search(pattern, text)
            if m and m.group("dir").startswith(("~", "/")):
                return m.group("dir")
    return None


def prompt_start(rows, row, cfg):
    """First row of the prompt block ending at input row `row`."""
    for pattern in cfg["ps1_dir_regex"]:
        if re.search(pattern, prompt_text(rows, row, cfg)):
            return row
    m = re.search(cfg["prompt_regex"], rows[row])
    if m and "❯" not in m.group():
        return row   # a self-contained "user@host dir $" prompt is one row
    return max(0, row - int(cfg["prompt_height"]) + 1)


def find_region(rows, cfg, whole_screen=False):
    """Rows holding the last command's output, plus that command and the dir
    its prompt showed. No prompt on screen → the whole screen."""
    content = [i for i, r in enumerate(rows) if r.strip()]
    if not content:
        return Region(0, 0)
    last_content = content[-1]
    prompt_re = re.compile(cfg["prompt_regex"])
    inputs = [i for i, r in enumerate(rows) if prompt_re.search(r)]
    if whole_screen or cfg["scope"] == "screen" or not inputs:
        return Region(0, last_content + 1)

    def command(row):
        return rows[row][prompt_re.search(rows[row]).end():].strip()

    last = inputs[-1]
    if last < last_content:
        # output after the last prompt: a command still running (tail -f, ssh login…)
        return Region(last + 1, last_content + 1, command(last), prompt_dir(rows, last, cfg))
    end = prompt_start(rows, last, cfg)
    if len(inputs) < 2:
        # the previous prompt scrolled away: output from the top, current prompt's dir
        return Region(0, end, "", prompt_dir(rows, last, cfg))
    prev = inputs[-2]
    return Region(prev + 1, end, command(prev), prompt_dir(rows, prev, cfg))


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


def resolve(tok, base, cfg):
    """What to copy: as seen, or (use_ps1) the full path under the prompt's dir."""
    if cfg["use_ps1"] and base and not tok.startswith(("/", "~")):
        slash = tok.endswith("/")
        tok = posixpath.normpath(posixpath.join(base, tok))
        if slash and not tok.endswith("/"):
            tok += "/"
    if cfg["expand_home"] and (tok == "~" or tok.startswith("~/")):
        tok = os.path.expanduser(tok)
    return tok


def local_base(base, pane_cwd):
    """`base` as a local dir when it IS the pane's local cwd (never over ssh)."""
    if not base or not pane_cwd:
        return None
    local = os.path.expanduser(base)
    return local if os.path.realpath(local) == os.path.realpath(pane_cwd) else None


def find_paths(rows, region, cfg, pane_cwd=None, wrap_width=None):
    base = region.dir or (pane_cwd if cfg["cwd_fallback"] else None)
    exists_base = local_base(base, pane_cwd) if cfg["check_exists"] else None
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
            hits.append(Hit(tok, resolve(path, base, cfg), slice_spans(spans, lo, hi)))
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

    def styled_row(self, r, flash=None, flash_on=False):
        row = self.rows[r]
        base = "" if self.region.start <= r < self.region.end else self.s_dim
        styles = [base] * len(row)
        chars = list(row)
        for hit in self.live():
            for i, (hr, a, b) in enumerate(hit.spans):
                if hr != r:
                    continue
                style = self.s_match
                if hit is flash or (flash and hit.copy == flash.copy):
                    style = "\x1b[7m" + self.s_match if flash_on else self.s_match
                for c in range(a, b):
                    styles[c] = style
                if i == 0 and flash is None:
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

    def draw(self, flash=None, flash_on=False):
        out = ["\x1b[H\x1b[2J"]
        for r in range(min(len(self.rows), self.rect["height"])):
            out.append(f"\x1b[{self.rect['y'] + r + 1};{self.rect['x'] + 1}H")
            out.append(self.styled_row(r, flash, flash_on))
        pos = self.status_pos()
        if pos and self.status_text:
            row, col, width = pos
            text = f" {self.status_text} "[:max(0, width)]
            out.append(f"\x1b[{row};{col}H{self.s_status}{text}\x1b[0m")
        sys.stdout.write("".join(out))
        sys.stdout.flush()

    def run(self):
        """Hint loop → the picked Hit, or None (Esc, Ctrl-C, timeout, resize)."""
        fd = sys.stdin.fileno()
        saved = termios.tcgetattr(fd)
        wake_r, wake_w = os.pipe()
        expected = (self.area["width"], self.area["height"])
        state = {"fit": os.get_terminal_size() == expected, "cancel": False}

        def on_resize(*_):
            size = tuple(os.get_terminal_size())
            if size == expected:
                state["fit"] = True
            elif state["fit"]:
                state["cancel"] = True   # snapshot no longer matches the pane
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
                    return None
                ready, _, _ = select.select([fd, wake_r], [], [], left)
                if wake_r in ready:
                    os.read(wake_r, 64)
                    if state["cancel"]:
                        return None
                    self.draw()
                if fd not in ready:
                    continue
                data = os.read(fd, 64).decode(errors="ignore")
                deadline = time.monotonic() + timeout
                if data in ("\x1b", "\x03") or data == "\x1b\x1b":
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
                        self.flash(picked[0])
                        return picked[0]
                self.update_status()
                self.draw()
        finally:
            sys.stdout.write("\x1b[0m\x1b[?25h\x1b[?1049l")
            sys.stdout.flush()
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)

    def flash(self, hit):
        steps = 6
        for i in range(steps):
            self.draw(flash=hit, flash_on=i % 2 == 0)
            time.sleep(self.cfg["flash_ms"] / 1000 / steps)

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
        ctx = {"pane_id": focused_pane_id(), "area": full, "rect": full, "cwd": None, "agent": None}
    read = call("pane.read", {"pane_id": ctx["pane_id"], "source": "visible",
                              "format": "text", "strip_ansi": True})["read"]["text"]
    rows = read.split("\n")[:ctx["rect"]["height"]]
    # an agent TUI (claude, opencode…) draws its own ❯: no shell prompts to go by
    region = find_region(rows, cfg, whole_screen=bool(ctx.get("agent")))
    # pane.read moves the wrap-pending last column to the next row
    wrap_width = max(1, ctx["rect"]["width"] - 1)
    hits = assign_labels(find_paths(rows, region, cfg, ctx.get("cwd"), wrap_width), cfg["alphabet"])
    log(f"pane={ctx['pane_id']} region={region.start}-{region.end} cmd={region.command!r} "
        f"dir={region.dir!r} hits={len(hits)}")
    if not hits:
        toast("copy-path: no paths in the last output")
        return
    ui = Overlay(rows, region, hits, ctx, cfg)
    ui.update_status()
    picked = ui.run()
    if picked:
        copy_text(picked.copy)
        toast(f"Copied {picked.copy}")


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
