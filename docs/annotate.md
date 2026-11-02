# Image annotation

Point at parts of an image before sending it to the agent: draw boxes, number them, add a note to each, and drop free text.

## Flow

1. Click an image in the chat or a staged thumbnail in the composer. The preview opens with an **Annotate** pill in the bottom-right corner.
2. Annotate shows the toolbar at the bottom center: Text, Rectangle (the default), four colors (red, the default, then blue, green, yellow), Undo, then Cancel and Done.
3. Drag on the image to draw a box. It gets a numbered pin, and an **Add a note…** popover opens under it (above it near the bottom edge). Enter commits the note. The x deletes the box.
4. With the Text tool, click to place text and type it. Enter commits; an empty text mark is dropped.
5. Click a box or its pin to select it. Backspace or Delete removes the selection, ⌘Z (Ctrl+Z) undoes, Esc commits an open note or leaves annotate mode.
6. Done flattens the marks into a new PNG named `NAME-annotated.png`. From the composer it replaces the original attachment; from the chat it is staged in the active composer. Cancel discards everything.

The thumbnail of an annotated attachment carries a small pen badge. On send, the notes go with the prompt:

```
Annotations on billing-annotated.png (boxes are x,y,w,h in image pixels):
1. [box 968,204,176,60] Make this the primary button
2. [box 304,280,408,60] Show the percentage next to the bar
Text on the image:
- [text 440,410] "Add a download link here"
```

## Code

- `crates/ui/src/annotate.rs`: the model (`Annotations`: add, select, recolor, remove, undo, pin numbers), the prompt text, and flattening. Flattening renders an SVG overlay with resvg (bundled Geist for text) and composites it onto the decoded image. Marks are drawn at screen size and the overlay is scaled by image pixels per screen pixel, so the file looks like what was on screen.
- `crates/ui/src/annotate/editor.rs`: the editor view inside the lightbox.
- `crates/ui/src/attachments.rs`: `PreviewImage::annotatable` and the Annotate pill.
- `crates/ui/src/composer.rs`, `transcript.rs`, `shell.rs`: wiring for staged and chat images.
- `apps/parity/vectors/annotations.json`: the prompt format, for a future phone port.

## Tests and screenshots

- `cargo test -p harness-ui --lib annotate`: the model, the prompt format and parity vectors, flattening (size, strokes, pins, scaling, text chips, transparency, SVG sources), and a headless end-to-end run through the lightbox.
- `cargo run -p harness-ui --example annotate-fixture --features appshots-fixture -- IMAGE OUT_DIR` with `HARNESS_FIXTURE_APPEARANCE=light|dark` captures every step.

## Limits

- Flattening runs on Done on the UI thread. It is not timed or moved off the thread yet, so very large images may pause the UI (decode is capped at 8192 px a side).
- Marks cannot be moved or resized after drawing; delete and redraw.
- Phones (iOS SwiftUI, Android) do not annotate yet. The prompt format is in the parity vectors so a port can match it.
