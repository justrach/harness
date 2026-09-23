use gpui::{Context, Pixels, Size, Task, Window, px, size};
use instant::Duration;

static INTERVAL: Duration = Duration::from_millis(500);
static PAUSE_DELAY: Duration = Duration::from_millis(300);

// On Windows, Linux, we should use integer to avoid blurry cursor.
#[cfg(not(target_os = "macos"))]
pub(super) const CURSOR_WIDTH: Pixels = px(2.);
#[cfg(target_os = "macos")]
pub(super) const CURSOR_WIDTH: Pixels = px(1.5);

const CURSOR_HEIGHT_RATIO: f32 = 0.85;

/// Returns caret dimensions whose physical extents are integral device pixels.
pub(super) fn cursor_size(window: &Window, line_height: Pixels) -> Size<Pixels> {
    cursor_size_with_snap(CURSOR_WIDTH, line_height, |dimension| {
        window.pixel_snap(dimension)
    })
}

pub(super) fn clamp_cursor_x_to_right_edge(
    cursor_x: Pixels,
    right_edge: Pixels,
    cursor_width: Pixels,
) -> Pixels {
    cursor_x.min(right_edge - cursor_width)
}

fn cursor_size_with_snap(
    width: Pixels,
    line_height: Pixels,
    mut pixel_snap: impl FnMut(Pixels) -> Pixels,
) -> Size<Pixels> {
    size(
        pixel_snap(width),
        pixel_snap(CURSOR_HEIGHT_RATIO * line_height),
    )
}

/// To manage the Input cursor blinking.
///
/// It will start blinking with a interval of 500ms.
/// Every loop will notify the view to update the `visible`, and Input will observe this update to touch repaint.
///
/// The input painter will check if this in visible state, then it will draw the cursor.
pub(crate) struct BlinkCursor {
    visible: bool,
    paused: bool,
    epoch: usize,

    _task: Task<()>,
}

impl BlinkCursor {
    pub(crate) fn new() -> Self {
        Self {
            visible: false,
            paused: false,
            epoch: 0,
            _task: Task::ready(()),
        }
    }

    /// Start the blinking
    pub(crate) fn start(&mut self, cx: &mut Context<Self>) {
        self.blink(self.epoch, cx);
    }

    pub(crate) fn stop(&mut self, cx: &mut Context<Self>) {
        self.epoch = 0;
        cx.notify();
    }

    fn next_epoch(&mut self) -> usize {
        self.epoch += 1;
        self.epoch
    }

    fn blink(&mut self, epoch: usize, cx: &mut Context<Self>) {
        if self.paused || epoch != self.epoch {
            self.visible = true;
            return;
        }

        self.visible = !self.visible;
        cx.notify();

        // Schedule the next blink
        let epoch = self.next_epoch();
        self._task = cx.spawn(async move |this, cx| {
            cx.background_executor().timer(INTERVAL).await;
            if let Some(this) = this.upgrade() {
                this.update(cx, |this, cx| this.blink(epoch, cx));
            }
        });
    }

    pub(crate) fn visible(&self) -> bool {
        // Keep showing the cursor if paused
        self.paused || self.visible
    }

    /// Pause the blinking, and delay 500ms to resume the blinking.
    pub(crate) fn pause(&mut self, cx: &mut Context<Self>) {
        self.paused = true;
        self.visible = true;
        cx.notify();

        // delay 500ms to start the blinking
        let epoch = self.next_epoch();
        self._task = cx.spawn(async move |this, cx| {
            cx.background_executor().timer(PAUSE_DELAY).await;

            if let Some(this) = this.upgrade() {
                this.update(cx, |this, cx| {
                    this.paused = false;
                    this.blink(epoch, cx);
                });
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_half_toward_zero(value: f32) -> f32 {
        (value.abs() - 0.5).ceil().copysign(value)
    }

    fn snap_at_scale(value: Pixels, scale_factor: f32) -> Pixels {
        px(round_half_toward_zero(value.as_f32() * scale_factor) / scale_factor)
    }

    fn physical_edge(value: Pixels, scale_factor: f32) -> i32 {
        round_half_toward_zero(value.as_f32() * scale_factor) as i32
    }

    #[test]
    fn caret_dimensions_have_stable_physical_extents_at_supported_scales() {
        let positions = [0., 0.1, 0.25, 0.49, 0.5, 0.75, 1.1, 5.33];

        for (scale_factor, expected_width) in [(1., 1), (1.5, 2), (2., 3)] {
            let cursor_size = cursor_size_with_snap(px(1.5), px(17.25), |dimension| {
                snap_at_scale(dimension, scale_factor)
            });

            assert!(cursor_size.width > px(0.));
            assert!(cursor_size.height > px(0.));
            assert_eq!(
                physical_edge(cursor_size.width, scale_factor),
                expected_width
            );

            let right_edge = px(100.);
            let clamped_x = clamp_cursor_x_to_right_edge(px(100.25), right_edge, cursor_size.width);
            assert!(clamped_x < right_edge);
            assert!(clamped_x + cursor_size.width <= right_edge);
            assert_eq!(
                physical_edge(clamped_x + cursor_size.width, scale_factor),
                physical_edge(right_edge, scale_factor)
            );

            for position in positions {
                let x = px(position);
                let y = px(position * 1.37);
                assert_eq!(
                    physical_edge(x + cursor_size.width, scale_factor)
                        - physical_edge(x, scale_factor),
                    expected_width,
                    "caret width changed at x={position}, scale={scale_factor}"
                );

                let physical_height = physical_edge(cursor_size.height, scale_factor);
                assert_eq!(
                    physical_edge(y + cursor_size.height, scale_factor)
                        - physical_edge(y, scale_factor),
                    physical_height,
                    "caret height changed at y={y:?}, scale={scale_factor}"
                );
            }
        }
    }
}
