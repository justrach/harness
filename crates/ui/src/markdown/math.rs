//! Math in replies. Models write LaTeX between `\(`…`\)`, `\[`…`\]` or
//! `$$`…`$$`. CommonMark reads `\(` and `\[` as escaped punctuation, so
//! `\(w_0\)` used to show as `(w_0)`, and underscores inside formulas could
//! turn into emphasis. These spans are found before Markdown parsing (see
//! `content_reference::rewrite`). The parser retains their source for native
//! equation layout; this module also supplies readable Unicode for plain-text
//! consumers: `w₀`, `h(x) = w₀ + w₁x`, `≤`, `∑`, `a/b`.
//!
//! Single-dollar inline math follows currency-aware delimiter rules: no
//! whitespace just inside either delimiter, no digit after the closing dollar,
//! and no crossing a line, a literal region, or another dollar delimiter.

use std::ops::Range;

/// Longest formula treated as math; anything longer stays literal text.
const MAX_MATH_BYTES: usize = 8 * 1024;
/// Groups and commands both recurse; byte limits alone do not bound stack use.
const MAX_CONVERSION_DEPTH: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MathSpan {
    /// The whole span in the source, delimiters included.
    pub range: Range<usize>,
    pub latex: String,
    pub display: bool,
}

/// Every complete math span outside `protected` ranges (code, HTML, links).
pub(crate) fn spans(source: &str, protected: &[Range<usize>]) -> Vec<MathSpan> {
    let bytes = source.as_bytes();
    let mut out = Vec::new();
    let mut at = 0;
    while at + 1 < bytes.len() {
        if bytes[at] == b'$' {
            if backslashes_before(bytes, at) % 2 != 0 {
                at += 1;
                continue;
            }
            let count = bytes[at..].iter().take_while(|&&b| b == b'$').count();
            if count > 2 {
                at += count;
                continue;
            }
            if count == 1 {
                if let Some(end) = inline_dollar_end(source, at, protected) {
                    out.push(MathSpan {
                        range: at..end,
                        latex: source[at + 1..end - 1].to_owned(),
                        display: false,
                    });
                    at = end;
                } else {
                    at += 1;
                }
                continue;
            }
        }
        let delims = match &bytes[at..at + 2] {
            b"\\(" => Some(("\\)", false)),
            b"\\[" => Some(("\\]", true)),
            b"$$" => Some(("$$", true)),
            _ => None,
        };
        let Some((close, display)) = delims else {
            at += 1;
            continue;
        };
        let open_escaped = backslashes_before(bytes, at) % 2 == 1;
        if open_escaped || protected.iter().any(|r| r.contains(&at)) {
            at += 2;
            continue;
        }
        let body_start = at + 2;
        let Some(body_len) = find_close(&source[body_start..], close) else {
            at += 2;
            continue;
        };
        let body = &source[body_start..body_start + body_len];
        let end = body_start + body_len + close.len();
        if body.len() > MAX_MATH_BYTES
            || crosses_paragraph(body)
            || !looks_like_math(body)
            || protected.iter().any(|r| r.start < end && at < r.end)
        {
            at += 2;
            continue;
        }
        out.push(MathSpan {
            range: at..end,
            latex: body.trim().to_owned(),
            display,
        });
        at = end;
    }
    out
}

/// Pandoc-style dollar boundaries prevent `$5 and $10` (including price
/// ranges) from becoming math without excluding `$x$`, `$1$` or LaTeX commands.
/// Stop at the first unescaped dollar even if it is not a valid closer: looking
/// past a price/code/display delimiter can swallow later prose or equations.
fn inline_dollar_end(source: &str, start: usize, protected: &[Range<usize>]) -> Option<usize> {
    if protected.iter().any(|r| r.contains(&start)) {
        return None;
    }
    let body_start = start + 1;
    let first = source[body_start..].chars().next()?;
    if first.is_whitespace() || first == '$' {
        return None;
    }
    for (offset, c) in source[body_start..].char_indices() {
        if offset > MAX_MATH_BYTES || matches!(c, '\n' | '\r') {
            return None;
        }
        let close = body_start + offset;
        if c != '$' || backslashes_before(source.as_bytes(), close) % 2 != 0 {
            continue;
        }
        let body = &source[body_start..close];
        let end = close + 1;
        return (!body.is_empty()
            && !price_before_parenthesis(body)
            && !body.ends_with(char::is_whitespace)
            && !source[end..].starts_with(|c: char| c == '$' || c.is_numeric())
            && !source[end..]
                .strip_prefix('.')
                .is_some_and(|tail| tail.starts_with(char::is_numeric))
            && !protected.iter().any(|r| r.start < end && start < r.end))
        .then_some(end);
    }
    None
}

/// Prefer a price in `pay $5 ($x^2$)`: otherwise the amount and opening
/// parentheses steal the equation's opening dollar. A bare `$5$` and complete
/// mathematical expressions such as `$5 (x)$` remain valid inline math.
fn price_before_parenthesis(body: &str) -> bool {
    if !body.starts_with(char::is_numeric)
        && !body
            .strip_prefix('.')
            .is_some_and(|tail| tail.starts_with(char::is_numeric))
    {
        return false;
    }
    let rest = body.trim_start_matches(|c: char| c.is_numeric() || matches!(c, '.' | ','));
    !rest.is_empty()
        && rest
            .chars()
            .all(|c| c.is_whitespace() || matches!(c, '(' | '[' | '{'))
}

/// CommonMark also treats CR and whitespace-only lines as paragraph breaks.
/// Rewriting across one can change code/link structure and leak placeholders.
fn crosses_paragraph(body: &str) -> bool {
    let bytes = body.as_bytes();
    let mut after_break = false;
    for (at, &byte) in bytes.iter().enumerate() {
        if byte == b'\n' && at > 0 && bytes[at - 1] == b'\r' {
            continue;
        }
        if matches!(byte, b'\n' | b'\r') {
            if after_break {
                return true;
            }
            after_break = true;
        } else if !matches!(byte, b' ' | b'\t') {
            after_break = false;
        }
    }
    false
}

fn backslashes_before(bytes: &[u8], at: usize) -> usize {
    bytes[..at]
        .iter()
        .rev()
        .take_while(|b| **b == b'\\')
        .count()
}

/// The closing delimiter's offset in `rest`, skipping escaped ones
/// (`\\)` is a LaTeX line break followed by a parenthesis).
fn find_close(rest: &str, close: &str) -> Option<usize> {
    let bytes = rest.as_bytes();
    bytes
        .windows(close.len())
        .take(MAX_MATH_BYTES + 1)
        .enumerate()
        .find_map(|(at, window)| {
            let whole_dollar_pair = close != "$$"
                || (bytes.get(at + 2) != Some(&b'$')
                    && (at == 0
                        || bytes[at - 1] != b'$'
                        || backslashes_before(bytes, at - 1) % 2 != 0));
            (window == close.as_bytes()
                && whole_dollar_pair
                && backslashes_before(bytes, at) % 2 == 0)
                .then_some(at)
        })
}

/// `\[1\]` and `\(optional\)` are escaped Markdown punctuation, not math.
/// A formula has a command, a script, an operator, or is a short symbol.
fn looks_like_math(body: &str) -> bool {
    let body = body.trim();
    if body.is_empty() {
        return false;
    }
    if body.chars().any(|c| {
        matches!(
            c,
            '\\' | '^' | '_' | '=' | '+' | '<' | '>' | '{' | '}' | '|'
        )
    }) {
        return true;
    }
    // A short symbol such as `x`, `n`, `f(x)` or `x2`, but not a bare number.
    body.chars().count() <= 4 && body.chars().any(char::is_alphabetic)
}

/// LaTeX as readable Unicode. Unknown commands keep their name.
pub(crate) fn to_unicode(latex: &str) -> String {
    let mut out = String::new();
    let mut converter = Converter {
        chars: latex.chars().collect(),
        at: 0,
        depth: 0,
        exhausted: false,
    };
    converter.convert_into(&mut out, None);
    if converter.exhausted {
        latex.to_owned()
    } else {
        tidy(&out)
    }
}

struct Converter {
    chars: Vec<char>,
    at: usize,
    depth: usize,
    exhausted: bool,
}

impl Converter {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }

    /// Convert until `stop` (a closing brace) or the end.
    fn convert_into(&mut self, out: &mut String, stop: Option<char>) {
        if !self.descend() {
            return;
        }
        self.convert_inner(out, stop);
        self.depth -= 1;
    }

    fn descend(&mut self) -> bool {
        if self.depth == MAX_CONVERSION_DEPTH {
            self.exhausted = true;
            self.at = self.chars.len();
            return false;
        }
        self.depth += 1;
        true
    }

    fn convert_inner(&mut self, out: &mut String, stop: Option<char>) {
        while let Some(c) = self.peek() {
            if Some(c) == stop {
                self.at += 1;
                return;
            }
            self.at += 1;
            match c {
                '\\' => self.command(out),
                '{' => self.convert_into(out, Some('}')),
                '}' => {}
                '^' => {
                    let arg = self.argument();
                    out.push_str(&script(&arg, true));
                }
                '_' => {
                    let arg = self.argument();
                    out.push_str(&script(&arg, false));
                }
                '~' => out.push(' '),
                '&' => out.push(' '),
                '\'' => out.push('′'),
                _ => out.push(c),
            }
        }
    }

    /// The next argument, converted: a braced group, a command, or one char.
    fn argument(&mut self) -> String {
        while self.peek() == Some(' ') {
            self.at += 1;
        }
        let mut out = String::new();
        match self.peek() {
            Some('{') => {
                self.at += 1;
                self.convert_into(&mut out, Some('}'));
            }
            Some('\\') => {
                self.at += 1;
                self.command(&mut out);
            }
            Some(c) => {
                self.at += 1;
                out.push(c);
            }
            None => {}
        }
        out
    }

    /// An optional `[...]` argument (`\sqrt[3]{x}`).
    fn optional(&mut self) -> Option<String> {
        if self.peek() != Some('[') {
            return None;
        }
        self.at += 1;
        let mut out = String::new();
        while let Some(c) = self.peek() {
            self.at += 1;
            if c == ']' {
                break;
            }
            out.push(c);
        }
        Some(out)
    }

    fn command(&mut self, out: &mut String) {
        if !self.descend() {
            return;
        }
        self.command_inner(out);
        self.depth -= 1;
    }

    fn command_inner(&mut self, out: &mut String) {
        let Some(first) = self.peek() else {
            return;
        };
        if !first.is_ascii_alphabetic() {
            self.at += 1;
            match first {
                ',' | ';' | ':' | ' ' => out.push(' '),
                '!' => {}
                '\\' => out.push('\n'),
                '{' | '}' | '$' | '%' | '#' | '&' | '_' | '|' => out.push(first),
                other => out.push(other),
            }
            return;
        }
        let mut name = String::new();
        while let Some(c) = self.peek().filter(char::is_ascii_alphabetic) {
            name.push(c);
            self.at += 1;
        }
        match name.as_str() {
            "frac" | "dfrac" | "tfrac" => {
                let num = self.argument();
                let den = self.argument();
                out.push_str(&format!("{}/{}", group(&num), group(&den)));
            }
            "sqrt" => {
                let index = self.optional();
                let arg = self.argument();
                if let Some(index) = index {
                    out.push_str(&script(&index, true));
                }
                out.push('√');
                out.push_str(&group(&arg));
            }
            "text" | "mathrm" | "mathit" | "mathbf" | "mathsf" | "mathtt" | "operatorname"
            | "textbf" | "textit" | "boldsymbol" | "bm" | "mbox" => {
                out.push_str(&self.argument());
            }
            "mathbb" => {
                let arg = self.argument();
                out.push_str(&arg.chars().map(double_struck).collect::<String>());
            }
            "hat" | "widehat" => accent(out, &self.argument(), '\u{0302}'),
            "bar" | "overline" => accent(out, &self.argument(), '\u{0304}'),
            "tilde" | "widetilde" => accent(out, &self.argument(), '\u{0303}'),
            "vec" => accent(out, &self.argument(), '\u{20D7}'),
            "dot" => accent(out, &self.argument(), '\u{0307}'),
            "ddot" => accent(out, &self.argument(), '\u{0308}'),
            // Sizing and spacing wrappers carry no meaning in plain text.
            "left" | "right" | "big" | "Big" | "bigg" | "Bigg" | "displaystyle" | "textstyle"
            | "limits" | "nolimits" => {}
            "quad" => out.push_str("  "),
            "qquad" => out.push_str("    "),
            "begin" | "end" => {
                // `\begin{aligned}`: drop the environment name.
                self.argument();
            }
            other => match symbol(other) {
                Some(symbol) => out.push_str(symbol),
                // `\log`, `\sin`, `\max`… read as their names.
                None => out.push_str(other),
            },
        }
    }
}

/// Parenthesize a multi-part fraction term or root body: `(a+b)/2`.
fn group(s: &str) -> String {
    let s = s.trim();
    let simple = s.chars().count() <= 1
        || s.chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '.' | '′'))
        || (s.starts_with('(') && s.ends_with(')'));
    if simple {
        s.to_owned()
    } else {
        format!("({s})")
    }
}

fn accent(out: &mut String, arg: &str, mark: char) {
    out.push_str(arg);
    if !arg.is_empty() {
        out.push(mark);
    }
}

/// Superscript or subscript in Unicode when every character has a form,
/// else `^(...)` / `_(...)`.
fn script(arg: &str, sup: bool) -> String {
    let arg = arg.trim();
    let mapped: Option<String> = arg
        .chars()
        .map(|c| if sup { superscript(c) } else { subscript(c) })
        .collect();
    match mapped {
        Some(mapped) if !mapped.is_empty() => mapped,
        _ if arg.chars().count() == 1 => format!("{}{arg}", if sup { '^' } else { '_' }),
        _ => format!("{}({arg})", if sup { '^' } else { '_' }),
    }
}

fn superscript(c: char) -> Option<char> {
    Some(match c {
        '0' => '⁰',
        '1' => '¹',
        '2' => '²',
        '3' => '³',
        '4' => '⁴',
        '5' => '⁵',
        '6' => '⁶',
        '7' => '⁷',
        '8' => '⁸',
        '9' => '⁹',
        '+' => '⁺',
        '-' | '−' => '⁻',
        '=' => '⁼',
        '(' => '⁽',
        ')' => '⁾',
        'a' => 'ᵃ',
        'b' => 'ᵇ',
        'c' => 'ᶜ',
        'd' => 'ᵈ',
        'e' => 'ᵉ',
        'f' => 'ᶠ',
        'g' => 'ᵍ',
        'h' => 'ʰ',
        'i' => 'ⁱ',
        'j' => 'ʲ',
        'k' => 'ᵏ',
        'l' => 'ˡ',
        'm' => 'ᵐ',
        'n' => 'ⁿ',
        'o' => 'ᵒ',
        'p' => 'ᵖ',
        'r' => 'ʳ',
        's' => 'ˢ',
        't' => 'ᵗ',
        'u' => 'ᵘ',
        'v' => 'ᵛ',
        'w' => 'ʷ',
        'x' => 'ˣ',
        'y' => 'ʸ',
        'z' => 'ᶻ',
        'T' => 'ᵀ',
        '′' => '′',
        '*' => '*',
        ' ' => ' ',
        _ => return None,
    })
}

fn subscript(c: char) -> Option<char> {
    Some(match c {
        '0' => '₀',
        '1' => '₁',
        '2' => '₂',
        '3' => '₃',
        '4' => '₄',
        '5' => '₅',
        '6' => '₆',
        '7' => '₇',
        '8' => '₈',
        '9' => '₉',
        '+' => '₊',
        '-' | '−' => '₋',
        '=' => '₌',
        '(' => '₍',
        ')' => '₎',
        'a' => 'ₐ',
        'e' => 'ₑ',
        'h' => 'ₕ',
        'i' => 'ᵢ',
        'j' => 'ⱼ',
        'k' => 'ₖ',
        'l' => 'ₗ',
        'm' => 'ₘ',
        'n' => 'ₙ',
        'o' => 'ₒ',
        'p' => 'ₚ',
        'r' => 'ᵣ',
        's' => 'ₛ',
        't' => 'ₜ',
        'u' => 'ᵤ',
        'v' => 'ᵥ',
        'x' => 'ₓ',
        'β' => 'ᵦ',
        'γ' => 'ᵧ',
        'ρ' => 'ᵨ',
        'φ' => 'ᵩ',
        'χ' => 'ᵪ',
        ',' => ',',
        ' ' => ' ',
        _ => return None,
    })
}

fn double_struck(c: char) -> char {
    match c {
        'R' => 'ℝ',
        'N' => 'ℕ',
        'Z' => 'ℤ',
        'Q' => 'ℚ',
        'C' => 'ℂ',
        'P' => 'ℙ',
        'E' => '𝔼',
        other => other,
    }
}

fn symbol(name: &str) -> Option<&'static str> {
    Some(match name {
        "alpha" => "α",
        "beta" => "β",
        "gamma" => "γ",
        "delta" => "δ",
        "epsilon" => "ε",
        "varepsilon" => "ε",
        "zeta" => "ζ",
        "eta" => "η",
        "theta" => "θ",
        "vartheta" => "ϑ",
        "iota" => "ι",
        "kappa" => "κ",
        "lambda" => "λ",
        "mu" => "μ",
        "nu" => "ν",
        "xi" => "ξ",
        "pi" => "π",
        "varpi" => "ϖ",
        "rho" => "ρ",
        "varrho" => "ϱ",
        "sigma" => "σ",
        "varsigma" => "ς",
        "tau" => "τ",
        "upsilon" => "υ",
        "phi" => "φ",
        "varphi" => "φ",
        "chi" => "χ",
        "psi" => "ψ",
        "omega" => "ω",
        "Gamma" => "Γ",
        "Delta" => "Δ",
        "Theta" => "Θ",
        "Lambda" => "Λ",
        "Xi" => "Ξ",
        "Pi" => "Π",
        "Sigma" => "Σ",
        "Upsilon" => "Υ",
        "Phi" => "Φ",
        "Psi" => "Ψ",
        "Omega" => "Ω",
        "cdot" => "·",
        "times" => "×",
        "div" => "÷",
        "pm" => "±",
        "mp" => "∓",
        "ast" => "∗",
        "star" => "⋆",
        "circ" => "∘",
        "bullet" => "•",
        "le" | "leq" => "≤",
        "ge" | "geq" => "≥",
        "ne" | "neq" => "≠",
        "approx" => "≈",
        "equiv" => "≡",
        "sim" => "∼",
        "simeq" => "≃",
        "cong" => "≅",
        "propto" => "∝",
        "ll" => "≪",
        "gg" => "≫",
        "infty" => "∞",
        "partial" => "∂",
        "nabla" => "∇",
        "sum" => "∑",
        "prod" => "∏",
        "int" => "∫",
        "iint" => "∬",
        "oint" => "∮",
        "in" => "∈",
        "notin" => "∉",
        "ni" => "∋",
        "subset" => "⊂",
        "subseteq" => "⊆",
        "supset" => "⊃",
        "supseteq" => "⊇",
        "cup" => "∪",
        "cap" => "∩",
        "emptyset" => "∅",
        "varnothing" => "∅",
        "setminus" => "∖",
        "forall" => "∀",
        "exists" => "∃",
        "neg" | "lnot" => "¬",
        "land" | "wedge" => "∧",
        "lor" | "vee" => "∨",
        "to" | "rightarrow" => "→",
        "leftarrow" | "gets" => "←",
        "leftrightarrow" => "↔",
        "Rightarrow" | "implies" => "⇒",
        "Leftarrow" => "⇐",
        "Leftrightarrow" | "iff" => "⇔",
        "mapsto" => "↦",
        "uparrow" => "↑",
        "downarrow" => "↓",
        "ldots" | "dots" | "dotsc" | "dotsb" => "…",
        "cdots" => "⋯",
        "vdots" => "⋮",
        "ddots" => "⋱",
        "prime" => "′",
        "degree" => "°",
        "angle" => "∠",
        "perp" => "⊥",
        "parallel" => "∥",
        "mid" => "|",
        "vert" | "lvert" | "rvert" => "|",
        "Vert" | "lVert" | "rVert" => "‖",
        "langle" => "⟨",
        "rangle" => "⟩",
        "lfloor" => "⌊",
        "rfloor" => "⌋",
        "lceil" => "⌈",
        "rceil" => "⌉",
        "lbrace" => "{",
        "rbrace" => "}",
        "hbar" => "ℏ",
        "ell" => "ℓ",
        "Re" => "ℜ",
        "Im" => "ℑ",
        "aleph" => "ℵ",
        "therefore" => "∴",
        "because" => "∵",
        "top" => "⊤",
        "bot" => "⊥",
        "oplus" => "⊕",
        "otimes" => "⊗",
        "dagger" => "†",
        _ => return None,
    })
}

/// Collapse the doubled spaces spacing commands leave, line by line.
fn tidy(s: &str) -> String {
    s.lines()
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned()
}

#[cfg(test)]
#[path = "math_dollar_tests.rs"]
mod dollar_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_reported_formulas_read_as_math() {
        assert_eq!(to_unicode("w_0"), "w₀");
        assert_eq!(to_unicode(" h(x)=w_0+w_1x, "), "h(x)=w₀+w₁x,");
        assert_eq!(to_unicode("x_{10}^2"), "x₁₀²");
    }

    #[test]
    fn commands_fractions_roots_and_sets() {
        assert_eq!(to_unicode("\\frac{1}{2}"), "1/2");
        assert_eq!(to_unicode("\\frac{a+b}{n}"), "(a+b)/n");
        assert_eq!(to_unicode("\\sqrt{x^2 + y^2}"), "√(x² + y²)");
        assert_eq!(to_unicode("\\sqrt[3]{8}"), "³√8");
        assert_eq!(to_unicode("\\sum_{i=1}^{n} x_i"), "∑ᵢ₌₁ⁿ xᵢ");
        assert_eq!(
            to_unicode("\\alpha \\le \\beta \\cdot \\theta"),
            "α ≤ β · θ"
        );
        assert_eq!(to_unicode("x \\in \\mathbb{R}^n"), "x ∈ ℝⁿ");
        assert_eq!(
            to_unicode("\\hat{y} = \\text{mean}(y)"),
            "y\u{0302} = mean(y)"
        );
        assert_eq!(to_unicode("\\left( a \\right)"), "( a )");
        assert_eq!(to_unicode("\\log n"), "log n");
        assert_eq!(to_unicode("\\theta^T x"), "θᵀ x");
    }

    #[test]
    fn scripts_without_unicode_forms_stay_readable() {
        assert_eq!(to_unicode("x_{max}"), "xₘₐₓ");
        assert_eq!(to_unicode("x_{best}"), "x_(best)");
        assert_eq!(to_unicode("e^{-\\lambda t}"), "e^(-λ t)");
        assert_eq!(to_unicode("a_B"), "a_B");
    }

    /// The reported reply, through the whole Markdown parser: the formulas
    /// keep their backslashes' meaning, bold still applies around them, and
    /// display math sits on its own line.
    #[test]
    fn a_reply_with_formulas_parses_to_readable_math() {
        use super::super::parser::{Block, parse_full};
        let source = "the parameters **\\(w_0\\) and \\(w_1\\)**, not the inputs \\(x_0\\).\n\n\
                      For a linear regression model, \\[ h(x)=w_0+w_1x, \\] choosing one.";
        let tree = parse_full(source);
        let paragraphs: Vec<_> = tree
            .blocks
            .iter()
            .filter_map(|b| match &b.block {
                Block::Paragraph { runs } => Some(runs.clone()),
                _ => None,
            })
            .collect();
        let text = |runs: &[super::super::parser::InlineRun]| {
            runs.iter().map(|r| r.text.as_str()).collect::<String>()
        };
        assert_eq!(
            text(&paragraphs[0]),
            "the parameters w₀ and w₁, not the inputs x₀."
        );
        assert_eq!(
            paragraphs[0]
                .iter()
                .filter(|r| r.style.bold)
                .map(|r| r.text.as_str())
                .collect::<String>(),
            "w₀ and w₁"
        );
        assert_eq!(
            paragraphs[0]
                .iter()
                .filter(|r| r.style.math.is_some())
                .count(),
            3
        );
        assert_eq!(
            text(&paragraphs[1]),
            "For a linear regression model,\nh(x)=w₀+w₁x,\nchoosing one."
        );
    }

    /// Streaming: every prefix parses the same incrementally as in full,
    /// including the moments a formula is still open.
    #[test]
    fn streaming_prefixes_parse_like_the_whole() {
        use super::super::parser::{IncrementalParser, parse_full};
        let source = "Weights \\(w_0\\) and $$a^2$$.\n\nModel \\[ h(x)=w_0+w_1x \\] done.\n";
        let mut parser = IncrementalParser::new();
        for (i, c) in source.char_indices() {
            let end = i + c.len_utf8();
            parser.set_text(&source[..end]);
            assert_eq!(parser.tree(), &parse_full(&source[..end]), "{end}");
        }
    }

    #[test]
    fn spans_find_each_delimiter_and_skip_escaped_or_plain_text() {
        let source = "the weights \\(w_0\\) and \\(w_1\\): \\[ h(x)=w_0+w_1x \\] and $$a^2$$.";
        let found = spans(source, &[]);
        assert_eq!(
            found
                .iter()
                .map(|s| (s.latex.as_str(), s.display))
                .collect::<Vec<_>>(),
            [
                ("w_0", false),
                ("w_1", false),
                ("h(x)=w_0+w_1x", true),
                ("a^2", true)
            ]
        );
        assert_eq!(&source[found[0].range.clone()], "\\(w_0\\)");

        // Escaped Markdown punctuation and prices are not math.
        assert!(spans("cite \\[1\\] and \\(optional\\)", &[]).is_empty());
        assert!(spans("costs $5 and $10", &[]).is_empty());
        assert!(spans("a literal \\\\(x\\)", &[]).is_empty());
        // No closing delimiter yet (still streaming), or across a paragraph.
        assert!(spans("so \\(w_0 is", &[]).is_empty());
        assert!(spans("\\[ a^2\n\nb^2 \\]", &[]).is_empty());
        // Inside a protected range (code) it stays literal.
        assert!(spans("`\\(x^2\\)`", &[0..9]).is_empty());
    }
}
