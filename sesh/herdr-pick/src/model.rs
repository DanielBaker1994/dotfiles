// The herdr snapshot model: workspaces / tabs / panes, keyed by herdr ids.
// Port of herdr-move.mjs + the entry_pane jq helpers in connect-herdr.sh.

use serde_json::Value;
use std::collections::HashMap;

#[derive(Clone, Debug)]
pub struct Workspace {
    pub id: String,
    pub label: String,
    pub number: i64,
    pub focused: bool,
    pub status: String,
    pub active_tab_id: Option<String>,
    pub tab_count: usize,
}

#[derive(Clone, Debug)]
pub struct Tab {
    pub id: String,
    pub ws_id: String,
    #[allow(dead_code)]
    pub number: i64,
    pub position: usize,
    #[allow(dead_code)]
    pub label: String,
    pub status: String,
}

#[derive(Clone, Debug)]
pub struct Pane {
    pub id: String,
    pub tab_id: String,
    pub ws_id: String,
    #[allow(dead_code)]
    pub index: usize,
    pub agent: Option<String>,
    pub status: String,
    pub title: String,
    pub cwd: String,
    pub focused: bool,
}

#[derive(Clone, Debug)]
pub enum Dest {
    Ws { ws_id: String },
    Tab { ws_id: String, tab_id: String },
}

impl Dest {
    pub fn tab_id(&self) -> Option<&str> {
        match self {
            Dest::Tab { tab_id, .. } => Some(tab_id),
            Dest::Ws { .. } => None,
        }
    }
    pub fn ws_id(&self) -> &str {
        match self {
            Dest::Ws { ws_id } => ws_id,
            Dest::Tab { ws_id, .. } => ws_id,
        }
    }
    pub fn is_tab(&self) -> bool {
        matches!(self, Dest::Tab { .. })
    }
}

#[derive(Clone, Debug, Default)]
pub struct Model {
    pub workspaces: Vec<Workspace>,
    pub tabs: Vec<Tab>,
    pub panes: Vec<Pane>,
}

impl Model {
    pub fn build(state: &Value) -> Model {
        let arr = |key: &str| -> Vec<Value> {
            state
                .get(key)
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default()
        };
        let s = |v: &Value, k: &str| -> String {
            v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string()
        };
        let i = |v: &Value, k: &str| -> i64 { v.get(k).and_then(|x| x.as_i64()).unwrap_or(0) };
        let b = |v: &Value, k: &str| -> bool { v.get(k).and_then(|x| x.as_bool()).unwrap_or(false) };

        let mut workspaces: Vec<Workspace> = arr("ws")
            .iter()
            .map(|w| {
                let id = s(w, "workspace_id");
                Workspace {
                    label: {
                        let l = s(w, "label");
                        if l.is_empty() { id.clone() } else { l }
                    },
                    id,
                    number: i(w, "number"),
                    focused: b(w, "focused"),
                    status: {
                        let st = s(w, "agent_status");
                        if st.is_empty() { "unknown".into() } else { st }
                    },
                    active_tab_id: w
                        .get("active_tab_id")
                        .and_then(|x| x.as_str())
                        .map(|x| x.to_string()),
                    tab_count: i(w, "tab_count") as usize,
                }
            })
            .collect();
        workspaces.sort_by_key(|w| w.number);

        let ws_ids: Vec<&str> = workspaces.iter().map(|w| w.id.as_str()).collect();
        let mut per_ws: HashMap<String, usize> = HashMap::new();
        let tabs: Vec<Tab> = arr("tabs")
            .iter()
            .filter(|t| ws_ids.contains(&s(t, "workspace_id").as_str()))
            .map(|t| {
                let ws_id = s(t, "workspace_id");
                let pos = per_ws.entry(ws_id.clone()).or_insert(0);
                *pos += 1;
                Tab {
                    id: s(t, "tab_id"),
                    ws_id,
                    number: i(t, "number"),
                    position: *pos,
                    label: s(t, "label"),
                    status: {
                        let st = s(t, "agent_status");
                        if st.is_empty() { "unknown".into() } else { st }
                    },
                }
            })
            .collect();

        let tab_ids: Vec<&str> = tabs.iter().map(|t| t.id.as_str()).collect();
        let mut per_tab: HashMap<String, usize> = HashMap::new();
        let panes: Vec<Pane> = arr("panes")
            .iter()
            .filter(|p| tab_ids.contains(&s(p, "tab_id").as_str()))
            .map(|p| {
                let tab_id = s(p, "tab_id");
                let idx = per_tab.entry(tab_id.clone()).or_insert(0);
                let index = *idx;
                *idx += 1;
                let fg = s(p, "foreground_cwd");
                let cwd = if fg.is_empty() { s(p, "cwd") } else { fg };
                Pane {
                    id: s(p, "pane_id"),
                    tab_id,
                    ws_id: s(p, "workspace_id"),
                    index,
                    agent: p
                        .get("agent")
                        .and_then(|x| x.as_str())
                        .map(|x| x.to_string())
                        .filter(|x| !x.is_empty()),
                    status: {
                        let st = s(p, "agent_status");
                        if st.is_empty() { "unknown".into() } else { st }
                    },
                    title: s(p, "terminal_title_stripped"),
                    cwd,
                    focused: b(p, "focused"),
                }
            })
            .collect();

        Model {
            workspaces,
            tabs,
            panes,
        }
    }

    pub fn ws(&self, id: &str) -> Option<&Workspace> {
        self.workspaces.iter().find(|w| w.id == id)
    }

    pub fn tab(&self, id: &str) -> Option<&Tab> {
        self.tabs.iter().find(|t| t.id == id)
    }

    pub fn pane(&self, id: &str) -> Option<&Pane> {
        self.panes.iter().find(|p| p.id == id)
    }

    pub fn ws_tabs(&self, ws_id: &str) -> Vec<&Tab> {
        self.tabs.iter().filter(|t| t.ws_id == ws_id).collect()
    }

    pub fn panes_of(&self, tab_id: &str) -> Vec<&Pane> {
        self.panes.iter().filter(|p| p.tab_id == tab_id).collect()
    }

    /// the pane a tab shows: its focused pane, else its first
    pub fn tab_pane(&self, tab_id: &str) -> Option<&Pane> {
        let panes = self.panes_of(tab_id);
        panes
            .iter()
            .find(|p| p.focused)
            .copied()
            .or_else(|| panes.first().copied())
    }

    pub fn tab_position(&self, tab_id: &str) -> usize {
        self.tab(tab_id).map(|t| t.position).unwrap_or(0)
    }

    /// would dropping pane_id on dest change nothing?
    pub fn is_noop(&self, pane_id: &str, dest: &Dest) -> bool {
        let p = match self.pane(pane_id) {
            Some(p) => p,
            None => return true,
        };
        match dest {
            Dest::Tab { tab_id, .. } => tab_id == &p.tab_id,
            Dest::Ws { ws_id } => {
                ws_id == &p.ws_id && self.panes_of(&p.tab_id).len() == 1
            }
        }
    }

    pub fn is_noop_tab(&self, tab_id: &str, dest: &Dest) -> bool {
        let t = match self.tab(tab_id) {
            Some(t) => t,
            None => return true,
        };
        match dest {
            Dest::Tab { tab_id, .. } => tab_id == &t.id,
            Dest::Ws { ws_id } => ws_id == &t.ws_id,
        }
    }

    /// resolve the pane an item points at (kind + target), like entry_pane
    pub fn entry_pane(&self, kind: &str, id: &str) -> Option<&Pane> {
        match kind {
            "agent" | "pane" => self.pane(id),
            "tab" => self.tab_pane(id),
            "ws" => {
                let tab_id = self.ws(id).and_then(|w| w.active_tab_id.clone());
                tab_id.and_then(|t| self.tab_pane(&t))
            }
            _ => None,
        }
    }

    /// unique agent names across a workspace, display order
    pub fn ws_agents(&self, ws_id: &str) -> Vec<String> {
        let mut out = Vec::new();
        for tab in self.ws_tabs(ws_id) {
            for pane in self.panes_of(&tab.id) {
                if let Some(a) = &pane.agent {
                    if !out.contains(a) {
                        out.push(a.clone());
                    }
                }
            }
        }
        out
    }

    /// unique agent names in a tab, display order
    pub fn tab_agents(&self, tab_id: &str) -> Vec<String> {
        let mut out = Vec::new();
        for pane in self.panes_of(tab_id) {
            if let Some(a) = &pane.agent {
                if !out.contains(a) {
                    out.push(a.clone());
                }
            }
        }
        out
    }

    pub fn pane_text(&self, p: &Pane) -> String {
        if let Some(a) = &p.agent {
            a.clone()
        } else if !p.title.is_empty() {
            p.title.clone()
        } else {
            base_name(&p.cwd)
        }
    }

    pub fn tab_text(&self, tab_id: &str) -> String {
        let agents = self.tab_agents(tab_id);
        if !agents.is_empty() {
            agents.join(", ")
        } else if let Some(p) = self.tab_pane(tab_id) {
            if !p.title.is_empty() {
                p.title.clone()
            } else {
                base_name(&p.cwd)
            }
        } else {
            String::new()
        }
    }

    pub fn short_id(id: &str) -> String {
        id.split(':').last().unwrap_or(id).to_string()
    }
}

pub fn base_name(path: &str) -> String {
    path.split('/')
        .filter(|s| !s.is_empty())
        .last()
        .unwrap_or("")
        .to_string()
}

pub fn home_rel(path: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    if !path.is_empty() && !home.is_empty() && (path == home || path.starts_with(&format!("{home}/")))
    {
        format!("~{}", &path[home.len()..])
    } else {
        path.to_string()
    }
}
