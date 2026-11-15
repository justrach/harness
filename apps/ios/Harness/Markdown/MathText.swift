// Math in replies (crates/ui/src/markdown/math.rs). Models write LaTeX between
// `\(`…`\)`, `\[`…`\]` or `$$`…`$$`. swift-markdown reads `\(` and `\[` as escaped
// punctuation, so `\(w_0\)` showed as `(w_0)`. Math spans are swapped for
// placeholder tokens before parsing (`protect`) and come back as readable
// Unicode (`w₀`, `h(x) = w₀ + w₁x`, `≤`, `∑`, `a/b`). A single `$` is left
// alone: prices would read as math.

import Foundation

enum MathText {
    private static let tokenStart: Character = "\u{E000}"
    private static let tokenEnd: Character = "\u{E001}"
    /// Marks a line the token carried over from a multi-line span.
    private static let continuation: Character = "\u{E002}"
    private static let maxMathChars = 8 * 1024

    struct Formula: Hashable {
        let latex: String
        let display: Bool
        /// The span as written, delimiters included, for code that held it.
        let source: String
    }

    /// `source` with each math span outside code replaced by a token naming its
    /// formula. The token keeps the span's line breaks (each followed by the
    /// line's indent and a continuation mark), so block line numbers, which the
    /// streaming reparse anchors on, don't move and the paragraph stays whole.
    static func protect(_ source: String) -> (text: String, formulas: [Formula]) {
        guard source.contains("\\(") || source.contains("\\[") || source.contains("$$") else {
            return (source, [])
        }
        let chars = Array(source)
        var out = ""
        var formulas: [Formula] = []
        var i = 0
        var inFence = false
        var lineStart = true
        while i < chars.count {
            let c = chars[i]
            if lineStart {
                // A fence line toggles a code block, which stays literal.
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                if j + 2 < chars.count, (chars[j...j + 2].allSatisfy { $0 == "`" } || chars[j...j + 2].allSatisfy { $0 == "~" }) {
                    inFence.toggle()
                }
            }
            lineStart = c == "\n"
            if inFence {
                out.append(c); i += 1
                continue
            }
            if c == "`", backslashesBefore(chars, i) % 2 == 0 {
                // An inline code span: copy it untouched up to its matching run.
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if let close = matchingTicks(chars, from: i + run, run: run) {
                    out.append(contentsOf: chars[i..<close + run])
                    i = close + run
                } else {
                    out.append(contentsOf: chars[i..<i + run])
                    i += run
                }
                continue
            }
            if (c == "\\" || c == "$"), let span = span(chars, at: i) {
                out.append(tokenStart)
                out.append(String(formulas.count))
                out.append(tokenEnd)
                var j = i
                while j < span.end {
                    if chars[j].isNewline {
                        out.append(chars[j])
                        j += 1
                        while j < span.end, chars[j] == " " || chars[j] == "\t" { out.append(chars[j]); j += 1 }
                        out.append(continuation)
                    } else {
                        j += 1
                    }
                }
                formulas.append(Formula(latex: span.latex, display: span.display, source: String(chars[i..<span.end])))
                i = span.end
                continue
            }
            out.append(c)
            i += 1
        }
        return (out, formulas)
    }

    private static func matchingTicks(_ chars: [Character], from: Int, run: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == "\n", i + 1 < chars.count, chars[i + 1] == "\n" { return nil }
            if chars[i] == "`" {
                var n = 0
                while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                if n == run { return i }
                i += n
                continue
            }
            i += 1
        }
        return nil
    }

    private static func backslashesBefore(_ chars: [Character], _ at: Int) -> Int {
        var n = 0
        var i = at - 1
        while i >= 0, chars[i] == "\\" { n += 1; i -= 1 }
        return n
    }

    private static func span(_ chars: [Character], at: Int) -> (end: Int, latex: String, display: Bool)? {
        guard at + 1 < chars.count else { return nil }
        let pair = String(chars[at...at + 1])
        let close: [Character]
        let display: Bool
        switch pair {
        case "\\(": close = ["\\", ")"]; display = false
        case "\\[": close = ["\\", "]"]; display = true
        case "$$": close = ["$", "$"]; display = true
        default: return nil
        }
        if backslashesBefore(chars, at) % 2 == 1 { return nil }
        let bodyStart = at + 2
        var i = bodyStart
        while i + 1 < chars.count, i - bodyStart <= maxMathChars {
            if chars[i] == close[0], chars[i + 1] == close[1],
               !(close[0] == "\\" && backslashesBefore(chars, i) % 2 == 1) {
                let body = String(chars[bodyStart..<i])
                guard !body.contains("\n\n"), looksLikeMath(body) else { return nil }
                return (i + 2, body.trimmingCharacters(in: .whitespacesAndNewlines), display)
            }
            i += 1
        }
        return nil
    }

    /// `\[1\]` and `\(optional\)` are escaped punctuation, not math.
    private static func looksLikeMath(_ body: String) -> Bool {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.contains(where: { "\\^_=+<>{}|".contains($0) }) { return true }
        return t.count <= 4 && t.contains(where: \.isLetter)
    }

    // MARK: - Tokens → math

    /// Parsed blocks with each token back as math in prose, or as the span as
    /// written in code.
    static func restore(_ blocks: [TopBlock], _ formulas: [Formula]) -> [TopBlock] {
        guard !formulas.isEmpty else { return blocks }
        return blocks.map { TopBlock(startLine: $0.startLine, block: restore($0.block, formulas)) }
    }

    private static func restore(_ block: MDBlock, _ formulas: [Formula]) -> MDBlock {
        switch block {
        case let .response(children):
            return .response(children.map { restore($0, formulas) })
        case let .paragraph(runs):
            return .paragraph(expand(runs, formulas))
        case let .heading(level, runs):
            return .heading(level: level, expand(runs, formulas))
        case let .codeBlock(language, code):
            return .codeBlock(language: language, code: written(code, formulas))
        case let .blockquote(children):
            return .blockquote(children.map { restore($0, formulas) })
        case let .list(start, items):
            return .list(orderedStart: start, items: items.map {
                MDListItem(checked: $0.checked, children: $0.children.map { restore($0, formulas) })
            })
        case let .table(header, rows, align):
            return .table(
                header: header.map { expand($0, formulas) },
                rows: rows.map { $0.map { expand($0, formulas) } },
                align: align
            )
        case .rule:
            return .rule
        }
    }

    /// The formula index of the token at `at`, and the index after it.
    private static func token(_ chars: [Character], at: Int, count: Int) -> (Int, Int)? {
        guard chars[at] == tokenStart else { return nil }
        var i = at + 1
        var digits = ""
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { digits.append(chars[i]); i += 1 }
        guard i < chars.count, chars[i] == tokenEnd, let n = Int(digits), n < count else { return nil }
        return (n, i + 1)
    }

    /// Code keeps the span as written; its carried-over lines are already in it.
    private static func written(_ code: String, _ formulas: [Formula]) -> String {
        let chars = Array(code)
        var out = ""
        var i = 0
        while i < chars.count {
            guard let (n, next) = token(chars, at: i, count: formulas.count) else {
                out.append(chars[i]); i += 1
                continue
            }
            i = next
            // Each later line of the span takes the indent its carried-over line
            // kept, which the code block has already trimmed.
            let lines = formulas[n].source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            out += lines[0]
            for line in lines.dropFirst() {
                guard i < chars.count, chars[i].isNewline else { break }
                var j = i + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                guard j < chars.count, chars[j] == continuation else { break }
                out.append(chars[i])
                out.append(contentsOf: chars[(i + 1)..<j])
                out += line.drop(while: { $0 == " " || $0 == "\t" })
                i = j + 1
            }
        }
        return out
    }

    /// Prose runs with each token as readable math. Display math takes a line
    /// of its own; code runs are left as they are.
    private static func expand(_ runs: [InlineRun], _ formulas: [Formula]) -> [InlineRun] {
        guard runs.contains(where: { !$0.style.code && $0.text.contains(tokenStart) }) else { return runs }
        var out: [InlineRun] = []
        var afterDisplay = false
        var endsWithDisplay = false
        for run in runs {
            if run.style.code {
                out.append(run)
                afterDisplay = false
                endsWithDisplay = false
                continue
            }
            let chars = Array(run.text)
            var text = ""
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if afterDisplay, c == " " || c == continuation { i += 1; continue }
                afterDisplay = false
                if c == continuation {
                    // The soft break before a carried-over line already spaces it.
                    if text.last == " " { text.removeLast() }
                    i += 1
                    continue
                }
                guard let (n, next) = token(chars, at: i, count: formulas.count) else {
                    text.append(c)
                    endsWithDisplay = false
                    i += 1
                    continue
                }
                let math = toUnicode(formulas[n].latex)
                if formulas[n].display {
                    while text.last == " " { text.removeLast() }
                    if text.isEmpty, out.last?.style.code == false {
                        while out[out.count - 1].text.last == " " { out[out.count - 1].text.removeLast() }
                    }
                    let lineStart = text.isEmpty ? (out.last?.text.last ?? "\n") == "\n" : text.last == "\n"
                    text += (lineStart ? "" : "\n") + math + "\n"
                    afterDisplay = true
                    endsWithDisplay = true
                } else {
                    text += math
                    endsWithDisplay = false
                }
                i = next
            }
            if !text.isEmpty { out.append(InlineRun(text: text, style: run.style)) }
        }
        // Display math at the end leaves a line break with nothing after it.
        if endsWithDisplay, let last = out.last, last.text.hasSuffix("\n") {
            out[out.count - 1].text.removeLast()
            if out[out.count - 1].text.isEmpty { out.removeLast() }
        }
        return MarkdownParser.mergeRuns(out)
    }

    // MARK: - LaTeX → Unicode

    static func toUnicode(_ latex: String) -> String {
        var converter = Converter(chars: Array(latex))
        var out = ""
        converter.convert(into: &out, stop: nil)
        return tidy(out)
    }

    private struct Converter {
        let chars: [Character]
        var at = 0

        func peek() -> Character? { at < chars.count ? chars[at] : nil }

        mutating func convert(into out: inout String, stop: Character?) {
            while let c = peek() {
                if c == stop { at += 1; return }
                at += 1
                switch c {
                case "\\": command(into: &out)
                case "{": convert(into: &out, stop: "}")
                case "}": break
                case "^": out += MathText.script(argument(), sup: true)
                case "_": out += MathText.script(argument(), sup: false)
                case "~", "&": out += " "
                case "'": out += "′"
                default: out.append(c)
                }
            }
        }

        mutating func argument() -> String {
            while peek() == " " { at += 1 }
            var out = ""
            switch peek() {
            case "{": at += 1; convert(into: &out, stop: "}")
            case "\\": at += 1; command(into: &out)
            case let c?: at += 1; out.append(c)
            case nil: break
            }
            return out
        }

        mutating func optional() -> String? {
            guard peek() == "[" else { return nil }
            at += 1
            var out = ""
            while let c = peek() {
                at += 1
                if c == "]" { break }
                out.append(c)
            }
            return out
        }

        mutating func command(into out: inout String) {
            guard let first = peek() else { return }
            guard first.isASCII, first.isLetter else {
                at += 1
                switch first {
                case ",", ";", ":", " ": out += " "
                case "!": break
                case "\\": out += "\n"
                default: out.append(first)
                }
                return
            }
            var name = ""
            while let c = peek(), c.isASCII, c.isLetter { name.append(c); at += 1 }
            switch name {
            case "frac", "dfrac", "tfrac":
                let num = argument(), den = argument()
                out += "\(MathText.group(num))/\(MathText.group(den))"
            case "sqrt":
                let index = optional(), arg = argument()
                if let index { out += MathText.script(index, sup: true) }
                out += "√" + MathText.group(arg)
            case "text", "mathrm", "mathit", "mathbf", "mathsf", "mathtt", "operatorname",
                 "textbf", "textit", "boldsymbol", "bm", "mbox":
                out += argument()
            case "mathbb":
                out += argument().map { MathText.doubleStruck($0) }.joined()
            case "hat", "widehat": MathText.accent(&out, argument(), "\u{0302}")
            case "bar", "overline": MathText.accent(&out, argument(), "\u{0304}")
            case "tilde", "widetilde": MathText.accent(&out, argument(), "\u{0303}")
            case "vec": MathText.accent(&out, argument(), "\u{20D7}")
            case "dot": MathText.accent(&out, argument(), "\u{0307}")
            case "ddot": MathText.accent(&out, argument(), "\u{0308}")
            case "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "textstyle", "limits", "nolimits":
                break
            case "quad": out += "  "
            case "qquad": out += "    "
            case "begin", "end": _ = argument()
            default: out += MathText.symbols[name] ?? name
            }
        }
    }

    fileprivate static func group(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        let simple = t.count <= 1 || t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "′" }
            || (t.hasPrefix("(") && t.hasSuffix(")"))
        return simple ? t : "(\(t))"
    }

    fileprivate static func accent(_ out: inout String, _ arg: String, _ mark: String) {
        out += arg
        if !arg.isEmpty { out += mark }
    }

    fileprivate static func script(_ arg: String, sup: Bool) -> String {
        let t = arg.trimmingCharacters(in: .whitespaces)
        let table = sup ? superscripts : subscripts
        let mapped = t.unicodeScalars.map { table[$0] }
        if !t.isEmpty, mapped.allSatisfy({ $0 != nil }) {
            return String(String.UnicodeScalarView(mapped.compactMap { $0 }))
        }
        let mark = sup ? "^" : "_"
        return t.count == 1 ? mark + t : "\(mark)(\(t))"
    }

    fileprivate static func doubleStruck(_ c: Character) -> String {
        switch c {
        case "R": return "ℝ"
        case "N": return "ℕ"
        case "Z": return "ℤ"
        case "Q": return "ℚ"
        case "C": return "ℂ"
        case "P": return "ℙ"
        case "E": return "𝔼"
        default: return String(c)
        }
    }

    private static func tidy(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func table(_ keys: String, _ values: String) -> [Unicode.Scalar: Unicode.Scalar] {
        Dictionary(uniqueKeysWithValues: zip(keys.unicodeScalars, values.unicodeScalars))
    }

    private static let superscripts: [Unicode.Scalar: Unicode.Scalar] = {
        var t = table("0123456789+-=()abcdefghijklmnoprstuvwxyzT′* ", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᵀ′* ")
        t["−"] = "⁻"
        return t
    }()

    private static let subscripts: [Unicode.Scalar: Unicode.Scalar] = {
        var t = table("0123456789+-=()aehijklmnoprstuvxβγρφχ, ", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵦᵧᵨᵩᵪ, ")
        t["−"] = "₋"
        return t
    }()

    fileprivate static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ",
        "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆",
        "circ": "∘", "bullet": "•", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠",
        "neq": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅",
        "propto": "∝", "ll": "≪", "gg": "≫", "infty": "∞", "partial": "∂", "nabla": "∇",
        "sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮", "in": "∈", "notin": "∉",
        "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "cup": "∪",
        "cap": "∩", "emptyset": "∅", "varnothing": "∅", "setminus": "∖", "forall": "∀",
        "exists": "∃", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "implies": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⇔",
        "mapsto": "↦", "uparrow": "↑", "downarrow": "↓", "ldots": "…", "dots": "…", "dotsc": "…",
        "dotsb": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "prime": "′", "degree": "°",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "mid": "|", "vert": "|", "lvert": "|",
        "rvert": "|", "Vert": "‖", "lVert": "‖", "rVert": "‖", "langle": "⟨", "rangle": "⟩",
        "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "lbrace": "{", "rbrace": "}",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "therefore": "∴",
        "because": "∵", "top": "⊤", "bot": "⊥", "oplus": "⊕", "otimes": "⊗", "dagger": "†",
    ]
}
