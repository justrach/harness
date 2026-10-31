//! Pure presentation rules for a confirmed shared-build wait.

pub(crate) fn label(since: i64, now: i64) -> String {
    let minutes = now.saturating_sub(since).max(0) / 60;
    format!("Waiting for another session · {minutes}m")
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Pulse {
    pub dot_opacity: f32,
    pub dot_scale: f32,
    pub ring_opacity: f32,
    pub ring_scale: f32,
}

/// A soft dot and faint breathing ring, inside a fixed slot. Neither rotates
/// nor moves surrounding text. Reduced motion keeps a quiet, steady mark.
pub(crate) fn pulse(phase: f32, reduced_motion: bool) -> Pulse {
    if reduced_motion {
        return Pulse {
            dot_opacity: 0.7,
            dot_scale: 1.0,
            ring_opacity: 0.12,
            ring_scale: 1.0,
        };
    }
    let breath = (1.0 - (phase * std::f32::consts::TAU).cos()) / 2.0;
    Pulse {
        dot_opacity: 0.3 + 0.7 * breath,
        dot_scale: 0.85 + 0.27 * breath,
        ring_opacity: 0.07 + 0.25 * breath,
        ring_scale: 0.72 + 0.43 * breath,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_wait_timer_is_compact_and_based_on_wait_not_turn_start() {
        assert_eq!(label(100, 100), "Waiting for another session · 0m");
        assert_eq!(label(100, 159), "Waiting for another session · 0m");
        assert_eq!(label(100, 340), "Waiting for another session · 4m");
        assert_eq!(label(100, 3700), "Waiting for another session · 60m");
        assert_eq!(label(100, 99), "Waiting for another session · 0m");
    }

    #[test]
    fn build_wait_pulse_is_soft_seamless_and_static_for_reduced_motion() {
        assert!((pulse(0.0, false).dot_opacity - 0.3).abs() < 0.001);
        assert!((pulse(0.5, false).dot_opacity - 1.0).abs() < 0.001);
        assert!((pulse(0.5, false).dot_scale - 1.12).abs() < 0.001);
        assert!((pulse(0.5, false).ring_opacity - 0.32).abs() < 0.001);
        assert!((pulse(0.5, false).ring_scale - 1.15).abs() < 0.001);
        assert_eq!(pulse(0.0, false), pulse(1.0, false));
        for step in 0..=100 {
            let phase = step as f32 / 100.0;
            assert!((0.3..=1.0).contains(&pulse(phase, false).dot_opacity));
            assert_eq!(pulse(phase, true), pulse(0.0, true));
        }
    }
}
