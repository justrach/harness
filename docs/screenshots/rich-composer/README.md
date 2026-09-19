# Rich composer evidence

These native GPUI captures come from the isolated `composer-polish-fixture` at source commit `6cd315d6b1c608177b3c53bf6310d97673843431` on `codex/rich-composer`. The fixture used synthetic content, a fresh temporary settings directory, and no network or engine connection.

- `composer-dark-840.png` shows Markdown editing with canonical file and skill chips at the wide dark appearance.
- `unicode-wrap-selection-light-440.png` shows narrow Unicode wrapping and a selection spanning rich content in the light appearance.

The fixture was built with:

```sh
CARGO_INCREMENTAL=0 cargo build --locked -p zeron-ui \
  --example composer-polish-fixture --features appshots-fixture
```

It generated 42 dark/light frames at 840 and 440 logical pixels. These two representative frames were visually inspected for chip alignment, Markdown layout, Unicode wrapping, selection geometry, and containment. The fixture exited successfully. Static captures do not establish animation performance.
