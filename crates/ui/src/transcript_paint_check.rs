//! Frame checks for the transcript's virtual list (#23: chat text and icons
//! intermittently read doubled and blurred after scrolling to the bottom).
//!
//! Two failures look like that on screen, and these checks catch both:
//!
//! - one frame paints a row twice, or paints rows that don't sit back to back
//!   (one scroll position can't produce either), see [`painted_rows_anomaly`];
//! - the viewport alternates between two positions on consecutive frames
//!   while nothing else changes, which the eye merges into a blurred double
//!   image, see [`ViewportFlicker`].
//!
//! Glyphs and icons are snapped to device pixels when painted, so a
//! fractional scroll offset alone cannot blur them.
//!
//! The transcript runs both checks after every layout and logs a warning,
//! at most every few seconds, when either fires.

use std::collections::{HashSet, VecDeque};
use std::time::{Duration, Instant};

use gpui::{Bounds, Pixels};

/// Gaps or overlaps up to this size are float noise, not a layout fault.
const SEAM_TOLERANCE_PX: f32 = 0.01;

/// What makes the rows one frame painted inconsistent with a single scroll
/// position: a row painted twice, rows out of order, or a gap or overlap
/// between neighbours. `None` when they sit back to back, in order, once each.
/// `painted` is the list's paint order (`ListState::painted_items`).
pub fn painted_rows_anomaly(painted: &[(usize, Bounds<Pixels>)]) -> Option<String> {
    let mut seen = HashSet::with_capacity(painted.len());
    for (ix, _) in painted {
        if !seen.insert(*ix) {
            return Some(format!("row {ix} painted twice in one frame"));
        }
    }
    for pair in painted.windows(2) {
        let ((above_ix, above), (below_ix, below)) = (pair[0], pair[1]);
        if below_ix != above_ix + 1 {
            return Some(format!("row {below_ix} painted right after row {above_ix}"));
        }
        let seam = f32::from(below.top() - above.bottom());
        if seam.abs() > SEAM_TOLERANCE_PX {
            return Some(format!(
                "{seam:+.2}px between rows {above_ix} and {below_ix} (top {:.2})",
                f32::from(above.top())
            ));
        }
    }
    None
}

/// One frame's viewport: the row count and where the first painted row sat.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ViewportSample {
    pub rows: usize,
    pub first_row: usize,
    /// The first painted row's top, in hundredths of a pixel.
    pub first_top: i64,
}

impl ViewportSample {
    pub fn new(rows: usize, painted: &[(usize, Bounds<Pixels>)]) -> Option<Self> {
        let (first_row, bounds) = painted.first()?;
        Some(Self {
            rows,
            first_row: *first_row,
            first_top: (f32::from(bounds.top()) * 100.0).round() as i64,
        })
    }
}

/// Spots a viewport that flips between two positions frame after frame with
/// the same rows: A, B, A, B, … for [`ViewportFlicker::FRAMES`] frames.
/// Scrolling and following move one way, so they never match.
#[derive(Debug, Default)]
pub struct ViewportFlicker {
    samples: VecDeque<ViewportSample>,
    last_report: Option<Instant>,
}

impl ViewportFlicker {
    pub const FRAMES: usize = 6;
    const REPORT_EVERY: Duration = Duration::from_secs(5);

    /// Record a frame. True when the last [`Self::FRAMES`] frames alternate.
    pub fn record(&mut self, sample: ViewportSample) -> bool {
        if self.samples.len() == Self::FRAMES {
            self.samples.pop_front();
        }
        self.samples.push_back(sample);
        self.samples.len() == Self::FRAMES
            && self.samples[0] != self.samples[1]
            && self
                .samples
                .iter()
                .enumerate()
                .all(|(ix, s)| *s == self.samples[ix % 2])
    }

    /// Whether a warning may be logged now (rate limit, one per transcript).
    pub fn should_report(&mut self, now: Instant) -> bool {
        if self
            .last_report
            .is_some_and(|last| now.duration_since(last) < Self::REPORT_EVERY)
        {
            return false;
        }
        self.last_report = Some(now);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{point, px, size};

    fn row(ix: usize, top: f32, height: f32) -> (usize, Bounds<Pixels>) {
        (
            ix,
            Bounds::new(point(px(0.0), px(top)), size(px(100.0), px(height))),
        )
    }

    #[test]
    fn back_to_back_rows_pass() {
        let rows = [row(4, -9.3, 34.0), row(5, 24.7, 66.0), row(6, 90.7, 20.0)];
        assert_eq!(painted_rows_anomaly(&rows), None);
        assert_eq!(painted_rows_anomaly(&[]), None);
    }

    #[test]
    fn a_row_painted_twice_is_reported() {
        let rows = [row(4, 0.0, 34.0), row(5, 34.0, 66.0), row(5, 35.0, 66.0)];
        assert!(
            painted_rows_anomaly(&rows)
                .unwrap()
                .contains("row 5 painted twice")
        );
    }

    #[test]
    fn gaps_overlaps_and_order_are_reported() {
        let gap = [row(4, 0.0, 34.0), row(5, 35.0, 66.0)];
        assert!(painted_rows_anomaly(&gap).unwrap().contains("+1.00px"));
        let overlap = [row(4, 0.0, 34.0), row(5, 33.5, 66.0)];
        assert!(painted_rows_anomaly(&overlap).unwrap().contains("-0.50px"));
        let order = [row(4, 0.0, 34.0), row(9, 34.0, 66.0)];
        assert!(
            painted_rows_anomaly(&order)
                .unwrap()
                .contains("row 9 painted right after row 4")
        );
    }

    #[test]
    fn flicker_needs_a_sustained_two_position_alternation() {
        let a = ViewportSample {
            rows: 10,
            first_row: 3,
            first_top: -2000,
        };
        let b = ViewportSample {
            first_top: -1950,
            ..a
        };
        let c = ViewportSample {
            first_top: -1900,
            ..a
        };

        let mut flicker = ViewportFlicker::default();
        let fired: Vec<bool> = [a, b, a, b, a, b].map(|s| flicker.record(s)).to_vec();
        assert_eq!(fired, [false, false, false, false, false, true]);
        assert!(flicker.record(a), "keeps firing while it alternates");

        let mut steady = ViewportFlicker::default();
        assert!(
            ![a; 8].into_iter().any(|s| steady.record(s)),
            "a still viewport"
        );

        let mut scrolling = ViewportFlicker::default();
        assert!(
            ![a, b, c, a, b, c, a, b]
                .into_iter()
                .any(|s| scrolling.record(s)),
            "not an A/B alternation"
        );

        let mut growing = ViewportFlicker::default();
        let more = ViewportSample { rows: 11, ..a };
        assert!(![a, b, more, b, a, b].into_iter().any(|s| growing.record(s)));
    }

    #[test]
    fn reports_are_rate_limited() {
        let mut flicker = ViewportFlicker::default();
        let now = Instant::now();
        assert!(flicker.should_report(now));
        assert!(!flicker.should_report(now + Duration::from_secs(1)));
        assert!(flicker.should_report(now + Duration::from_secs(6)));
    }
}
