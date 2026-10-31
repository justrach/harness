//! A thumbless range made of thin bars. Bars up to the value take the accent;
//! the bars at each stop stand a little taller. Dragging fast lifts the bars
//! the pointer sweeps past, and they spring back down behind it, a wake that
//! follows the hand (after bencho.dev's wake slider). Reduced motion keeps
//! the bars still.
//!
//! The rules are pure functions so tests can call them; the reasoning step of
//! the model picker draws the bars (`pickers::model_preview`).
use std::time::{Duration, Instant};

/// Bars across the track.
pub const BARS: usize = 36;
/// A bar's resting height, a stop's extra height and the most a wake lifts it.
pub const REST_HEIGHT: f32 = 12.0;
pub const STOP_HEIGHT: f32 = 6.0;
pub const LIFT_HEIGHT: f32 = 14.0;
pub const BAR_WIDTH: f32 = 3.0;
/// How long a lifted bar takes to settle.
pub const SETTLE: Duration = Duration::from_millis(420);

/// The bar nearest `fraction` (0 at the start of the track, 1 at its end).
pub fn bar_at(fraction: f32, bars: usize) -> usize {
    let last = bars.saturating_sub(1);
    ((fraction.clamp(0.0, 1.0) * last as f32).round() as usize).min(last)
}

/// A bar's place along the track, 0 to 1.
pub fn bar_fraction(bar: usize, bars: usize) -> f32 {
    if bars < 2 {
        return 0.0;
    }
    bar as f32 / (bars - 1) as f32
}

/// The bars that sit on a stop, one per stop.
pub fn stop_bars(stops: usize, bars: usize) -> Vec<usize> {
    match stops {
        0 => Vec::new(),
        1 => vec![0],
        _ => (0..stops)
            .map(|stop| bar_at(stop as f32 / (stops - 1) as f32, bars))
            .collect(),
    }
}

/// The bars a drag swept from `from` to `to`, both ends included.
pub fn swept(from: f32, to: f32, bars: usize) -> std::ops::RangeInclusive<usize> {
    let (a, b) = (bar_at(from, bars), bar_at(to, bars));
    a.min(b)..=a.max(b)
}

/// How high a sweep lifts the bars, 0 to 1, from the pointer's speed in
/// points per millisecond. A slow drag leaves the bars still; a flick lifts
/// them all the way.
pub fn lift_for_speed(points_per_ms: f32) -> f32 {
    ((points_per_ms.abs() - 0.15) / 1.6).clamp(0.0, 1.0)
}

/// A lifted bar's height above rest after `elapsed`, as a share of the lift:
/// a damped spring that overshoots once below rest and settles by [`SETTLE`].
pub fn spring(elapsed: Duration) -> f32 {
    let t = elapsed.as_secs_f32() / SETTLE.as_secs_f32();
    if t >= 1.0 {
        return 0.0;
    }
    (-4.0 * t).exp() * (std::f32::consts::PI * 2.2 * t).cos() * (1.0 - t)
}

/// Each bar's live lift, set by a sweep and decaying by [`spring`].
#[derive(Clone, Default)]
pub struct Wake {
    lifts: Vec<Option<(f32, Instant)>>,
    last: Option<(f32, Instant)>,
}

impl Wake {
    /// The pointer moved the value to `fraction` on a track `width` points
    /// wide. Lifts the bars it swept by how fast it moved.
    pub fn sweep(&mut self, fraction: f32, width: f32, now: Instant) {
        if self.lifts.len() != BARS {
            self.lifts = vec![None; BARS];
        }
        if let Some((from, at)) = self.last {
            let ms = now.saturating_duration_since(at).as_secs_f32() * 1000.0;
            let speed = if ms > 0.0 {
                (fraction - from) * width / ms
            } else {
                0.0
            };
            let lift = lift_for_speed(speed);
            if lift > 0.0 {
                for bar in swept(from, fraction, BARS) {
                    // A bar already rising keeps the higher of the two lifts.
                    let current = self.height(bar, now);
                    if lift > current {
                        self.lifts[bar] = Some((lift, now));
                    }
                }
            }
        }
        self.last = Some((fraction, now));
    }

    /// The drag ended: the next drag starts its own speed measurement.
    pub fn release(&mut self) {
        self.last = None;
    }

    /// Bar `bar`'s lift at `now`, as a share of [`LIFT_HEIGHT`].
    pub fn height(&self, bar: usize, now: Instant) -> f32 {
        self.lifts
            .get(bar)
            .copied()
            .flatten()
            .map_or(0.0, |(lift, at)| {
                lift * spring(now.saturating_duration_since(at))
            })
    }

    /// Whether any bar is still moving.
    pub fn active(&self, now: Instant) -> bool {
        self.lifts
            .iter()
            .flatten()
            .any(|(_, at)| now.saturating_duration_since(*at) < SETTLE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stops_land_on_the_first_and_last_bars_and_spread_between() {
        assert_eq!(stop_bars(4, 36), vec![0, 12, 23, 35]);
        assert_eq!(stop_bars(2, 36), vec![0, 35]);
        assert_eq!(stop_bars(1, 36), vec![0]);
        assert!(stop_bars(0, 36).is_empty());
    }

    #[test]
    fn a_sweep_covers_every_bar_between_its_ends_in_either_direction() {
        assert_eq!(swept(0.0, 1.0, 36), 0..=35);
        assert_eq!(swept(0.5, 0.25, 36), 9..=18);
    }

    #[test]
    fn slow_drags_leave_the_bars_still_and_flicks_lift_them_fully() {
        assert_eq!(lift_for_speed(0.1), 0.0);
        assert!(lift_for_speed(0.6) > 0.0 && lift_for_speed(0.6) < 1.0);
        assert_eq!(lift_for_speed(-4.0), 1.0);
    }

    #[test]
    fn the_spring_starts_at_full_lift_dips_below_rest_and_settles() {
        assert!((spring(Duration::ZERO) - 1.0).abs() < 1e-6);
        let dips = (1..100).any(|ms| spring(Duration::from_millis(ms * 4)) < 0.0);
        assert!(dips, "the spring overshoots once below rest");
        assert_eq!(spring(SETTLE), 0.0);
    }

    #[test]
    fn a_fast_drag_lifts_the_bars_it_passes_and_a_slow_one_does_not() {
        let start = Instant::now();
        let mut fast = Wake::default();
        fast.sweep(0.0, 300.0, start);
        // 300 points in 100 ms: 3 points a millisecond.
        fast.sweep(1.0, 300.0, start + Duration::from_millis(100));
        let now = start + Duration::from_millis(100);
        assert!(fast.height(18, now) > 0.9);
        assert!(fast.active(now));
        assert!(!fast.active(now + SETTLE));

        let mut slow = Wake::default();
        slow.sweep(0.0, 300.0, start);
        slow.sweep(0.1, 300.0, start + Duration::from_millis(400));
        assert_eq!(slow.height(2, start + Duration::from_millis(400)), 0.0);
    }

    #[test]
    fn a_new_drag_does_not_measure_speed_from_the_last_one() {
        let start = Instant::now();
        let mut wake = Wake::default();
        wake.sweep(0.0, 300.0, start);
        wake.release();
        // A press far along the track right after release is not a flick.
        wake.sweep(1.0, 300.0, start + Duration::from_millis(10));
        assert_eq!(wake.height(18, start + Duration::from_millis(10)), 0.0);
    }
}
