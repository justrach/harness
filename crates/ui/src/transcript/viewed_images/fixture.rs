//! Production disclosure, viewer, tool summary, and gallery over synthetic data.
use super::*;

const OWNER: &str = "synthetic-viewed-image-owner";
const ROW: &str = "fixture-viewed-image";
const PATH: &str = "/synthetic/attachment.png";
const TOOLS: &str = "fixture-process";

pub struct ViewedImageReview {
    transcript: Entity<Transcript>,
    original: Arc<gpui::Image>,
    results: Vec<GeneratedImageRef>,
    tools: Arc<Vec<ToolItem>>,
    phase: String,
    _subscription: Subscription,
}

impl ViewedImageReview {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let state = cx.new(|_| AppState::new());
        let transcript = cx.new(|cx| Transcript::new(state, cx));
        let subscription = cx.observe(&transcript, |_, _, cx| cx.notify());
        let mut images = Vec::new();
        for (index, color) in [[54, 109, 111], [160, 111, 73], [106, 97, 145]]
            .into_iter()
            .enumerate()
        {
            let mut bitmap =
                image::RgbaImage::from_pixel(384, 256, image::Rgba([240, 236, 225, 255]));
            for (x, y, pixel) in bitmap.enumerate_pixels_mut() {
                if (18..366).contains(&x) && (18..166).contains(&y) {
                    *pixel = image::Rgba([color[0], color[1], color[2], 255]);
                }
                if (38..230).contains(&x) && (40..50).contains(&y) {
                    *pixel = image::Rgba([246, 242, 232, 255]);
                }
                if (18..(200 + index as u32 * 28)).contains(&x) && (192..206).contains(&y) {
                    *pixel = image::Rgba([76, 73, 65, 255]);
                }
                if (18..334).contains(&x) && (222..230).contains(&y) {
                    *pixel = image::Rgba([178, 173, 162, 255]);
                }
            }
            let mut bytes = std::io::Cursor::new(Vec::new());
            image::DynamicImage::ImageRgba8(bitmap)
                .write_to(&mut bytes, image::ImageFormat::Png)
                .unwrap();
            let image = Arc::new(gpui::Image::from_bytes(
                gpui::ImageFormat::Png,
                bytes.into_inner(),
            ));
            let path = if index == 0 {
                PATH.to_string()
            } else {
                format!("/synthetic/result-{index}.png")
            };
            crate::attachments::store_loaded_for(
                &AttachmentKey::new(OWNER, &path, Some("image/png")),
                "Design.png".into(),
                image.clone(),
            );
            images.push((
                GeneratedImageRef {
                    path,
                    name: format!("Design {index}.png"),
                    mime_type: "image/png".into(),
                },
                image,
            ));
        }
        let parts = ["layout.rs", "theme.rs", "controls.rs"]
            .into_iter()
            .enumerate()
            .map(|(i, name)| MessagePart::Tool {
                id: format!("read-{i}"),
                call: ToolCall::ReadFile {
                    path: format!("/synthetic/{name}"),
                },
                is_error: false,
                resolved: i != 2,
                output: None,
                diff: None,
                output_ref: None,
                output_bytes: None,
                diff_ref: None,
                diff_stats: None,
                subagent_ref: None,
                subagent_status: None,
                subagent_tail: None,
                view: None,
            })
            .collect();
        let entry = SessionMessageEntry {
            id: "synthetic-tools".into(),
            role: MessageRole::Assistant,
            parts,
            created_at: 0,
            device_id: OWNER.into(),
            status: Some(MessageStatus::Streaming),
            continuation_of: None,
            duration_ms: None,
        };
        let rows = rows_for_entry(&entry, false, false, &mut |_, text| {
            Arc::new(parse_full(text))
        });
        let tools = rows
            .into_iter()
            .find_map(|r| {
                if let RowKind::ToolGroup { tools, .. } = r.kind {
                    Some(tools)
                } else {
                    None
                }
            })
            .unwrap();
        Self {
            transcript,
            original: images[0].1.clone(),
            results: images.into_iter().skip(1).map(|i| i.0).collect(),
            tools,
            phase: "closed".into(),
            _subscription: subscription,
        }
    }

    pub fn set_phase(&mut self, phase: &str, cx: &mut Context<Self>) {
        self.phase = phase.into();
        self.transcript.update(cx, |this, cx| {
            this.attachment_preview = None;
            this.pending_viewed_image = None;
            if phase == "results" {
                if let Some(disclosure) = this.viewed_images.get_mut(&SharedString::from(ROW)) {
                    disclosure.open = false;
                }
            }
            if phase == "unavailable" {
                this.viewed_images.remove(&SharedString::from(ROW));
                let _ = this.render_viewed_image(
                    &ROW.into(),
                    OWNER,
                    "/synthetic/missing.png",
                    "Design.png",
                    "image/png",
                    cx,
                );
                this.toggle_viewed_image(&ROW.into(), cx);
            }
            cx.notify();
        });
        cx.notify();
    }

    pub fn assert_disclosure(&self, open: bool, cx: &gpui::App) {
        assert_eq!(
            self.transcript.read(cx).viewed_images[&SharedString::from(ROW)].open,
            open
        );
    }

    pub fn assert_preview(&self, open: bool, cx: &gpui::App) {
        let transcript = self.transcript.read(cx);
        assert_eq!(transcript.attachment_preview.is_some(), open);
        if open {
            assert!(
                transcript
                    .attachment_preview
                    .as_ref()
                    .unwrap()
                    .annotate
                    .is_some(),
                "Markup/Comment staging hook survives"
            );
        }
    }

    pub fn assert_tools(&self, open: bool, cx: &gpui::App) {
        assert_eq!(
            self.transcript.read(cx).tool_group_reveals[&SharedString::from(TOOLS)].rendered_open,
            Some(open)
        );
    }
}

impl Render for ViewedImageReview {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.transcript
            .update(cx, |this, cx| this.resolve_viewed_image_preview(window, cx));
        if self.transcript.read(cx).attachment_preview.is_some() {
            return self.transcript.clone().into_any_element();
        }
        let theme = Theme::of(cx).clone();
        let original = div()
            .flex()
            .flex_col()
            .gap(px(10.0))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(theme.text_muted)
                    .child("You"),
            )
            .child(
                gpui::img(self.original.clone())
                    .w(px(128.0))
                    .h(px(96.0))
                    .object_fit(gpui::ObjectFit::Contain)
                    .rounded(px(8.0)),
            )
            .child("Please check this layout and improve the main action.");
        let mut body = div()
            .w_full()
            .max_w(px(700.0))
            .flex()
            .flex_col()
            .gap(px(20.0))
            .child(original)
            .child(div().h(px(1.0)).bg(theme.border))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(theme.text_muted)
                    .child("Harness"),
            );
        if self.phase == "tools" {
            let tools = self.tools.clone();
            let summary: SharedString = tool_group_summary(&tools).into();
            body = body
                .child("I’m checking the relevant files.")
                .child(self.transcript.update(cx, |this, cx| {
                    this.render_tool_group(
                        &TOOLS.into(),
                        &tools,
                        &summary,
                        true,
                        None,
                        false,
                        &theme,
                        cx,
                    )
                }));
        } else {
            let path = if self.phase == "unavailable" {
                "/synthetic/missing.png"
            } else {
                PATH
            };
            body = body
                .child("The layout is clear. I’ll make the primary action easier to find.")
                .child(self.transcript.update(cx, |this, cx| {
                    this.render_generated_image(
                        &ROW.into(),
                        OWNER,
                        path,
                        "Design.png",
                        "image/png",
                        true,
                        cx,
                    )
                }));
            if self.phase == "results" {
                body = body
                    .child("Here are two new directions.")
                    .child(self.transcript.update(cx, |this, cx| {
                        this.render_generated_image_gallery(
                            &"fixture-new-results".into(),
                            OWNER,
                            &self.results,
                            cx,
                        )
                    }));
            }
        }
        div()
            .size_full()
            .bg(theme.bg)
            .text_color(theme.text)
            .text_size(px(15.0))
            .flex()
            .flex_col()
            .child(
                div()
                    .h(px(48.0))
                    .flex_none()
                    .px(px(20.0))
                    .flex()
                    .items_center()
                    .justify_between()
                    .border_b_1()
                    .border_color(theme.border)
                    .child("Image review")
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(theme.text_muted)
                            .child("Synthetic fixture"),
                    ),
            )
            .child(
                div()
                    .id("viewed-fixture-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .p(px(24.0))
                    .flex()
                    .justify_center()
                    .child(body),
            )
            .into_any_element()
    }
}
