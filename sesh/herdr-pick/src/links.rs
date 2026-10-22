// The link bank (kitchen-sink PLAN-link-bank.md): the `links.v1` row
// contract shared with kitchen-sink. This side provides herdr's workspaces
// (`list --json`, `go-id`) and reads kitchen-sink's places over its socket
// for the collapsed group at the bottom of the picker. Every path, verb,
// argv and string lives in herdr-pick.json (`links`, `commands`, `texts`).

use crate::config::Config;
use crate::data;
use crate::model::{home_rel, Model};
use crate::proc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

pub const VERSION: i64 = 1;

/// One row of the contract. Every field is always written (`null` for an
/// absent optional) so both sides read one fixed shape.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct LinkRow {
    pub source: String,
    pub kind: String,
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub subtitle: String,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub recent: i64,
    #[serde(default)]
    pub preview: Option<String>,
}

impl LinkRow {
    pub fn active(&self) -> bool {
        matches!(self.status.as_deref(), Some("working") | Some("waiting"))
    }

    pub fn search_text(&self) -> String {
        format!("{} {} {}", self.title, self.subtitle, self.cwd.as_deref().unwrap_or(""))
    }
}

pub fn envelope(rows: &[LinkRow]) -> Value {
    json!({ "version": VERSION, "rows": rows })
}

#[derive(Clone, Debug, PartialEq)]
pub enum LinkErr {
    /// The other app is not running.
    Offline,
    /// Bad JSON, a timeout, an old daemon without the verb, an `{"error"}`.
    Unavailable(String),
}

pub fn parse_envelope(text: &str) -> Result<Vec<LinkRow>, LinkErr> {
    if text.trim().is_empty() {
        return Err(LinkErr::Unavailable("empty reply".into()));
    }
    let v: Value = serde_json::from_str(text.trim())
        .map_err(|e| LinkErr::Unavailable(format!("bad links reply: {e}")))?;
    if let Some(err) = v.get("error") {
        if v.get("offline").and_then(|o| o.as_bool()) == Some(true) {
            return Err(LinkErr::Offline);
        }
        return Err(LinkErr::Unavailable(err.as_str().unwrap_or("error").to_string()));
    }
    let version = v.get("version").and_then(|x| x.as_i64()).unwrap_or(0);
    if version != VERSION {
        return Err(LinkErr::Unavailable(format!("links version {version}")));
    }
    serde_json::from_value(v.get("rows").cloned().unwrap_or_else(|| json!([])))
        .map_err(|e| LinkErr::Unavailable(format!("bad links rows: {e}")))
}

/// The provider's most recent place first, busy / waiting agents next,
/// then the rest by `recent`.
pub fn order_rows(mut rows: Vec<LinkRow>) -> Vec<LinkRow> {
    rows.sort_by_key(|r| (r.recent != 0, !r.active(), r.recent));
    rows
}

// ── herdr → contract (`herdr-pick list --json`) ───────────────────────────

fn lk(cfg: &Config, key: &str) -> String {
    cfg.links.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

fn lk_ms(cfg: &Config, key: &str, default: u64) -> Duration {
    Duration::from_millis(cfg.links.get(key).and_then(|v| v.as_u64()).unwrap_or(default))
}

/// herdr agent status → the contract's `working | waiting | idle | unknown`.
fn contract_status(cfg: &Config, status: &str) -> String {
    cfg.links
        .get("status_map")
        .and_then(|m| m.get(status))
        .and_then(|s| s.as_str())
        .unwrap_or("unknown")
        .to_string()
}

/// herdr's workspaces as contract rows, ranked by the picker's MRU.
pub fn herdr_rows(cfg: &Config, model: &Model, mru: &[(String, i64)]) -> Vec<LinkRow> {
    let rank = |id: &str| mru.iter().position(|(m, _)| m == id).unwrap_or(usize::MAX);
    let mut ws: Vec<_> = model.workspaces.iter().collect();
    ws.sort_by_key(|w| (rank(&w.id), w.number));
    ws.iter()
        .enumerate()
        .map(|(i, w)| {
            let tabs = if w.tab_count > 0 { w.tab_count } else { model.ws_tabs(&w.id).len() };
            let tabs_text = proc::subst_str(
                &cfg.text(if tabs == 1 { "link_tab" } else { "link_tabs" }),
                &[("n", &tabs.to_string())],
            );
            let status = contract_status(cfg, &w.status);
            let subtitle = if status == "unknown" {
                tabs_text
            } else {
                proc::subst_str(&cfg.text("link_subtitle"), &[("tabs", &tabs_text), ("status", &status)])
            };
            let cwd = model.entry_pane("ws", &w.id).map(|p| home_rel(&p.cwd)).filter(|c| !c.is_empty());
            LinkRow {
                source: "herdr".into(),
                kind: "workspace".into(),
                id: w.id.clone(),
                title: w.label.clone(),
                subtitle,
                status: Some(status),
                cwd,
                recent: i as i64,
                preview: None,
            }
        })
        .collect()
}

/// `herdr-pick list --json`: the envelope, or an `{"error"}` (offline when
/// the herdr server is not up). Returns the exit code.
pub fn print_list_json(cfg: &Config) -> i32 {
    if data::ensure_herdr(cfg).is_err() {
        println!("{}", json!({ "error": cfg.text("link_herdr_offline"), "offline": true }));
        return 1;
    }
    match data::fetch_state(cfg) {
        Ok(state) => {
            let model = Model::build(&state);
            let rows = herdr_rows(cfg, &model, &data::load_mru(cfg));
            println!("{}", envelope(&rows));
            0
        }
        Err(e) => {
            println!("{}", json!({ "error": e }));
            1
        }
    }
}

// ── `herdr-pick go-id <workspace_id>` ─────────────────────────────────────

fn first_bin(cfg: &Config, key: &str) -> Option<String> {
    let names: Vec<String> = cfg
        .links
        .get(key)
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|s| s.as_str()).map(|s| cfg.expand_path(s)).collect())
        .unwrap_or_default();
    names.into_iter().find(|n| data::which(n).is_some())
}

/// The Ghostty window to raise: with one, that one; with several, the first
/// whose title contains any `links.ghostty_title_match` entry, else the first.
pub fn pick_window(windows: &Value, matches: &[String]) -> Option<i64> {
    let arr = windows.as_array()?;
    let id = |w: &Value| w.get("window-id").and_then(|x| x.as_i64());
    let title = |w: &Value| w.get("window-title").and_then(|x| x.as_str()).unwrap_or("").to_string();
    arr.iter()
        .find(|w| matches.iter().any(|m| !m.is_empty() && title(w).contains(m.as_str())))
        .or_else(|| arr.first())
        .and_then(id)
}

/// Raise Ghostty through AeroSpace, then focus the herdr workspace. With
/// no AeroSpace or no Ghostty window, `ghostty_open` (LaunchServices) brings
/// it up instead — never an error for a missing piece.
pub fn go_id(cfg: &Config, ws_id: &str) -> Result<(), String> {
    let mut raised = false;
    if let Some(aero) = first_bin(cfg, "aerospace") {
        let timeout = lk_ms(cfg, "aerospace_timeout_ms", 2000);
        let args = proc::subst(&cfg.cmd("aerospace_windows"), &[("bundle", &lk(cfg, "ghostty_bundle"))]);
        let windows = proc::run(&aero, &args, timeout)
            .ok()
            .and_then(|o| serde_json::from_str::<Value>(o.stdout.trim()).ok())
            .unwrap_or_else(|| json!([]));
        let matches: Vec<String> = cfg
            .links
            .get("ghostty_title_match")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|s| s.as_str()).map(str::to_string).collect())
            .unwrap_or_default();
        if let Some(wid) = pick_window(&windows, &matches) {
            let args = proc::subst(&cfg.cmd("aerospace_focus"), &[("id", &wid.to_string())]);
            raised = proc::run(&aero, &args, timeout).map(|o| o.status == 0).unwrap_or(false);
        }
    }
    if !raised {
        let argv = proc::subst(&cfg.cmd("ghostty_open"), &[("bundle", &lk(cfg, "ghostty_bundle"))]);
        if let Some((prog, args)) = argv.split_first() {
            let _ = proc::run(prog, args, lk_ms(cfg, "aerospace_timeout_ms", 2000));
        }
    }
    if ws_id.is_empty() || data::ensure_herdr(cfg).is_err() {
        return Ok(());
    }
    data::herdr_json(cfg, "workspace_focus", &[("id", ws_id)]).map(|_| ())
}

// ── kitchen-sink over its socket ──────────────────────────────────────────

fn ks_socket(cfg: &Config) -> String {
    let tmp = std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp/".into());
    let tmp = if tmp.ends_with('/') { tmp } else { format!("{tmp}/") };
    cfg.expand_path(&lk(cfg, "ks_socket")).replace("$TMPDIR/", &tmp).replace("$TMPDIR", &tmp)
}

/// One request line → the reply text. A missing / refused socket is
/// "offline" (listing never launches the daemon).
fn ks_request(cfg: &Config, line: &str, timeout: Duration) -> Result<String, LinkErr> {
    let mut s = UnixStream::connect(ks_socket(cfg)).map_err(|_| LinkErr::Offline)?;
    let _ = s.set_read_timeout(Some(timeout));
    let _ = s.set_write_timeout(Some(timeout));
    s.write_all(format!("{line}\n").as_bytes())
        .map_err(|e| LinkErr::Unavailable(e.to_string()))?;
    let mut out = String::new();
    s.read_to_string(&mut out).map_err(|e| LinkErr::Unavailable(e.to_string()))?;
    Ok(out)
}

/// kitchen-sink's places (`links` verb), within the `timeout_ms` budget.
pub fn fetch_ks(cfg: &Config) -> Result<Vec<LinkRow>, LinkErr> {
    let text = ks_request(cfg, &lk(cfg, "ks_list"), lk_ms(cfg, "timeout_ms", 300))?;
    parse_envelope(&text).map(order_rows)
}

/// Present a kitchen-sink place (`do:go:<id>`).
pub fn go_ks(cfg: &Config, id: &str) -> Result<(), LinkErr> {
    let line = proc::subst_str(&lk(cfg, "ks_go"), &[("id", id)]);
    let reply = ks_request(cfg, &line, lk_ms(cfg, "go_timeout_ms", 3000))?;
    match serde_json::from_str::<Value>(reply.trim()) {
        Ok(v) if v.get("error").is_some() => {
            Err(LinkErr::Unavailable(v["error"].as_str().unwrap_or("error").to_string()))
        }
        _ => Ok(()),
    }
}

/// kitchen-sink is on this machine: its socket is up, or the `ks_launch`
/// program exists. Without either the group is not shown at all.
pub fn ks_installed(cfg: &Config) -> bool {
    std::path::Path::new(&ks_socket(cfg)).exists()
        || cfg
            .cmd("ks_launch")
            .first()
            .map(|p| std::path::Path::new(&cfg.expand_path(p)).is_file())
            .unwrap_or(false)
}

/// Start kitchen-sink (the offline header's Return).
pub fn launch_ks(cfg: &Config) {
    let argv = cfg.cmd("ks_launch");
    if let Some((prog, args)) = argv.split_first() {
        let prog = cfg.expand_path(prog);
        let args: Vec<String> = args.iter().map(|a| cfg.expand_path(a)).collect();
        let _ = std::process::Command::new(prog)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

/// Last good kitchen-sink rows (stale-while-revalidate across opens).
pub fn load_cache(cfg: &Config) -> Option<Vec<LinkRow>> {
    let text = std::fs::read_to_string(cfg.expand_path(&lk(cfg, "ks_cache"))).ok()?;
    parse_envelope(&text).ok().map(order_rows)
}

pub fn save_cache(cfg: &Config, rows: &[LinkRow]) {
    let path = cfg.expand_path(&lk(cfg, "ks_cache"));
    if let Some(dir) = std::path::Path::new(&path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(path, envelope(rows).to_string());
}

// ── the collapsed group (the picker's model) ─────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GroupStatus {
    Loading,
    Ready,
    Offline,
    Unavailable,
}

#[derive(Clone, Debug)]
pub struct Group {
    pub rows: Vec<LinkRow>,
    pub status: GroupStatus,
    pub expanded: bool,
    /// Names that search the group itself (`links.group_names`): a query whose
    /// first word is one of them keeps the header and every row, and the rest
    /// of the query narrows the rows (`ks notes`).
    pub names: Vec<String>,
}

impl Group {
    pub fn new(cached: Option<Vec<LinkRow>>, expanded: bool, names: Vec<String>) -> Group {
        Group { rows: cached.unwrap_or_default(), status: GroupStatus::Loading, expanded, names }
    }

    pub fn apply(&mut self, r: Result<Vec<LinkRow>, LinkErr>) {
        match r {
            Ok(rows) => {
                self.rows = rows;
                self.status = GroupStatus::Ready;
            }
            Err(LinkErr::Offline) => {
                self.rows.clear();
                self.status = GroupStatus::Offline;
            }
            Err(LinkErr::Unavailable(_)) => {
                self.rows.clear();
                self.status = GroupStatus::Unavailable;
            }
        }
    }

    pub fn dim(&self) -> bool {
        matches!(self.status, GroupStatus::Offline | GroupStatus::Unavailable)
    }

    /// `Some(rest)` when the query's first word names the group (exactly, or
    /// a 3+ letter prefix of a name): `ks notes` → `notes`, `kitchen` → ``.
    pub fn scope<'a>(&self, query: &'a str) -> Option<&'a str> {
        let q = query.trim_start();
        let (first, rest) = q.split_once(char::is_whitespace).unwrap_or((q, ""));
        let first = first.to_lowercase();
        let hit = !first.is_empty()
            && self.names.iter().any(|n| {
                let n = n.to_lowercase();
                n == first || (first.chars().count() >= 3 && n.starts_with(&first))
            });
        hit.then(|| rest.trim())
    }

    /// The part of the query that filters the rows (the name word dropped).
    pub fn row_query<'a>(&self, query: &'a str) -> &'a str {
        self.scope(query).unwrap_or(query)
    }

    /// `(row index, score)` to draw under the header: a query shows its
    /// matches (auto-expanded, ranked), a query naming the group shows every
    /// row (or the matches of the words after the name), no query shows
    /// everything when expanded and nothing when collapsed.
    pub fn visible(&self, query: &str) -> Vec<(usize, f64)> {
        if query.is_empty() {
            return if self.expanded { (0..self.rows.len()).map(|i| (i, 0.0)).collect() } else { Vec::new() };
        }
        let q = self.row_query(query);
        if q.is_empty() {
            return (0..self.rows.len()).map(|i| (i, 0.0)).collect();
        }
        let mut v: Vec<(usize, f64)> = self
            .rows
            .iter()
            .enumerate()
            .filter_map(|(i, r)| crate::fuzzy::fuzzy_match(&r.search_text(), q).map(|(_, s)| (i, s)))
            .collect();
        v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        v
    }

    pub fn header_shown(&self, query: &str) -> bool {
        query.is_empty() || self.scope(query).is_some() || !self.visible(query).is_empty()
    }

    pub fn open(&self, query: &str) -> bool {
        self.expanded || !query.is_empty()
    }

    /// `kitchen-sink · 9 places` / `· …` / `· not running` / `· unavailable`.
    pub fn header_tail(&self, cfg: &Config) -> String {
        match self.status {
            GroupStatus::Offline => cfg.text("group_offline"),
            GroupStatus::Unavailable => cfg.text("group_unavailable"),
            GroupStatus::Loading if self.rows.is_empty() => cfg.text("group_loading"),
            _ => proc::subst_str(&cfg.text("group_count"), &[("n", &self.rows.len().to_string())]),
        }
    }
}

/// ↑ / ↓ through the whole list (the group pinned on top), wrapping.
pub fn step(len: usize, pos: usize, delta: i64) -> usize {
    if len == 0 {
        return 0;
    }
    (pos.min(len - 1) as i64 + delta.signum()).rem_euclid(len as i64) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    const KS: &str = include_str!("../tests/fixtures/links/kitchen-sink.json");
    const HERDR: &str = include_str!("../tests/fixtures/links/herdr.json");

    fn row(id: &str, recent: i64, status: Option<&str>) -> LinkRow {
        LinkRow {
            source: "kitchen-sink".into(),
            kind: "view".into(),
            id: id.into(),
            title: id.into(),
            status: status.map(str::to_string),
            recent,
            ..LinkRow::default()
        }
    }

    #[test]
    fn fixtures_round_trip() {
        for text in [KS, HERDR] {
            let rows = parse_envelope(text).unwrap();
            assert!(!rows.is_empty());
            assert_eq!(parse_envelope(&envelope(&rows).to_string()).unwrap(), rows);
        }
        let v = envelope(&[row("a", 0, None)]);
        for k in ["source", "kind", "id", "title", "subtitle", "status", "cwd", "recent", "preview"] {
            assert!(v["rows"][0].get(k).is_some(), "{k}");
        }
    }

    #[test]
    fn errors() {
        assert_eq!(parse_envelope(r#"{"error":"x","offline":true}"#), Err(LinkErr::Offline));
        assert!(matches!(parse_envelope(""), Err(LinkErr::Unavailable(_))));
        assert!(matches!(parse_envelope(r#"{"error":"x"}"#), Err(LinkErr::Unavailable(_))));
        assert!(matches!(parse_envelope(r#"{"version":9,"rows":[]}"#), Err(LinkErr::Unavailable(_))));
    }

    #[test]
    fn order_recent_then_busy() {
        let ids: Vec<String> = order_rows(vec![
            row("c", 3, None),
            row("w", 4, Some("working")),
            row("a", 0, None),
            row("b", 1, None),
        ])
        .into_iter()
        .map(|r| r.id)
        .collect();
        assert_eq!(ids, ["a", "w", "b", "c"]);
    }

    #[test]
    fn group_collapsed_then_query_expands_to_matches() {
        let mut g = Group::new(None, false, vec![]);
        g.apply(Ok(vec![row("notes", 0, None), row("files", 1, None)]));
        assert!(g.visible("").is_empty());
        assert!(g.header_shown(""));
        assert_eq!(g.visible("fil").iter().map(|x| x.0).collect::<Vec<_>>(), vec![1]);
        assert!(g.open("fil"));
        assert!(!g.header_shown("zzz"));
        g.expanded = true;
        assert_eq!(g.visible("").len(), 2);
        g.apply(Err(LinkErr::Offline));
        assert!(g.dim() && g.rows.is_empty());
    }

    #[test]
    fn group_name_keeps_header_and_scopes_rows() {
        let mut g = Group::new(None, true, vec!["kitchen-sink".into(), "ks".into()]);
        g.apply(Ok(vec![row("notes", 0, None), row("files", 1, None)]));
        assert_eq!(g.visible("").len(), 2, "expanded by default");
        assert!(g.header_shown("kitchen-sink"));
        assert_eq!(g.visible("kitchen-sink").len(), 2);
        assert_eq!(g.scope("kitch"), Some(""));
        assert_eq!(g.scope("ks  fil"), Some("fil"));
        assert_eq!(g.visible("ks fil").iter().map(|x| x.0).collect::<Vec<_>>(), vec![1]);
        assert_eq!(g.scope("ki"), None, "two letters is not a prefix hit");
        assert_eq!(g.scope("notes"), None);
        assert!(g.header_shown("ks zzz"), "the name alone keeps the header");
        assert!(g.visible("ks zzz").is_empty());
    }

    #[test]
    fn step_wraps() {
        assert_eq!(step(6, 0, 1), 1);
        assert_eq!(step(6, 5, 1), 0);
        assert_eq!(step(6, 0, -1), 5);
        assert_eq!(step(0, 0, 1), 0);
    }

    #[test]
    fn pick_window_prefers_a_title_match() {
        let w = json!([
            {"window-id": 1, "window-title": "zsh"},
            {"window-id": 2, "window-title": "host: herdr"}
        ]);
        assert_eq!(pick_window(&w, &[]), Some(1));
        assert_eq!(pick_window(&w, &["herdr".into()]), Some(2));
        assert_eq!(pick_window(&json!([]), &[]), None);
    }
}
