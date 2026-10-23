// The picker: terminal handling, keys + SGR mouse, async list/preview workers,
// drag & drop, and the renderer. Port of herdr-picker.mjs, with the default
// view drawn in the kitchen-sink design language (accent marks selection,
// status hues mark state, dim meta, the cursor row carries the accent edge).

use crate::ansi;
use crate::config::Config;
use crate::data::{self, Item, ItemKind, PreviewPart};
use crate::fuzzy;
use crate::links::{self, Group, GroupStatus, LinkErr, LinkRow};
use crate::model::{Dest, Model, Pane};
use crate::proc;
use crate::style::Style;
use crate::ui;
use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, MouseButton, MouseEvent, MouseEventKind,
};
use crossterm::terminal;
use std::collections::HashMap;
use std::io::{IsTerminal, Write};
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

static SIGNAL: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_signal(sig: i32) {
    SIGNAL.store(sig, Ordering::SeqCst);
}

pub fn install_signals() {
    unsafe {
        libc::signal(libc::SIGHUP, on_signal as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_signal as libc::sighandler_t);
        libc::signal(libc::SIGINT, on_signal as libc::sighandler_t);
    }
}

/// Bumped by the event loop on every pass. If it stops advancing the loop is
/// wedged: when the shell that launched the popup dies, crossterm's reader can
/// spin forever in `read()` on the revoked tty (returning EIO instead of
/// blocking) and never return to the loop that checks SIGNAL, so SIGTERM is
/// ignored too. The watchdog notices the stalled heartbeat and leaves instead
/// of burning a core for days.
static HEARTBEAT: AtomicU64 = AtomicU64::new(0);

fn spawn_watchdog() {
    const TICK_MS: u64 = 250;
    const STUCK_MS: u64 = 5000;
    std::thread::spawn(|| {
        let mut last = HEARTBEAT.load(Ordering::Relaxed);
        let mut stuck = 0u64;
        loop {
            std::thread::sleep(Duration::from_millis(TICK_MS));
            let now = HEARTBEAT.load(Ordering::Relaxed);
            if now == last {
                stuck += TICK_MS;
                if stuck >= STUCK_MS {
                    let _ = crossterm::terminal::disable_raw_mode();
                    std::process::exit(1);
                }
            } else {
                stuck = 0;
                last = now;
            }
        }
    });
}

enum Msg {
    List {
        gen: u64,
        items: Vec<Item>,
        model: Option<Model>,
    },
    Preview {
        key: String,
        parts: Vec<PreviewPart>,
        label: String,
    },
    DestPreview {
        key: String,
        text: String,
    },
    /// kitchen-sink's places arrived (or didn't) for the link group.
    Links(Result<Vec<LinkRow>, LinkErr>),
}

#[derive(Clone, Debug)]
struct ViewRow {
    it: Item,
    pos: Vec<usize>,
    score: f64,
}

#[derive(Clone, Debug, Default)]
struct Preview {
    key: String,
    label: String,
    scroll: usize,
    parts: Vec<PreviewPart>,
}

#[derive(Clone, Debug)]
struct Status {
    text: String,
    until: Instant,
}

#[derive(Clone, Debug)]
struct Drag {
    pane_id: String,
    tab_id: Option<String>,
    what: String,
    x: i64,
    y: i64,
    x0: i64,
    y0: i64,
    active: bool,
    dest: Option<Dest>,
    kb: bool,
}

#[derive(Clone, Debug)]
struct Flash {
    pane_id: String,
    t0: Instant,
    placed: bool,
}

#[derive(Clone, Debug)]
struct Undo {
    pane_id: String,
    dest: Dest,
}

#[derive(Clone, Copy, Debug, Default)]
struct Geo {
    list_y: usize,
    list_w: usize,
    rows_h: usize,
    pv_x: usize,
    pv_y: usize,
    pw: usize,
    ph: usize,
}

struct Term {
    active: bool,
}

impl Term {
    fn enter() -> Result<Term, String> {
        terminal::enable_raw_mode().map_err(|e| format!("raw mode: {e}"))?;
        let mut out = std::io::stdout();
        let _ = out.write_all(b"\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1002h\x1b[?1006h\x1b[>1u");
        let _ = out.flush();
        Ok(Term { active: true })
    }

    fn restore(&mut self) {
        if !self.active {
            return;
        }
        self.active = false;
        let mut out = std::io::stdout();
        let _ = out.write_all(b"\x1b[<u\x1b[?1006l\x1b[?1002l\x1b[?7h\x1b[?25h\x1b[0m\x1b[?1049l");
        let _ = out.flush();
        let _ = terminal::disable_raw_mode();
    }

    fn size(&self) -> (usize, usize) {
        terminal::size()
            .map(|(w, h)| (w as usize, h as usize))
            .unwrap_or((100, 30))
    }

    fn draw(&self, frame: &str) {
        let mut out = std::io::stdout();
        let _ = out.write_all(format!("\x1b[?2026h\x1b[H{frame}\x1b[?2026l").as_bytes());
        let _ = out.flush();
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        self.restore();
    }
}

pub struct App {
    cfg: Config,
    st: Style,
    tx: Sender<Msg>,
    rx: Receiver<Msg>,
    term: Term,
    mode: String,
    sort: String,
    expanded: bool,
    items: Vec<Item>,
    view: Vec<ViewRow>,
    query: String,
    sel: usize,
    top: usize,
    loading: bool,
    load_gen: u64,
    pending_sel: usize,
    model: Model,
    help: bool,
    preview: Preview,
    status: Option<Status>,
    drag: Option<Drag>,
    moving: bool,
    flash: Option<Flash>,
    undo: Option<Undo>,
    phase: u64,
    last_tick: Instant,
    geo: Geo,
    last_click: (Instant, i64),
    pending_preview: Option<(String, Item, Instant)>,
    prev_cache: HashMap<String, (Instant, Vec<PreviewPart>, String)>,
    inflight: HashMap<String, Instant>,
    sel_settled: Instant,
    prefetch_left: i64,
    dest_key: String,
    dest_text: String,
    pending_dest: Option<(String, Instant)>,
    dirty: bool,
    dry_run: bool,
    quit_code: Option<i32>,
    /// The link group (kitchen-sink's places) under the local rows.
    group: Group,
    /// The last refilter had a query (clearing it restores the group's default).
    group_had_query: bool,
    /// Rows of the pinned link group at the top of `view` (header + links).
    group_len: usize,
    /// kitchen-sink exists here (else no group, no fetch).
    ks_installed: bool,
}

pub fn run(cfg: Config) -> i32 {
    if !std::io::stdin().is_terminal() {
        eprintln!("{}", cfg.text("needs_terminal"));
        return 1;
    }
    let st = Style::new(&cfg);
    let term = match Term::enter() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };
    let (tx, rx) = channel();
    let dry = std::env::var("HERDR_PICKER_DRY_RUN").ok().as_deref() == Some("1");
    let mut app = App {
        cfg,
        st,
        tx,
        rx,
        term,
        mode: "ws".to_string(),
        sort: "recent".to_string(),
        expanded: false,
        items: Vec::new(),
        view: Vec::new(),
        query: String::new(),
        sel: 0,
        top: 0,
        loading: false,
        load_gen: 0,
        pending_sel: 0,
        model: Model::default(),
        help: false,
        preview: Preview::default(),
        status: None,
        drag: None,
        moving: false,
        flash: None,
        undo: None,
        phase: 0,
        last_tick: Instant::now(),
        geo: Geo::default(),
        last_click: (Instant::now(), -1),
        pending_preview: None,
        prev_cache: HashMap::new(),
        inflight: HashMap::new(),
        sel_settled: Instant::now(),
        prefetch_left: 0,
        dest_key: String::new(),
        dest_text: String::new(),
        pending_dest: None,
        dirty: true,
        dry_run: dry,
        quit_code: None,
        group: Group::new(None, false, Vec::new()),
        group_had_query: false,
        group_len: 0,
        ks_installed: false,
    };
    app.ks_installed = links::ks_installed(&app.cfg);
    let expanded = app.group_default_expanded();
    let names = app
        .cfg
        .links
        .get("group_names")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|n| n.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    app.group = Group::new(links::load_cache(&app.cfg), expanded, names);
    app.load_list("ws", false);
    app.fetch_links();
    spawn_watchdog();
    loop {
        HEARTBEAT.fetch_add(1, Ordering::Relaxed);
        // stdin gone (redirected away, or the popup's tty revoked under us):
        // no real input can arrive, so leave instead of spinning on it.
        if !std::io::stdin().is_terminal() {
            app.quit_code = Some(1);
            break;
        }
        let sig = SIGNAL.load(Ordering::SeqCst);
        if sig != 0 {
            app.quit_code = Some(128 + sig);
            break;
        }
        app.pump();
        app.tick();
        let timeout = app.poll_timeout();
        if event::poll(Duration::from_millis(timeout)).unwrap_or(false) {
            if let Ok(ev) = event::read() {
                app.on_event(ev);
            }
        }
        if app.dirty {
            app.draw();
            app.dirty = false;
        }
        if let Some(code) = app.quit_code {
            let _ = code;
            break;
        }
    }
    let code = app.quit_code.unwrap_or(0);
    app.term.restore();
    code
}

impl App {
    fn pump(&mut self) {
        while let Ok(msg) = self.rx.try_recv() {
            match msg {
                Msg::List { gen, items, model } => {
                    if gen != self.load_gen {
                        continue;
                    }
                    self.items = items;
                    if let Some(m) = model {
                        self.model = m;
                    }
                    self.loading = false;
                    self.refilter(self.pending_sel);
                    self.place_flash();
                }
                Msg::Preview { key, parts, label } => {
                    self.inflight.remove(&key);
                    self.prev_cache
                        .insert(key.clone(), (Instant::now(), parts.clone(), label.clone()));
                    let cur = self.current().map(|i| i.key());
                    if !self.help && cur.as_deref() == Some(key.as_str()) {
                        if self.preview.key == key {
                            // refresh of the item already shown: keep the scroll
                            self.preview.parts = parts;
                            self.preview.label = label;
                        } else {
                            self.preview = Preview {
                                key,
                                parts,
                                label,
                                scroll: 0,
                            };
                        }
                        self.dirty = true;
                    }
                }
                Msg::DestPreview { key, text } => {
                    self.inflight.remove(&key);
                    if key == self.dest_key {
                        self.dest_text = text;
                        self.dirty = true;
                    }
                }
                Msg::Links(result) => {
                    if let Ok(rows) = &result {
                        links::save_cache(&self.cfg, rows);
                    }
                    self.group.apply(result);
                    self.refilter_keep_current();
                }
            }
        }
    }

    fn tick(&mut self) {
        let now = Instant::now();
        if let Some((key, item, deadline)) = self.pending_preview.clone() {
            if now >= deadline {
                self.pending_preview = None;
                self.spawn_fetch(key, item);
            }
        }
        if let Some((key, deadline)) = self.pending_dest.clone() {
            if now >= deadline {
                self.pending_dest = None;
                self.spawn_dest_preview(key);
            }
        }
        if let Some(s) = &self.status {
            if now >= s.until {
                self.status = None;
                self.dirty = true;
            }
        }
        let anim_ms = self.cfg.num("anim_ms", 80).max(16) as u64;
        if self.animating() && now.duration_since(self.last_tick).as_millis() as u64 >= anim_ms {
            self.phase = self.phase.wrapping_add(1);
            self.last_tick = now;
            self.dirty = true;
        }
        self.prefetch(now);
        // a fetch thread that never answered must not keep the loop awake
        self.inflight
            .retain(|_, t| now.duration_since(*t) < Duration::from_secs(15));
    }

    /// poll timeout: stay awake while anything async is in flight so finished
    /// workers are drawn within a few ms instead of waiting for the idle tick
    fn poll_timeout(&self) -> u64 {
        if self.animating() {
            return self.cfg.num("anim_ms", 80).max(16) as u64;
        }
        if self.loading || self.pending_preview.is_some() || !self.inflight.is_empty() {
            return self.cfg.num("poll_active_ms", 15).max(1) as u64;
        }
        self.cfg.num("poll_idle_ms", 200).max(16) as u64
    }

    /// after the cursor settles, warm the cache for the adjacent rows so
    /// arrow-down/up shows the preview instantly
    fn prefetch(&mut self, now: Instant) {
        if self.prefetch_left <= 0 || self.help || self.pending_preview.is_some() {
            return;
        }
        let delay = self.cfg.num("preview_prefetch_delay_ms", 120).max(0) as u64;
        if (now.duration_since(self.sel_settled).as_millis() as u64) < delay {
            return;
        }
        let ttl = self.cfg.num("preview_cache_ms", 3000).max(0) as u128;
        let n = self.cfg.num("preview_prefetch", 1).max(0) as i64;
        let cur = self.current().map(|i| i.key());
        let mut candidates: Vec<Item> = Vec::new();
        for step in 1..=n {
            for dir in [1i64, -1i64] {
                let idx = self.sel as i64 + dir * step;
                if idx < 0 || idx as usize >= self.view.len() {
                    continue;
                }
                let it = &self.view[idx as usize].it;
                if !matches!(it.kind, ItemKind::Group | ItemKind::Link) {
                    candidates.push(it.clone());
                }
            }
        }
        for it in candidates {
            if self.prefetch_left <= 0 {
                break;
            }
            let key = it.key();
            if cur.as_deref() == Some(key.as_str()) || self.inflight.contains_key(&key) {
                continue;
            }
            if let Some((t, _, _)) = self.prev_cache.get(&key) {
                if t.elapsed().as_millis() < ttl {
                    continue;
                }
            }
            self.spawn_fetch(key, it);
            self.prefetch_left -= 1;
        }
    }

    fn animating(&self) -> bool {
        if let Some(d) = &self.drag {
            if d.active {
                return true;
            }
        }
        if let Some(f) = &self.flash {
            let ms = self.cfg.num("flash_ms", 900).max(1) as u128;
            return f.t0.elapsed().as_millis() < ms;
        }
        false
    }

    fn draw(&mut self) {
        let (w, h) = self.term.size();
        let mut lines = self.draw_pick(w, h);
        lines.truncate(h);
        while lines.len() < h {
            lines.push(String::new());
        }
        let mut frame = String::new();
        for (i, l) in lines.iter().enumerate() {
            if i > 0 {
                frame.push_str("\r\n");
            }
            frame.push_str(&ansi::fit(l, w));
        }
        self.term.draw(&frame);
    }

    fn on_event(&mut self, ev: Event) {
        match ev {
            Event::Key(k) => {
                if k.kind != KeyEventKind::Release {
                    self.on_key(k);
                }
            }
            Event::Mouse(m) => self.on_mouse(m),
            Event::Resize(_, _) => self.dirty = true,
            _ => {}
        }
    }

    // ── keys ────────────────────────────────────────────────────────────

    fn on_key(&mut self, k: KeyEvent) {
        let ctrl = k.modifiers.contains(crossterm::event::KeyModifiers::CONTROL);
        let alt = k.modifiers.contains(crossterm::event::KeyModifiers::ALT);
        let shift = k.modifiers.contains(crossterm::event::KeyModifiers::SHIFT);
        let ch: Option<char>;
        let name: String = match k.code {
            KeyCode::Char(c) => {
                ch = Some(c);
                if c == ' ' {
                    "space".into()
                } else {
                    c.to_lowercase().to_string()
                }
            }
            KeyCode::Esc => {
                ch = None;
                "escape".into()
            }
            KeyCode::Enter => {
                ch = None;
                "enter".into()
            }
            KeyCode::Tab => {
                ch = None;
                "tab".into()
            }
            KeyCode::BackTab => {
                ch = None;
                "tab".into()
            }
            KeyCode::Backspace => {
                ch = None;
                "backspace".into()
            }
            KeyCode::Delete => {
                ch = None;
                "delete".into()
            }
            KeyCode::Insert => {
                ch = None;
                "insert".into()
            }
            KeyCode::Home => {
                ch = None;
                "home".into()
            }
            KeyCode::End => {
                ch = None;
                "end".into()
            }
            KeyCode::PageUp => {
                ch = None;
                "pageup".into()
            }
            KeyCode::PageDown => {
                ch = None;
                "pagedown".into()
            }
            KeyCode::Up => {
                ch = None;
                "up".into()
            }
            KeyCode::Down => {
                ch = None;
                "down".into()
            }
            KeyCode::Left => {
                ch = None;
                "left".into()
            }
            KeyCode::Right => {
                ch = None;
                "right".into()
            }
            KeyCode::F(n) => {
                ch = None;
                format!("f{n}")
            }
            _ => {
                ch = None;
                "unknown".into()
            }
        };
        let mut ch = ch;
        let is_backtab = matches!(k.code, KeyCode::BackTab);
        if name == "space" && (ctrl || alt) {
            ch = None;
        }
        let mut parts: Vec<String> = Vec::new();
        if ctrl {
            parts.push("ctrl".into());
        }
        if alt {
            parts.push("alt".into());
        }
        if ch.is_none() && (shift || is_backtab) {
            parts.push("shift".into());
        }
        parts.push(name.clone());
        let id = parts.join("+");

        if self.moving {
            let action = self.cfg.keys.move_keymap.get(&id).cloned();
            match action.as_deref() {
                Some("cancel") => self.end_move(false),
                Some("drop") => self.end_move(true),
                Some("next") => self.move_move_sel(1),
                Some("prev") => self.move_move_sel(-1),
                _ => {}
            }
            return;
        }
        if self.drag.is_some() && (id == "escape" || id == "ctrl+c") {
            self.drag = None;
            self.dirty = true;
            return;
        }
        // h / l on the group are vim moves only with no query: while typing
        // (`kitchen-sink`, `ks fil`) a letter is a letter.
        let typing = ch.is_some() && !ctrl && !alt && !self.query.is_empty();
        let local = match self.current().map(|i| i.kind) {
            _ if typing => None,
            Some(ItemKind::Group) => self.cfg.keys.group_keymap.get(&id).cloned(),
            Some(ItemKind::Link) => self.cfg.keys.link_keymap.get(&id).cloned(),
            _ => None,
        };
        if let Some(action) = local.or_else(|| self.cfg.keys.keymap.get(&id).cloned()) {
            self.do_action(&action);
            return;
        }
        if let Some(c) = ch {
            if !ctrl && !alt {
                self.query.push(c);
                self.refilter(0);
            }
        } else if name == "space" {
            self.query.push(' ');
            self.refilter(0);
        }
    }

    fn do_action(&mut self, action: &str) {
        match action {
            "quit" => self.quit_code = Some(0),
            "choose" => self.choose(),
            "down" => self.move_sel(1),
            "up" => self.move_sel(-1),
            "page-down" => {
                let n = self.cfg.num("kb_page_lines", 10);
                self.move_sel(n)
            }
            "page-up" => {
                let n = self.cfg.num("kb_page_lines", 10);
                self.move_sel(-n)
            }
            "expand" => {
                if self.mode == "all" || self.mode == "ws" {
                    self.toggle_expanded();
                }
            }
            "sort" => {
                let sorts = self.cfg.ui.sorts.clone();
                let i = sorts.iter().position(|s| s == &self.sort).unwrap_or(0);
                self.sort = sorts[(i + 1) % sorts.len()].clone();
                let msg = proc::subst_str(&self.cfg.text("sorted"), &[("sort", &self.sort)]);
                self.set_status(&msg);
                let mode = self.mode.clone();
                self.load_list(&mode, true);
            }
            "scratch" => self.do_scratch(),
            "browser" => {
                self.term.restore();
                let _ = data::browser(&self.cfg, &self.st);
                self.quit_code = Some(0);
            }
            "kill" => self.do_kill(),
            "clear-query" => {
                self.query.clear();
                self.refilter(0);
            }
            "delete-word" => {
                let trimmed = self.query.trim_end();
                let cut = trimmed
                    .char_indices()
                    .rev()
                    .find(|(_, c)| c.is_whitespace())
                    .map(|(i, _)| i + 1)
                    .unwrap_or(0);
                self.query.truncate(cut);
                self.refilter(0);
            }
            "backspace" => {
                self.query.pop();
                self.refilter(0);
            }
            "help" => self.show_help(),
            "undo" => self.undo_move(),
            "start-move" => self.start_move(),
            "links-jump" => self.links_jump(),
            "group-open" => self.group_set(true),
            "group-close" => self.group_set(false),
            "group-toggle" => self.group_toggle(),
            a if a.starts_with("mode:") => {
                let m = a[5..].to_string();
                if m == "ws" {
                    self.expanded = false;
                    self.query.clear();
                    self.help = false;
                }
                self.load_list(&m, false);
            }
            _ => {}
        }
    }

    fn move_sel(&mut self, d: i64) {
        if self.view.is_empty() {
            return;
        }
        self.help = false;
        let max = self.view.len() as i64 - 1;
        self.sel = if d.abs() == 1 && self.group_len > 0 {
            // with the pinned group, ↑ / ↓ wrap through the whole list
            links::step(self.view.len(), self.sel, d)
        } else {
            (self.sel as i64 + d).clamp(0, max) as usize
        };
        self.schedule_preview();
        self.dirty = true;
    }

    fn current(&self) -> Option<&Item> {
        self.view.get(self.sel).map(|v| &v.it)
    }

    fn set_status(&mut self, text: &str) {
        let ms = self.cfg.num("status_ms", 2500).max(1) as u64;
        self.status = Some(Status {
            text: text.to_string(),
            until: Instant::now() + Duration::from_millis(ms),
        });
        self.dirty = true;
    }

    // ── list ────────────────────────────────────────────────────────────

    fn load_list(&mut self, mode: &str, keep_sel: bool) {
        self.load_gen += 1;
        let gen = self.load_gen;
        self.pending_sel = if keep_sel { self.sel } else { 0 };
        self.mode = mode.to_string();
        self.items.clear();
        self.loading = true;
        if !keep_sel {
            self.sel = 0;
            self.top = 0;
        }
        let cfg = self.cfg.clone();
        let st = self.st.clone();
        let mode = mode.to_string();
        let sort = self.sort.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let (items, model) = match data::list_items(&cfg, &st, &mode, &sort) {
                Ok((items, model)) => (items, Some(model)),
                Err(_) => (Vec::new(), None),
            };
            let _ = tx.send(Msg::List { gen, items, model });
        });
        self.dirty = true;
    }

    fn refilter(&mut self, keep_sel: usize) {
        self.view.clear();
        let query = self.query.clone();
        for it in &self.items {
            if !self.expanded && (it.kind == ItemKind::Tab || it.kind == ItemKind::Pane) {
                continue;
            }
            if !query.is_empty() {
                let hay = if it.search.is_empty() {
                    it.plain.clone()
                } else {
                    it.search.clone()
                };
                match fuzzy::fuzzy_match(&hay, &query) {
                    Some((_, score)) => {
                        let pos = fuzzy::fuzzy_match(&it.plain, &query)
                            .map(|(p, _)| p)
                            .unwrap_or_default();
                        self.view.push(ViewRow {
                            it: it.clone(),
                            pos,
                            score,
                        });
                    }
                    None => continue,
                }
            } else if !it.more {
                self.view.push(ViewRow {
                    it: it.clone(),
                    pos: Vec::new(),
                    score: 0.0,
                });
            }
        }
        if !query.is_empty() {
            self.view
                .sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        }
        let mut rows = self.group_rows(&query);
        self.group_len = rows.len();
        rows.append(&mut self.view);
        self.view = rows;
        let max = self.view.len().saturating_sub(1);
        // 0 = "from the top": the cursor's start for this query
        self.sel = if keep_sel == 0 { self.start_sel(&query) } else { keep_sel.min(max) };
        self.schedule_preview();
        self.place_flash_cursor();
        self.dirty = true;
    }

    fn place_flash(&mut self) {
        let ms = self.cfg.num("flash_ms", 900).max(1) as u128;
        let pane = match &self.flash {
            Some(f) if !f.placed && f.t0.elapsed().as_millis() < ms => f.pane_id.clone(),
            _ => return,
        };
        if let Some(i) = self
            .view
            .iter()
            .position(|v| v.it.kind == ItemKind::Pane && v.it.target == pane)
        {
            if let Some(f) = &mut self.flash {
                f.placed = true;
                f.t0 = Instant::now();
            }
            self.sel = i;
            self.schedule_preview();
            self.dirty = true;
        }
    }

    fn place_flash_cursor(&mut self) {
        // keep the cursor on the same row when the list reloads (post-move)
        if let Some(f) = &self.flash {
            if f.placed {
                if let Some(i) = self
                    .view
                    .iter()
                    .position(|v| v.it.kind == ItemKind::Pane && v.it.target == f.pane_id)
                {
                    self.sel = i;
                }
            }
        }
    }

    // ── preview ─────────────────────────────────────────────────────────

    fn schedule_preview(&mut self) {
        if self.help {
            return;
        }
        let it = match self.current() {
            Some(i) => i.clone(),
            None => {
                self.preview = Preview::default();
                self.dirty = true;
                return;
            }
        };
        let key = it.key();
        if self.preview.key == key {
            return;
        }
        if matches!(it.kind, ItemKind::Group | ItemKind::Link) {
            self.preview = self.group_preview(&it);
            self.pending_preview = None;
            self.dirty = true;
            return;
        }
        self.sel_settled = Instant::now();
        self.prefetch_left = self.cfg.num("preview_prefetch", 1);
        let cache_ms = self.cfg.num("preview_cache_ms", 3000).max(0) as u128;
        if let Some((t, parts, label)) = self.prev_cache.get(&key) {
            // stale-while-revalidate: draw what we have right away
            self.preview = Preview {
                key: key.clone(),
                parts: parts.clone(),
                label: label.clone(),
                scroll: 0,
            };
            self.dirty = true;
            if t.elapsed().as_millis() < cache_ms {
                self.pending_preview = None;
                return;
            }
        }
        let debounce = self.cfg.num("preview_debounce_ms", 15).max(0) as u64;
        self.pending_preview = Some((
            key,
            it,
            Instant::now() + Duration::from_millis(debounce),
        ));
    }

    fn spawn_fetch(&mut self, key: String, item: Item) {
        self.inflight.insert(key.clone(), Instant::now());
        let cfg = self.cfg.clone();
        let st = self.st.clone();
        let model = self.model.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let parts = data::preview_parts(&cfg, &st, &model, &item);
            let label = if parts.len() > 1 {
                data::grid_label(&cfg, &model, &item, parts.len())
            } else {
                data::label_for(&cfg, &st, &model, &item)
            };
            let _ = tx.send(Msg::Preview { key, parts, label });
        });
    }

    fn fetch_dest_preview(&mut self, dest: &Dest) {
        if !dest.is_tab() {
            return;
        }
        let key = format!("x\ttab\t{}", dest.tab_id().unwrap_or(""));
        if self.dest_key == key {
            return;
        }
        self.dest_key = key.clone();
        self.dest_text = String::new();
        self.pending_dest = Some((key, Instant::now()));
    }

    fn spawn_dest_preview(&mut self, key: String) {
        self.inflight.insert(key.clone(), Instant::now());
        let cfg = self.cfg.clone();
        let st = self.st.clone();
        let model = self.model.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let text = data::preview_for_key(&cfg, &st, &model, &key);
            let _ = tx.send(Msg::DestPreview { key, text });
        });
    }

    fn show_help(&mut self) {
        self.help = true;
        let label = if self.cfg.ui.help_label.is_empty() {
            " help ".to_string()
        } else {
            self.cfg.ui.help_label.clone()
        };
        self.preview = Preview {
            key: "?help".into(),
            parts: vec![PreviewPart {
                title: String::new(),
                text: data::help_text(&self.cfg, &self.st),
            }],
            label,
            scroll: 0,
        };
        self.dirty = true;
    }

    // ── expansion / movement ────────────────────────────────────────────

    fn toggle_expanded(&mut self) {
        let cur = self.current().cloned();
        self.expanded = !self.expanded;
        if self.expanded {
            let key = self.cfg.text("drag_status_key");
            let text = proc::subst_str(&self.cfg.text("drag_status"), &[("key", &key)]);
            self.set_status(&text);
        }
        let sel = self.sel;
        self.refilter(sel);
        if let Some(cur) = cur {
            let ws = cur.target.split(':').next().unwrap_or("").to_string();
            let mut i = self.view.iter().position(|v| v.it.line == cur.line);
            if i.is_none() {
                i = self
                    .view
                    .iter()
                    .position(|v| v.it.kind == ItemKind::Ws && v.it.target == ws);
            }
            if let Some(i) = i {
                self.sel = i;
                self.schedule_preview();
            }
        }
        self.dirty = true;
    }

    fn pane_what(&self, p: &Pane) -> String {
        data::pane_what(&self.cfg, &self.model, p)
    }

    fn drag_for(&self, it: &Item, x: i64, y: i64) -> Option<Drag> {
        let base = Drag {
            pane_id: String::new(),
            tab_id: None,
            what: String::new(),
            x,
            y,
            x0: x,
            y0: y,
            active: false,
            dest: None,
            kb: false,
        };
        match it.kind {
            ItemKind::Pane => {
                let p = self.model.pane(&it.target)?;
                Some(Drag {
                    pane_id: p.id.clone(),
                    what: self.pane_what(p),
                    ..base
                })
            }
            ItemKind::Tab => {
                let t = self.model.tab(&it.target)?;
                let ids: Vec<String> = self
                    .model
                    .panes_of(&t.id)
                    .iter()
                    .map(|p| p.id.clone())
                    .collect();
                let first = self.model.pane(ids.first()?)?;
                let n = ids.len();
                let what = if n > 1 {
                    proc::subst_str(&self.cfg.ui.splits_fmt, &[("n", &n.to_string())])
                } else {
                    self.pane_what(first)
                };
                Some(Drag {
                    pane_id: first.id.clone(),
                    tab_id: Some(t.id.clone()),
                    what,
                    ..base
                })
            }
            _ => None,
        }
    }

    fn drag_label(&self, d: &Drag) -> String {
        let id = if let Some(tab_id) = &d.tab_id {
            let pos = self
                .model
                .tab(tab_id)
                .map(|t| t.position.to_string())
                .unwrap_or_else(|| Model::short_id(tab_id));
            proc::subst_str(&self.cfg.text("tab_short"), &[("n", &pos)])
        } else {
            Model::short_id(&d.pane_id)
        };
        format!("{id} · {}", d.what)
    }

    fn dest_text(&self, dest: &Dest) -> String {
        match dest {
            Dest::Ws { ws_id } => {
                let name = self
                    .model
                    .ws(ws_id)
                    .map(|w| w.label.clone())
                    .unwrap_or_else(|| ws_id.clone());
                proc::subst_str(&self.cfg.text("dest_ws"), &[("name", &name)])
            }
            Dest::Tab { tab_id, .. } => {
                let name = self.tab_name(tab_id);
                proc::subst_str(&self.cfg.text("dest_tab"), &[("name", &name)])
            }
        }
    }

    fn tab_name(&self, tab_id: &str) -> String {
        match self.model.tab(tab_id) {
            Some(t) => {
                let ws = self
                    .model
                    .ws(&t.ws_id)
                    .map(|w| w.label.clone())
                    .unwrap_or_else(|| t.ws_id.clone());
                proc::subst_str(
                    &self.cfg.text("tab_name"),
                    &[("ws", &ws), ("n", &t.position.to_string())],
                )
            }
            None => tab_id.to_string(),
        }
    }

    fn dest_at(&self, idx: usize) -> Option<Dest> {
        let it = self.view.get(idx)?.it.clone();
        match it.kind {
            ItemKind::Ws => Some(Dest::Ws {
                ws_id: it.target.clone(),
            }),
            ItemKind::Tab => {
                let ws_id = self
                    .model
                    .tab(&it.target)
                    .map(|t| t.ws_id.clone())
                    .unwrap_or_else(|| it.target.split(':').next().unwrap_or("").to_string());
                Some(Dest::Tab {
                    ws_id,
                    tab_id: it.target.clone(),
                })
            }
            ItemKind::Pane => {
                let mut tab = None;
                if let Some(mut j) = self.items.iter().position(|x| x.line == it.line) {
                    while j > 0 {
                        j -= 1;
                        let prev = &self.items[j];
                        match prev.kind {
                            ItemKind::Tab => {
                                tab = Some(prev.target.clone());
                                break;
                            }
                            ItemKind::Pane => continue,
                            _ => break,
                        }
                    }
                }
                let tab_id = tab?;
                let ws_id = self
                    .model
                    .tab(&tab_id)
                    .map(|t| t.ws_id.clone())
                    .unwrap_or_else(|| tab_id.split(':').next().unwrap_or("").to_string());
                Some(Dest::Tab { ws_id, tab_id })
            }
            _ => None,
        }
    }

    fn dest_range(&self, dest: &Dest) -> Option<(usize, usize)> {
        let head = match dest {
            Dest::Ws { ws_id } => self
                .view
                .iter()
                .position(|v| v.it.kind == ItemKind::Ws && &v.it.target == ws_id),
            Dest::Tab { tab_id, .. } => self
                .view
                .iter()
                .position(|v| v.it.kind == ItemKind::Tab && &v.it.target == tab_id),
        }?;
        let under: &[ItemKind] = match dest {
            Dest::Ws { .. } => &[ItemKind::Tab, ItemKind::Pane],
            Dest::Tab { .. } => &[ItemKind::Pane],
        };
        let mut last = head;
        while let Some(next) = self.view.get(last + 1) {
            if under.contains(&next.it.kind) {
                last += 1;
            } else {
                break;
            }
        }
        Some((head, last))
    }

    fn drag_noop(&self, d: &Drag, dest: &Dest) -> bool {
        match &d.tab_id {
            Some(tab_id) => self.model.is_noop_tab(tab_id, dest),
            None => self.model.is_noop(&d.pane_id, dest),
        }
    }

    fn start_move(&mut self) {
        let d = self.current().and_then(|it| {
            let it = it.clone();
            self.drag_for(&it, -1, -1)
        });
        match d {
            None => {
                let msg = self.cfg.text("move_help");
                let dim = self.st.dim(&msg);
                self.set_status(&dim);
            }
            Some(mut d) => {
                d.active = true;
                d.kb = true;
                self.moving = true;
                self.drag = Some(d);
                self.move_move_sel(0);
            }
        }
    }

    fn move_move_sel(&mut self, dir: i64) {
        let d = match &self.drag {
            Some(d) => d.clone(),
            None => return,
        };
        let ok = |this: &App, i: usize| -> bool {
            let it = match this.view.get(i) {
                Some(v) => &v.it,
                None => return false,
            };
            if it.kind == ItemKind::Pane {
                return false;
            }
            match this.dest_at(i) {
                Some(dest) => !this.drag_noop(&d, &dest),
                None => false,
            }
        };
        let mut target: Option<usize> = None;
        if dir == 0 {
            for i in 0..self.view.len() {
                if ok(self, i) {
                    target = Some(i);
                    break;
                }
            }
        } else {
            let mut i = self.sel as i64 + dir;
            while i >= 0 && (i as usize) < self.view.len() {
                if ok(self, i as usize) {
                    target = Some(i as usize);
                    break;
                }
                i += dir;
            }
        }
        let i = target.unwrap_or(self.sel);
        self.sel = i;
        let dest = if ok(self, i) { self.dest_at(i) } else { None };
        if let Some(d) = &mut self.drag {
            d.dest = dest.clone();
        }
        let rows_h = if self.geo.rows_h > 0 { self.geo.rows_h } else { 10 };
        if i < self.top {
            self.top = i;
        }
        if i >= self.top + rows_h {
            self.top = i - rows_h + 1;
        }
        if let Some(dest) = dest {
            self.fetch_dest_preview(&dest);
        }
        self.dirty = true;
    }

    fn end_move(&mut self, drop: bool) {
        let d = self.drag.take();
        self.moving = false;
        if drop {
            if let Some(d) = d {
                if let Some(dest) = d.dest.clone() {
                    self.do_move(&d, &dest);
                }
            }
        }
        self.dirty = true;
    }

    fn do_move(&mut self, d: &Drag, dest: &Dest) {
        if let Some(tab_id) = &d.tab_id {
            self.move_tab(tab_id, dest);
        } else {
            self.move_pane(&d.pane_id, dest, true);
        }
    }

    fn move_pane(&mut self, pane_id: &str, dest: &Dest, record_undo: bool) {
        let p = match self.model.pane(pane_id) {
            Some(p) => p.clone(),
            None => {
                let msg = self.cfg.text("cant_undo");
                let err = self.st.fg("error_text", &msg);
                self.set_status(&err);
                return;
            }
        };
        let argv = data::move_argv(&self.cfg, &p, dest);
        let origin = if self.model.panes_of(&p.tab_id).len() > 1 {
            Dest::Tab {
                ws_id: p.ws_id.clone(),
                tab_id: p.tab_id.clone(),
            }
        } else {
            Dest::Ws {
                ws_id: p.ws_id.clone(),
            }
        };
        let what = format!("{} {}", Model::short_id(pane_id), self.pane_what(&p));
        let stamp = now_stamp();
        if self.dry_run {
            data::log_move(
                &self.cfg,
                &format!("{stamp} DRY ok herdr {}  → -", argv.join(" ")),
            );
            let msg = proc::subst_str(&self.cfg.text("dry_move"), &[("cmd", &argv.join(" "))]);
            let msg = self.st.fg("warn_text", &msg);
            self.set_status(&msg);
        } else {
            match data::herdr_args(&self.cfg, &argv) {
                Ok(v) => {
                    let new_id = v
                        .pointer("/result/move_result/pane/pane_id")
                        .and_then(|s| s.as_str())
                        .map(|s| s.to_string());
                    data::log_move(
                        &self.cfg,
                        &format!(
                            "{stamp} ok   herdr {}  → {}",
                            argv.join(" "),
                            new_id.clone().unwrap_or_else(|| "-".into())
                        ),
                    );
                    let undo_hint = if record_undo {
                        self.cfg.text("undo_hint")
                    } else {
                        String::new()
                    };
                    let dest_txt = self.dest_text(dest);
                    let arrow = self.cfg.text("arrow");
                    let msg = proc::subst_str(
                        &self.cfg.text("moved"),
                        &[
                            ("ok", &self.st.fg("ok_text", "✓")),
                            ("what", &self.st.bold(&what)),
                            ("arrow", &self.st.fg("hint_key", &arrow)),
                            ("dest", &dest_txt),
                            ("undo", &self.st.dim(&undo_hint)),
                        ],
                    );
                    self.set_status(&msg);
                    if record_undo && new_id.is_some() {
                        self.undo = Some(Undo {
                            pane_id: new_id.clone().unwrap(),
                            dest: origin,
                        });
                    } else {
                        self.undo = None;
                    }
                    if let Some(id) = new_id {
                        self.flash = Some(Flash {
                            pane_id: id,
                            t0: Instant::now(),
                            placed: false,
                        });
                    }
                }
                Err(e) => {
                    let first = e.lines().next().unwrap_or("").to_string();
                    data::log_move(&self.cfg, &format!("{stamp} fail herdr {}  {first}", argv.join(" ")));
                    let msg = proc::subst_str(
                        &self.cfg.text("move_failed"),
                        &[
                            ("err", &self.st.fg("error_text", "✗")),
                            ("what", &what),
                            ("msg", &first),
                        ],
                    );
                    self.set_status(&msg);
                }
            }
        }
        self.prev_cache.clear();
        self.preview.key.clear();
        let mode = self.mode.clone();
        self.load_list(&mode, true);
    }

    fn move_tab(&mut self, tab_id: &str, dest: &Dest) {
        let ids: Vec<String> = self
            .model
            .panes_of(tab_id)
            .iter()
            .map(|p| p.id.clone())
            .collect();
        if ids.is_empty() {
            return;
        }
        let base_name = self.tab_name(tab_id);
        let what = if ids.len() > 1 {
            proc::subst_str(
                &self.cfg.text("tab_what"),
                &[("name", &base_name), ("n", &ids.len().to_string())],
            )
        } else {
            base_name.clone()
        };
        let stamp = now_stamp();
        if self.dry_run {
            let msg = proc::subst_str(
                &self.cfg.text("dry_move_tab"),
                &[("id", tab_id), ("n", &ids.len().to_string())],
            );
            let msg = self.st.fg("warn_text", &msg);
            self.set_status(&msg);
            self.undo = None;
        } else {
            let mut landed: Option<String> = dest.tab_id().map(|s| s.to_string());
            let mut last: Option<String> = None;
            let mut err: Option<String> = None;
            for id in &ids {
                let p = match self.model.pane(id) {
                    Some(p) => p.clone(),
                    None => continue,
                };
                let argv = match &landed {
                    Some(t) => data::move_argv(
                        &self.cfg,
                        &p,
                        &Dest::Tab {
                            ws_id: dest.ws_id().to_string(),
                            tab_id: t.clone(),
                        },
                    ),
                    None => data::move_argv(&self.cfg, &p, dest),
                };
                match data::herdr_args(&self.cfg, &argv) {
                    Ok(v) => {
                        let np = v
                            .pointer("/result/move_result/pane/pane_id")
                            .and_then(|s| s.as_str())
                            .map(|s| s.to_string());
                        last = np.clone().or(last);
                        if landed.is_none() {
                            landed = v
                                .pointer("/result/move_result/pane/tab_id")
                                .and_then(|s| s.as_str())
                                .map(|s| s.to_string());
                            if landed.is_none() {
                                if let Some(np) = &np {
                                    if let Ok(pv) =
                                        data::herdr_json(&self.cfg, "pane_get", &[("id", np)])
                                    {
                                        landed = pv
                                            .pointer("/result/pane/tab_id")
                                            .and_then(|s| s.as_str())
                                            .map(|s| s.to_string());
                                    }
                                }
                            }
                        }
                        data::log_move(
                            &self.cfg,
                            &format!(
                                "{stamp} ok   tab {tab_id}: herdr {}  → {}",
                                argv.join(" "),
                                np.unwrap_or_else(|| "-".into())
                            ),
                        );
                    }
                    Err(e) => {
                        let first = e.lines().next().unwrap_or("").to_string();
                        data::log_move(&self.cfg, &format!("{stamp} fail tab {tab_id}  {first}"));
                        err = Some(first);
                        break;
                    }
                }
            }
            match err {
                Some(msg) => {
                    let msg = proc::subst_str(
                        &self.cfg.text("move_failed"),
                        &[
                            ("err", &self.st.fg("error_text", "✗")),
                            ("what", &what),
                            ("msg", &msg),
                        ],
                    );
                    self.set_status(&msg);
                }
                None => {
                    let dest_txt = self.dest_text(dest);
                    let arrow = self.cfg.text("arrow");
                    let msg = proc::subst_str(
                        &self.cfg.text("moved"),
                        &[
                            ("ok", &self.st.fg("ok_text", "✓")),
                            ("what", &self.st.bold(&what)),
                            ("arrow", &self.st.fg("hint_key", &arrow)),
                            ("dest", &dest_txt),
                            ("undo", ""),
                        ],
                    );
                    self.set_status(&msg);
                    self.undo = None;
                    if let Some(id) = last {
                        self.flash = Some(Flash {
                            pane_id: id,
                            t0: Instant::now(),
                            placed: false,
                        });
                    }
                }
            }
        }
        self.prev_cache.clear();
        self.preview.key.clear();
        let mode = self.mode.clone();
        self.load_list(&mode, true);
    }

    fn undo_move(&mut self) {
        let u = match self.undo.clone() {
            Some(u) => u,
            None => {
                let msg = self.st.dim(&self.cfg.text("nothing_undo"));
                self.set_status(&msg);
                return;
            }
        };
        self.undo = None;
        if self.model.pane(&u.pane_id).is_none() {
            let msg = self.st.fg("error_text", &self.cfg.text("cant_undo"));
            self.set_status(&msg);
            return;
        }
        let mut dest = u.dest.clone();
        if let Dest::Tab { ws_id, tab_id } = &dest {
            if self.model.tab(tab_id).is_none() {
                dest = Dest::Ws {
                    ws_id: ws_id.clone(),
                };
            }
        }
        self.move_pane(&u.pane_id, &dest, true);
    }

    fn do_kill(&mut self) {
        let it = match self.current() {
            Some(i) if !matches!(i.kind, ItemKind::Group | ItemKind::Link) => i.clone(),
            _ => return,
        };
        let _ = data::kill_item(&self.cfg, &it);
        self.prev_cache.clear();
        self.preview.key.clear();
        let mode = self.mode.clone();
        self.load_list(&mode, true);
    }

    fn do_scratch(&mut self) {
        self.term.restore();
        if let Some(path) = data::scratch(&self.cfg) {
            let _ = data::act(&self.cfg, &path);
        }
        self.quit_code = Some(0);
    }

    fn choose(&mut self) {
        match self.current().map(|i| (i.kind, i.target.clone())) {
            Some((ItemKind::Group, _)) => return self.choose_header(),
            Some((ItemKind::Link, id)) => return self.choose_link(&id),
            _ => {}
        }
        if let Some(it) = self.current() {
            let line = it.line.clone();
            self.term.restore();
            let _ = data::act(&self.cfg, &line);
        }
        self.quit_code = Some(0);
    }

    // ── link group (kitchen-sink's places) ──────────────────────────────

    /// Fetch kitchen-sink's rows in the background; never blocks the list.
    fn fetch_links(&mut self) {
        if !self.ks_installed {
            return;
        }
        let cfg = self.cfg.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let _ = tx.send(Msg::Links(links::fetch_ks(&cfg)));
        });
    }

    /// The group shows in the modes `links.modes` names (spaces / all).
    fn links_on(&self) -> bool {
        self.ks_installed
            && self.cfg
            .links
            .get("modes")
            .and_then(|m| m.as_array())
            .map(|a| a.iter().any(|m| m.as_str() == Some(self.mode.as_str())))
            .unwrap_or(false)
    }

    /// The pinned group: header + visible link rows, above the local ones.
    /// Clearing the query restores its default (`links.start_expanded`).
    fn group_rows(&mut self, query: &str) -> Vec<ViewRow> {
        let mut out = Vec::new();
        if !self.links_on() {
            return out;
        }
        if query.is_empty() && self.group_had_query {
            self.group.expanded = self.group_default_expanded();
        }
        self.group_had_query = !query.is_empty();
        if !self.group.header_shown(query) {
            return out;
        }
        out.push(ViewRow { it: self.header_item(query), pos: Vec::new(), score: 0.0 });
        let row_query = self.group.row_query(query).to_string();
        for (i, score) in self.group.visible(query) {
            let it = self.link_item(i);
            let pos = if row_query.is_empty() {
                Vec::new()
            } else {
                fuzzy::fuzzy_match(&it.plain, &row_query).map(|(p, _)| p).unwrap_or_default()
            };
            out.push(ViewRow { it, pos, score });
        }
        out
    }

    /// The group opens expanded unless `links.start_expanded` is false.
    fn group_default_expanded(&self) -> bool {
        self.cfg.links.get("start_expanded").and_then(|v| v.as_bool()).unwrap_or(true)
    }

    /// Where the cursor starts: no query → the header (`links.start_on_group`)
    /// so Return switches to kitchen-sink; a query naming the group → the
    /// header (`kitchen-sink`) or its best row (`ks notes`); any other query →
    /// the better of the best local and best kitchen-sink match (a tie goes to
    /// kitchen-sink, listed first).
    fn start_sel(&self, query: &str) -> usize {
        let g = self.group_len;
        let start_on_group = self.cfg.links.get("start_on_group").and_then(|v| v.as_bool()).unwrap_or(true);
        if g > 0 && self.links_on() {
            if let Some(rest) = self.group.scope(query) {
                return if rest.is_empty() || g < 2 { 0 } else { 1 };
            }
        }
        if query.is_empty() {
            if g > 0 && start_on_group {
                0
            } else if self.view.len() > g {
                g
            } else {
                0
            }
        } else if self.view.len() > g && g > 1 {
            // Both lists match: kitchen-sink wins unless the local match is
            // strictly better.
            if self.quality(1, self.group.row_query(query)) >= self.quality(g, query) {
                1
            } else {
                g
            }
        } else if self.view.len() > g {
            g
        } else if g > 1 {
            1
        } else {
            0
        }
    }

    fn quality(&self, i: usize, query: &str) -> f64 {
        let it = &self.view[i].it;
        let hay = if it.search.is_empty() { &it.plain } else { &it.search };
        fuzzy::match_quality(hay, query).unwrap_or(f64::MIN)
    }

    /// ^e / ^m on the header: open / close the group in place.
    fn group_toggle(&mut self) {
        let open = !self.group.expanded;
        self.group_set(open);
    }

    fn header_item(&self, query: &str) -> Item {
        let cfg = &self.cfg;
        let arrow = if self.group.open(query) { &cfg.icons.group_open } else { &cfg.icons.group_closed };
        let text = ui::fill_tmpl(
            &cfg.row("group"),
            &[
                ("arrow", arrow.clone()),
                ("label", cfg.text("group_label")),
                ("tail", self.group.header_tail(cfg)),
            ],
        );
        let display = if self.group.dim() { self.st.dim(&text) } else { self.st.fg("group", &text) };
        data::mk_item(display, ItemKind::Group, "group", "", false)
    }

    fn link_item(&self, i: usize) -> Item {
        let cfg = &self.cfg;
        let r = &self.group.rows[i];
        let icon = cfg.icons.link_kinds.get(&r.kind).cloned().unwrap_or_default();
        let display = ui::fill_tmpl(
            &cfg.row("link"),
            &[
                ("icon", self.st.fg("link_icon", &icon)),
                ("title", self.st.fg("link_title", &r.title)),
                ("subtitle", self.st.fg("link_meta", &r.subtitle)),
            ],
        );
        data::mk_item(display, ItemKind::Link, &r.id, &r.search_text(), false)
    }

    /// Refilter, keeping the cursor on the same item when it is still there.
    fn refilter_keep_current(&mut self) {
        let key = self.current().map(|i| i.key());
        self.refilter(self.sel);
        if let Some(i) = key.and_then(|k| self.view.iter().position(|v| v.it.key() == k)) {
            self.sel = i;
            self.schedule_preview();
        }
    }

    fn header_index(&self) -> Option<usize> {
        self.view.iter().position(|v| v.it.kind == ItemKind::Group)
    }

    /// `^k`: jump to the header and open the group.
    fn links_jump(&mut self) {
        if !self.links_on() {
            return;
        }
        self.group.expanded = true;
        self.refilter(self.sel);
        if let Some(i) = self.header_index() {
            self.sel = i;
            self.help = false;
            self.schedule_preview();
        }
    }

    /// → / l open the group from its header; ← / h close it from the header
    /// or a link row (the cursor lands on the header).
    fn group_set(&mut self, open: bool) {
        let kind = self.current().map(|i| i.kind);
        let on_header = kind == Some(ItemKind::Group);
        if !(on_header || (!open && kind == Some(ItemKind::Link))) {
            return;
        }
        self.group.expanded = open;
        self.refilter(self.sel);
        if let Some(i) = self.header_index() {
            self.sel = i;
            self.schedule_preview();
        }
    }

    /// Return on the header: just bring kitchen-sink forward (`do:go:app`,
    /// its last view); when it is down or too old to answer, start / raise
    /// it with `ks_launch`.
    fn choose_header(&mut self) {
        self.term.restore();
        let up = self.group.status != GroupStatus::Offline && links::go_ks(&self.cfg, "app").is_ok();
        if !up {
            links::launch_ks(&self.cfg);
        }
        self.quit_code = Some(0);
    }

    /// Return on a link row: kitchen-sink presents it (and activates; AeroSpace
    /// follows), the popup closes.
    fn choose_link(&mut self, id: &str) {
        match links::go_ks(&self.cfg, id) {
            Ok(()) => {
                self.term.restore();
                self.quit_code = Some(0);
            }
            Err(LinkErr::Offline) => {
                links::launch_ks(&self.cfg);
                self.quit_code = Some(0);
            }
            Err(LinkErr::Unavailable(e)) => {
                let msg = proc::subst_str(&self.cfg.text("link_failed"), &[("err", &e)]);
                let msg = self.st.fg("error_text", &msg);
                self.set_status(&msg);
            }
        }
    }

    fn group_preview(&self, it: &Item) -> Preview {
        let cfg = &self.cfg;
        let (text, label) = if it.kind == ItemKind::Group {
            let text = if self.group.status == GroupStatus::Offline {
                cfg.text("group_offline_preview")
            } else {
                cfg.text("group_header_preview")
            };
            (text, format!(" {} ", cfg.text("group_label")))
        } else {
            match self.group.rows.iter().find(|r| r.id == it.target) {
                Some(r) => {
                    let text = r.preview.clone().unwrap_or_else(|| {
                        proc::subst_str(&cfg.text("group_preview"), &[("title", &r.title), ("subtitle", &r.subtitle)])
                    });
                    (text, proc::subst_str(&cfg.text("link_label"), &[("kind", &r.kind)]))
                }
                None => (cfg.text("no_preview"), String::new()),
            }
        };
        Preview { key: it.key(), label, scroll: 0, parts: vec![PreviewPart { title: String::new(), text }] }
    }

    // ── mouse ───────────────────────────────────────────────────────────

    fn on_mouse(&mut self, m: MouseEvent) {
        let x = m.column as i64;
        let y = m.row as i64;
        let g = self.geo;
        let in_pv = x >= g.pv_x as i64
            && y >= g.pv_y as i64
            && x < (g.pv_x + g.pw) as i64
            && y < (g.pv_y + g.ph) as i64;
        match m.kind {
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown => {
                let dir: i64 = if m.kind == MouseEventKind::ScrollUp { -1 } else { 1 };
                if in_pv && self.drag.is_none() {
                    let n = self.cfg.num("wheel_preview_lines", 3).max(0) as usize;
                    self.preview.scroll = (self.preview.scroll as i64 + dir * n as i64).max(0) as usize;
                    self.dirty = true;
                } else if self.drag.is_some() {
                    let n = self.cfg.num("wheel_list_lines", 2).max(0) as usize;
                    self.top = (self.top as i64 + dir * n as i64).max(0) as usize;
                    self.dirty = true;
                } else {
                    self.move_sel(dir);
                }
            }
            MouseEventKind::Drag(_) => {
                if self.drag.is_none() {
                    return;
                }
                let (mut active, mut x0, mut y0) = (false, 0i64, 0i64);
                if let Some(d) = &self.drag {
                    active = d.active;
                    x0 = d.x0;
                    y0 = d.y0;
                }
                if !active {
                    let threshold = self.cfg.num("drag_threshold", 2);
                    if (x - x0).abs() + (y - y0).abs() < threshold {
                        return;
                    }
                }
                if let Some(d) = &mut self.drag {
                    d.active = true;
                    d.x = x;
                    d.y = y;
                }
                if y <= g.list_y as i64 && self.top > 0 {
                    self.top -= 1;
                } else if y >= (g.list_y + g.rows_h) as i64 - 1
                    && self.top + g.rows_h < self.view.len()
                {
                    self.top += 1;
                }
                let idx = self.row_idx(x, y);
                let dest = if idx >= 0 {
                    self.dest_at(idx as usize)
                } else {
                    None
                };
                let ok = match (&dest, &self.drag) {
                    (Some(dest), Some(d)) => !self.drag_noop(d, dest),
                    _ => false,
                };
                let dest = if ok { dest } else { None };
                if let Some(d) = &mut self.drag {
                    d.dest = dest.clone();
                }
                if let Some(dest) = dest {
                    self.fetch_dest_preview(&dest);
                }
                self.dirty = true;
            }
            MouseEventKind::Up(_) => {
                let d = self.drag.take();
                if let Some(d) = d {
                    if d.active {
                        if let Some(dest) = d.dest.clone() {
                            self.do_move(&d, &dest);
                        }
                    }
                }
                self.dirty = true;
            }
            MouseEventKind::Down(MouseButton::Left) => {
                let idx = self.row_idx(x, y);
                if idx < 0 || idx as usize >= self.view.len() {
                    return;
                }
                let idx = idx as usize;
                let now = Instant::now();
                let dbl_ms = self.cfg.num("double_click_ms", 400).max(0) as u128;
                let dbl = self.last_click.1 == idx as i64
                    && now.duration_since(self.last_click.0).as_millis() < dbl_ms;
                self.last_click = (now, idx as i64);
                self.help = false;
                self.sel = idx;
                let it = self.view[idx].it.clone();
                self.drag = self.drag_for(&it, x, y);
                self.schedule_preview();
                self.dirty = true;
                if dbl {
                    self.drag = None;
                    self.choose();
                }
            }
            _ => {}
        }
    }

    fn row_idx(&self, x: i64, y: i64) -> i64 {
        let g = self.geo;
        if x < g.list_w as i64
            && y >= g.list_y as i64
            && y < (g.list_y + g.rows_h) as i64
        {
            (self.top as i64 + (y - g.list_y as i64)) as i64
        } else {
            -1
        }
    }

    // ── draw ────────────────────────────────────────────────────────────

    fn draw_pick(&mut self, w: usize, h: usize) -> Vec<String> {
        let cfg = &self.cfg;
        let st = &self.st;
        let narrow_w = cfg.num("narrow_width", 110).max(1) as usize;
        let narrow = w < narrow_w;
        let pct = cfg.num("list_width_ratio", 55).clamp(0, 100) as usize;
        let list_w = if narrow { w } else { w - w * pct / 100 };
        let list_h = if narrow { h - h / 2 } else { h };
        let inner = list_h.saturating_sub(2);
        let iw = list_w.saturating_sub(2);
        let drag_owned = self.drag.clone();
        let drag = drag_owned.as_ref().filter(|d| d.active);
        let status = match &self.status {
            Some(s) if Instant::now() < s.until => Some(s.text.clone()),
            _ => None,
        };

        // hints
        let sep = &cfg.ui.hint_sep;
        let mut hint = String::new();
        let last_hint = cfg.ui.hints.iter().find(|h| h.last);
        let more = last_hint
            .map(|h| {
                format!(
                    "{} {}",
                    ansi::bold(&h.key),
                    st.fg("hint", &h.label)
                )
            })
            .unwrap_or_default();
        for item in cfg.ui.hints.iter().filter(|h| !h.last) {
            if !item.modes.is_empty() && !item.modes.iter().any(|m| m == &self.mode) {
                continue;
            }
            let label = if let (Some(alt), true) = (&item.alt, self.expanded) {
                alt.clone()
            } else {
                item.label.clone()
            };
            let label = proc::subst_str(&label, &[("sort", &self.sort)]);
            let active = item.active_modes.iter().any(|m| m == &self.mode);
            let part = format!(
                "{} {}",
                ansi::bold(&item.key),
                if active {
                    st.fg("hint_active", &label)
                } else {
                    st.fg("hint", &label)
                }
            );
            let probe = if hint.is_empty() {
                format!("{part}{sep}{more}")
            } else {
                format!("{hint}{sep}{part}{sep}{more}")
            };
            if ansi::width(&probe) <= iw.saturating_sub(2) {
                if !hint.is_empty() {
                    hint.push_str(sep);
                }
                hint.push_str(&part);
            }
        }
        if !hint.is_empty() {
            hint.push_str(sep);
        }
        hint.push_str(&more);

        // head
        let prompt = st.fg(
            "prompt",
            &format!("{}{}", cfg.prompt(&self.mode), cfg.ui.prompt_sep),
        );
        let mut head0 = format!("{prompt}{}\x1b[7m \x1b[27m", self.query);
        let info = st.fg(
            "info",
            &format!(
                "{}{}",
                if self.loading { &cfg.ui.loading } else { "" },
                proc::subst_str(
                    &cfg.ui.info_fmt,
                    &[
                        ("shown", &(self.view.len() - self.group_len).to_string()),
                        ("total", &self.items.len().to_string())
                    ]
                )
            ),
        );
        let avail = list_w.saturating_sub(3 + ansi::width(&info));
        head0 = ansi::slice(&head0, 0, avail);
        let pad = (list_w.saturating_sub(2 + ansi::width(&head0) + ansi::width(&info))).max(1);
        head0.push_str(&" ".repeat(pad));
        head0.push_str(&info);

        let moving_label = format!(
            "{} {}",
            st.bold(&st.fg("hint_active", &cfg.text("moving_label"))),
            st.fg("hint", &cfg.text("moving_hint"))
        );
        let head1 = if self.moving {
            moving_label
        } else {
            status.unwrap_or_else(|| hint.clone())
        };
        let tog = self.mode == "all" || self.mode == "ws";
        let head2 = if tog {
            ui::table_head(cfg, st, &self.sort, iw)
        } else {
            st.fg("table_head", &"─".repeat(iw))
        };
        let head: Vec<String> = vec![head0, head1, head2];

        let rows_h = (inner.saturating_sub(head.len())).max(1);
        if drag.is_none() {
            if self.sel < self.top {
                self.top = self.sel;
            }
            if self.sel >= self.top + rows_h {
                self.top = self.sel - rows_h + 1;
            }
        }
        let view_len = self.view.len();
        let max_top = view_len.saturating_sub(rows_h);
        self.top = self.top.min(max_top);

        let range = drag.and_then(|d| d.dest.as_ref()).and_then(|dest| self.dest_range(dest));
        let flash_ms = cfg.num("flash_ms", 900).max(1) as u128;
        let flash_bg = self
            .flash
            .as_ref()
            .and_then(|f| st.flash_bg_codes(f.t0.elapsed().as_millis(), flash_ms));
        let target_bg = st.bg_codes("target_bg");
        let sel_bg = st.bg_codes("selection_bg");

        let mut rows: Vec<String> = Vec::with_capacity(rows_h);
        for i in 0..rows_h {
            let idx = self.top + i;
            let v = match self.view.get(idx) {
                Some(v) => v,
                None => {
                    rows.push(String::new());
                    continue;
                }
            };
            let mut text = ui::highlight(&v.it.display, &v.pos);
            let mine = drag.map(|d| {
                if let Some(tab_id) = &d.tab_id {
                    (v.it.kind == ItemKind::Tab && &v.it.target == tab_id)
                        || (v.it.kind == ItemKind::Pane
                            && self
                                .model
                                .pane(&v.it.target)
                                .map(|p| &p.tab_id == tab_id)
                                .unwrap_or(false))
                } else {
                    v.it.kind == ItemKind::Pane && v.it.target == d.pane_id
                }
            }).unwrap_or(false);
            if mine {
                text = format!(
                    "\x1b[2;9m{}\x1b[22;29m  {}",
                    v.it.plain,
                    st.dim(&cfg.text("moving_row"))
                );
            } else if drag.is_some()
                && !matches!(v.it.kind, ItemKind::Ws | ItemKind::Tab | ItemKind::Pane)
            {
                text = st.dim(&v.it.plain);
            }
            if let Some((a, b)) = range {
                if idx >= a && idx <= b {
                    let one = a == b;
                    let pulse = st.pulse_codes(self.phase);
                    let edge = cfg
                        .ui
                        .edge_pulse
                        .get(if (idx as u64 + self.phase) % 3 == 0 { 0 } else { 1 })
                        .cloned()
                        .unwrap_or_else(|| "│".into());
                    let c = |s: &str| format!("{pulse}{s}\x1b[39m");
                    let (l, r) = if one {
                        ("[".to_string(), "]".to_string())
                    } else if idx == a {
                        ("╭".to_string(), "╮".to_string())
                    } else if idx == b {
                        ("╰".to_string(), "╯".to_string())
                    } else {
                        (edge.clone(), edge.clone())
                    };
                    if idx == a {
                        let label = if drag.and_then(|d| d.dest.as_ref()).map(|d| d.is_tab()).unwrap_or(false) {
                            cfg.text("split")
                        } else {
                            cfg.text("new_tab")
                        };
                        text.push_str(&format!("  {}", st.bold(&st.fg("target_fg", &label))));
                    }
                    let body = format!(
                        "{}{} {}",
                        c(&l),
                        " ",
                        ansi::fit(&text, iw.saturating_sub(3))
                    );
                    rows.push(ansi::with_bg(
                        &format!("{body}{target_bg}{}", c(&r)),
                        &target_bg,
                    ));
                    continue;
                }
            }
            if let Some(bg) = &flash_bg {
                if v.it.kind == ItemKind::Pane
                    && self.flash.as_ref().map(|f| f.pane_id == v.it.target).unwrap_or(false)
                {
                    rows.push(ansi::with_bg(
                        &format!("  {}{bg}", ansi::fit(&text, iw.saturating_sub(2))),
                        bg,
                    ));
                    continue;
                }
            }
            if idx == self.sel && drag.is_none() {
                let edge = st.fg("selection_edge", &st.edge);
                rows.push(ansi::with_bg(
                    &format!("{edge} {}", ansi::fit(&text, iw.saturating_sub(2))),
                    &sel_bg,
                ));
            } else {
                rows.push(format!("  {text}"));
            }
        }

        let mut left_lines = head;
        left_lines.extend(rows);
        let left = ui::box_lines(&left_lines, list_w, list_h, &cfg.ui.border_label, st, cfg);

        let pw = if narrow { w } else { w - list_w };
        let ph = if narrow { h - list_h } else { h };
        let pv_lines: Vec<String> = if let Some(d) = drag {
            self.landing_lines(d, pw.saturating_sub(2), ph.saturating_sub(2))
        } else if self.preview.parts.len() > 1 {
            ui::grid_lines(
                &self.preview.parts,
                pw.saturating_sub(2),
                ph.saturating_sub(2),
                st,
                cfg,
            )
        } else {
            let text = self
                .preview
                .parts
                .first()
                .map(|p| p.text.clone())
                .unwrap_or_default();
            ansi::sanitize(&text)
                .split('\n')
                .skip(self.preview.scroll)
                .map(|s| s.to_string())
                .collect()
        };
        let pv = ui::box_lines(&pv_lines, pw, ph, &self.preview.label, st, cfg);

        self.geo = Geo {
            list_y: 1 + 3,
            list_w,
            rows_h,
            pv_x: if narrow { 0 } else { list_w },
            pv_y: if narrow { list_h } else { 0 },
            pw,
            ph,
        };

        let mut lines: Vec<String> = if narrow {
            let mut v = left;
            v.extend(pv);
            v
        } else {
            left.iter()
                .enumerate()
                .map(|(i, l)| format!("{l}{}", pv.get(i).cloned().unwrap_or_default()))
                .collect()
        };

        if let Some(d) = drag {
            if d.y >= 0 && (d.y as usize) < lines.len() {
                let (bgc, fgc) = if d.dest.is_some() {
                    (st.bg_codes("chip_bg"), st.fg_codes("chip_fg"))
                } else {
                    (st.bg_codes("chip_bad_bg"), st.fg_codes("chip_bad_fg"))
                };
                let chip = format!(
                    "{bgc}{fgc}\x1b[1m {} {} \x1b[0m",
                    cfg.icons.grip,
                    self.drag_label(d)
                );
                let chip_w = ansi::width(&chip);
                let x = (d.x + 2).clamp(0, (w as i64 - chip_w as i64).max(0)) as usize;
                let line = lines[d.y as usize].clone();
                lines[d.y as usize] = format!(
                    "{}\x1b[0m{}{}",
                    ansi::slice(&line, 0, x),
                    chip,
                    ansi::slice(&line, x + chip_w, w)
                );
            }
        }
        lines
    }

    fn landing_lines(&self, d: &Drag, iw: usize, ih: usize) -> Vec<String> {
        let cfg = &self.cfg;
        let st = &self.st;
        let chip_label = proc::subst_str(&cfg.text("chip"), &[("label", &self.drag_label(d))]);
        let chip = st.bold(&st.fg("accent", &chip_label));
        let dest = match &d.dest {
            Some(dest) => dest,
            None => {
                let mut lines = vec![String::new(); ih.max(1)];
                let msg = st.dim(&cfg.text("drop_hint"));
                let idx = ih / 2;
                if idx < lines.len() {
                    let pad = (iw.saturating_sub(ansi::width(&msg))) / 2;
                    lines[idx] = ansi::fit(&format!("{}{}", " ".repeat(pad), msg), iw);
                }
                return lines;
            }
        };
        match dest {
            Dest::Ws { ws_id } => {
                let tabs = self.model.ws_tabs(ws_id);
                let strip: Vec<String> = tabs
                    .iter()
                    .map(|t| st.dim(&format!(" {} ", t.position)))
                    .collect();
                let head = format!(
                    " {} {} {}",
                    strip.join(" "),
                    "",
                    st.bold(&st.fg("accent", &cfg.icons.landing_add))
                );
                let name = self
                    .model
                    .ws(ws_id)
                    .map(|w| w.label.clone())
                    .unwrap_or_else(|| ws_id.clone());
                let sub = st.dim(&proc::subst_str(&cfg.text("new_tab_in"), &[("name", &name)]));
                let mut lines = vec![head, String::new()];
                lines.extend(ui::ants_rect(
                    iw,
                    ih.saturating_sub(2).max(3),
                    &[chip, String::new(), sub],
                    self.phase,
                    st,
                    cfg,
                ));
                lines
            }
            Dest::Tab { .. } => {
                let lw = iw / 2;
                let left: Vec<String> = ansi::sanitize(&self.dest_text)
                    .split('\n')
                    .map(|s| s.to_string())
                    .collect();
                let rect = ui::ants_rect(
                    iw.saturating_sub(lw).saturating_sub(1).max(4),
                    ih.max(3),
                    &[chip, String::new(), st.dim(&cfg.text("splits_in_here"))],
                    self.phase,
                    st,
                    cfg,
                );
                rect.iter()
                    .enumerate()
                    .map(|(i, r)| {
                        format!(
                            "{}{}{}",
                            ansi::fit(left.get(i).map(|s| s.as_str()).unwrap_or(""), lw),
                            st.dim("│"),
                            r
                        )
                    })
                    .collect()
            }
        }
    }
}

fn now_stamp() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs().to_string())
        .unwrap_or_else(|_| "0".into())
}
