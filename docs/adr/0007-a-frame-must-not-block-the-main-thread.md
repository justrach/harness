# ADR 0007: A frame must not block the main thread

- Status: Accepted
- Date: 2026-11-08

## Context

Nano's window is one thread. AppKit delivers the key, the wheel, and the display link to that thread, and the frame is built, laid out, and painted before the next event is taken. A stall there is the rainbow spinner. There is no second thread to keep the caret moving.

On 2026-11-08 a key in a chat that contained a screenshot sat in `CGImageSourceCreateThumbnailAtIndex` for several seconds. The sample (`~/.harness/logs/harness-nano-stall-*.txt`) was `view_transcript.user` → `Images.info` → ImageIO, on the main thread, and it ran again on the next key because the decoded tile was not the thing being reused. The same window's scroll, which had been on the display's own pace (above 120 Hz on ProMotion), felt stuck because each scroll frame waited on that decode.

A second foot-gun showed up beside it. The display link uses the soonest `frameIn`. A working clock that asks for a frame in one second, or a loader that asks for one in 1/15 s, becomes the link's rate the moment a scroll's short linger ends. The gesture then steps at that rate instead of the screen's.

## Decision

A frame may schedule work. It may not wait for it.

- Do not decode, thumbnail, or read an image on the main thread during a frame. A tile that is not already a small preview is a glyph. The preview is produced off the frame, once, and then drawn from the cache. A 56-point attachment tile does not justify decoding a multi-megabyte screenshot inline.
- Do not call `frameIn` in a loop to "correct" layout. One correction, then stop. A correction that sets `changed` every frame is a beachball with no ImageIO in the sample.
- A scroll that just moved asks for the next frame within 1/120 s, so a loader or a clock cannot become the display-link rate for that gesture. When the scroll stops, the loader's own rate applies again.
- A new main-thread stall is a bug even if the frame eventually finishes. `harness-nano.log` already records "main thread hasn't answered". That line is the regression, not a warning to ignore.
- Scroll, typing, and Cmd+B stay on the display's pace. A loader's `frame_in` does not disable a scroll-only scene shift. The caret is a hairline (1.5 points), the same weight as GPUI's insertion cursor, so a key does not paint a block. Cmd+B eases the seam over 200 ms; the sidebar content is clipped, not reflowed, and the animation requests a frame rather than waiting on a slow clock.


## Consequences

- Attachment previews can be missing for a frame. That is better than a spinner.
- Scroll stays on the display's pace while the wheel is moving, including while a session is working.
- Code that wants a large decode has to put it on a background queue and redraw when the bytes are ready. Doing it inside `view` is the bug this ADR exists to refuse.
