// Style: resolves style.tokens against style.palette. The palette can track
// the live kitchen-sink theme (style.palette_source reads the [theme] section
// of ~/.config/kitchen-sink/commands.toml and derives the tonal ramps), so the
// picker wears the same card colours as kitchen-sink's default view.

use crate::ansi::{self, Rgb};
use crate::config::Config;
use std::collections::HashMap;
use std::fs;

#[derive(Clone, Debug)]
pub struct Style {
    pub palette: HashMap<String, Rgb>,
    pub tokens: HashMap<String, String>,
    pub edge: String,
    pub ws_bold: bool,
    pub pulse: Vec<Rgb>,
    pub flash_from: Rgb,
    pub flash_to: Rgb,
    pub flash_steps: usize,
}

impl Style {
    pub fn new(cfg: &Config) -> Style {
        let mut palette: HashMap<String, Rgb> = HashMap::new();
        for (k, v) in &cfg.style.palette {
            if let Some(c) = Rgb::parse(v) {
                palette.insert(k.clone(), c);
            }
        }
        if let Some(src) = &cfg.style.palette_source {
            if let Ok(raw) = fs::read_to_string(cfg.expand_path(&src.file)) {
                let vals = parse_theme_section(&raw, &src.section);
                for (theme_key, token) in &src.map {
                    if let Some(v) = vals.get(theme_key) {
                        if let Some(c) = Rgb::parse(v) {
                            palette.insert(token.clone(), c);
                        }
                    }
                }
                let base = palette.get("base").copied();
                let text = palette.get("text").copied();
                let accent = palette.get("accent").copied();
                let header = palette.get("header").copied();
                for key in &src.derive {
                    match key.as_str() {
                        "crust" => {
                            if let Some(h) = header {
                                palette.insert("crust".into(), h);
                            }
                        }
                        "mantle" => {
                            if let (Some(b), Some(c)) = (base, palette.get("crust").copied()) {
                                palette.insert("mantle".into(), b.mix(c, 0.5));
                            }
                        }
                        "surface0" => {
                            if let (Some(b), Some(t)) = (base, text) {
                                palette.insert("surface0".into(), b.mix(t, 0.09));
                            }
                        }
                        "surface1" => {
                            if let (Some(b), Some(t)) = (base, text) {
                                palette.insert("surface1".into(), b.mix(t, 0.16));
                            }
                        }
                        "outline" => {
                            if let (Some(b), Some(a)) = (base, accent) {
                                palette.insert("outline".into(), b.mix(a, 0.45));
                            }
                        }
                        _ => {}
                    }
                }
            }
        }

        let mut tokens = cfg.style.tokens.clone();
        let lookup = |tokens: &HashMap<String, String>, palette: &HashMap<String, Rgb>, tok: &str| -> Option<Rgb> {
            let name = tokens.get(tok).cloned().unwrap_or_else(|| tok.to_string());
            if name.starts_with('#') {
                Rgb::parse(&name)
            } else {
                palette.get(&name).copied()
            }
        };
        // make sure every token can resolve; drop the ones that cannot
        tokens.retain(|_, _| true);
        let pulse_from = lookup(&tokens, &palette, &cfg.style.pulse_from)
            .unwrap_or(Rgb { r: 255, g: 255, b: 255 });
        let pulse_to =
            lookup(&tokens, &palette, &cfg.style.pulse_to).unwrap_or(Rgb { r: 0, g: 0, b: 0 });
        let steps = cfg.style.pulse_steps.max(2) as usize;
        let mut pulse: Vec<Rgb> = Vec::with_capacity(steps * 2);
        for i in 0..steps * 2 {
            let t = if i < steps {
                i as f32 / (steps - 1) as f32
            } else {
                (steps * 2 - 1 - i) as f32 / (steps - 1) as f32
            };
            pulse.push(pulse_to.mix(pulse_from, t));
        }
        let flash_from = lookup(&tokens, &palette, &cfg.style.tokens.get("flash_from").cloned().unwrap_or_else(|| "success".into()))
            .unwrap_or(pulse_from);
        let flash_to = lookup(&tokens, &palette, &cfg.style.tokens.get("flash_to").cloned().unwrap_or_else(|| "base".into()))
            .unwrap_or(pulse_to);
        let flash_steps = 5;

        Style {
            palette,
            tokens,
            edge: cfg.style.selection_edge_glyph.clone(),
            ws_bold: cfg.style.ws_bold,
            pulse,
            flash_from,
            flash_to,
            flash_steps,
        }
    }

    pub fn color(&self, tok: &str) -> Rgb {
        let name = self.tokens.get(tok).cloned().unwrap_or_else(|| tok.to_string());
        if name.starts_with('#') {
            if let Some(c) = Rgb::parse(&name) {
                return c;
            }
        }
        if let Some(c) = self.palette.get(&name) {
            return *c;
        }
        if let Some(c) = self.palette.get("text") {
            return *c;
        }
        Rgb { r: 255, g: 255, b: 255 }
    }

    pub fn fg_codes(&self, tok: &str) -> String {
        self.color(tok).fg_codes()
    }

    pub fn bg_codes(&self, tok: &str) -> String {
        self.color(tok).bg_codes()
    }

    pub fn fg(&self, tok: &str, s: &str) -> String {
        format!("{}{s}\x1b[39m", self.color(tok).fg_codes())
    }

    pub fn bold(&self, s: &str) -> String {
        ansi::bold(s)
    }

    pub fn dim(&self, s: &str) -> String {
        self.fg("dim", s)
    }

    pub fn pulse_at(&self, phase: u64) -> Rgb {
        self.pulse[(phase as usize) % self.pulse.len().max(1)]
    }

    pub fn pulse_codes(&self, phase: u64) -> String {
        self.pulse_at(phase).fg_codes()
    }

    pub fn flash_bg_codes(&self, age_ms: u128, total_ms: u128) -> Option<String> {
        if age_ms >= total_ms || total_ms == 0 {
            return None;
        }
        let step = ((age_ms * self.flash_steps as u128) / total_ms).min(self.flash_steps as u128 - 1);
        let t = step as f32 / (self.flash_steps.max(2) - 1) as f32;
        Some(self.flash_from.mix(self.flash_to, t).bg_codes())
    }
}

fn parse_theme_section(raw: &str, section: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut current = String::new();
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            current = line[1..line.len() - 1].trim().to_string();
            continue;
        }
        if current != section {
            continue;
        }
        if let Some(eq) = line.find('=') {
            let key = line[..eq].trim().to_string();
            let mut val = line[eq + 1..].trim().to_string();
            if let Some(hash) = val.find(" #") {
                val = val[..hash].trim().to_string();
            }
            val = val.trim_matches('"').trim_matches('\'').to_string();
            out.insert(key, val);
        }
    }
    out
}
