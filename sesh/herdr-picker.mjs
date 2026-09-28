#!/usr/bin/env node
// herdr-picker.mjs — the prefix+w popup (run by connect-herdr.sh).
//
// Picker: same rows / keys as the old fzf picker; every row, preview, label,
// help text and action comes from connect-herdr.sh (list / preview / label /
// help / kill / go / browser), so the shell script stays the one backend.
//
// Moving splits: drag a ⠿ split row onto a workspace (→ new tab there) or a
// tab / another split (→ split into that tab). An animated frame marks where
// it lands, the preview shows the landing spot, and letting go runs
// `herdr pane move` right away (herdr-move.mjs), then the list reloads.
//
// No dependencies: raw ANSI + SGR mouse (1002 = press / drag motion /
// release, 1006 = coordinates).
//
//   HERDR_PICKER_DRY_RUN=1   show the herdr command instead of running it

import { spawn, spawnSync, execFile, execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { buildModel, isNoop, moveArgv, shortId } from "./herdr-move.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SH = join(HERE, "connect-herdr.sh");
const SCRATCH = join(HERE, "create_scratch.sh");
const HOME = homedir();
const DRY = process.env.HERDR_PICKER_DRY_RUN === "1";
const LOG_DIR = join(HOME, ".cache", "herdr-picker");

// ── ansi ────────────────────────────────────────────────────────────────
const E = "\x1b[";
const sgr = (...n) => `${E}${n.join(";")}m`;
const RESET = sgr(0);
const dim = (s) => `${sgr(90)}${s}${sgr(39)}`;
const fg = (n, s) => `${sgr(n)}${s}${sgr(39)}`;
const bold = (s) => `${sgr(1)}${s}${sgr(22)}`;
const ACCENT = 35; // magenta ≈ herdr's mauve
const SEL_BG = sgr(48, 5, 237);
const TARGET_BG = sgr(48, 5, 53);
const TOKEN_RE = /\x1b\[[0-9;:?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[P^_][^\x1b]*\x1b\\|\x1b[@-Z\\-_]|[\s\S]/gu;

const strip = (s) => s.replace(/\x1b\[[0-9;:?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]/g, "");

function charWidth(cp) {
    if (cp < 32 || (cp >= 0x7f && cp < 0xa0)) return 0;
    if ((cp >= 0x300 && cp <= 0x36f) || (cp >= 0x200b && cp <= 0x200f) ||
        (cp >= 0xfe00 && cp <= 0xfe0f) || cp === 0x20e3) return 0;
    if ((cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) ||
        (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) ||
        (cp >= 0xfe30 && cp <= 0xfe4f) || (cp >= 0xff00 && cp <= 0xff60) ||
        (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1f64f) ||
        (cp >= 0x1f900 && cp <= 0x1f9ff) || (cp >= 0x20000 && cp <= 0x3fffd)) return 2;
    return 1;
}
const width = (s) => { let w = 0; for (const ch of strip(s)) w += charWidth(ch.codePointAt(0)); return w; };

// visible columns [start, end) of s; SGR codes are kept so styles carry over
function slice(s, start, end = Infinity) {
    let out = "", col = 0;
    for (const tok of s.match(TOKEN_RE) ?? []) {
        if (tok.length > 1 && tok[0] === "\x1b") {
            if (tok.startsWith(E) && tok.endsWith("m")) out += tok;
            continue;
        }
        const w = charWidth(tok.codePointAt(0));
        if (tok === "\t") { const n = 4 - (col % 4); for (let i = 0; i < n; i++) { if (col >= start && col < end) out += " "; col++; } continue; }
        if (w === 0) { if (col > start && col <= end) out += tok; continue; }
        if (col >= start && col + w <= end) out += tok;
        else if (col < end && col + w > start) out += " ".repeat(Math.min(col + w, end) - Math.max(col, start));
        col += w;
        if (col >= end && end !== Infinity) break;
    }
    return out;
}
// exactly w columns, style reset at the end
const fit = (s, w) => { const t = slice(s, 0, w); return t + RESET + " ".repeat(Math.max(0, w - width(t))); };
// keep a background through inner resets
const withBg = (s, bg) => bg + s.replace(/\x1b\[0?m/g, (m) => m + bg);
// only SGR survives (pane dumps carry cursor moves etc.)
const sanitize = (s) => s.replace(/\r/g, "").replace(/\x1b\[[0-9;:?<>=]*[ -/]*[@-~]/g, (m) => (m.endsWith("m") ? m : ""))
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]/g, "");

function box(lines, w, h, label = "", color = 90, labelColor = null) {
    if (w < 4 || h < 2) return Array.from({ length: h }, () => " ".repeat(Math.max(0, w)));
    const b = (s) => `${sgr(color)}${s}${sgr(39)}`;
    let lab = label ? slice(label, 0, w - 4) : "";
    const lw = width(lab);
    lab = labelColor ? fg(labelColor, lab) : lab;
    const out = [b("╭─") + lab + RESET + b("─".repeat(Math.max(0, w - 3 - lw)) + "╮")];
    for (let i = 0; i < h - 2; i++) out.push(b("│") + fit(lines[i] ?? "", w - 2) + b("│"));
    out.push(b("╰" + "─".repeat(w - 2) + "╯"));
    return out;
}

// ── terminal ────────────────────────────────────────────────────────────
const out = process.stdout;
let termOn = false;
function termStart() {
    if (!process.stdin.isTTY) { console.error("herdr-picker: needs a terminal"); process.exit(1); }
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.setEncoding("utf8");
    // alt screen, hide cursor, no autowrap, drag mouse + SGR
    out.write(`${E}?1049h${E}?25l${E}?7l${E}?1002h${E}?1006h`);
    termOn = true;
}
function termStop() {
    if (!termOn) return;
    termOn = false;
    out.write(`${E}?1006l${E}?1002l${E}?7h${E}?25h${RESET}${E}?1049l`);
    try { process.stdin.setRawMode(false); } catch { /* closed */ }
    process.stdin.pause();
}
function quit(code = 0) { termStop(); process.exit(code); }
process.on("exit", termStop);
process.on("SIGINT", () => quit(130));
process.on("SIGTERM", () => quit(143));
process.on("SIGHUP", () => quit(129)); // popup closed: plan discarded, nothing half-applied
process.on("uncaughtException", (e) => { termStop(); console.error(e); process.exit(1); });

// leave the TUI and hand the tty to a shell action
function handOff(cmd, args, opts = {}) {
    termStop();
    return spawnSync(cmd, args, { stdio: "inherit", ...opts });
}

// ── input: keys + SGR mouse ─────────────────────────────────────────────
const NAMED = { 27: "escape", 13: "enter", 9: "tab", 127: "backspace", 8: "backspace", 32: "space" };
function codeKey(code, mods) {
    const m = Math.max(0, (mods || 1) - 1);
    const name = NAMED[code] ?? String.fromCodePoint(code).toLowerCase();
    return { type: "key", name, ch: NAMED[code] ? "" : String.fromCodePoint(code), ctrl: !!(m & 4), alt: !!(m & 2), shift: !!(m & 1) };
}
function csiKey(params, final) {
    const p = params.split(";").map((x) => x.split(":")[0]);
    if (final === "u") return codeKey(+p[0], +p[1]);
    if (final === "~") {
        if (p[0] === "27") return codeKey(+p[2], +p[1]);
        const names = { 1: "home", 7: "home", 4: "end", 8: "end", 3: "delete", 5: "pageup", 6: "pagedown", 2: "insert" };
        return { ...codeKey(0, +p[1]), name: names[p[0]] ?? "unknown", ch: "" };
    }
    const arrows = { A: "up", B: "down", C: "right", D: "left", H: "home", F: "end" };
    if (arrows[final]) return { ...codeKey(0, +(p[1] || 1)), name: arrows[final], ch: "" };
    if (final === "Z") return { type: "key", name: "tab", ch: "", shift: true, ctrl: false, alt: false };
    return { type: "key", name: "unknown", ch: "" };
}
function parseInput(buf) {
    const ev = [];
    let i = 0;
    while (i < buf.length) {
        const c = buf[i];
        if (c === "\x1b") {
            if (i + 1 >= buf.length) break;
            const rest = buf.slice(i);
            if (buf[i + 1] === "[") {
                let m = /^\x1b\[<(\d+);(\d+);(\d+)([Mm])/.exec(rest);
                if (m) { ev.push({ type: "mouse", b: +m[1], x: +m[2] - 1, y: +m[3] - 1, release: m[4] === "m" }); i += m[0].length; continue; }
                m = /^\x1b\[([0-9;:?]*)([ -/]*)([@-~])/.exec(rest);
                if (m) { ev.push(csiKey(m[1], m[3])); i += m[0].length; continue; }
                if (/^\x1b\[[0-9;:?<]*$/.test(rest)) break; // incomplete
                ev.push(codeKey(27)); i++; continue;
            }
            if (buf[i + 1] === "O") {
                if (i + 2 >= buf.length) break;
                ev.push(csiKey("", buf[i + 2])); i += 3; continue;
            }
            if (buf[i + 1] === "\x1b") { ev.push(codeKey(27)); i++; continue; }
            const ch = String.fromCodePoint(buf.codePointAt(i + 1));
            ev.push({ ...codeKey(ch.codePointAt(0)), alt: true }); i += 1 + ch.length; continue;
        }
        const cp = buf.codePointAt(i);
        const ch = String.fromCodePoint(cp);
        i += ch.length;
        if (cp === 13) ev.push(codeKey(13));
        else if (cp === 9) ev.push(codeKey(9));
        else if (cp === 127 || cp === 8) ev.push(codeKey(127));
        else if (cp === 0) ev.push({ ...codeKey(32, 5) });
        else if (cp < 27) ev.push({ ...codeKey(cp + 96, 5) });
        else if (cp < 32) continue;
        else ev.push({ type: "key", name: ch === " " ? "space" : ch.toLowerCase(), ch, ctrl: false, alt: false, shift: false });
    }
    return { ev, rest: buf.slice(i) };
}
const keyId = (k) => [k.ctrl && "ctrl", k.alt && "alt", k.shift && !k.ch && "shift", k.name].filter(Boolean).join("+");

let inBuf = "";
let escTimer = null;
process.stdin.on("data", (d) => {
    clearTimeout(escTimer);
    const { ev, rest } = parseInput(inBuf + d);
    inBuf = rest;
    for (const e of ev) handle(e);
    if (inBuf) escTimer = setTimeout(() => { if (inBuf === "\x1b") { inBuf = ""; handle(codeKey(27)); } }, 30);
});


// ── app state ───────────────────────────────────────────────────────────
const size = () => ({ W: out.columns || 100, H: out.rows || 30 });
const PROMPTS = { all: "all", agents: "agents", dirs: "dirs", browse: "browse" };
const pick = {
    mode: "all", items: [], loading: false, loadGen: 0,
    query: "", sel: 0, top: 0, view: [],
    help: false, preview: { key: "", text: "", label: "", scroll: 0 },
    lastClick: { t: 0, idx: -1 },
    geo: null,
    model: null,     // buildModel(state), for drag and drop
    drag: null,      // {paneId, what, x, y, active, dest}
    status: null,    // {text, until}: result of the last move, over the key hints
    flash: null,     // {paneId, t0}: the moved row, fading green
    phase: 0,        // animation tick
};

let renderQueued = false;
function render() {
    if (renderQueued) return;
    renderQueued = true;
    setImmediate(() => { renderQueued = false; draw(); });
}
out.on("resize", render);

// ── picker: rows from `connect-herdr.sh list MODE` (streamed, like fzf) ──
function loadList(mode, keepSel = false) {
    const gen = ++pick.loadGen;
    const prevSel = keepSel ? pick.sel : 0;
    pick.mode = mode;
    pick.items = [];
    pick.loading = true;
    if (!keepSel) { pick.sel = 0; pick.top = 0; }
    if (mode === "all") loadState();
    const p = spawn(SH, ["list", mode], { stdio: ["ignore", "pipe", "ignore"] });
    let partial = "";
    p.stdout.setEncoding("utf8");
    p.stdout.on("data", (chunk) => {
        if (gen !== pick.loadGen) return;
        const lines = (partial + chunk).split("\n");
        partial = lines.pop();
        for (const l of lines) if (l) pick.items.push(item(l));
        refilter(keepSel ? prevSel : pick.sel);
    });
    p.on("close", () => {
        if (gen !== pick.loadGen) return;
        if (partial) pick.items.push(item(partial));
        pick.loading = false;
        refilter(keepSel ? prevSel : pick.sel);
        // after a move: put the cursor on the moved split (once)
        const f = pick.flash;
        if (f && !f.placed) {
            f.placed = true;
            f.t0 = Date.now(); // fade from when it shows up, not from the move
            animate();
            const i = pick.view.findIndex((v) => v.it.kind === "pane" && v.it.target === f.paneId);
            if (i >= 0) { pick.sel = i; schedulePreview(); render(); }
        }
    });
}
function loadState() {
    execFile(SH, ["state"], { encoding: "utf8", maxBuffer: 16 << 20 }, (_e, so) => {
        try { pick.model = buildModel(JSON.parse(so)); } catch { /* keep the last one */ }
    });
}
function item(line) {
    const [display = "", kind = "", target = "", search = "", flag = ""] = line.split("\t");
    // more: a non-frecent zoxide dir, only listed while searching
    return { line, display, kind, target, search: strip(search).trim(), plain: strip(display), more: flag === "more" };
}

// fzf-ish: space-separated terms, each a fuzzy subsequence; smart case.
// Returns match positions (into text) plus a score: contiguous runs, word
// boundaries and earlier matches score higher, so top matches sort first.
function match(text, query) {
    const terms = query.split(/\s+/).filter(Boolean);
    const chars = Array.from(text);
    const pos = new Set();
    let score = 0;
    for (const term of terms) {
        const cs = term !== term.toLowerCase();
        const t = Array.from(cs ? term : term.toLowerCase());
        let ti = 0, prev = -2;
        const hit = [];
        for (let i = 0; i < chars.length && ti < t.length; i++) {
            const c = cs ? chars[i] : chars[i].toLowerCase();
            if (c !== t[ti]) continue;
            hit.push(i);
            score += i === prev + 1 ? 6 : -Math.min(i - prev - 1, 8);
            if (i === 0 || /[\s\-/_.]/.test(chars[i - 1] ?? "")) score += 10;
            score += 1;
            prev = i;
            ti++;
        }
        if (ti < t.length) return null;
        hit.forEach((h) => pos.add(h));
    }
    return { pos, score: score - text.length * 0.02 };
}
function refilter(sel = 0) {
    pick.view = [];
    for (const it of pick.items) {
        if (pick.query) {
            const m = match(it.search || it.plain, pick.query);
            if (!m) continue;
            const hl = match(it.plain, pick.query); // highlight only what's shown
            pick.view.push({ it, pos: hl ? hl.pos : new Set(), score: m.score });
        } else if (!it.more) {
            pick.view.push({ it, pos: new Set(), score: 0 });
        }
    }
    if (pick.query) pick.view.sort((a, b) => b.score - a.score); // best matches first
    pick.sel = Math.max(0, Math.min(sel, pick.view.length - 1));
    schedulePreview();
    render();
}
function highlight(display, pos) {
    if (!pos.size) return display;
    let out = "", idx = 0;
    for (const tok of display.match(TOKEN_RE) ?? []) {
        if (tok.length > 1 && tok[0] === "\x1b") { out += tok; continue; }
        out += pos.has(idx) ? `${sgr(1, 4)}${tok}${sgr(22, 24)}` : tok;
        idx++;
    }
    return out;
}
const current = () => pick.view[pick.sel]?.it;

// preview + border label: async, debounced, stale results dropped
let prevTimer = null;
let prevGen = 0;
const prevCache = new Map();
function schedulePreview() {
    clearTimeout(prevTimer);
    const it = current();
    if (pick.help) return;
    if (!it) { pick.preview = { key: "", text: "", label: "", scroll: 0 }; return; }
    if (pick.preview.key === it.line) return;
    const cached = prevCache.get(it.line);
    if (cached && Date.now() - cached.t < 3000) { pick.preview = { key: it.line, ...cached, scroll: 0 }; render(); return; }
    prevTimer = setTimeout(() => {
        const gen = ++prevGen;
        const got = { text: null, label: null };
        const done = () => {
            if (gen !== prevGen || got.text === null || got.label === null) return;
            prevCache.set(it.line, { ...got, t: Date.now() });
            pick.preview = { key: it.line, ...got, scroll: 0 };
            render();
        };
        const opt = { timeout: 5000, maxBuffer: 16 << 20, encoding: "utf8" };
        execFile(SH, ["preview", it.line], opt, (_e, so) => { got.text = so ?? ""; done(); });
        execFile(SH, ["label", it.line], opt, (_e, so) => { got.label = (so ?? "").replace(/\n/g, ""); done(); });
    }, 60);
}
function showHelp() {
    pick.help = true;
    execFile(SH, ["help"], { encoding: "utf8" }, (_e, so) => {
        pick.preview = { key: "?help", text: so ?? "", label: " help ", scroll: 0 };
        render();
    });
}
function moveSel(d) {
    if (!pick.view.length) return;
    pick.help = false;
    pick.sel = Math.max(0, Math.min(pick.view.length - 1, pick.sel + d));
    schedulePreview();
    render();
}

// ── drag and drop: names, targets, the move itself ──────────────────────
const wsName = (id) => pick.model?.ws.get(id)?.label ?? id;
const tabName = (id) => { const t = pick.model?.tab.get(id); return t ? `${wsName(t.wsId)} › tab ${t.position}` : id; };
const destText = (d) => !d ? "" : d.kind === "ws" ? `${wsName(d.wsId)} (new tab)` : `${tabName(d.tabId)} (split)`;
const paneWhat = (p) => p.agent || p.title || basename(p.cwd || "") || "shell";

// where a drop on view row idx lands: ws row → new tab; tab row, or a split
// under it → that tab; anything else → nowhere
function destAt(idx) {
    const it = pick.view[idx]?.it;
    if (!it) return null;
    if (it.kind === "ws") return { kind: "ws", wsId: it.target };
    let tab = it.kind === "tab" ? it : null;
    if (it.kind === "pane") for (let j = pick.items.indexOf(it) - 1; j >= 0 && !tab; j--) {
        if (pick.items[j].kind === "tab") tab = pick.items[j];
        else if (pick.items[j].kind !== "pane") break;
    }
    if (!tab) return null;
    return { kind: "tab", wsId: pick.model?.tab.get(tab.target)?.wsId ?? tab.target.split(":")[0], tabId: tab.target };
}
// view rows [first, last] framed for dest (its header row + everything under it)
function destRange(dest) {
    if (!dest) return null;
    const head = pick.view.findIndex(({ it }) => dest.kind === "ws" ? it.kind === "ws" && it.target === dest.wsId : it.kind === "tab" && it.target === dest.tabId);
    if (head < 0) return null;
    const under = dest.kind === "ws" ? ["tab", "pane"] : ["pane"];
    let last = head;
    while (pick.view[last + 1] && under.includes(pick.view[last + 1].it.kind)) last++;
    return [head, last];
}

function setStatus(text) {
    pick.status = { text, until: Date.now() + 2500 };
    setTimeout(render, 2600);
}
function herdr(argv) {
    if (DRY) return {};
    const so = execFileSync("herdr", argv, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 15000 });
    const res = JSON.parse(so || "{}");
    if (res.error) throw new Error(res.error.message ?? JSON.stringify(res.error));
    return res;
}
function log(line) {
    try { mkdirSync(LOG_DIR, { recursive: true }); appendFileSync(join(LOG_DIR, "moves.log"), line + "\n"); } catch { /* best effort */ }
}
function movePane(paneId, dest) {
    const p = pick.model.pane.get(paneId);
    const argv = moveArgv(paneId, dest);
    const stamp = new Date().toISOString();
    const what = `${shortId(paneId)} ${paneWhat(p)}`;
    try {
        const r = herdr(argv);
        const newId = r?.result?.move_result?.pane?.pane_id ?? null;
        log(`${stamp} ${DRY ? "DRY " : ""}ok   herdr ${argv.join(" ")}  → ${newId ?? "-"}`);
        setStatus(DRY ? fg(33, `dry run: herdr ${argv.join(" ")}`)
            : `${fg(32, "✓")} moved ${bold(what)} ${fg(ACCENT, "→")} ${destText(dest)}`);
        if (newId) { pick.flash = { paneId: newId, t0: Date.now() }; animate(); }
    } catch (e) {
        const msg = String(e.stderr || e.message || e).trim().split("\n")[0];
        log(`${stamp} fail herdr ${argv.join(" ")}  ${msg}`);
        setStatus(fg(31, `✗ couldn't move ${what}: ${msg}`));
    }
    prevCache.clear();
    pick.preview.key = "";
    loadList(pick.mode, true);
}

// ── animation: the drop frame + landing rectangle, the moved row's flash ─
const FLASH_MS = 900;
const PULSE = [53, 89, 125, 161, 197, 161, 125, 89]; // 256-color magenta ramp
const pulse = () => `38;5;${PULSE[pick.phase % PULSE.length]}`;
let animTimer = null;
function animate() {
    const want = !!pick.drag?.active || (!!pick.flash && Date.now() - pick.flash.t0 < FLASH_MS);
    if (want && !animTimer) animTimer = setInterval(() => { pick.phase++; animate(); render(); }, 80);
    else if (!want && animTimer) { clearInterval(animTimer); animTimer = null; render(); }
}

// w × h rectangle with marching ants (dashes run clockwise) and centered text
function antsRect(w, h, lines = []) {
    if (w < 4 || h < 3) return Array.from({ length: Math.max(0, h) }, () => " ".repeat(Math.max(0, w)));
    const col = pulse();
    const ant = (i, on, off) => (((i - pick.phase) % 4 + 4) % 4 < 3 ? on : off);
    const c = (s) => `${sgr(col)}${s}${sgr(39)}`;
    const P = 2 * w + 2 * h; // perimeter positions: top →, right ↓, bottom ←, left ↑
    const top = Array.from({ length: w - 2 }, (_, i) => ant(i + 1, "─", " ")).join("");
    const bot = Array.from({ length: w - 2 }, (_, i) => ant(w + h + (w - 2 - i), "─", " ")).join("");
    const first = Math.floor((h - 2 - lines.length) / 2);
    const rows = [c("╭" + top + "╮")];
    for (let r = 0; r < h - 2; r++) {
        const t = lines[r - first] ?? "";
        const pad = Math.max(0, Math.floor((w - 2 - width(t)) / 2));
        rows.push(c(ant(P - 1 - r, "│", " ")) + fit(" ".repeat(pad) + t, w - 2) + c(ant(w + r, "│", " ")));
    }
    rows.push(c("╰" + bot + "╯"));
    return rows;
}

// the preview panel while dragging: where the split will land
const destPv = { key: "", text: "" };
function fetchDestPreview(dest) {
    if (dest?.kind !== "tab") return;
    const key = `x\ttab\t${dest.tabId}`;
    if (destPv.key === key) return;
    destPv.key = key;
    destPv.text = prevCache.get(key)?.text ?? "";
    execFile(SH, ["preview", key], { timeout: 5000, maxBuffer: 16 << 20, encoding: "utf8" }, (_e, so) => {
        if (destPv.key !== key) return;
        destPv.text = so ?? "";
        render();
    });
}
function landingLines(d, iw, ih) {
    const chip = `${fg(ACCENT, bold(`⠿ ${shortId(d.paneId)} · ${d.what}`))}`;
    if (!d.dest) return Array.from({ length: ih }, (_, i) => i === Math.floor(ih / 2) - 1
        ? fit(" ".repeat(Math.max(0, Math.floor((iw - 44) / 2))) + dim("drop on a workspace (new tab) or a tab (split)"), iw) : "");
    if (d.dest.kind === "ws") {
        const tabs = (pick.model?.tabs ?? []).filter((t) => t.wsId === d.dest.wsId);
        const strip = " " + tabs.map((t) => dim(` ${t.position} `)).join(" ") + " " + fg(ACCENT, bold("[+]"));
        return [strip, "", ...antsRect(iw, ih - 2, [chip, "", dim(`new tab in ${wsName(d.dest.wsId)}`)])];
    }
    const lw = Math.floor(iw / 2);
    const left = sanitize(destPv.text).split("\n");
    const rect = antsRect(iw - lw - 1, ih, [chip, "", dim("splits in here")]);
    return rect.map((r, i) => fit(left[i] ?? "", lw) + dim("│") + r);
}

// ── draw ────────────────────────────────────────────────────────────────
function drawPick(W, H) {
    const narrow = W < 110;
    const listW = narrow ? W : W - Math.floor(W * 0.55);
    const listH = narrow ? H - Math.floor(H * 0.5) : H;
    const inner = listH - 2;
    const iw = listW - 2;
    const d = pick.drag?.active ? pick.drag : null;
    const status = pick.status && Date.now() < pick.status.until ? pick.status.text : null;
    const head = [
        `${fg(ACCENT, PROMPTS[pick.mode] + " › ")}${pick.query}${sgr(7)} ${sgr(27)}`,
        status ?? dim(`^a all  ^t agents  ^x dirs  ^f browse${pick.mode === "all" ? "  drag ⠿ to move" : ""}`),
        dim("^s new  ^b web  ^d close/forget  ? help"),
        dim("─".repeat(iw)),
    ];
    const info = dim(`${pick.loading ? "⋯ " : ""}${pick.view.length}/${pick.items.length}`);
    head[0] = slice(head[0], 0, listW - 3 - width(info));
    head[0] += " ".repeat(Math.max(1, listW - 2 - width(head[0]) - width(info))) + info;
    const rowsH = Math.max(1, inner - head.length);
    if (!d) { // while dragging, the list only scrolls at its edges
        if (pick.sel < pick.top) pick.top = pick.sel;
        if (pick.sel >= pick.top + rowsH) pick.top = pick.sel - rowsH + 1;
    }
    pick.top = Math.max(0, Math.min(pick.top, Math.max(0, pick.view.length - rowsH)));
    const range = d ? destRange(d.dest) : null;
    const flashAge = pick.flash ? Date.now() - pick.flash.t0 : Infinity;
    const flashBg = flashAge < FLASH_MS ? sgr(48, 5, [28, 28, 22, 22, 236][Math.floor(flashAge / (FLASH_MS / 5))]) : null;
    const rows = [];
    for (let i = 0; i < rowsH; i++) {
        const idx = pick.top + i;
        const v = pick.view[idx];
        if (!v) { rows.push(""); continue; }
        let text = highlight(v.it.display, v.pos);
        if (d && v.it.kind === "pane" && v.it.target === d.paneId) // the one being dragged
            text = `${sgr(2, 9)}${v.it.plain}${sgr(22, 29)}  ${dim("⇢ moving")}`;
        if (range && idx >= range[0] && idx <= range[1]) {
            const one = range[0] === range[1];
            const c = (s) => `${sgr(pulse())}${s}${sgr(39)}`;
            const edge = ((idx + pick.phase) % 3 === 0) ? "┆" : "│";
            const [l, r] = one ? ["[", "]"] : idx === range[0] ? ["╭", "╮"] : idx === range[1] ? ["╰", "╯"] : [edge, edge];
            if (idx === range[0]) text += "  " + fg(ACCENT, bold(d.dest.kind === "ws" ? "▶ new tab" : "▶ split"));
            rows.push(withBg(c(l) + " " + fit(text, iw - 3) + TARGET_BG + c(r), TARGET_BG));
        } else if (flashBg && v.it.kind === "pane" && v.it.target === pick.flash.paneId)
            rows.push(withBg("  " + fit(text, iw - 2) + flashBg, flashBg));
        else if (idx === pick.sel && !d) rows.push(withBg(fg(ACCENT, "▌") + " " + fit(text, iw - 2) + SEL_BG, SEL_BG));
        else rows.push("  " + text);
    }
    const left = box([...head, ...rows], listW, listH, " herdr sessions · ? help ", 90, ACCENT);
    const pw = narrow ? W : W - listW;
    const ph = narrow ? H - listH : H;
    const pv = d
        ? box(landingLines(d, pw - 2, ph - 2), pw, ph, d.dest ? ` drop → ${destText(d.dest)} ` : " move a split ", d.dest ? pulse() : 90, ACCENT)
        : box(sanitize(pick.preview.text).split("\n").slice(pick.preview.scroll), pw, ph, pick.preview.label);
    pick.geo = { listX: 1, listY: 1 + head.length, listW, rowsH, pvX: narrow ? 0 : listW, pvY: narrow ? listH : 0, pw, ph };
    const lines = narrow ? [...left, ...pv] : left.map((l, i) => l + pv[i]);
    // the dragged split follows the cursor as a chip (✗ over nowhere)
    if (d && d.y >= 0 && d.y < lines.length) {
        const chip = d.dest
            ? `${sgr(45, 30, 1)} ⠿ ${shortId(d.paneId)} · ${d.what} ${RESET}`
            : `${sgr(100, 37)} ✗ ${shortId(d.paneId)} · ${d.what} ${RESET}`;
        const x = Math.max(0, Math.min(d.x + 2, W - width(chip)));
        const l = lines[d.y];
        lines[d.y] = slice(l, 0, x) + RESET + chip + slice(l, x + width(chip), W);
    }
    return lines;
}

// ── keys + mouse ────────────────────────────────────────────────────────
function pickKey(k) {
    const id = keyId(k);
    if (pick.drag && (id === "escape" || id === "ctrl+c")) { pick.drag = null; animate(); return render(); }
    switch (id) {
        case "escape": case "ctrl+c": case "ctrl+q": return quit(0);
        case "enter": return choose();
        case "tab": case "ctrl+n": case "down": return moveSel(1);
        case "shift+tab": case "ctrl+p": case "up": return moveSel(-1);
        case "pagedown": return moveSel(pick.geo?.rowsH ?? 10);
        case "pageup": return moveSel(-(pick.geo?.rowsH ?? 10));
        case "ctrl+a": return loadList("all");
        case "ctrl+t": return loadList("agents");
        case "ctrl+x": return loadList("dirs");
        case "ctrl+f": return loadList("browse");
        case "ctrl+s": return scratch();
        case "ctrl+b": return quit(handOff(SH, ["browser"]).status ?? 0);
        case "ctrl+d": {
            const it = current();
            if (!it) return;
            execFile(SH, ["kill", it.line], () => { prevCache.clear(); pick.preview.key = ""; loadList(pick.mode, true); });
            return;
        }
        case "ctrl+u": pick.query = ""; return refilter();
        case "ctrl+w": pick.query = pick.query.replace(/\S*\s*$/, ""); return refilter();
        case "backspace": pick.query = Array.from(pick.query).slice(0, -1).join(""); return refilter();
        case "?": return showHelp();
    }
    if (k.ch && !k.ctrl && !k.alt) { pick.query += k.ch; refilter(); }
    else if (k.name === "space") { pick.query += " "; refilter(); }
}
function choose() {
    const it = current();
    if (!it || it.kind === "none") return;
    quit(handOff(SH, ["go", it.line]).status ?? 0);
}
function scratch() {
    termStop();
    const r = spawnSync(SCRATCH, [], { stdio: ["inherit", "pipe", "inherit"], encoding: "utf8" });
    const path = (r.stdout ?? "").trim();
    if (r.status === 0 && path) spawnSync(SH, ["go", path], { stdio: "inherit" });
    process.exit(0);
}
function pickMouse(m) {
    const g = pick.geo;
    if (!g) return;
    const rowIdx = (y) => (m.x < g.listW && y >= g.listY && y < g.listY + g.rowsH ? pick.top + (y - g.listY) : -1);
    const inPv = m.x >= g.pvX && m.y >= g.pvY && m.x < g.pvX + g.pw && m.y < g.pvY + g.ph;
    if (m.b === 64 || m.b === 65) { // wheel
        const dir = m.b === 64 ? -1 : 1;
        if (inPv && !pick.drag) { pick.preview.scroll = Math.max(0, pick.preview.scroll + dir * 3); render(); }
        else if (pick.drag) { pick.top = Math.max(0, pick.top + dir * 2); render(); }
        else moveSel(dir);
        return;
    }
    const d = pick.drag;
    if (m.b & 32) { // motion while a button is held (1002)
        if (!d) return;
        d.active = true;
        d.x = m.x; d.y = m.y;
        if (m.y <= g.listY && pick.top > 0) pick.top--;                                        // edge auto-scroll
        else if (m.y >= g.listY + g.rowsH - 1 && pick.top + g.rowsH < pick.view.length) pick.top++;
        const idx = rowIdx(m.y);
        const dest = idx >= 0 ? destAt(idx) : null;
        d.dest = dest && !isNoop(pick.model, d.paneId, dest) ? dest : null;
        fetchDestPreview(d.dest);
        animate();
        render();
        return;
    }
    if (m.release) {
        pick.drag = null;
        if (d?.active) {
            if (d.dest) movePane(d.paneId, d.dest);
            animate();
            render();
        }
        return;
    }
    const idx = rowIdx(m.y);
    if (m.b !== 0 || idx < 0 || idx >= pick.view.length) return;
    const now = Date.now();
    const dbl = pick.lastClick.idx === idx && now - pick.lastClick.t < 400;
    pick.lastClick = { t: now, idx };
    pick.help = false;
    pick.sel = idx;
    // a press on a split arms a drag; it starts once the mouse moves
    const it = pick.view[idx].it;
    const p = it.kind === "pane" ? pick.model?.pane.get(it.target) : null;
    if (p) pick.drag = { paneId: p.id, what: paneWhat(p), x: m.x, y: m.y, active: false, dest: null };
    schedulePreview();
    render();
    if (dbl) { pick.drag = null; choose(); }
}

// ── dispatch ────────────────────────────────────────────────────────────
function handle(e) {
    if (e.type === "mouse") return pickMouse(e);
    if (e.type === "key") return pickKey(e);
}
function draw() {
    if (!termOn) return;
    const { W, H } = size();
    const lines = drawPick(W, H).slice(0, H);
    while (lines.length < H) lines.push("");
    out.write(`${E}?2026h${E}H` + lines.map((l) => fit(l, W)).join("\r\n") + `${E}?2026l`);
}

termStart();
loadList("all");
render();
