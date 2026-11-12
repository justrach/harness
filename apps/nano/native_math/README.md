# Native equation engine

Nano retains the original desktop equation implementation (`math_layout.rs`
before the native-UI migration), including its geometry corrections and safety
checks. The pinned `latex-rust = 2.1.1` dependency supplies the real TeX AST,
exact-rational box layout, and embedded STIX Two Math font. `usvg` measures
trusted generated glyph outlines to keep italic bearings and negative spacing
inside the viewport. No system math-font installation or network access is
needed at runtime.

`build.zig` builds this static library with Cargo and links it directly into
nano. `src/native_math.zig` copies a caller-owned equation result into the
frame arena and frees the native allocation. Generated SVG contains font
outlines/rules only; nanoui's native SVG primitive paints it. User LaTeX is
never interpolated into SVG/HTML, evaluated, or sent to a browser/service.

Supported original syntax includes nested fractions, superscripts/subscripts,
indexed radicals, Greek/Unicode symbols, stretchy delimiters, matrices and
aligned environments, accents, underbraces and their annotations, display
operator limits, text/font commands, colors, and supported absolute spacing.
Inline equations share a baseline with surrounding styled prose and links.
Selection copies the original delimited equation source, not flattened math.

The original intentional literal fallbacks remain: unknown/malformed input,
explicit style declarations, explicit `limits`/`nolimits` overrides,
barless/style-specific fraction commands, `rule`, and explicit spacing whose
semantics the upstream AST loses. Source/token/depth/AST/grid/box/output/area
limits and the 32-entry/2-MiB vector cache are retained. FFI panics are caught;
failed layouts return literal source rather than a changed equation.

Verification (from the repository root):

```sh
scripts/heavy-build.sh cargo test --locked --manifest-path apps/nano/native_math/Cargo.toml -j2
# The regular `zig build test -j2` also runs the Rust engine tests.
```

The first build requires Cargo and its pinned dependency sources; release
binaries contain the math engine and font and require neither Cargo nor a
runtime download.
