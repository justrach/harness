// A window's frame source goes idle after every frame that finds nothing to
// draw and wakes on the next invalidation. Streaming text does that once per
// chunk, and a scroll whose events land between frames does it every frame.
//
// On macOS 14 and later the frame source is the view's CADisplayLink, which
// idles by pausing. Before, it was a subscription to the display's shared
// CVDisplayLink, which idles by stopping the link (its io thread winds down)
// and wakes by starting it again. This compares the two idle/wake cycles.
//
// Runs on the process's main thread (harness = false), as both paths require.
#[cfg(target_os = "macos")]
#[path = "../src/display_link.rs"]
mod display_link;
#[cfg(target_os = "macos")]
#[path = "../src/frame_pacing.rs"]
#[allow(dead_code)]
mod frame_pacing;
#[cfg(target_os = "macos")]
#[path = "../src/frame_stats.rs"]
#[allow(dead_code)]
mod frame_stats;
#[cfg(target_os = "macos")]
#[path = "../src/view_display_link.rs"]
mod view_display_link;

fn main() {
    #[cfg(target_os = "macos")]
    macos::run();
}

#[cfg(target_os = "macos")]
mod macos {
    use crate::{
        display_link::WindowFrameSource,
        frame_pacing::{FramePacing, frame_pacing},
        view_display_link::ViewDisplayLink,
    };
    use cocoa::{
        base::id,
        foundation::{NSPoint, NSRect, NSSize},
    };
    use core_graphics::display::CGMainDisplayID;
    use objc::{
        class,
        declare::ClassDecl,
        msg_send,
        runtime::{Object, Sel},
        sel, sel_impl,
    };
    use std::{
        ffi::c_void,
        sync::{Arc, atomic::AtomicBool},
        time::{Duration, Instant},
    };

    const CYCLES: u32 = 200;

    extern "C" fn tick(_: &Object, _: Sel, _: id) {}
    extern "C" fn unused_callback(_: *mut c_void) {}

    fn new_view() -> id {
        unsafe {
            let mut decl = ClassDecl::new("FrameSourceIdleCyclesView", class!(NSView)).unwrap();
            decl.add_method(
                sel!(frameSourceTick:),
                tick as extern "C" fn(&Object, Sel, id),
            );
            let class = decl.register();
            let view: id = msg_send![class, alloc];
            msg_send![view, initWithFrame: NSRect::new(NSPoint::new(0., 0.), NSSize::new(100., 100.))]
        }
    }

    /// Idle then wake a view's CADisplayLink `CYCLES` times, the way a window
    /// does on macOS 14 and later.
    fn view_link_cycles(view: id) -> Option<Duration> {
        let mut link = unsafe { ViewDisplayLink::new(view, sel!(frameSourceTick:)) }?;
        let running = frame_pacing(true, 240, None);
        assert!(matches!(running, FramePacing::Running(_)));
        let started = Instant::now();
        for _ in 0..CYCLES {
            link.set_pacing(running);
            assert!(link.is_running());
            link.set_pacing(frame_pacing(false, 240, None));
            assert!(!link.is_running());
        }
        Some(started.elapsed())
    }

    /// Idle then wake a CVDisplayLink subscription `CYCLES` times, the way a
    /// window did before (and still does before macOS 14).
    fn core_video_cycles() -> Option<Duration> {
        let requested = Arc::new(AtomicBool::new(false));
        let mut source = WindowFrameSource::new(std::ptr::null_mut(), unused_callback, requested);
        let display_id = unsafe { CGMainDisplayID() };
        // Headless runners can lack a usable CoreVideo display.
        source.start(display_id).ok()?;
        source.stop();
        let started = Instant::now();
        for _ in 0..CYCLES {
            source.start(display_id).expect("restart the display link");
            source.stop();
        }
        Some(started.elapsed())
    }

    pub fn run() {
        let view = new_view();
        let Some(view_cycles) = view_link_cycles(view) else {
            println!("SKIP: NSView has no displayLink before macOS 14");
            return;
        };
        let per_view_cycle = view_cycles / CYCLES;
        println!("CADisplayLink pause/resume: {per_view_cycle:?} per idle/wake cycle");

        let Some(core_video_cycles) = core_video_cycles() else {
            println!("SKIP: no CoreVideo display to compare against");
            return;
        };
        let per_core_video_cycle = core_video_cycles / CYCLES;
        println!("CVDisplayLink stop/start: {per_core_video_cycle:?} per idle/wake cycle");

        // Generous: locally the gap is far larger than this.
        assert!(
            view_cycles * 5 <= core_video_cycles,
            "pausing a CADisplayLink should be at least 5x cheaper than stopping and \
             starting a CVDisplayLink: {per_view_cycle:?} vs {per_core_video_cycle:?}"
        );
        unsafe {
            let _: () = msg_send![view, release];
        }
        println!("PASS: idling a window's frame source no longer restarts a CVDisplayLink");
    }
}
