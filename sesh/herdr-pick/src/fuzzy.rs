// Fuzzy matching: port of the match() function in herdr-picker.mjs.
// Space-separated terms, each a fuzzy subsequence; smart case.
// Returns match positions (into the plain text) plus a score.

pub fn fuzzy_match(text: &str, query: &str) -> Option<(Vec<usize>, f64)> {
    raw_match(text, query).map(|(pos, score)| (pos, score - text.chars().count() as f64 * 0.02))
}

/// How well `query` matches `text`, without the length tie-break, so rows
/// whose search text carries different extras (paths, subtitles) compare fairly.
pub fn match_quality(text: &str, query: &str) -> Option<f64> {
    raw_match(text, query).map(|(_, score)| score)
}

fn raw_match(text: &str, query: &str) -> Option<(Vec<usize>, f64)> {
    let terms: Vec<&str> = query.split_whitespace().collect();
    if terms.is_empty() {
        return None;
    }
    let chars: Vec<char> = text.chars().collect();
    let mut pos: Vec<usize> = Vec::new();
    let mut score = 0f64;
    for term in terms {
        let case_sensitive = term.chars().any(|c| c.is_uppercase());
        let t: Vec<char> = if case_sensitive {
            term.chars().collect()
        } else {
            term.chars().flat_map(|c| c.to_lowercase()).collect()
        };
        let mut ti = 0usize;
        let mut prev: i64 = -2;
        let mut hit: Vec<usize> = Vec::new();
        let mut i = 0usize;
        while i < chars.len() && ti < t.len() {
            let c = if case_sensitive {
                chars[i]
            } else {
                chars[i].to_lowercase().next().unwrap_or(chars[i])
            };
            if c != t[ti] {
                i += 1;
                continue;
            }
            hit.push(i);
            if i as i64 == prev + 1 {
                score += 6.0;
            } else {
                score -= ((i as i64 - prev - 1).min(8)) as f64;
            }
            let boundary = i == 0
                || matches!(chars.get(i - 1), Some(c) if c.is_whitespace() || matches!(c, '-' | '/' | '_' | '.'));
            if boundary {
                score += 10.0;
            }
            score += 1.0;
            prev = i as i64;
            ti += 1;
            i += 1;
        }
        if ti < t.len() {
            return None;
        }
        pos.extend(hit);
    }
    pos.sort_unstable();
    pos.dedup();
    Some((pos, score))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quality_ignores_extra_text() {
        let ks = match_quality("Notes Untitled-1.md /Users/me/notes", "Notes").unwrap();
        let local = match_quality("Notes /private/tmp/Notes", "Notes").unwrap();
        assert_eq!(ks, local);
        assert!(match_quality("my-notes", "Notes").is_none());
        assert!(match_quality("xnotes", "notes").unwrap() < local);
    }
}
