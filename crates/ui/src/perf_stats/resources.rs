//! Native macOS counters: one syscall per five seconds, no process scans.
//! Only numeric histograms and fixed workload labels leave this module.

use std::time::{Duration, Instant};

use gpui::{App, Entity};
use harness_doc::MessageStatus;

use super::Metric;
use crate::state::AppState;

const SAMPLE_EVERY: Duration = Duration::from_secs(5);
const LOG_EVERY: Duration = Duration::from_secs(60);
const LARGE_BYTES: usize = 256 * 1024;
const LARGE_ENTRIES: usize = 200;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Workload {
    Empty,
    SettledSmall,
    SettledLarge,
    Streaming,
}

impl Workload {
    fn classify(entries: usize, prepared_bytes: usize, streaming: bool) -> Self {
        if streaming {
            Self::Streaming
        } else if entries == 0 {
            Self::Empty
        } else if entries >= LARGE_ENTRIES || prepared_bytes >= LARGE_BYTES {
            Self::SettledLarge
        } else {
            Self::SettledSmall
        }
    }

    fn metrics(self) -> (Metric, Metric) {
        match self {
            Self::Empty => (Metric::CpuEmpty, Metric::FootprintEmpty),
            Self::SettledSmall => (Metric::CpuSettledSmall, Metric::FootprintSettledSmall),
            Self::SettledLarge => (Metric::CpuSettledLarge, Metric::FootprintSettledLarge),
            Self::Streaming => (Metric::CpuStreaming, Metric::FootprintStreaming),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Empty => "empty",
            Self::SettledSmall => "settled_small",
            Self::SettledLarge => "settled_large",
            Self::Streaming => "streaming",
        }
    }
}

#[derive(Clone, Copy)]
struct Sample {
    at: Instant,
    cpu_seconds: f64,
    footprint_mib: f64,
}

impl Sample {
    fn cpu_percent_since(self, previous: Self) -> Option<f64> {
        let elapsed = self.at.checked_duration_since(previous.at)?.as_secs_f64();
        // Sleep/wake and stalled sampling aren't comparable five-second windows.
        if elapsed <= 0.0 || elapsed > SAMPLE_EVERY.as_secs_f64() * 3.0 {
            return None;
        }
        let cpu = self.cpu_seconds - previous.cpu_seconds;
        (cpu >= 0.0).then_some(cpu / elapsed * 100.0)
    }
}

#[allow(deprecated)] // libc's existing Mach bindings avoid a new dependency.
fn read_sample() -> Option<Sample> {
    static TIMEBASE: std::sync::OnceLock<Option<(u32, u32)>> = std::sync::OnceLock::new();
    let (numer, denom) = (*TIMEBASE.get_or_init(|| {
        let mut timebase = libc::mach_timebase_info { numer: 0, denom: 0 };
        // SAFETY: the pointer refers to an initialized Mach timebase structure.
        let result = unsafe { libc::mach_timebase_info(&mut timebase) };
        (result == 0 && timebase.denom != 0).then_some((timebase.numer, timebase.denom))
    }))?;
    let mut usage = std::mem::MaybeUninit::<libc::rusage_info_v2>::uninit();
    // SAFETY: RUSAGE_INFO_V2 writes precisely a rusage_info_v2; only read on success.
    let result = unsafe {
        libc::proc_pid_rusage(
            std::process::id() as libc::pid_t,
            libc::RUSAGE_INFO_V2,
            usage.as_mut_ptr().cast(),
        )
    };
    if result != 0 {
        return None;
    }
    // SAFETY: proc_pid_rusage successfully initialized the full structure above.
    let usage = unsafe { usage.assume_init() };
    Some(Sample {
        at: Instant::now(),
        cpu_seconds: (usage.ri_user_time as f64 + usage.ri_system_time as f64) * numer as f64
            / denom as f64
            / 1e9,
        footprint_mib: usage.ri_phys_footprint as f64 / 1048576.0,
    })
}

pub(super) fn start(state: Entity<AppState>, cx: &mut App) {
    cx.spawn(async move |cx| {
        let mut previous: Option<(Sample, Option<Workload>)> = None;
        let mut last_log: Option<Instant> = None;
        loop {
            let workload = cx.update(|cx| {
                if cx.windows().is_empty() {
                    return None;
                }
                let state = state.read(cx);
                let Some(chat) = state.selected_chat.as_ref() else {
                    return Some(Workload::Empty);
                };
                // Loading is not an empty transcript; don't attribute it to idle.
                if !state.transcript_replayed {
                    return None;
                }
                let bytes = state.prepared_transcripts.get(chat).map_or(0, |p| p.bytes);
                let streaming = state
                    .transcript
                    .last()
                    .is_some_and(|e| e.status == Some(MessageStatus::Streaming));
                Some(Workload::classify(state.transcript.len(), bytes, streaming))
            });
            let sample = cx
                .background_executor()
                .spawn(async { read_sample() })
                .await;
            if let Some(sample) = sample {
                if let Some((old, old_workload)) = previous
                    && let Some(workload) = workload
                    && old_workload == Some(workload)
                    && let Some(cpu_pct) = sample.cpu_percent_since(old)
                {
                    let (cpu_metric, memory_metric) = workload.metrics();
                    super::with(|r| {
                        r.add(cpu_metric, cpu_pct);
                        r.add(memory_metric, sample.footprint_mib);
                    });
                    if cpu_pct >= 100.0 && last_log.is_none_or(|at| at.elapsed() >= LOG_EVERY) {
                        tracing::info!(
                            cpu_pct = (cpu_pct * 100.0).round() / 100.0,
                            footprint_mib = (sample.footprint_mib * 100.0).round() / 100.0,
                            workload = workload.name(),
                            "high process resource usage (100% CPU = one core)"
                        );
                        last_log = Some(Instant::now());
                    }
                }
                previous = Some((sample, workload));
            } else {
                // Failed reads must not create a misleading multi-window delta.
                previous = None;
            }
            cx.background_executor().timer(SAMPLE_EVERY).await;
        }
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workload_labels_are_coarse_and_streaming_takes_priority() {
        assert_eq!(Workload::classify(0, 0, false), Workload::Empty);
        assert_eq!(
            Workload::classify(1, LARGE_BYTES - 1, false),
            Workload::SettledSmall
        );
        assert_eq!(
            Workload::classify(1, LARGE_BYTES, false),
            Workload::SettledLarge
        );
        assert_eq!(
            Workload::classify(LARGE_ENTRIES, 0, false),
            Workload::SettledLarge
        );
        assert_eq!(
            Workload::classify(LARGE_ENTRIES, LARGE_BYTES, true),
            Workload::Streaming
        );
    }

    #[test]
    fn cpu_uses_interval_deltas_and_preserves_multiple_cores() {
        let old = Sample {
            at: Instant::now(),
            cpu_seconds: 100.0,
            footprint_mib: 300.0,
        };
        let mut next = Sample {
            at: old.at + SAMPLE_EVERY,
            cpu_seconds: 112.5,
            footprint_mib: 400.0,
        };
        assert_eq!(next.cpu_percent_since(old), Some(250.0));
        next.cpu_seconds = 99.0;
        assert_eq!(next.cpu_percent_since(old), None);
        next.cpu_seconds = 112.5;
        next.at = old.at + Duration::from_secs(60);
        assert_eq!(next.cpu_percent_since(old), None);
    }

    #[test]
    fn native_sample_reads_current_process_without_children() {
        let sample = read_sample().expect("current-process resource counters");
        assert!(sample.cpu_seconds.is_finite() && sample.cpu_seconds >= 0.0);
        assert!(sample.footprint_mib.is_finite() && sample.footprint_mib > 0.0);
    }
}
