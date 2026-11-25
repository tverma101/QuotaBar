//! A port of the ordering Foundation's `localizedStandardCompare` gives model names: natural
//! (digit runs compare numerically), case-insensitive, with a literal tie-break so the order is total.

use std::cmp::Ordering;

/// Collation weights for ASCII punctuation in Unicode default-collation order (whitespace, then these,
/// then digits, then letters).
const PUNCTUATION_ORDER: &str = "_-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$";

#[derive(PartialEq, Eq, PartialOrd, Ord)]
enum Weight {
    Space,
    Punctuation(usize),
    Other(char),
    Letter(char),
}

fn weight(c: char) -> Weight {
    if c.is_whitespace() {
        Weight::Space
    } else if let Some(index) = PUNCTUATION_ORDER.find(c) {
        Weight::Punctuation(index)
    } else if c.is_alphabetic() {
        Weight::Letter(c.to_lowercase().next().unwrap_or(c))
    } else {
        Weight::Other(c)
    }
}

enum Chunk<'a> {
    Digits(&'a str),
    Text(&'a str),
}

fn chunks(s: &str) -> Vec<Chunk<'_>> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut in_digits = None;
    for (i, c) in s.char_indices() {
        let digit = c.is_ascii_digit();
        match in_digits {
            Some(prev) if prev == digit => {}
            Some(prev) => {
                out.push(if prev {
                    Chunk::Digits(&s[start..i])
                } else {
                    Chunk::Text(&s[start..i])
                });
                start = i;
                in_digits = Some(digit);
            }
            None => in_digits = Some(digit),
        }
    }
    if let Some(prev) = in_digits {
        out.push(if prev {
            Chunk::Digits(&s[start..])
        } else {
            Chunk::Text(&s[start..])
        });
    }
    out
}

fn compare_digits(a: &str, b: &str) -> Ordering {
    let (a, b) = (a.trim_start_matches('0'), b.trim_start_matches('0'));
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

/// `lhs.localizedStandardCompare(rhs)`: `Less` when `lhs` sorts first.
pub fn localized_standard_compare(lhs: &str, rhs: &str) -> Ordering {
    let (left, right) = (chunks(lhs), chunks(rhs));
    for (l, r) in left.iter().zip(right.iter()) {
        let order = match (l, r) {
            (Chunk::Digits(a), Chunk::Digits(b)) => compare_digits(a, b),
            // Digits sort before letters and after punctuation, as in the default collation.
            (Chunk::Digits(_), Chunk::Text(t)) => match t.chars().next().map(weight) {
                Some(Weight::Letter(_)) | Some(Weight::Other(_)) => Ordering::Less,
                _ => Ordering::Greater,
            },
            (Chunk::Text(t), Chunk::Digits(_)) => match t.chars().next().map(weight) {
                Some(Weight::Letter(_)) | Some(Weight::Other(_)) => Ordering::Greater,
                _ => Ordering::Less,
            },
            (Chunk::Text(a), Chunk::Text(b)) => a.chars().map(weight).cmp(b.chars().map(weight)),
        };
        if order != Ordering::Equal {
            return order;
        }
    }
    left.len().cmp(&right.len()).then_with(|| lhs.cmp(rhs))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orders_naturally_and_ignores_case_first() {
        assert_eq!(
            localized_standard_compare("gpt-5.5", "gpt-5.10"),
            Ordering::Less
        );
        assert_eq!(
            localized_standard_compare("gpt-5", "gpt-5-codex"),
            Ordering::Less
        );
        assert_eq!(
            localized_standard_compare("Beta", "alpha"),
            Ordering::Greater
        );
        assert_eq!(localized_standard_compare("alpha", "Beta"), Ordering::Less);
        assert_eq!(
            localized_standard_compare("A", "a"),
            Ordering::Less,
            "literal tie-break"
        );
        assert_eq!(localized_standard_compare("a", "a"), Ordering::Equal);
        assert_eq!(
            localized_standard_compare("model-2", "model-10"),
            Ordering::Less
        );
        assert_eq!(localized_standard_compare("1x", "ax"), Ordering::Less);
    }
}
