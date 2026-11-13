//! Native equation layout retained from the original desktop renderer.
//! The exact bounded AST/TeX box layout and embedded STIX Two Math outlines
//! are shared with that implementation; nano paints trusted paths/rules via
//! its native SVG primitive. No browser, scripts, URLs, or input XML.
use latex_rust::{
    BoxContent, Dim, EnvRow, EqNumber, MathBox, MathFont, MathNode, MathParams, MathStyle,
    MatrixStyle, ParseOptions, SpaceKind, SvgOptions, Token,
};
use std::{cell::RefCell, collections::VecDeque, sync::OnceLock};
const MAX_SOURCE_BYTES: usize = 4096;
const MAX_TOKENS: usize = 512;
const MAX_COMMANDS: usize = 128;
const MAX_DEPTH: usize = 20;
const MAX_AST_NODES: usize = 512;
const MAX_BOXES: usize = 4096;
const MAX_SVG_BYTES: usize = 512 * 1024;
const MAX_WIDTH: f32 = 4096.0;
const MAX_HEIGHT: f32 = 1024.0;
const MAX_AREA: f32 = 256.0 * 1024.0;
const CACHE_ENTRIES: usize = 32;
const CACHE_BYTES: usize = 2 * 1024 * 1024;
const PADDING: f32 = 1.0;
#[derive(Clone)]
struct VectorEquation {
    svg: String,
    width: f32,
    height: f32,
    ascent: f32,
    depth: f32,
}
#[derive(Clone, PartialEq, Eq)]
struct Key {
    source: Box<str>,
    display: bool,
    size: u32,
    rgba: [u8; 4],
}
#[derive(Default)]
struct Cache {
    entries: VecDeque<(Key, VectorEquation)>,
    bytes: usize,
}
thread_local! { static CACHE: RefCell<Cache> = RefCell::new(Cache::default()); }
fn cached(source: &str, display: bool, size: f32, rgba: [u8; 4]) -> Result<VectorEquation, String> {
    validate_size(size)?;
    if source.len() > MAX_SOURCE_BYTES {
        return Err("Equation exceeds source size limit".into());
    }
    let key = Key {
        source: source.into(),
        display,
        size: size.to_bits(),
        rgba,
    };
    CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        if let Some(at) = cache.entries.iter().position(|(k, _)| *k == key) {
            let entry = cache.entries.remove(at).unwrap();
            let out = entry.1.clone();
            cache.entries.push_back(entry);
            return Ok(out);
        }
        let equation = render_svg(source, display, size, rgba)?;
        let bytes = key.source.len() + equation.svg.len();
        while cache.entries.len() >= CACHE_ENTRIES || cache.bytes + bytes > CACHE_BYTES {
            let Some((key, old)) = cache.entries.pop_front() else {
                break;
            };
            cache.bytes -= key.source.len() + old.svg.len();
        }
        if bytes <= CACHE_BYTES {
            cache.bytes += bytes;
            cache.entries.push_back((key, equation.clone()));
        }
        Ok(equation)
    })
}
/// Caller-owned result. A failed parse/layout is a literal fallback, never
/// partially rewritten mathematics. No Rust panic may cross the C ABI.
#[repr(C)]
pub struct Output {
    svg: *const u8,
    len: usize,
    width: f32,
    height: f32,
    ascent: f32,
    depth: f32,
    owner: *mut std::ffi::c_void,
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn harness_math_layout(
    source: *const u8,
    len: usize,
    display: bool,
    size: f32,
    color: u32,
    out: *mut Output,
) -> bool {
    if source.is_null() || out.is_null() || len > MAX_SOURCE_BYTES {
        return false;
    }
    let result = std::panic::catch_unwind(|| {
        let bytes = unsafe { std::slice::from_raw_parts(source, len) };
        let source = std::str::from_utf8(bytes).ok()?;
        cached(source, display, size, color.to_be_bytes()).ok()
    });
    let Ok(Some(equation)) = result else {
        return false;
    };
    let equation = Box::new(equation);
    let value = Output {
        svg: equation.svg.as_ptr(),
        len: equation.svg.len(),
        width: equation.width,
        height: equation.height,
        ascent: equation.ascent,
        depth: equation.depth,
        owner: Box::into_raw(equation).cast(),
    };
    unsafe {
        out.write(value);
    }
    true
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn harness_math_free(owner: *mut std::ffi::c_void) {
    if !owner.is_null() {
        unsafe {
            drop(Box::from_raw(owner.cast::<VectorEquation>()));
        }
    }
}
fn validate_size(size: f32) -> Result<(), String> {
    if !size.is_finite() || !(6.0..=96.0).contains(&size) {
        return Err("Equation font size is outside supported bounds".into());
    }
    Ok(())
}

fn font() -> Result<&'static MathFont, String> {
    static FONT: OnceLock<Result<MathFont, String>> = OnceLock::new();
    FONT.get_or_init(|| MathFont::stix_two_math().map_err(|e| e.to_string()))
        .as_ref()
        .map_err(Clone::clone)
}

fn preflight(source: &str) -> Result<(), String> {
    if source.len() > MAX_SOURCE_BYTES || source.trim().is_empty() {
        return Err("Equation is empty or exceeds source size limit".into());
    }
    let tokens = latex_rust::tokenize(source).map_err(|e| e.to_string())?;
    if tokens.len() > MAX_TOKENS {
        return Err("Equation exceeds token limit".into());
    }
    let (mut depth, mut commands, mut numeric_run) = (0usize, 0usize, 0usize);
    for token in &tokens {
        // Bound decimal parsing before it reaches upstream's i128 rationals.
        if matches!(token, Token::Char(c) if c.is_ascii_digit() || *c == '.') {
            numeric_run += 1;
            if numeric_run > 12 {
                return Err("Equation numeric literal exceeds limit".into());
            }
        } else {
            numeric_run = 0;
        }
        match token {
            Token::BeginGroup => {
                depth += 1;
                if depth > MAX_DEPTH {
                    return Err("Equation exceeds nesting limit".into());
                }
            }
            Token::EndGroup => depth = depth.saturating_sub(1),
            Token::Command(name) => {
                commands += 1;
                if commands > MAX_COMMANDS {
                    return Err("Equation exceeds command limit".into());
                }
                // Upstream currently treats \rule as a strut and discards its
                // width; decline it rather than silently drawing incorrect math.
                if matches!(
                    name.as_str(),
                    "rule"
                        | "binom"
                        | "dbinom"
                        | "tbinom"
                        | "genfrac"
                        | "dfrac"
                        | "tfrac"
                        | "cfrac"
                ) {
                    // Barless and explicit-style fractions collapse to the
                    // same Fraction AST as ordinary \\frac. Once parsed, their
                    // missing rule/style intent cannot be recovered reliably.
                    return Err(format!("Unsupported equation command: {name}"));
                }
                // parse_command consumes style declarations without retaining
                // them; parse_atom retains limit modifiers only on named text
                // operators, not Sum/Product/Integral. No downstream geometry
                // correction can recover this lost scope/intent. Until the AST
                // can represent it, report the limitation rather than silently
                // rendering a different equation (including inside groups).
                if matches!(
                    name.as_str(),
                    "displaystyle"
                        | "textstyle"
                        | "scriptstyle"
                        | "scriptscriptstyle"
                        | "limits"
                        | "nolimits"
                ) {
                    return Err(format!("Unsupported equation command: {name}"));
                }
            }
            _ => {}
        }
    }
    Ok(())
}

fn scalar(dim: &Dim) -> Result<f32, String> {
    let (n, d) = dim
        .as_ratio()
        .ok_or_else(|| "Invalid equation dimension".to_string())?;
    let value = (n as f64 / d as f64) as f32;
    if !value.is_finite() {
        return Err("Invalid equation dimension".into());
    }
    Ok(value)
}

// Explicit glue is classless upstream. It can erase automatic glue or
// reclassify a binary operator as unary. Admit known zero-glue boundaries,
// including ordinary letters and punctuation/delimiters, but never Bin atoms.
fn spacing_atom_kind(node: &MathNode) -> Option<latex_rust::AtomKind> {
    use latex_rust::AtomKind;
    match node {
        MathNode::Atom(_, kind) | MathNode::SizedDelim(_, _, kind) => Some(*kind),
        MathNode::Text(_, _) | MathNode::Ref(_) => Some(AtomKind::Ord),
        MathNode::Symbol(name) => Some(latex_rust::symbol_atom_kind(name)),
        MathNode::Row(nodes) if nodes.len() == 1 => spacing_atom_kind(&nodes[0]),
        MathNode::Row(_) => Some(AtomKind::Ord),
        MathNode::Superscript(base, _)
        | MathNode::Subscript(base, _)
        | MathNode::SubSup(base, _, _)
        | MathNode::Color(_, base)
        | MathNode::TextColor(_, base)
        | MathNode::Phantom(_, base) => spacing_atom_kind(base),
        _ => None,
    }
}

fn zero_implicit_glue(left: &MathNode, right: &MathNode) -> bool {
    use latex_rust::AtomKind::*;
    // Zero entries in TeX's inter-atom spacing table, excluding Bin because
    // a classless neighbor also changes binary reclassification. Unknown
    // compound atom classes conservatively retain their source instead.
    matches!(
        (spacing_atom_kind(left), spacing_atom_kind(right)),
        (Some(Ord | Close), Some(Ord | Open | Close | Punct))
            | (
                Some(Open),
                Some(Ord | Op | Rel | Open | Close | Punct | Inner)
            )
            | (Some(Op), Some(Open | Close | Punct))
            | (Some(Rel), Some(Rel | Close | Punct))
            | (Some(Inner), Some(Close))
    )
}

fn validate_row_spacing(nodes: &[MathNode]) -> Result<(), String> {
    let mut previous = None;
    let mut spaced = false;
    for node in nodes {
        if matches!(node, MathNode::Space(_)) {
            spaced = true;
            continue;
        }
        if let Some(previous) = previous {
            if spaced && !zero_implicit_glue(previous, node) {
                return Err("Explicit spacing affecting automatic math glue is unsupported".into());
            }
        }
        previous = Some(node);
        spaced = false;
    }
    Ok(())
}

// Validate the AST before potentially expensive grid/assembly layout. This also
// catches left-associated script chains which need not nest source braces.
fn validate_ast(root: &MathNode) -> Result<(), String> {
    let mut pending = vec![(root, 0usize)];
    let mut count = 0;
    while let Some((node, depth)) = pending.pop() {
        count += 1;
        if count > MAX_AST_NODES || depth > MAX_DEPTH {
            return Err("Equation exceeds layout complexity limit".into());
        }
        let mut push = |node| pending.push((node, depth + 1));
        match node {
            MathNode::Fraction(a, b)
            | MathNode::Superscript(a, b)
            | MathNode::Subscript(a, b)
            | MathNode::CancelTo(a, b) => {
                push(a);
                push(b);
            }
            MathNode::SubSup(a, b, c) => {
                push(a);
                push(b);
                push(c);
            }
            MathNode::Radical(index, body) => {
                push(body);
                if let Some(index) = index {
                    push(index);
                }
            }
            MathNode::Delimited(_, body, _)
            | MathNode::Accent(body, _)
            | MathNode::Intertext(body)
            | MathNode::Color(_, body)
            | MathNode::TextColor(_, body)
            | MathNode::ColorBox(_, body)
            | MathNode::FColorBox(_, _, body)
            | MathNode::Phantom(_, body)
            | MathNode::Tag { body, .. } => push(body),
            MathNode::Row(nodes) | MathNode::Substack(nodes) => {
                if matches!(node, MathNode::Row(_)) {
                    validate_row_spacing(nodes)?;
                }
                for node in nodes {
                    push(node);
                }
            }
            MathNode::Sum(lower, upper)
            | MathNode::Product(lower, upper)
            | MathNode::Integral(_, lower, upper) => {
                for node in lower.iter().chain(upper) {
                    push(node);
                }
            }
            MathNode::Limit(lower) => {
                if let Some(node) = lower {
                    push(node);
                }
            }
            MathNode::OverUnder(body, upper, lower) => {
                push(body);
                for node in upper.iter().chain(lower) {
                    push(node);
                }
            }
            MathNode::Matrix(_, columns, rows) => {
                if columns.len() > 16 || rows.len() > 16 {
                    return Err("Equation grid exceeds size limit".into());
                }
                for row in rows {
                    match row {
                        EnvRow::Cells { cells, number, .. } => {
                            if cells.len() > 16 {
                                return Err("Equation grid exceeds size limit".into());
                            }
                            for node in cells {
                                push(node);
                            }
                            if let EqNumber::Tag { body, .. } = number {
                                push(body);
                            }
                        }
                        EnvRow::Intertext(node) => push(node),
                        EnvRow::Hline => {}
                    }
                }
            }
            MathNode::Space(SpaceKind::Hspace(value)) => {
                if scalar(value)?.abs() > 64.0 {
                    return Err("Equation spacing exceeds limit".into());
                }
            }
            MathNode::Strut(height, depth) => {
                for value in [height, depth] {
                    if !(0.0..=64.0).contains(&scalar(value)?) {
                        return Err("Equation strut exceeds limit".into());
                    }
                }
            }
            _ => {}
        }
    }
    Ok(())
}

// Rewrite only real math commands, never substrings in literal text, comments,
// or escaped control sequences. The caller parses the original first, so this
// cannot repair malformed input into an accepted equation. Keep the original
// source for copying and cache keys; this temporary string is layout-only.
fn normalize_absolute_hspace(source: &str, size: f32) -> Result<(String, Vec<Dim>), String> {
    fn trivia(bytes: &[u8], mut i: usize) -> usize {
        loop {
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            if bytes.get(i) != Some(&b'%') {
                return i;
            }
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
        }
    }
    fn command_end(bytes: &[u8], mut i: usize) -> usize {
        if bytes.get(i).is_some_and(u8::is_ascii_alphabetic) {
            while bytes.get(i).is_some_and(u8::is_ascii_alphabetic) {
                i += 1;
            }
        } else if i < bytes.len() {
            // Control symbols may be non-ASCII; advance to a UTF-8 boundary.
            i += 1;
            while bytes.get(i).is_some_and(|b| b & 0xc0 == 0x80) {
                i += 1;
            }
        }
        i
    }
    fn group_end(bytes: &[u8], start: usize) -> Option<usize> {
        let (mut i, mut depth) = (start + 1, 1usize);
        while i < bytes.len() {
            match bytes[i] {
                b'%' => {
                    i = trivia(bytes, i);
                    continue;
                }
                b'\\' => {
                    i = command_end(bytes, i + 1);
                    continue;
                }
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(i);
                    }
                }
                _ => {}
            }
            i += 1;
        }
        None
    }
    let bytes = source.as_bytes();
    let (mut i, mut copied) = (0, 0);
    let mut out = String::new();
    let mut spaces = Vec::new();
    while i < bytes.len() {
        if bytes[i] == b'%' {
            i = trivia(bytes, i);
            continue;
        }
        if bytes[i] != b'\\' {
            i += 1;
            continue;
        }
        let command_start = i;
        let end = command_end(bytes, i + 1);
        let name = &source[i + 1..end];
        i = end;
        if !matches!(
            name,
            "hspace" | "text" | "mbox" | "operatorname" | "intertext" | "label" | "ref"
        ) {
            continue;
        }
        let start = trivia(bytes, end);
        if bytes.get(start) != Some(&b'{') {
            continue;
        }
        let Some(close) = group_end(bytes, start) else {
            continue;
        };
        i = close + 1;
        if name != "hspace" {
            continue;
        }
        let tokens = latex_rust::tokenize(&source[start + 1..close]).map_err(|e| e.to_string())?;
        let mut spec = String::new();
        for token in tokens {
            match token {
                Token::Char(c) => spec.push(c),
                Token::Space => spec.push(' '),
                _ => return Err("Invalid equation spacing".into()),
            }
        }
        let spec = spec.trim();
        let Some(number) = spec.strip_suffix("pt").or_else(|| spec.strip_suffix("bp")) else {
            continue;
        };
        let points: f64 = number
            .trim()
            .parse()
            .map_err(|_| "Invalid equation spacing")?;
        let em = points / (f64::from(size) * 0.75);
        if !em.is_finite() || em.abs() > 64.0 {
            return Err("Equation spacing exceeds limit".into());
        }
        out.push_str(&source[copied..command_start]);
        // Original AST validation reserves values above 64 for these markers.
        // Resolve each marker after parsing, using the actual enclosing style.
        out.push_str(&format!(r"\hspace{{{}em}}", 65 + spaces.len()));
        spaces.push(Dim::from_ieee32_bits((em as f32).to_bits()));
        copied = close + 1;
    }
    out.push_str(&source[copied..]);
    Ok((out, spaces))
}

// Mirror latex-rust's layout style transitions. Cramping does not affect scale,
// but retaining it here makes nested fractions/scripts follow the engine too.
fn resolve_absolute_hspace(
    node: &mut MathNode,
    style: MathStyle,
    spaces: &[Dim],
    params: &MathParams,
) {
    let visit = |node: &mut MathNode, style| {
        resolve_absolute_hspace(node, style, spaces, params);
    };
    match node {
        MathNode::Space(SpaceKind::Hspace(value)) => {
            for (index, desired) in spaces.iter().enumerate() {
                if *value == Dim::from_i64(65 + index as i64) {
                    *value = desired / &params.scale(style);
                    break;
                }
            }
        }
        MathNode::Fraction(num, den) => {
            visit(num, style.numerator());
            visit(den, style.denominator());
        }
        MathNode::Superscript(base, sup) => {
            visit(base, style);
            visit(sup, style.into_script().cramp());
        }
        MathNode::Subscript(base, sub) => {
            visit(base, style);
            visit(sub, style.into_script());
        }
        MathNode::SubSup(base, sub, sup) => {
            visit(base, style);
            visit(sub, style.into_script());
            visit(sup, style.into_script().cramp());
        }
        MathNode::Radical(index, body) => {
            visit(body, style.cramp());
            if let Some(index) = index {
                visit(index, MathStyle::ScriptScript);
            }
        }
        MathNode::CancelTo(value, body) => {
            visit(value, style.into_script());
            visit(body, style);
        }
        MathNode::Sum(lower, upper) | MathNode::Product(lower, upper) => {
            if let Some(lower) = lower {
                visit(lower, style.into_script());
            }
            if let Some(upper) = upper {
                visit(
                    upper,
                    if style.is_display() {
                        style.into_script()
                    } else {
                        style.into_script().cramp()
                    },
                );
            }
        }
        MathNode::Integral(_, lower, upper) => {
            if let Some(lower) = lower {
                visit(lower, style.into_script());
            }
            if let Some(upper) = upper {
                visit(upper, style.into_script().cramp());
            }
        }
        MathNode::Limit(lower) => {
            if let Some(lower) = lower {
                visit(lower, style.into_script());
            }
        }
        MathNode::OverUnder(body, upper, lower) => {
            visit(body, style);
            for node in upper.iter_mut().chain(lower) {
                visit(node, style.into_script());
            }
        }
        MathNode::Row(nodes) => {
            for node in nodes {
                visit(node, style);
            }
        }
        MathNode::Substack(nodes) => {
            for node in nodes {
                visit(node, MathStyle::Script);
            }
        }
        MathNode::Intertext(body) | MathNode::Tag { body, .. } => visit(body, MathStyle::Text),
        MathNode::Accent(body, kind) => {
            use latex_rust::AccentKind::*;
            let cramped = matches!(
                kind,
                Hat | Check
                    | Breve
                    | Acute
                    | Grave
                    | Tilde
                    | Bar
                    | Vec
                    | Dot
                    | Ddot
                    | Dddot
                    | Ddddot
                    | Ring
                    | WideHat
                    | WideTilde
                    | Overleftarrow
                    | Overrightarrow
                    | Overleftrightarrow
                    | Underleftarrow
                    | Underrightarrow
                    | Underleftrightarrow
                    | Overbrace
                    | Underbrace
            );
            visit(body, if cramped { style.cramp() } else { style });
        }
        MathNode::Delimited(_, body, _)
        | MathNode::Color(_, body)
        | MathNode::TextColor(_, body)
        | MathNode::ColorBox(_, body)
        | MathNode::FColorBox(_, _, body)
        | MathNode::Phantom(_, body) => visit(body, style),
        MathNode::Matrix(kind, _, rows) => {
            let cell_style = match kind {
                MatrixStyle::Aligned
                    if rows.iter().all(|row| matches!(row, EnvRow::Cells { .. })) =>
                {
                    MathStyle::Display
                }
                MatrixStyle::Aligned => style,
                kind if kind.is_display_env() => MathStyle::Display,
                MatrixStyle::Array | MatrixStyle::Split => style,
                _ => MathStyle::Text,
            };
            for row in rows {
                match row {
                    EnvRow::Cells { cells, number, .. } => {
                        for cell in cells {
                            visit(cell, cell_style);
                        }
                        if let EqNumber::Tag { body, .. } = number {
                            visit(body, MathStyle::Text);
                        }
                    }
                    EnvRow::Intertext(body) => visit(body, MathStyle::Text),
                    EnvRow::Hline => {}
                }
            }
        }
        _ => {}
    }
}

fn layout_source(source: &str, display: bool, size: f32) -> Result<MathBox, String> {
    validate_size(size)?;
    preflight(source)?;
    let (ast, _) =
        latex_rust::parse_with_options(source, &ParseOptions::new().with_max_depth(MAX_DEPTH))
            .map_err(|e| e.to_string())?;
    // Reject user-provided marker values and bound traversal before rewriting.
    validate_ast(&ast)?;
    let (normalized, spaces) = normalize_absolute_hspace(source, size)?;
    let mut ast = if normalized == source {
        ast
    } else {
        latex_rust::parse_with_options(&normalized, &ParseOptions::new().with_max_depth(MAX_DEPTH))
            .map_err(|e| e.to_string())?
            .0
    };
    let style = if display {
        MathStyle::Display
    } else {
        MathStyle::Text
    };
    if !spaces.is_empty() {
        let params = MathParams::from_font(font()?).map_err(|e| e.to_string())?;
        resolve_absolute_hspace(&mut ast, style, &spaces, &params);
    }
    validate_ast(&ast)?;
    // Layout's own recursion guard is 32. The AST is restricted further above.
    // 1 logical CSS pixel = 3/4 point; this matters for AMS absolute spacing.
    let em_pt = Dim::from_ieee32_bits((size * 0.75).to_bits());
    let tree = latex_rust::layout_with_em_size_pt(&ast, font()?, style, &em_pt)
        .map_err(|e| e.to_string())?;
    let mut pending = vec![(&tree, 0usize)];
    let mut count = 0;
    while let Some((node, depth)) = pending.pop() {
        count += 1;
        if count > MAX_BOXES || depth > 96 {
            return Err("Equation exceeds output complexity limit".into());
        }
        for value in [&node.width, &node.height, &node.depth, &node.shift] {
            if scalar(value)?.abs() * size > MAX_WIDTH {
                return Err("Equation exceeds dimension limit".into());
            }
        }
        match &node.content {
            BoxContent::HList(nodes) | BoxContent::VList(nodes) | BoxContent::Overlap(nodes) => {
                pending.extend(nodes.iter().map(|node| (node, depth + 1)));
            }
            BoxContent::Color(_, node)
            | BoxContent::BackColor(_, node)
            | BoxContent::Frame { inner: node, .. } => pending.push((node, depth + 1)),
            _ => {}
        }
    }
    Ok(tree)
}

fn render_svg(
    source: &str,
    display: bool,
    size: f32,
    rgba: [u8; 4],
) -> Result<VectorEquation, String> {
    let tree = layout_source(source, display, size)?;
    let advance_width = scalar(&tree.width)? * size;
    let mut ascent = scalar(&tree.height)? * size + PADDING;
    let mut depth = scalar(&tree.depth)? * size + PADDING;
    let mut width = advance_width + 2.0 * PADDING;
    let mut height = ascent + depth;
    if advance_width <= 0.0
        || ascent < PADDING
        || depth < PADDING
        || width > MAX_WIDTH
        || height > MAX_HEIGHT
        || width * height > MAX_AREA
    {
        return Err("Equation exceeds image dimension limit or has no visible size".into());
    }
    let options = SvgOptions {
        font_size_pt: Dim::from_ieee32_bits((size * 0.75).to_bits()),
        color: latex_rust::Color::rgb(rgba[0], rgba[1], rgba[2]),
        display,
    };
    let generated = latex_rust::render_svg(&tree, font()?, &options).map_err(|e| e.to_string())?;
    if generated.len() > MAX_SVG_BYTES {
        return Err("Equation exceeds SVG size limit".into());
    }
    let start = generated
        .find("<svg ")
        .and_then(|start| generated[start..].find('>').map(|end| start + end + 1))
        .ok_or_else(|| "Invalid generated equation SVG".to_string())?;
    let end = generated
        .rfind("</svg>")
        .ok_or_else(|| "Invalid generated equation SVG".to_string())?;
    // Replace the upstream pt viewport with logical px without changing its
    // point-based path coordinates. Advance bounds are not ink bounds: italic
    // bearings and negative glue can put paths outside a positive-width box.
    let wrap = |left: f32, top: f32, width: f32, height: f32, opacity: f32| {
        format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="{} {} {} {}" opacity="{opacity}">{}</svg>"#,
            (-PADDING - left) * 0.75,
            (-PADDING - top) * 0.75,
            width * 0.75,
            height * 0.75,
            &generated[start..end],
        )
    };
    // Measure only the trusted, bounded path/rule output, at full opacity so
    // transparent equations keep identical geometry. This runs on cache misses.
    let measured =
        usvg::Tree::from_str(&wrap(0., 0., width, height, 1.), &usvg::Options::default())
            .map_err(|error| format!("Invalid generated equation SVG: {error}"))?;
    let ink = measured.root().abs_stroke_bounding_box();
    let padding = |overflow: f32| {
        if overflow > 0. {
            overflow + PADDING
        } else {
            0.
        }
    };
    let left = padding(-ink.left());
    let right = padding(ink.right() - width);
    let top = padding(-ink.top());
    let bottom = padding(ink.bottom() - height);
    width += left + right;
    ascent += top;
    depth += bottom;
    height = ascent + depth;
    // Reapply allocation limits after expanding for the actual ink extent.
    if width > MAX_WIDTH || height > MAX_HEIGHT || width * height > MAX_AREA {
        return Err("Equation exceeds image dimension limit or has no visible size".into());
    }
    let svg = wrap(left, top, width, height, f32::from(rgba[3]) / 255.0);
    if svg.len() > MAX_SVG_BYTES {
        return Err("Equation exceeds SVG size limit".into());
    }
    Ok(VectorEquation {
        svg,
        width,
        height,
        ascent,
        depth,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vector(source: &str, display: bool) -> VectorEquation {
        render_svg(source, display, 20.0, [230, 220, 210, 255]).unwrap()
    }

    fn value(dim: &Dim) -> f32 {
        scalar(dim).unwrap()
    }

    #[test]
    fn equation_viewports_contain_negative_bearings_and_leading_glue() {
        for source in [
            r"\hspace{-0.25em}x",
            "y",
            r"x\hspace{-0.25em}",
            r"\hspace{-0.3em}\frac{a}{b}\hspace{-0.1em}",
            r"\boxed{y}",
        ] {
            for size in [12., 20., 40., 96.] {
                for display in [false, true] {
                    let equation = render_svg(source, display, size, [0, 0, 0, 255]).unwrap();
                    let svg =
                        usvg::Tree::from_str(&equation.svg, &usvg::Options::default()).unwrap();
                    let ink = svg.root().abs_stroke_bounding_box();
                    assert!(ink.left() >= -0.001, "{source}: {ink:?}");
                    assert!(ink.right() <= equation.width + 0.001, "{source}: {ink:?}");
                    assert!(ink.top() >= -0.001, "{source}: {ink:?}");
                    assert!(ink.bottom() <= equation.height + 0.001, "{source}: {ink:?}");
                }
            }
        }
    }

    #[test]
    fn ink_expansion_preserves_transparent_geometry_and_allocation_limits() {
        let source = r"\hspace{-0.25em}y";
        let opaque = render_svg(source, false, 96., [10, 20, 30, 255]).unwrap();
        let transparent = render_svg(source, false, 96., [10, 20, 30, 0]).unwrap();
        assert_eq!(
            (opaque.width, opaque.height, opaque.ascent, opaque.depth),
            (
                transparent.width,
                transparent.height,
                transparent.ascent,
                transparent.depth
            )
        );
        let source = r"\hspace{-40em}\frac{a}{b}\hspace{40em}";
        // Advance size alone fits; ink expansion must be checked again before
        // allocating a raster image with a large, mostly empty viewport.
        assert!(layout_source(source, false, 96.).is_ok());
        assert!(render_svg(source, false, 96., [0, 0, 0, 255]).is_err());
    }

    #[test]
    fn barless_fraction_commands_never_silently_gain_a_fraction_rule() {
        for source in [
            r"\binom{n}{k}",
            r"\dbinom{n}{k}",
            r"\tbinom{n}{k}",
            r"\genfrac{}{}{0pt}{}{n}{k}",
        ] {
            if let Ok(tree) = layout_source(source, false, 20.) {
                let mut pending = vec![&tree];
                while let Some(node) = pending.pop() {
                    match &node.content {
                        BoxContent::Rule => panic!("barless coefficient gained a rule: {source}"),
                        BoxContent::HList(nodes)
                        | BoxContent::VList(nodes)
                        | BoxContent::Overlap(nodes) => pending.extend(nodes),
                        BoxContent::Color(_, inner)
                        | BoxContent::BackColor(_, inner)
                        | BoxContent::Frame { inner, .. } => pending.push(inner),
                        _ => {}
                    }
                }
            }
        }
    }

    #[test]
    fn explicit_spacing_never_silently_removes_operator_glue() {
        for display in [false, true] {
            for operator in ["+", "=", r"\times", r"\leq"] {
                let base = layout_source(&format!("a{operator} b"), display, 20.).unwrap();
                for (spacing, delta) in [
                    ("0em", 0.),
                    ("0pt", 0.),
                    ("1pt", 4. / 3.),
                    ("-1pt", -4. / 3.),
                ] {
                    for source in [
                        format!(r"a\hspace{{{spacing}}}{operator} b"),
                        format!(r"a{operator}\hspace{{{spacing}}}b"),
                    ] {
                        if let Ok(actual) = layout_source(&source, display, 20.) {
                            assert!(
                                (20. * (value(&actual.width) - value(&base.width)) - delta).abs()
                                    < 0.01,
                                "spacing must supplement, not replace, automatic glue: {source}"
                            );
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn ordinary_letter_spacing_remains_typeset_in_styled_and_nested_rows() {
        for (base, source) in [
            ("ab", r"a\hspace{1pt}b"),
            (r"\alpha\beta", r"\alpha\hspace{1pt}\beta"),
            ("x_i y", r"x_i\hspace{1pt}y"),
            (r"\text{a}b", r"\text{a}\hspace{1pt}b"),
            (r"\color{red}{a}b", r"\color{red}{a}\hspace{1pt}b"),
            ("x^{ab}", r"x^{a\hspace{1pt}b}"),
            ("(a)b", r"(a)\hspace{1pt}b"),
            ("a(b)", r"a\hspace{1pt}(b)"),
            ("(a)", r"(\hspace{1pt}a)"),
            ("a,b", r"a\hspace{1pt},b"),
        ] {
            for display in [false, true] {
                let base = layout_source(base, display, 20.).unwrap();
                let spaced = layout_source(source, display, 20.).unwrap();
                assert!(
                    (20. * (value(&spaced.width) - value(&base.width)) - 4. / 3.).abs() < 0.01,
                    "{source}"
                );
            }
        }
    }

    #[test]
    fn explicit_fraction_style_commands_are_not_silently_ignored() {
        for (command, display) in [("dfrac", false), ("tfrac", true), ("cfrac", false)] {
            let source = format!(r"\{command}{{a}}{{b}}");
            if let Ok(actual) = layout_source(&source, display, 20.) {
                let default = layout_source(r"\frac{a}{b}", display, 20.).unwrap();
                assert_ne!(
                    actual, default,
                    "explicit fraction style was discarded: {source}"
                );
            }
        }
    }

    #[test]
    fn explicit_math_style_declarations_are_not_silently_ignored() {
        for command in [
            "displaystyle",
            "textstyle",
            "scriptstyle",
            "scriptscriptstyle",
        ] {
            for display in [false, true] {
                for body in [r"\frac{a}{b}", r"x^{y}", r"\sum_{i}^{n}"] {
                    for source in [
                        format!(r"\{command} {body}"),
                        format!(r"x+{{\{command} {body}}}"),
                    ] {
                        assert!(
                            render_svg(&source, display, 20.0, [0; 4]).is_err(),
                            "silently ignored: {source}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn explicit_large_operator_limit_modifiers_are_not_silently_ignored() {
        for display in [false, true] {
            for source in [
                r"\sum\nolimits_{i}^{n}",
                r"\prod\nolimits_{i}^{n}",
                r"\int\limits_{a}^{b}",
            ] {
                assert!(
                    render_svg(source, display, 20.0, [0; 4]).is_err(),
                    "silently ignored: {source}"
                );
            }
        }
    }

    #[test]
    fn text_control_symbol_escapes_match_literal_glyphs() {
        for (escaped, expected) in [
            (r"\text{a\&b\%c\#d\$e}", "a&b%c#d$e"),
            (r"\text{\{x\}}", "{x}"),
        ] {
            // A literal percent starts a comment, so compare against the AST's
            // expected text directly rather than reparsing it as source.
            let (ast, _) = latex_rust::parse_with_options(escaped, &ParseOptions::new()).unwrap();
            let MathNode::Text(text, _) = ast else {
                panic!("text node")
            };
            assert_eq!(text, expected);
            assert!(render_svg(escaped, false, 20.0, [0; 4]).is_ok());
        }
    }

    #[test]
    fn accents_preserve_script_binding_and_script_order() {
        for display in [false, true] {
            for base in [r"\hat{x}", r"\acute{x}", r"\bar{x}"] {
                let upper_first = vector(&format!("{base}^{{2}}_{{i}}"), display);
                let lower_first = vector(&format!("{base}_{{i}}^{{2}}"), display);
                assert_eq!(upper_first.svg, lower_first.svg);
                assert!(upper_first.ascent > vector(base, display).ascent);
            }
        }
    }

    #[test]
    fn nonpositive_advance_visible_equations_fail_instead_of_disappearing() {
        for display in [false, true] {
            // Negative glue can cancel advance while preserving visible ink.
            let tree = layout_source(r"x\hspace{-1em}", display, 20.0).unwrap();
            assert!(value(&tree.width) < 0.0);
            assert!(render_svg(r"x\hspace{-1em}", display, 20.0, [0; 4]).is_err());
            // A zero-width phantom remains useful as a strut beside real ink.
            assert!(render_svg(r"x\vphantom{\frac{a}{b}}", display, 20.0, [0; 4]).is_ok());
        }
    }

    #[test]
    fn native_abi_owns_its_paths_and_rejects_invalid_input() {
        let source = br"\frac{x_i}{\sqrt{y}}";
        let mut output = std::mem::MaybeUninit::<Output>::uninit();
        assert!(unsafe {
            harness_math_layout(
                source.as_ptr(),
                source.len(),
                false,
                20.,
                0x223344ff,
                output.as_mut_ptr(),
            )
        });
        let output = unsafe { output.assume_init() };
        let svg = unsafe { std::slice::from_raw_parts(output.svg, output.len) };
        let svg = std::str::from_utf8(svg).unwrap();
        assert!(svg.contains("<path ") && svg.contains("<rect "));
        assert!(output.ascent > 0. && output.depth > 0.);
        assert!((output.height - output.ascent - output.depth).abs() < 0.001);
        unsafe { harness_math_free(output.owner) };
        assert!(!unsafe {
            harness_math_layout(
                source.as_ptr(),
                source.len(),
                false,
                20.,
                0,
                std::ptr::null_mut(),
            )
        });
        let mut invalid = std::mem::MaybeUninit::<Output>::uninit();
        assert!(!unsafe {
            harness_math_layout([255u8].as_ptr(), 1, false, 20., 0, invalid.as_mut_ptr())
        });
        assert!(!unsafe {
            harness_math_layout(
                source.as_ptr(),
                MAX_SOURCE_BYTES + 1,
                false,
                20.,
                0,
                invalid.as_mut_ptr(),
            )
        });
        assert!(!unsafe {
            harness_math_layout(
                source.as_ptr(),
                source.len(),
                false,
                f32::NAN,
                0,
                invalid.as_mut_ptr(),
            )
        });
    }

    #[test]
    fn native_vector_cache_is_bounded_and_keeps_color_in_its_key() {
        CACHE.with(|cache| *cache.borrow_mut() = Cache::default());
        for i in 0..80 {
            cached(&format!("x_{{{i}}}"), false, 20., [1, 2, 3, 255]).unwrap();
        }
        let red = cached("x", false, 20., [255, 0, 0, 255]).unwrap();
        let blue = cached("x", false, 20., [0, 0, 255, 255]).unwrap();
        assert_ne!(red.svg, blue.svg);
        assert_eq!(red.width, blue.width);
        CACHE.with(|cache| {
            let cache = cache.borrow();
            assert_eq!(cache.entries.len(), CACHE_ENTRIES);
            assert!(cache.bytes <= CACHE_BYTES);
            assert_eq!(
                cache.bytes,
                cache
                    .entries
                    .iter()
                    .map(|(key, equation)| key.source.len() + equation.svg.len())
                    .sum::<usize>()
            );
        });
    }

    #[test]
    fn superscript_and_subscript_have_opposite_offsets_and_reduced_glyphs() {
        let tree = layout_source("x_i^n", false, 20.).unwrap();
        let BoxContent::HList(parts) = &tree.content else {
            panic!("scripts must sit beside their nucleus")
        };
        let base = &parts[0];
        let scripts = parts
            .iter()
            .find_map(|part| {
                if let BoxContent::Overlap(scripts) = &part.content {
                    Some(scripts)
                } else {
                    None
                }
            })
            .expect("positioned script slot");
        assert_eq!(scripts.len(), 2);
        let above = scripts
            .iter()
            .find(|p| value(&p.shift) > value(&base.shift))
            .expect("raised script");
        let below = scripts
            .iter()
            .find(|p| value(&p.shift) < value(&base.shift))
            .expect("lowered script");
        assert!(
            value(&above.shift) - value(&above.depth) > value(&below.shift) + value(&below.height)
        );
        let full_n = layout_source("n", false, 20.).unwrap();
        let full_i = layout_source("i", false, 20.).unwrap();
        assert!(value(&above.height) < value(&full_n.height));
        assert!(value(&below.height) < value(&full_i.height));
        assert!(value(&tree.height) > value(&base.height));
        assert!(value(&tree.depth) > value(&base.depth));
    }

    #[test]
    fn stacked_and_nested_fractions_have_separated_boxes_and_rules() {
        let tree = layout_source(r"\frac{1}{2}", true, 20.0).unwrap();
        let BoxContent::Overlap(parts) = &tree.content else {
            panic!("fraction must stack numerator, rule and denominator");
        };
        let [num, bar, den] = parts.as_slice() else {
            panic!("three fraction branches")
        };
        assert!(matches!(bar.content, BoxContent::Rule));
        assert!(value(&num.shift) - value(&num.depth) > value(&bar.shift) + value(&bar.height));
        assert!(value(&den.shift) + value(&den.height) < value(&bar.shift) - value(&bar.depth));
        let flat = vector("12", true);
        let stacked = vector(r"\frac{1}{2}", true);
        let nested = vector(r"\frac{1}{\frac{2}{3}}", true);
        assert!(stacked.height > flat.height * 1.5);
        assert!(nested.depth > stacked.depth);
        assert_eq!(stacked.svg.matches("<rect ").count(), 1);
        assert_eq!(nested.svg.matches("<rect ").count(), 2);
        assert!((nested.height - nested.ascent - nested.depth).abs() < 0.001);
    }

    #[test]
    fn display_operator_places_limits_above_and_below_the_operator() {
        let tree = layout_source(r"\sum_{i=1}^{n}", true, 20.0).unwrap();
        let BoxContent::Overlap(parts) = &tree.content else {
            panic!("display operator must stack limits");
        };
        let [base, upper, lower] = parts.as_slice() else {
            panic!("operator and two limits")
        };
        assert!(
            value(&upper.shift) - value(&upper.depth) > value(&base.shift) + value(&base.height)
        );
        assert!(
            value(&lower.shift) + value(&lower.height) < value(&base.shift) - value(&base.depth)
        );
        let display = vector(r"\sum_{i=1}^{n}", true);
        let inline = vector(r"\sum_{i=1}^{n}", false);
        assert!(display.ascent > inline.ascent);
        assert!(display.depth > inline.depth);
    }

    #[test]
    fn bracketed_matrices_and_aligned_rows_keep_two_dimensional_geometry() {
        let matrix = vector(r"\begin{bmatrix}a&b\\c&d\end{bmatrix}", true);
        let single = vector(r"\begin{bmatrix}a&b\end{bmatrix}", true);
        assert!(matrix.height > single.height * 1.3);
        assert!(matrix.depth > single.depth);
        let bare = vector(r"\begin{matrix}a&b\\c&d\end{matrix}", true);
        assert!(matrix.width > bare.width);
        let aligned = vector(r"\left[\begin{aligned}a&=b\\c&=d\end{aligned}\right]", true);
        let row = vector("a=b", true);
        assert!(aligned.height > row.height * 1.5);
        assert!(aligned.depth > row.depth);
        assert!(aligned.svg.matches("<path ").count() >= 8);
    }

    #[test]
    fn underbrace_and_annotation_extend_below_the_nucleus() {
        let base = vector("a+b", true);
        let brace = vector(r"\underbrace{a+b}", true);
        let annotated = vector(r"\underbrace{a+b}_{n}", true);
        assert!(brace.depth > base.depth + 2.0);
        assert!(annotated.depth > brace.depth);
        assert!(brace.width >= base.width);
        assert!(brace.svg.matches("<path ").count() > base.svg.matches("<path ").count());
    }

    #[test]
    fn svg_is_self_contained_and_uses_pixel_viewport_and_real_baseline() {
        let equation = vector(r"\frac{x^2}{\sqrt{y}}", false);
        let tree = usvg::Tree::from_str(&equation.svg, &usvg::Options::default()).unwrap();
        assert!((tree.size().width() - equation.width).abs() < 0.001);
        assert!((tree.size().height() - equation.height).abs() < 0.001);
        assert!(equation.ascent > 0.0 && equation.depth > 0.0);
        assert!(!equation.svg.contains("<text"));
        assert!(!equation.svg.contains("href="));
        assert!(!equation.svg.contains("<image"));
        let larger = render_svg(r"\frac{x^2}{\sqrt{y}}", false, 40.0, [0, 0, 0, 128]).unwrap();
        assert!((larger.width - 2.0 * (equation.width - 2.0) - 2.0).abs() < 0.01);
        assert!(larger.svg.contains("opacity=\"0.5019608\""));
    }

    #[test]
    fn unsupported_malformed_and_excessive_equations_return_errors() {
        for source in [
            "",
            r"\frac{1}",
            r"\left(x",
            r"\unknown{x}",
            r"\includegraphics{file}",
            r"\rule{2em}{1em}",
            r"\hspace{999999999999em}x",
            "9999999999999",
        ] {
            assert!(render_svg(source, false, 20.0, [0; 4]).is_err(), "{source}");
        }
        let deep = "{".repeat(40) + "x" + &"}".repeat(40);
        let radicals = r"\sqrt{".repeat(24) + "x" + &"}".repeat(24);
        let wide = "x".repeat(MAX_TOKENS + 1);
        let script_chain = "x".to_string() + &"'".repeat(80);
        let huge = "x".repeat(MAX_SOURCE_BYTES + 1);
        let grid = format!(r"\begin{{matrix}}{}\end{{matrix}}", vec!["x"; 17].join("&"));
        for source in [&deep, &radicals, &wide, &script_chain, &huge, &grid] {
            assert!(render_svg(source, false, 20.0, [0; 4]).is_err());
        }
        for size in [f32::NAN, f32::INFINITY, 0.0, -1.0, 1000.0] {
            assert!(render_svg("x", false, size, [0; 4]).is_err());
        }
        assert!(render_svg(&"W".repeat(200), true, 96.0, [0; 4]).is_err());
    }

    #[test]
    fn generated_malformed_and_deep_inputs_are_bounded() {
        for depth in [1, 2, 8, MAX_DEPTH, MAX_DEPTH + 1, 40] {
            for opening in ["{", r"\sqrt{", r"\frac{1}{"] {
                let source = opening.repeat(depth) + "x" + &"}".repeat(depth);
                let result = render_svg(&source, false, 20.0, [0; 4]);
                if depth > MAX_DEPTH {
                    assert!(result.is_err(), "accepted depth {depth}: {opening}");
                }
                let unclosed = opening.repeat(depth) + "x";
                assert!(
                    render_svg(&unclosed, false, 20.0, [0; 4]).is_err(),
                    "accepted unclosed input: {unclosed}"
                );
            }
        }
        for source in [
            "}",
            "x}",
            "{x}}",
            r"\frac",
            r"\sqrt",
            r"x^",
            r"x_",
            r"\begin{matrix}x",
            r"\begin{matrix}x\end{aligned}",
        ] {
            assert!(render_svg(source, true, 20.0, [0; 4]).is_err(), "{source}");
        }
    }

    #[test]
    fn numeric_and_spacing_boundaries_preserve_geometry() {
        for digits in [1, 6, 12, 13, 32] {
            let source = "9".repeat(digits);
            assert_eq!(preflight(&source).is_ok(), digits <= 12, "{source}");
        }
        let base = vector("xx", false);
        for (dimension, pixels) in [
            ("1em", 20.0),
            ("18mu", 20.0),
            ("0em", 0.0),
            ("-0.25em", -5.0),
        ] {
            let source = format!(r"x\hspace{{{dimension}}}x");
            let spaced = vector(&source, false);
            assert!(
                (spaced.width - base.width - pixels).abs() < 0.01,
                "{source}: {} vs {}",
                spaced.width,
                base.width
            );
        }
        for dimension in [
            "65em",
            "-65em",
            "999999999999em",
            "0.0000000000001em",
            "NaNem",
            "infem",
            "1e100em",
        ] {
            let source = format!(r"x\hspace{{{dimension}}}x");
            assert!(
                render_svg(&source, false, 20.0, [0; 4]).is_err(),
                "{source}"
            );
        }
    }

    #[test]
    fn absolute_hspace_geometry_is_independent_of_font_size() {
        // Upstream treats pt and bp alike; preserve that convention, but not
        // its fixed 10pt em conversion. One point is 4/3 logical CSS pixels.
        for size in [20.0, 40.0] {
            let base = render_svg("xx", false, size, [0; 4]).unwrap();
            for (spec, pixels) in [
                ("1pt", 4.0 / 3.0),
                ("1bp", 4.0 / 3.0),
                ("-3bp", -4.0),
                ("0pt", 0.0),
            ] {
                let source = format!(r"x\hspace{{{spec}}}x");
                let spaced = render_svg(&source, false, size, [0; 4]).unwrap();
                assert!(
                    (spaced.width - base.width - pixels).abs() < 0.01,
                    "{source} at {size}"
                );
            }
        }
    }

    #[test]
    fn absolute_hspace_keeps_its_width_inside_scripts() {
        for size in [20.0, 40.0] {
            for (base, source) in [
                ("x^{ab}", r"x^{a\hspace{1pt}b}"),
                ("x_{ab}", r"x_{a\hspace{1pt}b}"),
                ("x^{a^{bc}}", r"x^{a^{b\hspace{1pt}c}}"),
            ] {
                let baseline = render_svg(base, false, size, [0; 4]).unwrap();
                let spaced = render_svg(source, false, size, [0; 4]).unwrap();
                assert!(
                    (spaced.width - baseline.width - 4.0 / 3.0).abs() < 0.01,
                    "{source} at {size}: delta={}",
                    spaced.width - baseline.width
                );
            }
        }
    }

    #[test]
    fn absolute_hspace_tracks_fraction_radical_limit_and_environment_styles() {
        // Compare to explicitly compensated relative lengths, independently of
        // the normalizer. Include style resets inside already nested scripts.
        for display in [false, true] {
            for size in [20.0, 40.0] {
                for (template, scale) in [
                    (r"\frac{a\hspace{ABS}b}{x}", if display { 1.0 } else { 0.7 }),
                    (r"\frac{x}{a\hspace{ABS}b}", if display { 1.0 } else { 0.7 }),
                    (r"x^{\frac{a\hspace{ABS}b}{x}}", 0.55),
                    (r"\sqrt[a\hspace{ABS}b]{x}", 0.55),
                    (r"x^{\sqrt{a\hspace{ABS}b}}", 0.7),
                    (r"\sum_{a\hspace{ABS}b}^{x}", 0.7),
                    (r"\int_{x}^{a\hspace{ABS}b}", 0.7),
                    (r"\overset{a\hspace{ABS}b}{x}", 0.7),
                    (r"x^{y^{\substack{a\hspace{ABS}b}}}", 0.7),
                    (r"x^{\begin{matrix}a\hspace{ABS}b\end{matrix}}", 1.0),
                    (r"x^{\begin{array}{c}a\hspace{ABS}b\end{array}}", 0.7),
                    (r"x^{\begin{aligned}a\hspace{ABS}b\end{aligned}}", 1.0),
                    (r"a\hspace{ABS}b\hspace{ABS}c", 1.0),
                ] {
                    for points in [1.0, -1.0, 0.0] {
                        let source = template.replace("ABS", &format!("{points}pt"));
                        let reference = template
                            .replace("ABS", &format!("{:.9}em", points / (size * 0.75 * scale)));
                        let actual = render_svg(&source, display, size, [0; 4]).unwrap();
                        let expected = render_svg(&reference, display, size, [0; 4]).unwrap();
                        assert!(
                            (actual.width - expected.width).abs() < 0.001,
                            "{source}, display={display}, size={size}: {} vs {}",
                            actual.width,
                            expected.width
                        );
                    }
                }
            }
        }
        for display in [false, true] {
            let source = r"x^{a\hspace{1pt}b\hspace{-2bp}c\hspace{3pt}d}";
            let baseline = r"x^{abcd}";
            let actual = render_svg(source, display, 20.0, [0; 4]).unwrap();
            let base = render_svg(baseline, display, 20.0, [0; 4]).unwrap();
            assert!((actual.width - base.width - 8.0 / 3.0).abs() < 0.001);
        }
        // A user cannot inject or collide with internal marker dimensions.
        for source in [
            r"x\hspace{65em}x",
            r"x^{\hspace{66em}}",
            r"x\hspace{1pt}\hspace{65em}",
        ] {
            assert!(layout_source(source, false, 20.0).is_err(), "{source}");
        }
    }

    #[test]
    fn absolute_hspace_normalization_preserves_literals_comments_and_escapes() {
        for source in [
            r"\text{x\hspace{1pt}y}",
            r"\mbox{x\hspace{1bp}y}",
            r"\operatorname{x\hspace{1pt}y}",
            r"\text{nested {x\hspace{1pt}} y}",
            r"\\hspace{1pt}",
            r"\hspaceother{1pt}",
            "x% \\hspace{1pt}\ny",
        ] {
            assert_eq!(normalize_absolute_hspace(source, 20.0).unwrap().0, source);
        }
        let source = "x\\hspace % comment\n {1% inner\n pt}x";
        let base = vector("xx", false);
        let spaced = vector(source, false);
        assert!((spaced.width - base.width - 4.0 / 3.0).abs() < 0.01);
        let source = r"\text{\hspace{1pt}}x\hspace{1bp}x";
        let (normalized, _) = normalize_absolute_hspace(source, 20.0).unwrap();
        assert!(normalized.starts_with(r"\text{\hspace{1pt}}x"));
        assert!(normalized.ends_with("em}x"));
        for source in [
            r"x\hspace{1pt",
            r"x\hspace{{1pt}}x",
            r"x\hspace{1..2pt}x",
            r"x\hspace{NaNpt}x",
            r"x\hspace{-999999pt}x",
        ] {
            assert!(render_svg(source, false, 20.0, [0; 4]).is_err(), "{source}");
        }
    }

    #[test]
    fn generated_scripts_limits_and_grids_stay_finite() {
        for display in [false, true] {
            for source in [
                r"x_i^2",
                r"x^2_i",
                r"\sum_{i=0}^{n}",
                r"\prod_{k=1}^{n}",
                r"\int_0^1 x",
                r"\lim_{x\to0}x",
                r"\overbrace{x+y}^{n}",
            ] {
                let equation = vector(source, display);
                assert!(
                    equation.width.is_finite() && equation.height.is_finite(),
                    "{source}"
                );
                assert!((equation.height - equation.ascent - equation.depth).abs() < 0.001);
            }
        }
        for count in [1, 2, 8, 16, 17] {
            for separator in ["&", r"\\"] {
                let source = format!(
                    r"\begin{{matrix}}{}\end{{matrix}}",
                    vec!["x"; count].join(separator)
                );
                assert_eq!(
                    render_svg(&source, true, 20.0, [0; 4]).is_ok(),
                    count <= 16,
                    "{source}"
                );
            }
        }
        for source in [
            r"\begin{notanenvironment}x\end{notanenvironment}",
            r"\htmlClass{evil}{x}",
            r"\unsupported{x}",
        ] {
            assert!(render_svg(source, false, 20.0, [0; 4]).is_err(), "{source}");
        }
    }

    #[test]
    fn malicious_markup_and_resources_never_reach_generated_svg() {
        for source in [
            r"\includegraphics{https://invalid.example/image.svg}",
            r"\href{javascript:alert(1)}{x}",
            r"\url{https://invalid.example}",
            r"\htmlStyle{background:url(https://invalid.example)}{x}",
            r"\text{<script>alert(1)</script>}",
            r#"\text{<image href="file:///synthetic.svg"/>}"#,
            r"\text{<!DOCTYPE svg SYSTEM 'https://invalid.example'>}",
            r"\text{<foreignObject>test</foreignObject>}",
        ] {
            if let Ok(equation) = render_svg(source, false, 20.0, [0; 4]) {
                for forbidden in [
                    "<script",
                    "<image",
                    "<foreignObject",
                    "<!DOCTYPE",
                    "href=",
                    "https://",
                    "file://",
                    "javascript:",
                    "<text",
                ] {
                    assert!(!equation.svg.contains(forbidden), "{source}: {forbidden}");
                }
                usvg::Tree::from_str(&equation.svg, &usvg::Options::default()).unwrap();
            }
        }
    }
}
