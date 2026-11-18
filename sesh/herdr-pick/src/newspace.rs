// `herdr-pick new` — the prefix+n popup: create a new space at a directory,
// with vim-:cd style completion. Type a path (~/x, /abs, ./rel) and the
// subdirectories of the part you've typed are offered; type a bare word and
// your zoxide directories are fuzzy-filtered instead. Tab completes, ↑/↓
// choose, enter creates the directory if needed, registers it with zoxide and
// opens the space. All strings live in herdr-pick.json (texts.new_*).

use crate::config::Config;
use crate::data;
use crate::fuzzy::fuzzy_match;
use crate::proc;
use crate::style::Style;
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

struct Guard;
impl Guard {
    fn enter() -> Result<Guard, String> {
        terminal::enable_raw_mode().map_err(|e| format!("raw mode: {e}"))?;
        let mut o = std::io::stdout();
        let _ = o.write_all(b"\x1b[?1049h\x1b[?25l");
        let _ = o.flush();
        Ok(Guard)
    }
}
impl Drop for Guard {
    fn drop(&mut self) {
        let mut o = std::io::stdout();
        let _ = o.write_all(b"\x1b[0m\x1b[?25h\x1b[?1049l");
        let _ = o.flush();
        let _ = terminal::disable_raw_mode();
    }
}

fn pathy(s: &str) -> bool {
    s.contains('/') || s.starts_with('~') || s.starts_with('.')
}

fn expand(cfg: &Config, s: &str) -> String {
    if s == "~" {
        cfg.home()
    } else if let Some(r) = s.strip_prefix("~/") {
        format!("{}/{r}", cfg.home())
    } else if s.starts_with('/') {
        s.to_string()
    } else if s.contains('/') {
        format!("{}/{s}", cfg.home())
    } else {
        format!("/tmp/{s}")
    }
}

fn zoxide_dirs(cfg: &Config) -> Vec<String> {
    let out = match proc::run(&cfg.bins.zoxide, &cfg.cmd("zoxide_query"), Duration::from_millis(5000)) {
        Ok(o) if o.status == 0 => o,
        _ => return Vec::new(),
    };
    let mut rows: Vec<(f64, String)> = out
        .stdout
        .lines()
        .filter_map(|l| {
            let (s, p) = l.trim().split_once(' ')?;
            let p = p.trim();
            Path::new(p).is_dir().then(|| (s.parse().unwrap_or(0.0), p.to_string()))
        })
        .collect();
    rows.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    rows.into_iter().map(|r| r.1).collect()
}

/// candidates for the current input: (full path as shown/typed, is completion)
fn candidates(cfg: &Config, zox: &[String], input: &str) -> Vec<String> {
    if pathy(input) {
        let (dir_part, prefix) = match input.rfind('/') {
            Some(i) => (&input[..=i], &input[i + 1..]),
            None => (if input == "~" { "~/" } else { "./" }, if input == "~" { "" } else { input }),
        };
        let real = if dir_part == "./" && !input.starts_with("./") {
            PathBuf::from(cfg.home())
        } else {
            PathBuf::from(expand(cfg, dir_part))
        };
        let shown_dir = if input.rfind('/').is_none() && input != "~" { "" } else { dir_part };
        let mut names: Vec<String> = std::fs::read_dir(&real)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().is_dir())
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| prefix.starts_with('.') || !n.starts_with('.'))
            .filter(|n| n.to_lowercase().starts_with(&prefix.to_lowercase()))
            .collect();
        names.sort_by_key(|n| n.to_lowercase());
        names.into_iter().map(|n| format!("{shown_dir}{n}/")).collect()
    } else if input.trim().is_empty() {
        zox.iter().take(40).map(|p| tilde(cfg, p)).collect()
    } else {
        let mut v: Vec<(f64, String)> = zox
            .iter()
            .filter_map(|p| fuzzy_match(&tilde(cfg, p), input).map(|(_, s)| (s, tilde(cfg, p))))
            .collect();
        v.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        v.into_iter().take(40).map(|x| x.1).collect()
    }
}

fn tilde(cfg: &Config, p: &str) -> String {
    let h = cfg.home();
    match p.strip_prefix(&h) {
        Some(r) if r.is_empty() || r.starts_with('/') => format!("~{r}"),
        _ => p.to_string(),
    }
}

pub fn run(cfg: &Config, st: &Style) -> i32 {
    let _g = match Guard::enter() {
        Ok(g) => g,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };
    let zox = zoxide_dirs(cfg);
    let mut input = String::new();
    let mut sel = 0usize;
    let mut moved = false;
    let chosen: Option<String>;
    loop {
        let cands = candidates(cfg, &zox, &input);
        sel = sel.min(cands.len().saturating_sub(1));
        // what enter would create
        let from_list = !cands.is_empty() && (moved || (!pathy(&input) && !input.trim().is_empty()));
        let target = if from_list {
            expand(cfg, &cands[sel])
        } else {
            expand(cfg, input.trim())
        };
        let (w, h) = terminal::size().map(|(w, h)| (w as usize, h as usize)).unwrap_or((80, 24));
        let mut f = String::from("\x1b[2J\x1b[H");
        f += &format!(
            "{}{}\x1b[7m \x1b[27m\r\n",
            st.fg("prompt", &cfg.text("new_prompt")),
            input
        );
        let status = if input.trim().is_empty() && !moved {
            st.dim(&cfg.text("new_pick"))
        } else if Path::new(&target).is_dir() {
            st.fg("ok_text", &format!("{} {}", cfg.text("new_exists"), tilde(cfg, &target)))
        } else {
            st.fg("warn_text", &format!("{} {}", cfg.text("new_create"), tilde(cfg, &target)))
        };
        f += &format!("{status}\r\n\r\n");
        let rows = h.saturating_sub(6).max(3);
        let top = sel.saturating_sub(rows.saturating_sub(1));
        for (i, c) in cands.iter().enumerate().skip(top).take(rows) {
            let c: String = c.chars().take(w.saturating_sub(4)).collect();
            if i == sel {
                f += &format!("{} {}\r\n", st.fg("prompt", "▌"), st.bold(&st.fg("dir", &c)));
            } else {
                f += &format!("  {}\r\n", st.dim(&c));
            }
        }
        if cands.is_empty() {
            f += &format!("  {}\r\n", st.dim(&cfg.text("new_none")));
        }
        f += &format!("\x1b[{};1H{}", h, st.dim(&cfg.text("new_hint")));
        let mut o = std::io::stdout();
        let _ = o.write_all(f.as_bytes());
        let _ = o.flush();

        let ev = match event::read() {
            Ok(e) => e,
            Err(_) => return 1,
        };
        let Event::Key(k) = ev else { continue };
        if k.kind == KeyEventKind::Release {
            continue;
        }
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        match (k.code, ctrl) {
            (KeyCode::Esc, _) | (KeyCode::Char('c'), true) | (KeyCode::Char('q'), true) => return 0,
            (KeyCode::Enter, _) => {
                if input.trim().is_empty() && !moved {
                    continue;
                }
                chosen = Some(target);
                break;
            }
            (KeyCode::Tab, _) => {
                if let Some(c) = cands.get(sel) {
                    input = c.clone();
                    sel = 0;
                    moved = false;
                }
            }
            (KeyCode::Down, _) | (KeyCode::Char('n'), true) => {
                sel = (sel + 1).min(cands.len().saturating_sub(1));
                moved = true;
            }
            (KeyCode::Up, _) | (KeyCode::Char('p'), true) | (KeyCode::BackTab, _) => {
                sel = sel.saturating_sub(1);
                moved = true;
            }
            (KeyCode::Backspace, _) => {
                input.pop();
                sel = 0;
                moved = false;
            }
            (KeyCode::Char('u'), true) => {
                input.clear();
                sel = 0;
                moved = false;
            }
            (KeyCode::Char('w'), true) => {
                let t = input.trim_end_matches('/').len();
                input.truncate(input[..t].rfind('/').map(|i| i + 1).unwrap_or(0));
                sel = 0;
                moved = false;
            }
            (KeyCode::Char(c), false) => {
                input.push(c);
                sel = 0;
                moved = false;
            }
            _ => {}
        }
    }
    drop(_g);
    let Some(path) = chosen else { return 0 };
    let path = path.trim_end_matches('/').to_string();
    if std::fs::create_dir_all(&path).is_err() {
        eprintln!("herdr-pick: can't create {path}");
        return 1;
    }
    let path = std::fs::canonicalize(&path)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or(path);
    // register with zoxide first so the directory shows up in the picker
    let _ = proc::run(&cfg.bins.zoxide, &proc::subst(&cfg.cmd("zoxide_add"), &[("path", &path)]), Duration::from_millis(5000));
    let _ = data::act(cfg, &path);
    0
}
