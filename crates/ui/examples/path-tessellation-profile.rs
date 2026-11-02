//! What building the window's paths costs per frame: time and allocations.
//!
//! Builds, frame after frame, the paths Harness paints with `PathBuilder` (the
//! agents card's spinner and its dashed ring, the context ring, an upload
//! ring, the plan's connector lines and history graph lanes that scroll), the
//! way their canvases build them, and prints the time and the allocations
//! one frame of them costs. No window: path building is plain CPU work.
//!
//! ```sh
//! cargo build --profile app-dev -p harness-ui --example path-tessellation-profile
//! target/app-dev/examples/path-tessellation-profile
//! ```
use std::{
    alloc::{GlobalAlloc, Layout, System},
    f32::consts::{FRAC_PI_2, TAU},
    sync::atomic::{AtomicI64, AtomicU64, Ordering::Relaxed},
    time::Instant,
};

use gpui::{PathBuilder, Pixels, Point, point, px};

/// Counts allocations, so a frame's are its own count's difference.
struct Counting;

static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);
static ALLOCATED: AtomicU64 = AtomicU64::new(0);
/// Bytes allocated and not yet freed.
static LIVE: AtomicI64 = AtomicI64::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Relaxed);
        ALLOCATED.fetch_add(layout.size() as u64, Relaxed);
        LIVE.fetch_add(layout.size() as i64, Relaxed);
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size() as i64, Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Relaxed);
        ALLOCATED.fetch_add(new_size as u64, Relaxed);
        LIVE.fetch_add(new_size as i64 - layout.size() as i64, Relaxed);
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

const FRAMES: usize = 3000;
/// `agent_work::SPINNER_GAP`.
const SPINNER_GAP: f32 = 0.15;

/// `agent_work::arc_path`: a polyline arc, `start` and `sweep` in turns.
fn arc(center: Point<Pixels>, radius: f32, start: f32, sweep: f32, stroke: f32, dash: bool) {
    let steps = (48.0 * sweep).ceil().max(2.0) as usize;
    let mut path = PathBuilder::stroke(px(stroke));
    if dash {
        path = path.dash_array(&[px(2.0), px(2.2)]);
    }
    for i in 0..=steps {
        let angle = -FRAC_PI_2 + TAU * (start + sweep * i as f32 / steps as f32);
        let p = point(
            center.x + px(radius * angle.cos()),
            center.y + px(radius * angle.sin()),
        );
        if i == 0 {
            path.move_to(p);
        } else {
            path.line_to(p);
        }
    }
    std::hint::black_box(path.build().ok());
}

/// `context_usage` and `loaders::upload_progress_ring`: a track and a filled
/// fraction, 64 segments a turn.
fn ring(center: Point<Pixels>, radius: f32, stroke: f32, fraction: f32) {
    for sweep in [1.0, fraction] {
        let steps = (64.0 * sweep).ceil().max(2.0) as usize;
        let mut path = PathBuilder::stroke(px(stroke));
        for i in 0..=steps {
            let angle = -FRAC_PI_2 + TAU * sweep * i as f32 / steps as f32;
            let p = point(
                center.x + px(radius * angle.cos()),
                center.y + px(radius * angle.sin()),
            );
            if i == 0 {
                path.move_to(p);
            } else {
                path.line_to(p);
            }
        }
        std::hint::black_box(path.build().ok());
    }
}

/// The agents card's plan connectors (`agent_work`): short strokes, some
/// curved, some dashed.
fn connectors(origin: Point<Pixels>) {
    for i in 0..6 {
        let from = origin + point(px(8.0), px(20.0 * i as f32 + 14.0));
        let to = origin + point(px(8.0), px(20.0 * i as f32 + 26.0));
        let mut path = PathBuilder::stroke(px(1.5));
        if i % 3 == 2 {
            path = path.dash_array(&[px(3.0), px(3.0)]);
        }
        path.move_to(from);
        if i % 2 == 0 {
            path.cubic_bezier_to(
                to,
                from + point(px(6.0), px(4.0)),
                to - point(px(6.0), px(4.0)),
            );
        } else {
            path.line_to(to);
        }
        std::hint::black_box(path.build().ok());
    }
}

/// History graph lanes (`history.rs`): one polyline per lane color down the
/// visible rows, moving as the list scrolls.
fn lanes(scroll: f32) {
    for lane in 0..4 {
        let mut path = PathBuilder::stroke(px(1.5));
        let x = 20.0 + lane as f32 * 12.0;
        path.move_to(point(px(x), px(-scroll)));
        for row in 1..40 {
            let jog = if row % (lane + 3) == 0 { 12.0 } else { 0.0 };
            path.line_to(point(px(x + jog), px(row as f32 * 28.0 - scroll)));
        }
        std::hint::black_box(path.build().ok());
    }
}

struct Run {
    name: &'static str,
    us: Vec<f64>,
    allocations: u64,
    bytes: u64,
    /// Bytes still held after the run that were not before it (kept shapes).
    held: i64,
}

fn run(name: &'static str, frame: impl Fn(usize)) -> Run {
    let live = LIVE.load(Relaxed);
    // Warm up: first-frame tessellation is not the steady state.
    for i in 0..60 {
        frame(i);
    }
    let (allocations, bytes) = (ALLOCATIONS.load(Relaxed), ALLOCATED.load(Relaxed));
    let mut us = Vec::with_capacity(FRAMES);
    for i in 0..FRAMES {
        let start = Instant::now();
        frame(60 + i);
        us.push(start.elapsed().as_secs_f64() * 1e6);
    }
    Run {
        name,
        us,
        allocations: ALLOCATIONS.load(Relaxed) - allocations,
        bytes: ALLOCATED.load(Relaxed) - bytes,
        held: LIVE.load(Relaxed) - live,
    }
}

fn main() {
    // A spinner turns about once a second; its phase comes from the clock, so
    // no two frames draw the arc at exactly the same angle.
    let phase = |frame: usize| (frame as f32 * 0.016_734).fract();
    let spinner = |frame: usize| {
        let center = point(px(300.0), px(700.0));
        let radius = (12.0 - 1.5) / 2.0;
        arc(center, radius, 0.0, 1.0, 1.5, false);
        arc(center, radius, phase(frame), 1.0 - SPINNER_GAP, 1.5, false);
    };
    let runs = [
        run("spinner", spinner),
        run("chrome", |frame| {
            spinner(frame);
            arc(point(px(330.0), px(700.0)), 5.25, 0.0, 1.0, 1.5, true);
            ring(point(px(900.0), px(840.0)), 6.0, 1.8, 0.42);
            ring(point(px(500.0), px(400.0)), 17.5, 2.5, 0.6);
            connectors(point(px(280.0), px(560.0)));
        }),
        run("scrolling", |frame| lanes((frame % 600) as f32 * 2.0)),
    ];
    for run in runs {
        let mut sorted = run.us.clone();
        sorted.sort_by(f64::total_cmp);
        let n = sorted.len() as f64;
        println!(
            "{:<10} frames={} us_per_frame mean={:.2} p50={:.2} p95={:.2} \
             allocations_per_frame={:.1} bytes_per_frame={:.0} held_after_kib={:.0}",
            run.name,
            run.us.len(),
            sorted.iter().sum::<f64>() / n,
            sorted[sorted.len() / 2],
            sorted[sorted.len() * 95 / 100],
            run.allocations as f64 / n,
            run.bytes as f64 / n,
            run.held as f64 / 1024.0,
        );
    }
}
