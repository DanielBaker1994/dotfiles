// ANSI-aware text helpers: width, slicing, fitting, sanitising.
// Port of the helpers in herdr-picker.mjs (TOKEN_RE, charWidth, slice, fit,
// withBg, sanitize) using the unicode-width crate for character widths.

use unicode_width::UnicodeWidthChar;

pub const RESET: &str = "\x1b[0m";

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Rgb {
    pub fn parse(s: &str) -> Option<Rgb> {
        let s = s.trim().trim_start_matches('#');
        if s.len() != 6 {
            return None;
        }
        let r = u8::from_str_radix(&s[0..2], 16).ok()?;
        let g = u8::from_str_radix(&s[2..4], 16).ok()?;
        let b = u8::from_str_radix(&s[4..6], 16).ok()?;
        Some(Rgb { r, g, b })
    }

    pub fn mix(self, other: Rgb, t: f32) -> Rgb {
        let t = t.clamp(0.0, 1.0);
        let f = |a: u8, b: u8| -> u8 { (a as f32 + (b as f32 - a as f32) * t).round().clamp(0.0, 255.0) as u8 };
        Rgb { r: f(self.r, other.r), g: f(self.g, other.g), b: f(self.b, other.b) }
    }

    pub fn fg_codes(self) -> String {
        format!("\x1b[38;2;{};{};{}m", self.r, self.g, self.b)
    }

    pub fn bg_codes(self) -> String {
        format!("\x1b[48;2;{};{};{}m", self.r, self.g, self.b)
    }
}

/// End of the token starting at byte index `i`.
/// ANSI sequences (CSI, OSC, single ESC) are one token; otherwise one char.
/// Returns (end_index, is_ansi).
pub fn token_end(s: &str, i: usize) -> (usize, bool) {
    let bytes = s.as_bytes();
    if bytes[i] != 0x1b {
        let c = s[i..].chars().next().unwrap();
        return (i + c.len_utf8(), false);
    }
    if i + 1 >= bytes.len() {
        return (bytes.len(), true);
    }
    match bytes[i + 1] {
        b'[' => {
            let mut j = i + 2;
            while j < bytes.len()
                && matches!(bytes[j], b'0'..=b'9' | b';' | b':' | b'?' | b'<' | b'>' | b'=')
            {
                j += 1;
            }
            while j < bytes.len() && (b' '..=b'/').contains(&bytes[j]) {
                j += 1;
            }
            if j < bytes.len() {
                j += 1;
            }
            (j, true)
        }
        b']' => {
            let mut j = i + 2;
            while j < bytes.len() {
                if bytes[j] == 0x07 {
                    j += 1;
                    break;
                }
                if bytes[j] == 0x1b {
                    j = (j + 2).min(bytes.len());
                    break;
                }
                j += 1;
            }
            (j, true)
        }
        _ => ((i + 2).min(bytes.len()), true),
    }
}

pub fn char_width(c: char) -> usize {
    if (c as u32) < 32 || ((c as u32) >= 0x7f && (c as u32) < 0xa0) {
        return 0;
    }
    UnicodeWidthChar::width(c).unwrap_or(0)
}

pub fn width(s: &str) -> usize {
    let mut w = 0;
    let mut i = 0;
    while i < s.len() {
        let (ni, is_ansi) = token_end(s, i);
        if !is_ansi {
            w += char_width(s[i..ni].chars().next().unwrap());
        }
        i = ni;
    }
    w
}

pub fn strip(s: &str) -> String {
    let mut out = String::new();
    let mut i = 0;
    while i < s.len() {
        let (ni, is_ansi) = token_end(s, i);
        if !is_ansi {
            out.push_str(&s[i..ni]);
        }
        i = ni;
    }
    out
}

/// Visible columns [start, end); SGR codes are kept so styles carry over.
/// `end` may be usize::MAX for "to the end".
pub fn slice(s: &str, start: usize, end: usize) -> String {
    let mut out = String::new();
    let mut col = 0usize;
    let mut i = 0;
    while i < s.len() {
        let (ni, is_ansi) = token_end(s, i);
        let tok = &s[i..ni];
        if is_ansi {
            if tok.starts_with("\x1b[") && tok.ends_with('m') {
                out.push_str(tok);
            }
            i = ni;
            continue;
        }
        let c = tok.chars().next().unwrap();
        if c == '\t' {
            let n = 4 - (col % 4);
            for _ in 0..n {
                if col >= start && col < end {
                    out.push(' ');
                }
                col += 1;
            }
            i = ni;
            continue;
        }
        let w = char_width(c);
        if w == 0 {
            if col > start && col <= end {
                out.push(c);
            }
            i = ni;
            continue;
        }
        if col >= start && col + w <= end {
            out.push(c);
        } else if col < end && col + w > start {
            let n = (col + w).min(end) - col.max(start);
            for _ in 0..n {
                out.push(' ');
            }
        }
        col += w;
        if col >= end && end != usize::MAX {
            break;
        }
        i = ni;
    }
    out
}

/// Exactly `w` columns, style reset at the end, padded with spaces.
pub fn fit(s: &str, w: usize) -> String {
    let t = slice(s, 0, w);
    let tw = width(&t);
    format!("{t}{RESET}{}", " ".repeat(w.saturating_sub(tw)))
}

/// Text padded with spaces to `w` columns (never truncated, no reset).
pub fn fill(s: &str, w: usize) -> String {
    let sw = width(s);
    format!("{s}{}", " ".repeat(w.saturating_sub(sw)))
}

/// Keep a background through inner resets.
pub fn with_bg(s: &str, bg: &str) -> String {
    let mut out = String::new();
    let mut i = 0;
    while i < s.len() {
        if s[i..].starts_with("\x1b[0m") {
            out.push_str("\x1b[0m");
            out.push_str(bg);
            i += 4;
        } else if s[i..].starts_with("\x1b[m") {
            out.push_str("\x1b[m");
            out.push_str(bg);
            i += 3;
        } else {
            let c = s[i..].chars().next().unwrap();
            out.push(c);
            i += c.len_utf8();
        }
    }
    out
}

/// Only SGR survives (pane dumps carry cursor moves etc.).
pub fn sanitize(s: &str) -> String {
    let mut out = String::new();
    let mut i = 0;
    while i < s.len() {
        let (ni, is_ansi) = token_end(s, i);
        let tok = &s[i..ni];
        if is_ansi {
            if tok.starts_with("\x1b[") && tok.ends_with('m') {
                out.push_str(tok);
            }
        } else {
            for c in tok.chars() {
                if c != '\r' {
                    out.push(c);
                }
            }
        }
        i = ni;
    }
    out
}

pub fn sgr(codes: &str) -> String {
    format!("\x1b[{codes}m")
}

pub fn bold(s: &str) -> String {
    format!("\x1b[1m{s}\x1b[22m")
}
