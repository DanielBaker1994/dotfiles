// Data backend: the port of connect-herdr.sh's list / state / preview / label /
// help / kill / go / browser. Where the shell script leaned on jq and python,
// this builds the rows natively and keeps every command in the config.

use crate::ansi;
use crate::config::Config;
use crate::model::{base_name, home_rel, Dest, Model, Pane};
use crate::proc::{self, Out};
use crate::style::Style;
use crate::ui;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemKind {
    Ws,
    Tab,
    Pane,
    Agent,
    Cfg,
    Dir,
    None,
}

impl ItemKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            ItemKind::Ws => "ws",
            ItemKind::Tab => "tab",
            ItemKind::Pane => "pane",
            ItemKind::Agent => "agent",
            ItemKind::Cfg => "cfg",
            ItemKind::Dir => "dir",
            ItemKind::None => "none",
        }
    }
    pub fn parse(s: &str) -> ItemKind {
        match s {
            "ws" => ItemKind::Ws,
            "tab" => ItemKind::Tab,
            "pane" => ItemKind::Pane,
            "agent" => ItemKind::Agent,
            "cfg" => ItemKind::Cfg,
            "dir" => ItemKind::Dir,
            _ => ItemKind::None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub line: String,
    pub display: String,
    pub plain: String,
    pub kind: ItemKind,
    pub target: String,
    pub search: String,
    pub more: bool,
}

pub fn mk_item(display: String, kind: ItemKind, target: &str, search: &str, more: bool) -> Item {
    let plain = ansi::strip(&display);
    let search_plain = ansi::strip(search).trim().to_string();
    let line = format!("{}\t{}\t{}\t{}", display, kind.as_str(), target, search_plain);
    Item {
        line,
        display,
        plain,
        kind,
        target: target.to_string(),
        search: search_plain,
        more,
    }
}

impl Item {
    /// stable cache key for previews: survives reloads and display changes
    pub fn key(&self) -> String {
        format!("{}\t{}", self.kind.as_str(), self.target)
    }
}

pub fn item_from_line(line: &str) -> Item {
    let mut parts = line.splitn(4, '\t');
    let display = parts.next().unwrap_or("").to_string();
    let kind = ItemKind::parse(parts.next().unwrap_or(""));
    let target = parts.next().unwrap_or("").to_string();
    let search = parts.next().unwrap_or("").to_string();
    let plain = ansi::strip(&display);
    Item {
        line: line.to_string(),
        display,
        plain,
        kind,
        target,
        search: search.trim().to_string(),
        more: false,
    }
}

pub fn timeout_ms(cfg: &Config, key: &str, default: i64) -> Duration {
    Duration::from_millis(cfg.num(key, default).max(0) as u64)
}

pub fn herdr_bin(cfg: &Config) -> String {
    let mut cands: Vec<String> = Vec::new();
    if !cfg.bins.herdr_env.is_empty() {
        if let Ok(v) = std::env::var(&cfg.bins.herdr_env) {
            if !v.is_empty() {
                cands.push(v);
            }
        }
    }
    cands.push(cfg.bins.herdr.clone());
    for f in &cfg.bins.herdr_fallbacks {
        cands.push(cfg.expand_path(f));
    }
    for c in &cands {
        if which(c).is_some() {
            return c.clone();
        }
    }
    cands.pop().unwrap_or_else(|| "herdr".to_string())
}

pub fn which(program: &str) -> Option<String> {
    if program.contains('/') {
        let p = Path::new(program);
        if p.is_file() {
            return Some(program.to_string());
        }
        return None;
    }
    let path = std::env::var("PATH").unwrap_or_default();
    for dir in path.split(':') {
        if dir.is_empty() {
            continue;
        }
        let p = Path::new(dir).join(program);
        if p.is_file() {
            return Some(p.to_string_lossy().into_owned());
        }
    }
    None
}

pub fn herdr_out(cfg: &Config, key: &str, vars: &[(&str, &str)]) -> Result<Out, String> {
    let bin = herdr_bin(cfg);
    let args = proc::subst(&cfg.cmd(key), vars);
    proc::run(&bin, &args, timeout_ms(cfg, "herdr_timeout_ms", 15000))
}

pub fn herdr_json(cfg: &Config, key: &str, vars: &[(&str, &str)]) -> Result<Value, String> {
    let out = herdr_out(cfg, key, vars)?;
    proc::parse_json(&out, "herdr")
}

/// Run herdr with an already-substituted argv (pane move, built from config).
pub fn herdr_args(cfg: &Config, args: &[String]) -> Result<Value, String> {
    let bin = herdr_bin(cfg);
    let out = proc::run(&bin, args, timeout_ms(cfg, "herdr_timeout_ms", 15000))?;
    proc::parse_json(&out, "herdr")
}

pub fn herdr_quiet(cfg: &Config, key: &str, vars: &[(&str, &str)]) {
    let _ = herdr_out(cfg, key, vars);
}

/// workspaces / tabs / panes as one JSON value: one snapshot, else three lists.
pub fn fetch_state(cfg: &Config) -> Result<Value, String> {
    if let Ok(v) = herdr_json(cfg, "snapshot", &[]) {
        if let Some(s) = v.pointer("/result/snapshot") {
            return Ok(json!({
                "ws": s.get("workspaces").cloned().unwrap_or_else(|| json!([])),
                "tabs": s.get("tabs").cloned().unwrap_or_else(|| json!([])),
                "panes": s.get("panes").cloned().unwrap_or_else(|| json!([])),
            }));
        }
    }
    let w = herdr_json(cfg, "workspace_list", &[]).unwrap_or_else(|_| json!({}));
    let t = herdr_json(cfg, "tab_list", &[]).unwrap_or_else(|_| json!({}));
    let p = herdr_json(cfg, "pane_list", &[]).unwrap_or_else(|_| json!({}));
    Ok(json!({
        "ws": w.pointer("/result/workspaces").cloned().unwrap_or_else(|| json!([])),
        "tabs": t.pointer("/result/tabs").cloned().unwrap_or_else(|| json!([])),
        "panes": p.pointer("/result/panes").cloned().unwrap_or_else(|| json!([])),
    }))
}

pub fn ensure_herdr(cfg: &Config) -> Result<(), String> {
    let bin = herdr_bin(cfg);
    if which(&bin).is_none() {
        let env = if cfg.bins.herdr_env.is_empty() {
            "$HERDR_BIN_PATH".to_string()
        } else {
            format!("${}", cfg.bins.herdr_env)
        };
        let fallback = cfg
            .bins
            .herdr_fallbacks
            .first()
            .map(|f| cfg.expand_path(f))
            .unwrap_or_default();
        return Err(proc::subst_str(
            &cfg.text("herdr_missing"),
            &[("env", &env), ("fallback", &fallback)],
        ));
    }
    if std::env::var("HERDR_ENV").ok().as_deref() == Some("1") {
        return Ok(());
    }
    match herdr_out(cfg, "workspace_list", &[]) {
        Ok(o) if o.status == 0 => Ok(()),
        _ => Err(format!(
            "{}\n{}",
            proc::subst_str(&cfg.text("herdr_no_server"), &[("socket", &cfg.path("herdr_socket"))]),
            cfg.text("herdr_start")
        )),
    }
}

// ── list ────────────────────────────────────────────────────────────────

pub fn list_items(
    cfg: &Config,
    st: &Style,
    mode: &str,
    sort: &str,
) -> Result<(Vec<Item>, Model), String> {
    let state = fetch_state(cfg)?;
    let model = Model::build(&state);
    let items = match mode {
        "ws" => list_ws(cfg, st, &model, sort),
        "agents" => list_agents(cfg, st, &model),
        "dirs" => list_dir(cfg, st, &model, true),
        _ => {
            let mut v = list_ws(cfg, st, &model, sort);
            v.extend(list_cfg(cfg, st, &model));
            v.extend(list_dir(cfg, st, &model, false));
            v
        }
    };
    Ok((items, model))
}

fn status_icon(cfg: &Config, st: &Style, status: &str) -> String {
    let glyph = cfg.icon_status(status);
    if glyph.trim().is_empty() {
        return glyph;
    }
    st.fg(&format!("status_{status}"), &glyph)
}

fn age_text(cfg: &Config, secs: i64) -> String {
    let fmt = |key: &str, n: i64| proc::subst_str(&cfg.ui.age.get(key).cloned().unwrap_or_default(), &[("n", &n.to_string())]);
    if secs < 60 {
        fmt("now", secs.max(0))
    } else if secs < 3600 {
        fmt("min", secs / 60)
    } else if secs < 86400 {
        fmt("hour", secs / 3600)
    } else {
        fmt("day", secs / 86400)
    }
}

fn now_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub fn load_mru(cfg: &Config) -> Vec<(String, i64)> {
    let raw = std::fs::read_to_string(cfg.path("mru_file")).unwrap_or_default();
    raw.lines()
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            let id = it.next()?.to_string();
            let t = it.next().and_then(|x| x.parse::<i64>().ok()).unwrap_or(0);
            Some((id, t))
        })
        .collect()
}

fn list_ws(cfg: &Config, st: &Style, model: &Model, sort: &str) -> Vec<Item> {
    let mru = load_mru(cfg);
    let rank = |id: &str| -> f64 {
        mru.iter()
            .position(|(mid, _)| mid == id)
            .map(|i| i as f64)
            .unwrap_or(1000.0)
    };
    let recent = |w: &crate::model::Workspace| -> f64 {
        if w.focused {
            0.5
        } else {
            rank(&w.id)
        }
    };
    let srank = |s: &str| -> i32 {
        match s {
            "blocked" => 0,
            "working" => 1,
            "done" => 2,
            "idle" => 3,
            _ => 4,
        }
    };
    let mut order: Vec<&crate::model::Workspace> = model.workspaces.iter().collect();
    match sort {
        "name" => order.sort_by(|a, b| a.label.to_lowercase().cmp(&b.label.to_lowercase())),
        "status" => order.sort_by(|a, b| {
            (srank(&a.status), recent(a))
                .partial_cmp(&(srank(&b.status), recent(b)))
                .unwrap_or(std::cmp::Ordering::Equal)
        }),
        _ => order.sort_by(|a, b| {
            recent(a)
                .partial_cmp(&recent(b))
                .unwrap_or(std::cmp::Ordering::Equal)
        }),
    }

    let mut items: Vec<Item> = Vec::new();
    for w in order {
        let tabs = model.ws_tabs(&w.id);
        let agents = model.ws_agents(&w.id);
        let active_cwd = w
            .active_tab_id
            .as_deref()
            .and_then(|t| model.tab_pane(t))
            .map(|p| home_rel(&p.cwd))
            .unwrap_or_default();
        let q = format!("{} {}", w.label, active_cwd);
        let icon = status_icon(cfg, st, &w.status);
        let label = if st.ws_bold {
            st.bold(&st.fg("ws", &w.label))
        } else {
            st.fg("ws", &w.label)
        };
        let tab_n = if w.tab_count > 0 { w.tab_count } else { tabs.len() };
        let agents_txt = agents.join(", ");
        let agents_styled = if agents_txt.is_empty() {
            String::new()
        } else {
            st.fg("agent", &agents_txt)
        };
        let last = if w.focused {
            cfg.text("here")
        } else {
            match mru.iter().find(|(id, _)| id == &w.id) {
                Some((_, t)) => age_text(cfg, now_epoch() - t),
                None => cfg.text("none"),
            }
        };
        let last = st.fg("dim", &last);
        let display = ui::fill_tmpl(
            &cfg.row("ws"),
            &[
                ("icon", icon),
                ("label", label),
                ("tabs", tab_n.to_string()),
                ("agents", agents_styled),
                ("last", last),
            ],
        );
        items.push(mk_item(display, ItemKind::Ws, &w.id, &q, false));

        for (ti, tab) in tabs.iter().enumerate() {
            let last_tab = ti + 1 == tabs.len();
            let branch = st.fg(
                "tree",
                if last_tab {
                    &cfg.icons.tree_last
                } else {
                    &cfg.icons.tree_mid
                },
            );
            let icon = status_icon(cfg, st, &tab.status);
            let number = st.fg("tab_number", &tab.position.to_string());
            let agents = model.tab_agents(&tab.id);
            let text = if agents.is_empty() {
                st.fg("tab_text", &model.tab_text(&tab.id))
            } else {
                st.fg("agent", &agents.join(", "))
            };
            let splits_n = model.panes_of(&tab.id).len();
            let splits = if splits_n > 1 {
                format!(
                    "  {}",
                    st.fg(
                        "dim",
                        &proc::subst_str(&cfg.ui.splits_fmt, &[("n", &splits_n.to_string())])
                    )
                )
            } else {
                String::new()
            };
            let active = if w.active_tab_id.as_deref() == Some(tab.id.as_str()) {
                format!(" {}", st.fg("dim", &cfg.icons.active_dot))
            } else {
                String::new()
            };
            let display = ui::fill_tmpl(
                &cfg.row("tab"),
                &[
                    ("branch", branch),
                    ("icon", icon),
                    ("number", number),
                    ("text", text),
                    ("splits", splits),
                    ("active", active),
                ],
            );
            items.push(mk_item(display, ItemKind::Tab, &tab.id, &q, false));

            let panes = model.panes_of(&tab.id);
            for (pi, p) in panes.iter().enumerate() {
                let last_pane = pi + 1 == panes.len();
                let pipe = if last_tab {
                    " ".to_string()
                } else {
                    st.fg("tree", &cfg.icons.pipe)
                };
                let branch = st.fg(
                    "tree",
                    if last_pane {
                        &cfg.icons.tree_last
                    } else {
                        &cfg.icons.tree_mid
                    },
                );
                let grip = st.fg("dim", &cfg.icons.grip);
                let icon = status_icon(cfg, st, &p.status);
                let text = if p.agent.is_some() {
                    st.fg("agent", &model.pane_text(p))
                } else {
                    model.pane_text(p)
                };
                let id = st.fg("pane_id", &Model::short_id(&p.id));
                let display = ui::fill_tmpl(
                    &cfg.row("pane"),
                    &[
                        ("pipe", pipe),
                        ("branch", branch),
                        ("grip", grip),
                        ("icon", icon),
                        ("text", text),
                        ("id", id),
                    ],
                );
                items.push(mk_item(display, ItemKind::Pane, &p.id, &q, false));
            }
        }
    }
    items
}

fn list_agents(cfg: &Config, st: &Style, model: &Model) -> Vec<Item> {
    let rank = |s: &str| -> i32 {
        match s {
            "blocked" => 0,
            "done" => 1,
            "working" => 2,
            "idle" => 3,
            _ => 4,
        }
    };
    let mut panes: Vec<&Pane> = model.panes.iter().filter(|p| p.agent.is_some()).collect();
    panes.sort_by(|a, b| (rank(&a.status), a.id.clone()).cmp(&(rank(&b.status), b.id.clone())));
    if panes.is_empty() {
        return vec![mk_item(st.dim(&cfg.text("no_agents")), ItemKind::None, "", "", false)];
    }
    let mut items = Vec::new();
    for p in panes {
        let ws = model.ws(&p.ws_id);
        let ws_label = ws
            .map(|w| st.fg("ws", &w.label))
            .unwrap_or_default();
        let sep = st.dim(&cfg.icons.sep);
        let number = st.fg("tab_number", &model.tab_position(&p.tab_id).to_string());
        let agent = st.fg("agent", p.agent.as_deref().unwrap_or(""));
        let title = st.fg("dim", &p.title);
        let display = ui::fill_tmpl(
            &cfg.row("agent"),
            &[
                ("icon", status_icon(cfg, st, &p.status)),
                ("ws", ws_label),
                ("sep", sep),
                ("number", number),
                ("agent", agent),
                ("title", title),
            ],
        );
        let search = ws.map(|w| w.label.clone()).unwrap_or_default();
        items.push(mk_item(display, ItemKind::Agent, &p.id, &search, false));
    }
    items
}

fn list_cfg(cfg: &Config, st: &Style, model: &Model) -> Vec<Item> {
    let args = cfg.cmd("sesh_list_config");
    let out = match proc::run(&cfg.bins.sesh, &args, timeout_ms(cfg, "list_timeout_ms", 15000)) {
        Ok(o) if o.status == 0 => o,
        _ => return Vec::new(),
    };
    let v: Value = serde_json::from_str(out.stdout.trim()).unwrap_or_else(|_| json!([]));
    let live_names: Vec<String> = model.workspaces.iter().map(|w| w.label.clone()).collect();
    let live_cwds: Vec<String> = model.panes.iter().map(|p| p.cwd.clone()).collect();
    let mut items = Vec::new();
    for s in v.as_array().cloned().unwrap_or_default() {
        let name = s.get("Name").and_then(|x| x.as_str()).unwrap_or("");
        let path = s.get("Path").and_then(|x| x.as_str()).unwrap_or("");
        if name.is_empty() || live_names.iter().any(|n| n == name) {
            continue;
        }
        if live_cwds.iter().any(|c| c == path) {
            continue;
        }
        let display = ui::fill_tmpl(
            &cfg.row("cfg"),
            &[
                ("icon", st.fg("dim", &cfg.icons.cfg)),
                ("name", st.fg("cfg", name)),
                ("saved", st.fg("dim", &cfg.text("saved"))),
            ],
        );
        items.push(mk_item(display, ItemKind::Cfg, name, name, false));
    }
    items
}

fn sesh_toml_paths(cfg: &Config) -> Vec<String> {
    let raw = std::fs::read_to_string(cfg.path("sesh_toml")).unwrap_or_default();
    let mut out = Vec::new();
    for line in raw.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("path") {
            let rest = rest.trim_start();
            if let Some(rest) = rest.strip_prefix('=') {
                let val = rest.trim().trim_matches('"').trim_matches('\'');
                if !val.is_empty() {
                    out.push(cfg.expand_path(val));
                }
            }
        }
    }
    out
}

fn score_tag(score: f64) -> String {
    if (score.fract()).abs() < f64::EPSILON {
        format!("{}", score as i64)
    } else {
        let s = format!("{score:.1}");
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

fn list_dir(cfg: &Config, st: &Style, model: &Model, full: bool) -> Vec<Item> {
    let args = cfg.cmd("zoxide_query");
    let out = match proc::run(&cfg.bins.zoxide, &args, timeout_ms(cfg, "list_timeout_ms", 15000)) {
        Ok(o) if o.status == 0 => o,
        _ => return Vec::new(),
    };
    let mut agg: HashMap<String, (f64, String)> = HashMap::new();
    for line in out.stdout.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let (score_s, path) = match line.split_once(' ') {
            Some(x) => x,
            None => continue,
        };
        let score: f64 = score_s.parse().unwrap_or(0.0);
        let path = path.trim();
        if path.is_empty() {
            continue;
        }
        let canon = match std::fs::canonicalize(path) {
            Ok(c) => c.to_string_lossy().into_owned(),
            Err(_) => continue,
        };
        if !Path::new(&canon).is_dir() {
            continue;
        }
        let e = agg.entry(canon).or_insert((0.0, path.to_string()));
        e.0 += score;
        if path.len() < e.1.len() {
            e.1 = path.to_string();
        }
    }

    let mut skip: HashSet<String> = HashSet::new();
    for p in &model.panes {
        if let Ok(c) = std::fs::canonicalize(&p.cwd) {
            skip.insert(c.to_string_lossy().into_owned());
        }
    }
    for p in sesh_toml_paths(cfg) {
        if let Ok(c) = std::fs::canonicalize(&p) {
            skip.insert(c.to_string_lossy().into_owned());
        }
    }

    let mut rows: Vec<(f64, String, String)> = agg
        .into_iter()
        .filter(|(real, _)| !skip.contains(real))
        .map(|(real, (score, p))| (score, p, real))
        .collect();
    rows.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.1.cmp(&a.1))
    });

    let ordered: Vec<(f64, String, String)> = if full {
        rows
    } else {
        let min = cfg.num("min_score", 1) as f64;
        let max = cfg.num("max_dirs", 400).max(0) as usize;
        let mut top: Vec<(f64, String, String)> = rows
            .iter()
            .filter(|(score, _, real)| *score >= min || Path::new(real).join(".git").exists())
            .cloned()
            .collect();
        top.truncate(max);
        let rest: Vec<(f64, String, String)> = rows
            .into_iter()
            .filter(|r| !top.contains(r))
            .collect();
        top.into_iter().chain(rest).collect()
    };

    let mut items = Vec::new();
    for (score, path, _real) in ordered {
        let mut shown = home_rel(&path);
        if let Some(rest) = shown.strip_prefix("/private/") {
            shown = format!("/{rest}");
        }
        let tag = if full {
            score_tag(score)
        } else {
            cfg.text("recent")
        };
        let display = ui::fill_tmpl(
            &cfg.row("dir"),
            &[
                ("icon", st.fg("dir", &cfg.icons.dir)),
                ("path", shown),
                ("tag", st.fg("dim", &tag)),
            ],
        );
        items.push(mk_item(display, ItemKind::Dir, &path, &path, false));
    }
    items
}

// ── preview / label / help ──────────────────────────────────────────────

/// One pane of the preview: a title line (tab headers in a grid) plus text.
#[derive(Clone, Debug)]
pub struct PreviewPart {
    pub title: String,
    pub text: String,
}

fn pane_read_text(cfg: &Config, pane_id: &str) -> String {
    let bin = herdr_bin(cfg);
    let args = proc::subst(&cfg.cmd("pane_read"), &[("id", pane_id)]);
    match proc::run(&bin, &args, timeout_ms(cfg, "preview_timeout_ms", 5000)) {
        Ok(o) if o.status == 0 => o.stdout,
        _ => cfg.text("no_preview"),
    }
}

pub fn preview_for(cfg: &Config, _st: &Style, model: &Model, item: &Item) -> String {
    match item.kind {
        ItemKind::Ws | ItemKind::Tab | ItemKind::Agent | ItemKind::Pane => {
            match model.entry_pane(item.kind.as_str(), &item.target) {
                Some(p) => pane_read_text(cfg, &p.id),
                None => cfg.text("no_preview"),
            }
        }
        ItemKind::Cfg | ItemKind::Dir => {
            let args = proc::subst(&cfg.cmd("sesh_preview"), &[("target", &item.target)]);
            match proc::run(&cfg.bins.sesh, &args, timeout_ms(cfg, "preview_timeout_ms", 5000)) {
                Ok(o) if o.status == 0 => o.stdout,
                _ => {
                    if item.kind == ItemKind::Dir {
                        let path = cfg.expand_path(&item.target);
                        let args = proc::subst(&cfg.cmd("ls_dir"), &[("path", &path)]);
                        match proc::run(&cfg.bins.ls, &args, timeout_ms(cfg, "preview_timeout_ms", 5000)) {
                            Ok(o) if o.status == 0 => o.stdout,
                            _ => cfg.text("no_preview"),
                        }
                    } else {
                        cfg.text("no_preview")
                    }
                }
            }
        }
        ItemKind::None => cfg.text("no_preview"),
    }
}

/// Parts to draw in the preview pane. A workspace with several tabs previews
/// one pane per tab (preview_grid in the config); everything else is one part.
pub fn preview_parts(cfg: &Config, st: &Style, model: &Model, item: &Item) -> Vec<PreviewPart> {
    let grid = &cfg.ui.preview_grid;
    if grid.enabled && item.kind == ItemKind::Ws {
        let tabs = model.ws_tabs(&item.target);
        if tabs.len() >= grid.min_tabs.max(1) && !tabs.is_empty() {
            let max = grid.max.max(1);
            let mut parts = Vec::new();
            for tab in tabs.iter().take(max) {
                let text = match model.tab_pane(&tab.id) {
                    Some(p) => pane_read_text(cfg, &p.id),
                    None => cfg.text("no_preview"),
                };
                let title = format!(
                    "{} {} {}",
                    status_icon(cfg, st, &tab.status),
                    st.fg("tab_number", &tab.position.to_string()),
                    st.fg("table_head", &model.tab_text(&tab.id))
                );
                parts.push(PreviewPart { title, text });
            }
            return parts;
        }
    }
    vec![PreviewPart {
        title: String::new(),
        text: preview_for(cfg, st, model, item),
    }]
}

/// Border label for a grid preview: "name · N tabs", marked when capped.
pub fn grid_label(cfg: &Config, model: &Model, item: &Item, shown: usize) -> String {
    let total = if item.kind == ItemKind::Ws {
        model.ws_tabs(&item.target).len()
    } else {
        shown
    };
    let name = model
        .ws(&item.target)
        .map(|w| w.label.clone())
        .unwrap_or_else(|| item.target.clone());
    let fmt = if shown < total {
        cfg.text("grid_label_more")
    } else {
        cfg.text("grid_label")
    };
    proc::subst_str(
        &fmt,
        &[
            ("name", &name),
            ("n", &total.to_string()),
            ("shown", &shown.to_string()),
        ],
    )
}

pub fn preview_for_key(cfg: &Config, st: &Style, model: &Model, key: &str) -> String {
    let item = item_from_line(key);
    preview_for(cfg, st, model, &item)
}

pub fn label_for(cfg: &Config, _st: &Style, model: &Model, item: &Item) -> String {
    let inner = match item.kind {
        ItemKind::Ws | ItemKind::Tab | ItemKind::Agent | ItemKind::Pane => {
            let pane = model.entry_pane(item.kind.as_str(), &item.target);
            match pane {
                Some(p) => {
                    let tab = model.tab(&p.tab_id);
                    let ws = tab.and_then(|t| model.ws(&t.ws_id));
                    let ws_label = ws.map(|w| w.label.clone()).unwrap_or_default();
                    let tab_count = ws
                        .map(|w| {
                            if w.tab_count > 0 {
                                w.tab_count
                            } else {
                                model.ws_tabs(&w.id).len()
                            }
                        })
                        .unwrap_or(1);
                    let mut parts = vec![ws_label];
                    if tab_count > 1 {
                        parts.push(proc::subst_str(
                            &cfg.text("tab_short"),
                            &[("n", &model.tab_position(&p.tab_id).to_string())],
                        ));
                    }
                    if let Some(a) = &p.agent {
                        parts.push(a.clone());
                    }
                    if p.status != "unknown" {
                        parts.push(p.status.clone());
                    }
                    let cwd = home_rel(&p.cwd);
                    if !cwd.is_empty() {
                        parts.push(cwd);
                    }
                    parts.join(" · ")
                }
                None => item.target.clone(),
            }
        }
        ItemKind::Cfg | ItemKind::Dir => item.target.clone(),
        ItemKind::None => String::new(),
    };
    if cfg.ui.preview_label_fmt.is_empty() {
        format!(" {inner} ")
    } else {
        proc::subst_str(&cfg.ui.preview_label_fmt, &[("text", &inner)])
    }
}

pub fn help_text(cfg: &Config, st: &Style) -> String {
    let mut s = cfg.help.clone();
    s = proc::subst_str(&s, &[("min_score", &cfg.num("min_score", 1).to_string())]);
    s = proc::subst_str(&s, &[("max_dirs", &cfg.num("max_dirs", 40).to_string())]);
    let markup: Vec<(&str, String)> = vec![
        ("red", st.fg_codes("danger")),
        ("r", ansi::RESET.to_string()),
        ("b", "\x1b[1m".to_string()),
        ("d", st.fg_codes("dim")),
        ("y", st.fg_codes("warning")),
        ("g", st.fg_codes("success")),
        ("c", st.fg_codes("info")),
        ("m", st.fg_codes("accent")),
        ("o", st.fg_codes("warning")),
        ("B", format!("\x1b[1m{}", st.fg_codes("accent2"))),
    ];
    for (k, v) in markup {
        s = s.replace(&format!("{{{k}}}"), &v);
    }
    s
}

// ── actions ─────────────────────────────────────────────────────────────

pub fn kill_item(cfg: &Config, item: &Item) -> Result<(), String> {
    match item.kind {
        ItemKind::Ws => {
            herdr_quiet(cfg, "workspace_close", &[("id", &item.target)]);
            Ok(())
        }
        ItemKind::Tab => {
            herdr_quiet(cfg, "tab_close", &[("id", &item.target)]);
            Ok(())
        }
        ItemKind::Dir => {
            let args = proc::subst(&cfg.cmd("zoxide_remove"), &[("path", &item.target)]);
            let _ = proc::run(&cfg.bins.zoxide, &args, timeout_ms(cfg, "herdr_timeout_ms", 15000));
            Ok(())
        }
        _ => Ok(()),
    }
}

fn find_key(v: &Value, key: &str) -> Option<String> {
    match v {
        Value::Object(map) => {
            if let Some(Value::String(s)) = map.get(key) {
                return Some(s.clone());
            }
            for (_, val) in map {
                if let Some(found) = find_key(val, key) {
                    return Some(found);
                }
            }
            None
        }
        Value::Array(arr) => {
            for val in arr {
                if let Some(found) = find_key(val, key) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

fn workspace_id_for(cfg: &Config, name: &str) -> Result<Option<String>, String> {
    let v = herdr_json(cfg, "workspace_list", &[])?;
    Ok(v.pointer("/result/workspaces")
        .and_then(|a| a.as_array())
        .and_then(|arr| {
            arr.iter().find(|w| {
                w.get("label").and_then(|l| l.as_str()) == Some(name)
            })
        })
        .and_then(|w| w.get("workspace_id"))
        .and_then(|s| s.as_str())
        .map(|s| s.to_string()))
}

pub fn connect(cfg: &Config, name: &str, path: &str, cmd: &str) -> Result<(), String> {
    if let Some(id) = workspace_id_for(cfg, name)? {
        return herdr_json(cfg, "workspace_focus", &[("id", &id)]).map(|_| ());
    }
    let path = if Path::new(path).is_dir() {
        path.to_string()
    } else {
        cfg.home()
    };
    let mut id = herdr_json(cfg, "workspace_create", &[("path", &path), ("label", name)])
        .ok()
        .and_then(|v| find_key(&v, "workspace_id"));
    if id.is_none() {
        id = workspace_id_for(cfg, name)?;
    }
    if !cmd.is_empty() {
        if let Some(id) = id {
            let wait = cfg.num("connect_wait_ms", 200).max(0) as u64;
            std::thread::sleep(Duration::from_millis(wait));
            let first = proc::subst_str(&cfg.conn("first_pane"), &[("id", &id)]);
            let _ = herdr_json(cfg, "pane_run", &[("id", &first), ("cmd", cmd)]);
        }
    }
    Ok(())
}

fn sesh_session(cfg: &Config, name: &str) -> (String, String) {
    let args = cfg.cmd("sesh_list_config");
    let out = proc::run(&cfg.bins.sesh, &args, timeout_ms(cfg, "list_timeout_ms", 15000));
    let v: Value = out
        .ok()
        .and_then(|o| serde_json::from_str(o.stdout.trim()).ok())
        .unwrap_or_else(|| json!([]));
    for s in v.as_array().cloned().unwrap_or_default() {
        if s.get("Name").and_then(|x| x.as_str()) == Some(name) {
            let path = s.get("Path").and_then(|x| x.as_str()).unwrap_or("");
            let cmd = s.get("StartupCommand").and_then(|x| x.as_str()).unwrap_or("");
            return (cfg.expand_path(path), cmd.to_string());
        }
    }
    (String::new(), String::new())
}

pub fn act(cfg: &Config, text: &str) -> Result<(), String> {
    if text.is_empty() {
        return Ok(());
    }
    if !text.contains('\t') {
        let path = cfg.expand_path(text);
        return connect(cfg, &base_name(&path), &path, "");
    }
    let item = item_from_line(text);
    match item.kind {
        ItemKind::Ws => {
            herdr_json(cfg, "workspace_focus", &[("id", &item.target)]).map(|_| ())
        }
        ItemKind::Tab => herdr_json(cfg, "tab_focus", &[("id", &item.target)]).map(|_| ()),
        ItemKind::Agent => herdr_json(cfg, "agent_focus", &[("id", &item.target)]).map(|_| ()),
        ItemKind::Pane => {
            let v = herdr_json(cfg, "pane_get", &[("id", &item.target)])?;
            let tab = v
                .pointer("/result/pane/tab_id")
                .and_then(|s| s.as_str())
                .unwrap_or("")
                .to_string();
            if tab.is_empty() {
                return Ok(());
            }
            herdr_json(cfg, "tab_focus", &[("id", &tab)]).map(|_| ())
        }
        ItemKind::Cfg => {
            let (path, cmd) = sesh_session(cfg, &item.target);
            connect(cfg, &item.target, &path, &cmd)
        }
        ItemKind::Dir => {
            let path = cfg.expand_path(&item.target);
            connect(cfg, &base_name(&path), &path, "")
        }
        ItemKind::None => Ok(()),
    }
}

pub fn browser(cfg: &Config, _st: &Style) -> Result<(), String> {
    print!("{}", cfg.text("browser_prompt"));
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    if std::io::stdin().read_line(&mut line).is_err() {
        return Ok(());
    }
    let input = line.trim().trim_end_matches('/');
    if input.is_empty() {
        return Ok(());
    }
    let s = match input.find("://") {
        Some(i) => &input[i + 3..],
        None => input,
    };
    let s = if s.to_lowercase().starts_with("www.") {
        &s[4..]
    } else {
        s
    };
    let host = s.split('/').next().unwrap_or("");
    let mut label = host.split('.').next().unwrap_or("").to_string();
    if let Some(first) = label.chars().next() {
        let mut it = label.chars();
        it.next();
        label = format!("{}{}", first.to_uppercase(), it.as_str());
    }
    let name = proc::subst_str(&cfg.conn("browser_label"), &[("label", &label)]);
    let cmd = proc::subst_str(
        &cfg.conn("browser_run"),
        &[
            ("terminal_browser", &cfg.expand_path(&cfg.bins.terminal_browser)),
            ("url", input),
        ],
    );
    connect(cfg, &name, &cfg.home(), &cmd)
}

pub fn scratch(cfg: &Config) -> Option<String> {
    let script = cfg.path("scratch_script");
    let (status, out) = proc::run_script_capture(&script, &[]).ok()?;
    if status != 0 {
        return None;
    }
    let path = out.trim().to_string();
    if path.is_empty() {
        None
    } else {
        Some(path)
    }
}

pub fn log_move(cfg: &Config, line: &str) {
    let dir = cfg.path("log_dir");
    if dir.is_empty() {
        return;
    }
    let _ = std::fs::create_dir_all(&dir);
    use std::fs::OpenOptions;
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{dir}/moves.log"))
    {
        let _ = writeln!(f, "{line}");
    }
}

pub fn move_argv(cfg: &Config, pane: &Pane, dest: &Dest) -> Vec<String> {
    match dest {
        Dest::Tab { tab_id, .. } => {
            proc::subst(&cfg.cmd("pane_move_tab"), &[("pane", &pane.id), ("tab", tab_id)])
        }
        Dest::Ws { ws_id } => {
            proc::subst(&cfg.cmd("pane_move_new_tab"), &[("pane", &pane.id), ("ws", ws_id)])
        }
    }
}

/// what a split is called in the UI: agent, title, cwd basename, else "shell"
pub fn pane_what(cfg: &Config, model: &Model, p: &Pane) -> String {
    let text = model.pane_text(p);
    if text.is_empty() {
        cfg.text("shell")
    } else {
        text
    }
}
