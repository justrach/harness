//! Measures frame work on Windows: what an idle window costs, and how fast a window that
//! animates every frame draws.
//!
//! ```powershell
//! cargo build --release -p gpui_windows --example windows_idle_frames
//! .\target\release\examples\windows_idle_frames.exe idle.json             # 20 s idle
//! .\target\release\examples\windows_idle_frames.exe animate.json --animate # 5 s animating
//! .\target\release\examples\windows_idle_frames.exe verify.json --verify   # updates still draw
//! ```
//!
//! Add `--dcomp` to keep DirectComposition on (it is off by default, as in gpui-fast's run).
//! Frame callbacks are counted as the WM_PAINT messages the window's thread takes from its
//! queue, so the count needs no hook inside the backend and means the same before and after.
//!
//! Modified by Harness: adapted from the Apache-2.0 GPUI fork
//! https://github.com/longbridge/gpui-fast at 124f79b (`gpui_perf/examples/windows_idle_frames.rs`),
//! adding the WM_PAINT count, an animation mode and the display refresh rate.
//! See vendor/zui/NOTICE.

#[cfg(target_os = "windows")]
mod windows_benchmark {
    use gpui::*;
    use std::{
        rc::Rc,
        sync::{
            Arc,
            atomic::{AtomicU64, AtomicUsize, Ordering},
        },
        time::{Duration, Instant},
    };
    use windows::Win32::{
        Foundation::{FILETIME, HWND, LPARAM, LRESULT, WPARAM},
        Graphics::Dwm::{DWM_TIMING_INFO, DwmGetCompositionTimingInfo},
        System::Threading::{GetCurrentProcess, GetCurrentThreadId, GetProcessTimes},
        UI::WindowsAndMessaging::{
            CallNextHookEx, MSG, PM_REMOVE, SetWindowsHookExW, WH_GETMESSAGE, WM_PAINT,
        },
    };

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn QueryProcessCycleTime(process: *mut std::ffi::c_void, cycles: *mut u64) -> i32;
    }

    static PAINTS: AtomicU64 = AtomicU64::new(0);

    unsafe extern "system" fn count_paints(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 && wparam.0 == PM_REMOVE.0 as usize {
            let message = unsafe { &*(lparam.0 as *const MSG) };
            if message.message == WM_PAINT {
                PAINTS.fetch_add(1, Ordering::Relaxed);
            }
        }
        unsafe { CallNextHookEx(None, code, wparam, lparam) }
    }

    fn filetime(time: FILETIME) -> u64 {
        ((time.dwHighDateTime as u64) << 32) | time.dwLowDateTime as u64
    }

    /// Process CPU time in 100 ns units, and process CPU cycles.
    fn counters() -> (u64, u64) {
        let (mut created, mut exited, mut kernel, mut user) = Default::default();
        let mut cycles = 0;
        unsafe {
            GetProcessTimes(
                GetCurrentProcess(),
                &mut created,
                &mut exited,
                &mut kernel,
                &mut user,
            )
            .unwrap();
            assert_ne!(QueryProcessCycleTime(GetCurrentProcess().0, &mut cycles), 0);
        }
        (filetime(kernel) + filetime(user), cycles)
    }

    fn refresh_hz() -> f64 {
        let mut info = DWM_TIMING_INFO {
            cbSize: std::mem::size_of::<DWM_TIMING_INFO>() as u32,
            ..Default::default()
        };
        match unsafe { DwmGetCompositionTimingInfo(HWND::default(), &mut info) } {
            Ok(()) if info.rateRefresh.uiDenominator != 0 => {
                info.rateRefresh.uiNumerator as f64 / info.rateRefresh.uiDenominator as f64
            }
            _ => 0.0,
        }
    }

    struct View {
        renders: Arc<AtomicUsize>,
        animate: bool,
        lit: bool,
    }

    impl Render for View {
        fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            let frame = self.renders.fetch_add(1, Ordering::Relaxed);
            if self.animate {
                window.request_animation_frame();
            }
            let shift = if self.animate {
                (frame % 240) as f32
            } else {
                0.
            };
            div()
                .size_full()
                .flex()
                .flex_col()
                .p_8()
                .gap_4()
                .font_family("Segoe UI")
                .text_color(rgb(0xe8e8e8))
                .bg(rgb(0x202124))
                .child("GPUI Windows frame benchmark")
                .child(
                    div()
                        .flex()
                        .gap_4()
                        .ml(px(shift))
                        .children(["Panel 1", "Panel 2"].map(|label| {
                            div()
                                .w(px(320.))
                                .h(px(180.))
                                .rounded_lg()
                                .flex()
                                .items_center()
                                .justify_center()
                                .border_2()
                                .border_color(if self.lit {
                                    rgb(0x65b879)
                                } else {
                                    rgb(0x404246)
                                })
                                .bg(rgb(0x303236))
                                .child(label)
                        })),
                )
        }
    }

    fn chain(window: &Window, completed: Arc<AtomicUsize>, remaining: usize) {
        window.on_next_frame(move |window, _| {
            completed.fetch_add(1, Ordering::Relaxed);
            if remaining > 1 {
                chain(window, completed, remaining - 1);
            }
        });
    }

    fn open(cx: &mut App, renders: Arc<AtomicUsize>, animate: bool) -> WindowHandle<View> {
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    point(px(100.), px(100.)),
                    size(px(1280.), px(800.)),
                ))),
                ..Default::default()
            },
            |_, cx| {
                cx.new(|_| View {
                    renders,
                    animate,
                    lit: true,
                })
            },
        )
        .unwrap()
    }

    pub fn run() {
        let output =
            std::path::PathBuf::from(std::env::args_os().nth(1).expect("output JSON path"));
        let verify = std::env::args().any(|arg| arg == "--verify");
        let animate = std::env::args().any(|arg| arg == "--animate");
        let dcomp = std::env::args().any(|arg| arg == "--dcomp");
        if !dcomp {
            unsafe { std::env::set_var("GPUI_DISABLE_DIRECT_COMPOSITION", "true") };
        }
        unsafe {
            SetWindowsHookExW(
                WH_GETMESSAGE,
                Some(count_paints),
                None,
                GetCurrentThreadId(),
            )
            .expect("installing the WM_PAINT counter");
        }
        let platform = Rc::new(gpui_windows::WindowsPlatform::new(false).unwrap());
        Application::with_platform(platform).run(move |cx: &mut App| {
            let renders = Arc::new(AtomicUsize::new(0));
            let handle = open(cx, renders.clone(), animate);
            cx.spawn(async move |cx| {
                let warmup = if animate { 1 } else { 3 };
                let measured = if animate { 5 } else { 20 };
                cx.background_executor()
                    .timer(Duration::from_secs(warmup))
                    .await;
                let before = counters();
                let before_renders = renders.load(Ordering::Relaxed);
                let before_paints = PAINTS.load(Ordering::Relaxed);
                let start = Instant::now();
                cx.background_executor()
                    .timer(Duration::from_secs(measured))
                    .await;
                let elapsed = start.elapsed().as_secs_f64();
                let after = counters();
                let measured_renders = renders.load(Ordering::Relaxed) - before_renders;
                let measured_paints = PAINTS.load(Ordering::Relaxed) - before_paints;

                let mut callbacks = 0;
                let mut update_renders = 0;
                if verify {
                    let second_renders = Arc::new(AtomicUsize::new(0));
                    let second = cx.update(|cx| open(cx, second_renders.clone(), false));
                    cx.background_executor().timer(Duration::from_secs(1)).await;
                    let old_renders =
                        renders.load(Ordering::Relaxed) + second_renders.load(Ordering::Relaxed);
                    for frame in 0..25 {
                        for target in [handle, second] {
                            target
                                .update(cx, |view, _, cx| {
                                    view.lit = frame % 2 == 0;
                                    cx.notify();
                                })
                                .unwrap();
                        }
                        cx.background_executor()
                            .timer(Duration::from_millis(80))
                            .await;
                    }
                    update_renders = renders.load(Ordering::Relaxed)
                        + second_renders.load(Ordering::Relaxed)
                        - old_renders;
                    let completed = Arc::new(AtomicUsize::new(0));
                    for target in [handle, second] {
                        let completed = completed.clone();
                        target
                            .update(cx, |_, window, _| chain(window, completed, 60))
                            .unwrap();
                    }
                    cx.background_executor().timer(Duration::from_secs(3)).await;
                    callbacks = completed.load(Ordering::Relaxed);
                    second
                        .update(cx, |_, window, _| window.remove_window())
                        .unwrap();
                }

                let result = format!(
                    concat!(
                        "{{\n",
                        "  \"mode\": \"{}\",\n",
                        "  \"direct_composition\": {},\n",
                        "  \"refresh_hz\": {:.2},\n",
                        "  \"elapsed_seconds\": {:.3},\n",
                        "  \"frame_callbacks\": {},\n",
                        "  \"frame_callbacks_per_second\": {:.2},\n",
                        "  \"renders\": {},\n",
                        "  \"renders_per_second\": {:.2},\n",
                        "  \"process_cpu_ms\": {:.1},\n",
                        "  \"process_cycles\": {},\n",
                        "  \"update_renders\": {},\n",
                        "  \"chained_callbacks\": {}\n",
                        "}}\n"
                    ),
                    if animate { "animate" } else { "idle" },
                    dcomp,
                    refresh_hz(),
                    elapsed,
                    measured_paints,
                    measured_paints as f64 / elapsed,
                    measured_renders,
                    measured_renders as f64 / elapsed,
                    (after.0 - before.0) as f64 / 10_000.,
                    after.1 - before.1,
                    update_renders,
                    callbacks,
                );
                print!("{result}");
                std::fs::write(&output, result).unwrap();
                if !animate {
                    assert_eq!(measured_renders, 0, "an idle view rendered");
                }
                if verify {
                    assert!(update_renders >= 50, "updates did not draw");
                    assert_eq!(callbacks, 120, "chained next-frame callbacks stalled");
                }
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    }
}

fn main() {
    #[cfg(target_os = "windows")]
    windows_benchmark::run();
    #[cfg(not(target_os = "windows"))]
    eprintln!("This benchmark requires Windows.");
}
