//! Native integration diagnostic for #625/#626. No production code changes.
//! Uses the real Harness attachment cache, GPUI cached sibling views, and Metal.
//! Run with --features appshots-fixture. Arguments: <output-dir> control|empty|reuse.
//! Does not start the Harness engine or read application/user data.
use anyhow::{Context as _, ensure};
use gpui::{
    AnyElement, AppContext, AsyncApp, Bounds, Context, Entity, Image, ImageFormat, IntoElement,
    Render, Styled, Window, WindowBounds, WindowOptions, div, img, prelude::*, px, rgb, size,
};
use harness_ui::attachments::{self, AttachmentSnapshot};
use image::{DynamicImage, ImageBuffer, Rgba, RgbaImage};
use std::{
    io::Cursor,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

const DEVICE: &str = "synthetic-fixture";
const A: &str = "synthetic-a.png";
const B: &str = "synthetic-b.png";

fn source(side: u32, color: [u8; 4]) -> Arc<Image> {
    let pixels = ImageBuffer::from_pixel(side, side, Rgba(color));
    let mut out = Cursor::new(Vec::new());
    DynamicImage::ImageRgba8(pixels)
        .write_to(&mut out, image::ImageFormat::Png)
        .unwrap();
    Arc::new(Image::from_bytes(ImageFormat::Png, out.into_inner()))
}

struct ImagePane {
    renders: Arc<AtomicUsize>,
}
impl Render for ImagePane {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        self.renders.fetch_add(1, Ordering::SeqCst);
        let content: AnyElement = match attachments::attachment_snapshot(DEVICE, A) {
            AttachmentSnapshot::Loaded(image) => {
                img(image.image).w(px(256.)).h(px(256.)).into_any_element()
            }
            _ => div()
                .w(px(256.))
                .h(px(256.))
                .bg(rgb(0xe8e8e8))
                .child("Loading image...")
                .into_any_element(),
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .p(px(16.))
            .gap(px(12.))
            .child("Cached pane A")
            .child(content)
    }
}

struct PressurePane {
    replacement: Arc<Image>,
    pressure: Option<Arc<Image>>,
    active: bool,
    reuse: bool,
    flushed: Arc<AtomicUsize>,
}
impl PressurePane {
    fn advance(&mut self, cx: &mut Context<Self>) {
        // This is the production load-completion cache insertion API. Its
        // actual 64 MiB LRU policy, not manual atlas removal, evicts A.
        if let Some(pressure) = &self.pressure {
            attachments::store_loaded(
                DEVICE,
                "synthetic-pressure.png",
                "Pressure".into(),
                pressure.clone(),
            );
        }
        attachments::store_loaded(DEVICE, B, "Synthetic B".into(), self.replacement.clone());
        self.active = true;
        cx.notify(); // Only B is notified, as with a load in another transcript.
    }
}
impl Render for PressurePane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // Same production flush API used at Transcript::render entry.
        attachments::flush_evicted(Some(window), cx);
        if self.active {
            self.flushed.fetch_add(1, Ordering::SeqCst);
        }
        let replacement = self.replacement.clone();
        let body: AnyElement = if self.active && self.reuse {
            img(replacement).w(px(256.)).h(px(256.)).into_any_element()
        } else {
            // Run real Img layout to warm the decoder but never call its paint
            // method: even a zero-size Img paint would upload an atlas tile.
            gpui::canvas(
                move |_, window, cx| {
                    let mut preload = img(replacement).w(px(1.)).h(px(1.)).into_any_element();
                    preload.layout_as_root(
                        size(
                            gpui::AvailableSpace::MinContent,
                            gpui::AvailableSpace::MinContent,
                        ),
                        window,
                        cx,
                    );
                },
                |_, (), _, _| {},
            )
            .w(px(0.))
            .h(px(0.))
            .into_any_element()
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .p(px(16.))
            .gap(px(12.))
            .child("Pressure pane B")
            .child(body)
    }
}

struct Root {
    a: Entity<ImagePane>,
    b: Entity<PressurePane>,
}
impl Render for Root {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .bg(rgb(0xffffff))
            .text_color(rgb(0x202020))
            .text_size(px(16.))
            .flex()
            .flex_row()
            .child(
                div().w(px(320.)).h_full().child(
                    self.a
                        .clone()
                        .cached(gpui::StyleRefinement::default().size_full()),
                ),
            )
            .child(
                div().w(px(320.)).h_full().child(
                    self.b
                        .clone()
                        .cached(gpui::StyleRefinement::default().size_full()),
                ),
            )
    }
}

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}
fn capture(
    window: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    path: &Path,
) -> anyhow::Result<RgbaImage> {
    window.update(cx, |_, window, cx| {
        // draw does not globally refresh views: unchanged cached A must replay.
        window.draw(cx).clear();
        let image = window.render_to_image()?;
        image.save(path)?;
        Ok(image)
    })?
}
fn counts(image: &RgbaImage) -> (usize, usize) {
    let mut red = 0;
    let mut blue = 0;
    for (x, _, p) in image.enumerate_pixels() {
        if x >= image.width() / 2 {
            continue;
        }
        if p[0] > 180 && p[1] < 100 && p[2] < 100 {
            red += 1;
        }
        if p[0] < 100 && p[1] < 150 && p[2] > 180 {
            blue += 1;
        }
    }
    (red, blue)
}

fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let output = PathBuf::from(args.next().context("output directory required")?);
    let mode = args
        .next()
        .context("control, empty, reuse, or partial required")?;
    ensure!(
        ["control", "empty", "reuse", "partial"].contains(&mode.as_str()),
        "unknown mode"
    );
    std::fs::create_dir_all(&output)?;
    let a = source(2048, [230, 40, 40, 255]);
    let b = source(
        if mode == "control" || mode == "partial" {
            256
        } else {
            2048
        },
        [40, 80, 230, 255],
    );
    let pressure = (mode == "partial").then(|| source(2048, [40, 200, 40, 255]));
    attachments::store_loaded(DEVICE, A, "Synthetic A".into(), a);
    let renders = Arc::new(AtomicUsize::new(0));
    let flushed = Arc::new(AtomicUsize::new(0));
    let failure = Arc::new(Mutex::new(None));
    let outcome = failure.clone();
    let mode_for_app = mode.clone();
    std::panic::set_hook(Box::new(|info| {
        eprintln!("UI_REPRO_PANIC: {info}");
    }));
    gpui_platform::application().run(move |cx| {
        let pane_a = cx.new(|_| ImagePane { renders: renders.clone() });
        let pane_b = cx.new(|_| PressurePane {
            replacement: b, pressure, active: false, reuse: mode_for_app != "empty", flushed: flushed.clone(),
        });
        let b_handle = pane_b.clone();
        let window = cx.open_window(WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                gpui::point(px(40.), px(40.)), size(px(640.), px(360.)),
            ))),
            ..Default::default()
        }, |_, cx| cx.new(|_| Root { a: pane_a, b: pane_b })).unwrap();
        cx.activate(true);
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                pause(cx, 1400).await;
                let before = capture(window.into(), cx, &output.join("before.png"))?;
                let before_counts = counts(&before);
                ensure!(before_counts.0 > 10000, "original red image did not load: {before_counts:?}");
                let renders_before = renders.load(Ordering::SeqCst);
                println!("BASELINE: mode={mode_for_app} A_renders={renders_before} red_pixels={} blue_pixels={}",
                         before_counts.0, before_counts.1);
                b_handle.update(cx, |pane, cx| pane.advance(cx));
                let evicted = !matches!(attachments::attachment_snapshot(DEVICE, A), AttachmentSnapshot::Loaded(_));
                println!("CACHE: A_evicted_by_real_budget={evicted}");
                ensure!(evicted == (mode_for_app != "control"), "unexpected cache eviction state");
                // Native presentation may already panic here in empty mode.
                pause(cx, 500).await;
                let after = capture(window.into(), cx, &output.join("after.png"))?;
                let after_counts = counts(&after);
                let renders_after = renders.load(Ordering::SeqCst);
                let was_cached = renders_before == renders_after;
                let substituted = after_counts.0 < before_counts.0 / 100
                    && after_counts.1 > before_counts.0 * 9 / 10;
                let partial = after_counts.0 < before_counts.0 / 100
                    && after_counts.1 > 0 && after_counts.1 < before_counts.0 / 2;
                let summary = serde_json::json!({
                    "mode": mode_for_app, "cache_evicted_a": evicted,
                    "a_renders_before": renders_before, "a_renders_after": renders_after,
                    "cached_a_replayed": was_cached, "pressure_pane_rendered": flushed.load(Ordering::SeqCst),
                    "red_before": before_counts.0, "blue_before": before_counts.1,
                    "red_after": after_counts.0, "blue_after": after_counts.1,
                    "replacement_pixels_in_a": substituted, "partial_image_in_a": partial,
                });
                std::fs::write(output.join("result.json"), serde_json::to_vec_pretty(&summary)?)?;
                println!("RESULT: {summary}");
                if substituted && was_cached {
                    println!("REPRODUCED: real LRU eviction -> cached sibling replay -> wrong image pixels");
                }
                if partial && was_cached {
                    println!("REPRODUCED: real LRU eviction -> smaller reused texture -> partial/blank image");
                }
                // Regression assertion: unsafe release behavior fails rather
                // than treating visible corruption as a passing test.
                ensure!(after_counts.0 >= before_counts.0 * 9 / 10 && !substituted,
                        "REGRESSION: pane A no longer displays its original image");
                println!("VERIFIED: pane A remains correct after mode={mode_for_app}");
                Ok(())
            }.await;
            let code = if let Err(error) = run {
                eprintln!("FIXTURE_FAILED: {error:#}");
                *outcome.lock().unwrap() = Some(error);
                1
            } else { 0 };
            let _ = window.update(cx, |_, w, _| w.remove_window());
            pause(cx, 50).await;
            // Native App::quit can exit with zero before main returns. Preserve
            // the regression assertion's status in this standalone process.
            std::process::exit(code);
        }).detach();
    });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
