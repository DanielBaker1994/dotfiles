// Config: everything user-facing and every CLI invocation lives in
// herdr-pick.json (see sesh/herdr-pick.json). Nothing in this file hardcodes
// strings, sizes or commands — only lookup defaults for safety.

use serde::Deserialize;
use std::collections::HashMap;
use std::fs;

#[derive(Deserialize, Clone, Debug)]
pub struct Config {
    #[serde(default)]
    #[allow(dead_code)]
    pub meta: serde_json::Value,
    pub bins: Bins,
    #[serde(default)]
    pub commands: HashMap<String, Vec<String>>,
    #[serde(default)]
    pub paths: HashMap<String, String>,
    #[serde(default)]
    pub behavior: HashMap<String, i64>,
    #[serde(default)]
    pub connect: HashMap<String, String>,
    pub ui: Ui,
    pub icons: Icons,
    #[serde(default)]
    pub rows: HashMap<String, String>,
    #[serde(default)]
    pub texts: HashMap<String, String>,
    pub keys: Keys,
    pub style: StyleCfg,
    pub help: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Bins {
    pub herdr: String,
    #[serde(default)]
    pub herdr_env: String,
    #[serde(default)]
    pub herdr_fallbacks: Vec<String>,
    pub sesh: String,
    pub zoxide: String,
    #[allow(dead_code)]
    pub fd: String,
    pub ls: String,
    pub terminal_browser: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Ui {
    pub border_label: String,
    #[serde(default)]
    pub preview_label_fmt: String,
    #[serde(default)]
    pub help_label: String,
    pub prompt_sep: String,
    #[serde(default)]
    pub prompts: HashMap<String, String>,
    pub sorts: Vec<String>,
    pub table_head: TableHead,
    pub hints: Vec<Hint>,
    #[serde(default = "default_sep")]
    pub hint_sep: String,
    pub info_fmt: String,
    pub loading: String,
    pub splits_fmt: String,
    #[serde(default)]
    pub age: HashMap<String, String>,
    #[serde(rename = "box")]
    pub box_chars: BoxChars,
    #[serde(default)]
    pub edge_pulse: Vec<String>,
    #[serde(default)]
    pub preview_grid: PreviewGrid,
}

/// Multi-tab preview: a space with several tabs previews one pane per tab in
/// a grid instead of only its active tab.
#[derive(Deserialize, Clone, Debug)]
pub struct PreviewGrid {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_grid_max")]
    pub max: usize,
    #[serde(default = "default_grid_min")]
    pub min_tabs: usize,
}

impl Default for PreviewGrid {
    fn default() -> Self {
        PreviewGrid {
            enabled: true,
            max: default_grid_max(),
            min_tabs: default_grid_min(),
        }
    }
}

fn default_true() -> bool {
    true
}

fn default_grid_max() -> usize {
    4
}

fn default_grid_min() -> usize {
    2
}

fn default_sep() -> String {
    "  ".to_string()
}

#[derive(Deserialize, Clone, Debug)]
pub struct TableHead {
    pub name: String,
    pub name_w: usize,
    pub tabs: String,
    pub tabs_w: usize,
    pub agents: String,
    pub agents_w: usize,
    pub last: String,
    #[serde(default)]
    pub sort_mark: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Hint {
    pub key: String,
    pub label: String,
    #[serde(default)]
    pub alt: Option<String>,
    #[serde(default)]
    pub modes: Vec<String>,
    #[serde(default)]
    pub active_modes: Vec<String>,
    #[serde(default)]
    pub last: bool,
}

#[derive(Deserialize, Clone, Debug)]
pub struct BoxChars {
    pub tl: String,
    pub tr: String,
    pub bl: String,
    pub br: String,
    pub h: String,
    pub v: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Icons {
    #[serde(default)]
    pub status: HashMap<String, String>,
    pub tree_mid: String,
    pub tree_last: String,
    pub pipe: String,
    pub grip: String,
    pub cfg: String,
    pub dir: String,
    pub sep: String,
    pub active_dot: String,
    pub landing_add: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Keys {
    #[serde(default)]
    pub keymap: HashMap<String, String>,
    #[serde(default)]
    pub move_keymap: HashMap<String, String>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct StyleCfg {
    #[serde(default)]
    pub palette: HashMap<String, String>,
    #[serde(default)]
    pub palette_source: Option<PaletteSource>,
    #[serde(default)]
    pub tokens: HashMap<String, String>,
    pub selection_edge_glyph: String,
    #[serde(default)]
    pub ws_bold: bool,
    pub pulse_from: String,
    pub pulse_to: String,
    pub pulse_steps: u32,
}

#[derive(Deserialize, Clone, Debug)]
pub struct PaletteSource {
    pub file: String,
    pub section: String,
    #[serde(default)]
    pub map: HashMap<String, String>,
    #[serde(default)]
    pub derive: Vec<String>,
}

impl Config {
    pub fn load() -> Result<(Config, String), String> {
        let candidates = Self::candidates();
        let mut path: Option<String> = None;
        if let Ok(p) = std::env::var("HERDR_PICK_CONFIG") {
            if !p.is_empty() && std::path::Path::new(&p).is_file() {
                path = Some(p);
            }
        }
        if path.is_none() {
            for c in &candidates {
                if std::path::Path::new(c).is_file() {
                    path = Some(c.clone());
                    break;
                }
            }
        }
        let path = path.ok_or_else(|| {
            format!(
                "herdr-pick: config not found (looked at {})",
                candidates.join(", ")
            )
        })?;
        let raw = fs::read_to_string(&path).map_err(|e| format!("herdr-pick: {path}: {e}"))?;
        let value: serde_json::Value =
            serde_json::from_str(&raw).map_err(|e| format!("herdr-pick: bad config {path}: {e}"))?;
        let cfg: Config = serde_json::from_value(value)
            .map_err(|e| format!("herdr-pick: bad config {path}: {e}"))?;
        Ok((cfg, path))
    }

    fn candidates() -> Vec<String> {
        let mut v: Vec<String> = Vec::new();
        if let Ok(exe) = std::env::current_exe() {
            if let Some(d) = exe.parent() {
                v.push(d.join("herdr-pick.json").to_string_lossy().into_owned());
                if let Some(parent) = d.parent() {
                    v.push(parent.join("herdr-pick.json").to_string_lossy().into_owned());
                }
            }
        }
        v.push(default_config_path());
        v
    }

    pub fn home(&self) -> String {
        std::env::var("HOME").unwrap_or_else(|_| String::new())
    }

    pub fn expand_path(&self, s: &str) -> String {
        let home = self.home();
        let mut out = s.replace("${HOME}", &home).replace("$HOME", &home);
        if out == "~" {
            out = home.clone();
        } else if let Some(rest) = out.strip_prefix("~/") {
            out = format!("{home}/{rest}");
        }
        out
    }

    pub fn path(&self, key: &str) -> String {
        self.paths
            .get(key)
            .map(|v| self.expand_path(v))
            .unwrap_or_default()
    }

    pub fn text(&self, key: &str) -> String {
        self.texts.get(key).cloned().unwrap_or_default()
    }

    pub fn cmd(&self, key: &str) -> Vec<String> {
        self.commands.get(key).cloned().unwrap_or_default()
    }

    pub fn conn(&self, key: &str) -> String {
        self.connect.get(key).cloned().unwrap_or_default()
    }

    pub fn row(&self, key: &str) -> String {
        self.rows.get(key).cloned().unwrap_or_default()
    }

    pub fn num(&self, key: &str, default: i64) -> i64 {
        self.behavior.get(key).copied().unwrap_or(default)
    }

    pub fn prompt(&self, mode: &str) -> String {
        self.ui.prompts.get(mode).cloned().unwrap_or_else(|| mode.to_string())
    }

    pub fn icon_status(&self, status: &str) -> String {
        self.icons
            .status
            .get(status)
            .cloned()
            .unwrap_or_else(|| " ".to_string())
    }
}

pub fn default_config_path() -> String {
    let home = std::env::var("HOME").unwrap_or_else(|_| "~".to_string());
    format!("{home}/.dotfiles/sesh/herdr-pick.json")
}
