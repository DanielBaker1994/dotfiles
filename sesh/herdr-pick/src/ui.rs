// Drawing primitives: template filling, rounded boxes, marching-ants frames,
// the table header, fuzzy-match highlighting and the tab-grid preview.

use crate::ansi;
use crate::config::Config;
use crate::data::PreviewPart;
use crate::style::Style;

/// Fill a row template: {name} plain, {name:width} padded right to `width`
/// columns (ANSI-aware). Styled values pass through untouched.
pub fn fill_tmpl(tmpl: &str, vars: &[(&str, String)]) -> String {
    let mut out = String::new();
    let mut i = 0;
    let bytes = tmpl.as_bytes();
    while i < bytes.len() {
        if bytes[i] == b'{' {
            if let Some(close) = tmpl[i + 1..].find('}') {
                let inner = &tmpl[i + 1..i + 1 + close];
                let (name, width) = match inner.split_once(':') {
                    Some((n, w)) => (n, w.parse::<usize>().ok()),
                    None => (inner, None),
                };
                let value = vars
                    .iter()
                    .find(|(k, _)| *k == name)
                    .map(|(_, v)| v.as_str());
                match value {
                    Some(v) => {
                        if let Some(w) = width {
                            out.push_str(&ansi::fill(v, w));
                        } else {
                            out.push_str(v);
                        }
                    }
                    None => out.push_str(&tmpl[i..=i + close]),
                }
                i += close + 2;
                continue;
            }
        }
        let c = tmpl[i..].chars().next().unwrap();
        out.push(c);
        i += c.len_utf8();
    }
    out
}

/// Rounded box, port of box() in herdr-picker.mjs.
pub fn box_lines(
    lines: &[String],
    w: usize,
    h: usize,
    label: &str,
    st: &Style,
    cfg: &Config,
) -> Vec<String> {
    let bx = &cfg.ui.box_chars;
    if w < 4 || h < 2 {
        return vec![" ".repeat(w); h];
    }
    let b = |s: &str| st.fg("border", s);
    let lab = ansi::slice(label, 0, w.saturating_sub(4));
    let lw = ansi::width(&lab);
    let lab_styled = st.fg("box_label", &lab);
    let mut out = Vec::with_capacity(h);
    out.push(format!(
        "{}{}{}{}",
        b(&format!("{}{}", bx.tl, bx.h)),
        lab_styled,
        ansi::RESET,
        b(&format!("{}{}", bx.h.repeat(w.saturating_sub(3 + lw)), bx.tr))
    ));
    for i in 0..h.saturating_sub(2) {
        out.push(format!(
            "{}{}{}",
            b(&bx.v),
            ansi::fit(lines.get(i).map(|s| s.as_str()).unwrap_or(""), w - 2),
            b(&bx.v)
        ));
    }
    out.push(b(&format!(
        "{}{}{}",
        bx.bl,
        bx.h.repeat(w.saturating_sub(2)),
        bx.br
    )));
    out
}

/// w × h rectangle with marching ants and centred text.
pub fn ants_rect(w: usize, h: usize, lines: &[String], phase: u64, st: &Style, cfg: &Config) -> Vec<String> {
    let corner = &cfg.ui.box_chars;
    if w < 4 || h < 3 {
        return vec![" ".repeat(w); h];
    }
    let col = st.pulse_codes(phase);
    let ant = |i: i64, on: &str, off: &str| -> String {
        if ((i - phase as i64).rem_euclid(4)) < 3 {
            on.to_string()
        } else {
            off.to_string()
        }
    };
    let c = |s: &str| format!("{col}{s}{}", ansi::sgr("39"));
    let p = 2 * w + 2 * h;
    let mut top = String::new();
    for i in 1..w.saturating_sub(1) {
        top.push_str(&ant(i as i64, &corner.h, " "));
    }
    let mut bot = String::new();
    for i in 0..w.saturating_sub(2) {
        bot.push_str(&ant((w + h + (w - 2 - i)) as i64, &corner.h, " "));
    }
    let first = (h.saturating_sub(2).saturating_sub(lines.len())) / 2;
    let mut out = Vec::with_capacity(h);
    out.push(c(&format!("{}{}{}", corner.tl, top, corner.tr)));
    for r in 0..h.saturating_sub(2) {
        let t = lines.get(r.wrapping_sub(first)).map(|s| s.as_str()).unwrap_or("");
        let pad = (w.saturating_sub(2).saturating_sub(ansi::width(t))) / 2;
        let row = format!(
            "{}{}{}",
            c(&ant((p - 1 - r) as i64, &corner.v, " ")),
            ansi::fit(&format!("{}{}", " ".repeat(pad), t), w - 2),
            c(&ant((w + r) as i64, &corner.v, " "))
        );
        out.push(row);
    }
    out.push(c(&format!("{}{}{}", corner.bl, bot, corner.br)));
    out
}

/// Column header for the open-workspace table (widths from ui.table_head);
/// the sorted column is marked.
pub fn table_head(cfg: &Config, st: &Style, sort: &str, iw: usize) -> String {
    let th = &cfg.ui.table_head;
    let col = |name: &str, w: usize, on: bool| -> String {
        let mut s = if on {
            format!("{name}{}", th.sort_mark)
        } else {
            name.to_string()
        };
        while ansi::width(&s) < w + 1 {
            s.push(' ');
        }
        s
    };
    let mut h = format!(
        "    {}{}{}{}",
        col(&th.name, th.name_w, sort == "name"),
        col(&th.tabs, th.tabs_w, false),
        col(&th.agents, th.agents_w, sort == "status"),
        th.last
    );
    if sort == "recent" {
        h.push_str(&th.sort_mark);
    }
    let line = format!("{} {}", h, "─".repeat(iw));
    st.fg("table_head", &ansi::slice(&line, 0, iw))
}

/// Bold+underline the matched characters of a display string.
pub fn highlight(display: &str, pos: &[usize]) -> String {
    if pos.is_empty() {
        return display.to_string();
    }
    let mut out = String::new();
    let mut idx = 0usize;
    let mut i = 0;
    while i < display.len() {
        let (ni, is_ansi) = ansi::token_end(display, i);
        let tok = &display[i..ni];
        if is_ansi {
            out.push_str(tok);
        } else {
            if pos.contains(&idx) {
                out.push_str("\x1b[1;4m");
                out.push_str(tok);
                out.push_str("\x1b[22;24m");
            } else {
                out.push_str(tok);
            }
            idx += 1;
        }
        i = ni;
    }
    out
}

/// Preview grid: one cell per tab, packed into ceil(sqrt(k)) columns with
/// thin border-coloured separators. Falls back to the first part's lines when
/// the pane is too small for a grid.
pub fn grid_lines(parts: &[PreviewPart], iw: usize, ih: usize, st: &Style, cfg: &Config) -> Vec<String> {
    let k = parts.len();
    if k <= 1 || iw < 8 || ih < 3 {
        let text = parts.first().map(|p| p.text.clone()).unwrap_or_default();
        return ansi::sanitize(&text)
            .split('\n')
            .take(ih.max(1))
            .map(|s| ansi::fit(s, iw))
            .collect();
    }
    let cols = (k as f64).sqrt().ceil() as usize;
    let cols = cols.clamp(1, k);
    let rows = (k + cols - 1) / cols;
    let widths: Vec<usize> = {
        let base = (iw.saturating_sub(cols - 1)) / cols;
        let rem = iw.saturating_sub(cols - 1).saturating_sub(base * cols);
        (0..cols)
            .map(|c| base + if c + 1 == cols { rem } else { 0 })
            .collect()
    };
    let heights: Vec<usize> = {
        let base = (ih.saturating_sub(rows - 1)) / rows;
        let rem = ih.saturating_sub(rows - 1).saturating_sub(base * rows);
        (0..rows)
            .map(|r| base + if r + 1 == rows { rem } else { 0 })
            .collect()
    };
    if widths.iter().min().copied().unwrap_or(0) < 4 || heights.iter().min().copied().unwrap_or(0) < 2 {
        let text = parts.first().map(|p| p.text.clone()).unwrap_or_default();
        return ansi::sanitize(&text)
            .split('\n')
            .take(ih.max(1))
            .map(|s| ansi::fit(s, iw))
            .collect();
    }
    let vsep = st.fg("border", &cfg.ui.box_chars.v);
    let hsep = st.fg("border", &cfg.ui.box_chars.h.repeat(iw));
    let mut out: Vec<String> = Vec::with_capacity(ih);
    for r in 0..rows {
        for l in 0..heights[r] {
            let mut cells: Vec<String> = Vec::with_capacity(cols);
            for c in 0..cols {
                let idx = r * cols + c;
                let content = match parts.get(idx) {
                    None => String::new(),
                    Some(p) => {
                        if l == 0 {
                            p.title.clone()
                        } else {
                            ansi::sanitize(&p.text)
                                .split('\n')
                                .nth(l - 1)
                                .unwrap_or("")
                                .to_string()
                        }
                    }
                };
                cells.push(ansi::fit(&content, widths[c]));
            }
            out.push(cells.join(&vsep));
        }
        if r + 1 < rows {
            out.push(hsep.clone());
        }
    }
    out
}
