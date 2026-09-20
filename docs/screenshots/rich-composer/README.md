# Rich composer screenshots

Captured on 20 September 2026 from the native `composer-polish-fixture`, using production code at `f6eaec50e873ec5fcb50e9b73503f36fb29772dd` plus the fixture-only `/review` example included with these images.

- `composer-dark-840.png` and `composer-light-840.png` show Markdown and file, command, and skill chips in both appearances.
- `unicode-wrap-selection-light-440.png` shows selection across wrapped text and chips in a narrow composer.

The fixture uses synthetic content, a fresh temporary settings directory, and no engine or network connection. Its disconnected model control is expected. The filenames describe requested logical window widths; the operating system may constrain the final window size.

Build command:

```sh
CARGO_INCREMENTAL=0 cargo build --locked -p zeron-ui \
  --example composer-polish-fixture --features appshots-fixture
```

The build and capture run completed successfully. The published frames were visually inspected for chip spacing, icon alignment, light/dark contrast, wrapping, selection geometry, and containment. These static, offline captures do not verify animation performance or live agent delivery.

Captured executable SHA-256: `4455ff422acf753205a9650434e0c0886bd8f7c9424509cb69dc4f228d6e4ce8`.
