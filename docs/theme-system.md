# Theme system

Zeron themes are complete, source-neutral `ThemeVariant` values owned by the
`zeron-theme` crate. Runtime components consume only Zeron semantic roles. VS
Code workbench ids and TextMate selectors stop at the source compiler.

## Runtime model

- `ThemeFamily` groups related variants.
- `ThemeVariant` is one completely resolved light or dark palette.
- `ThemeSelection` stores independent light and dark variant ids.
- `AccentSelection::ThemeDefault` preserves the variant's authored accent.
- `AccentSelection::Preset` derives a contrast-checked interaction overlay.
- Every variant records a recommended `SurfaceTreatment`: Zeron recommends
  frost, while VS Code-derived themes recommend opaque surfaces because that is
  what their authors targeted.
- `SurfacePreference` is a separate device-local choice: `Theme default`,
  `Frosted`, or `Opaque`. It does not change appearance, theme, or accent
  selection.
- Terminal background, foreground, selection and ANSI16 colors belong to the
  variant instead of the terminal renderer.

Accent overlays affect controls, focus, selections, caret, activity and the
three-tone glyph. They do not recolor syntax, terminal ANSI, status, or diff
semantics.

Surface preference affects only surface composition. Theme default preserves
the variant's recommendation; either override remains active while users move
between built-in, imported, and linked themes. Forced frost derives window,
floating, input, card, and hover tints from the variant's mapped shell roles
instead of fixed Zeron greys. Its window tint becomes denser when necessary to
keep primary text at 4.5:1 and muted text at 3:1 against the adverse desktop
luminance.

macOS can frost the main window. Linux and Windows keep the main window opaque
because compositor blur is not guaranteed; supported floating surfaces can
still frost on macOS and Linux. The preference remains portable even where a
particular surface cannot honor blur.

The built-in registry contains 30 variants across 19 families:

- Zeron Light and Dark
- VS Code Light+ and Dark+
- Catppuccin Latte and Mocha
- Tokyo Night Light and Tokyo Night
- Dracula
- GitHub Light and Dark
- Ayu Light, Dark, and Mirage
- Gruvbox Light and Dark
- Rosé Pine Dawn and Moon
- Nord
- One Dark Pro
- Atom One Dark
- Night Owl and Night Owl Light
- Winter is Coming Dark Blue and Light
- Palenight
- SynthWave '84
- Shades of Purple
- Cobalt2
- Andromeda

Every bundled variant records source URL, exact upstream revision, license, and
a SHA-256 hash of the resolved curated definition.

Appearance settings keep light and dark choices in ordinary settings rows.
Each row opens a palette-preview menu, which allows the catalog to grow without
turning the page into a grid of bespoke buttons. Accent remains a compact
right-aligned swatch control; its three-tone first swatch means “Theme default.”
Glass is an adjacent conventional settings row with a compact
`Theme default` / `Frosted` / `Opaque` selector.

## VS Code import

The importer supports JSONC, trailing commas,
`include` inheritance, inline or external token rules, TextMate plist files,
workbench colors, semantic token colors, and terminal ANSI colors.

Appearance settings accept a single theme file, an extension `package.json`, or
an extension folder. Packages are detected from `contributes.themes`; variants
are classified by `uiTheme`, an explicit theme `type`, or the resolved editor
background. Each package variant compiles independently so a broken variant is
reported without hiding valid siblings. Users can select all or individual
variants, preview representative workbench/code/terminal/diff roles, and open
the optional mapping review.

The importer records `Opaque` as the variant's recommended surface treatment
and reports that inference. This preserves the source palette by default while
still allowing the independent Zeron surface preference to force frost.

The custom library has three source forms:

- `ImportedSnapshot` persists a self-contained compiled copy.
- `LinkedFile` follows one source theme file.
- `LinkedPackage` follows a VS Code extension package.

Linked sources reload explicitly. A failed reload stores a quiet warning and
continues using the last successfully compiled family. All three forms compile
to the same `ThemeFamily` model as built-ins, so runtime components remain
unaware of VS Code tokens. The library is stored in
`{data_dir}/theme-library.json` and is loaded before the first palette is
installed.

The `zeron-theme-import` development tool exposes the same single-file adapter
for built-in curation:

Example:

```bash
cargo run -p zeron-theme --bin zeron-theme-import -- \
  --input /path/to/theme.json \
  --output /tmp/theme.zeron.json \
  --report /tmp/theme.report.json \
  --id example-dark \
  --family-id example \
  --name "Example Dark" \
  --appearance dark \
  --source-url https://github.com/example/theme \
  --revision 0123456789abcdef \
  --license MIT
```

The report records every source mapping, fallback, unsupported font style,
invalid color, and accent candidate. Zeron does not fetch or execute VSIX
packages at runtime; custom sources are local files and folders compiled into
resolved data.

## Acceptance and visual QA

`ThemeRegistry::validate` checks unique ids, provenance, text contrast,
interaction contrast, on-accent contrast, and terminal foreground contrast.
Tests also exercise every preset against both appearances.

Before adding or updating a bundled variant, review both appearances where
available across every `VisualFixture` scene:

1. Sidebar
2. Transcript Markdown
3. Transcript code
4. Composer
5. Picker/popover
6. Appearance settings
7. Diff
8. Terminal
9. Empty state
10. Dialog

Review normal, hover, active, focused, selected, disabled, working, warning,
error, and success states. Importer reports and automated contrast checks are
gates, not substitutes for this visual pass.
