//! Count formatting for the Usage Trend readouts (Swift `MetricFormatter.number(_, kind: .count,
//! style: .row)`, pinned to en_US): below 1,000 up to one decimal, above that the compact
//! "12.9K / 3.4M / 1.2B / 1T" form with up to one fractional digit, half-even like ICU.

const COMPACT_TIERS: [(usize, &str); 4] = [(3, "K"), (6, "M"), (9, "B"), (12, "T")];

/// Round the decimal expansion of `abs` (shortest round-trip digits, as ICU reads a double) after
/// moving the decimal point `shift` places left, to one fractional digit, half-even. Returns the
/// integer digits and the tenths digit.
fn scaled_round(abs: f64, shift: usize) -> (String, u8) {
    let text = format!("{abs}");
    let (int_part, frac_part) = text.split_once('.').unwrap_or((text.as_str(), ""));
    let mut digits: Vec<u8> = int_part
        .bytes()
        .chain(frac_part.bytes())
        .map(|b| b - b'0')
        .collect();
    let point = int_part.len() as isize - shift as isize;
    let pad = (-point).max(0) as usize;
    digits.splice(0..0, std::iter::repeat_n(0u8, pad));
    let keep = point.max(0) as usize + 1;
    while digits.len() < keep {
        digits.push(0);
    }
    let rest = digits.split_off(keep);
    let round_up = match rest.first() {
        None => false,
        Some(&d) if d > 5 => true,
        Some(&d) if d < 5 => false,
        Some(_) => {
            rest[1..].iter().any(|&x| x != 0) || digits.last().is_some_and(|last| last % 2 == 1)
        }
    };
    if round_up {
        let mut i = digits.len();
        loop {
            if i == 0 {
                digits.insert(0, 1);
                break;
            }
            i -= 1;
            if digits[i] == 9 {
                digits[i] = 0;
            } else {
                digits[i] += 1;
                break;
            }
        }
    }
    let tenths = digits.pop().unwrap_or(0);
    let int_digits: String = digits.iter().map(|d| (b'0' + d) as char).collect();
    let int_digits = int_digits.trim_start_matches('0').to_string();
    (
        if int_digits.is_empty() {
            "0".to_string()
        } else {
            int_digits
        },
        tenths,
    )
}

fn group(int_digits: &str, min_digits: usize) -> String {
    if int_digits.len() < min_digits {
        return int_digits.to_string();
    }
    let mut out = String::new();
    for (i, c) in int_digits.chars().enumerate() {
        if i > 0 && (int_digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn assemble(int_digits: &str, tenths: u8, min_group: usize) -> String {
    let int = group(int_digits, min_group);
    if tenths == 0 {
        int
    } else {
        format!("{int}.{tenths}")
    }
}

/// The popover-row spelling of a token count (`500`, `12.9K`, `222M`, `1.5B`).
pub fn format_count_row(value: f64) -> String {
    if !value.is_finite() {
        return "0".to_string();
    }
    let sign = if value < 0.0 { "-" } else { "" };
    let abs = value.abs();
    if abs < 1000.0 {
        let (int, tenths) = scaled_round(abs, 0);
        return format!("{sign}{}", assemble(&int, tenths, 4));
    }
    let mut tier = COMPACT_TIERS
        .iter()
        .rposition(|(shift, _)| abs >= 10f64.powi(*shift as i32))
        .unwrap_or(0);
    loop {
        let (shift, suffix) = COMPACT_TIERS[tier];
        let (int, tenths) = scaled_round(abs, shift);
        // Rounding up to 1000 of this tier rolls over into the next one ("999.95K" is "1M").
        if int.len() > 3 && tier + 1 < COMPACT_TIERS.len() {
            tier += 1;
            continue;
        }
        return format!("{sign}{}{suffix}", assemble(&int, tenths, 5));
    }
}

#[cfg(test)]
mod tests {
    use super::format_count_row;

    #[test]
    fn matches_the_row_style_samples() {
        for (value, expected) in [
            (0.0, "0"),
            (500.0, "500"),
            (820.6, "820.6"),
            (999.0, "999"),
            (1000.0, "1K"),
            (12_900.0, "12.9K"),
            (1_500_000.0, "1.5M"),
            (222_000_000.0, "222M"),
            (999_950.0, "1M"),
            (1_850.0, "1.8K"),
            (1_250.0, "1.2K"),
            (1_251.0, "1.3K"),
            (3_400_000_000.0, "3.4B"),
            (1.0e12, "1T"),
        ] {
            assert_eq!(format_count_row(value), expected, "{value}");
        }
        assert_eq!(format_count_row(i64::MAX as f64), "9,223,372T");
    }
}
