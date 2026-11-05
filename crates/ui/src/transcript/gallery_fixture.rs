//! Synthetic native comparison of the unchanged individual-image renderer and
//! the repaired gallery. No account, transcript, engine or network is involved.
use super::*;

const OWNER: &str = "synthetic-gallery-owner";
const GALLERY: &str = "fixture-gallery";

pub struct GalleryReview {
    transcript: Entity<Transcript>,
    images: Vec<GeneratedImageRef>,
    previews: Vec<crate::attachments::PreviewImage>,
    phase: String,
    _subscription: Subscription,
}

impl GalleryReview {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let state = cx.new(|_| AppState::new());
        let transcript = cx.new(|cx| Transcript::new(state, cx));
        let subscription = cx.observe(&transcript, |_, _, cx| cx.notify());
        let mut images = Vec::new();
        let mut previews = Vec::new();
        let colors = [[37, 106, 111], [166, 100, 61], [89, 91, 158], [82, 124, 82]];
        for (index, color) in colors.into_iter().enumerate() {
            // Literal test boards: colored panes and geometry, not pretend
            // photographs or generated product examples.
            let mut bitmap =
                image::RgbaImage::from_pixel(720, 460, image::Rgba([243, 240, 232, 255]));
            for (x, y, pixel) in bitmap.enumerate_pixels_mut() {
                if (30..690).contains(&x) && (30..310).contains(&y) {
                    *pixel = image::Rgba([color[0], color[1], color[2], 255]);
                }
                if (55..260).contains(&x) && (55..74).contains(&y) {
                    *pixel = image::Rgba([240, 236, 221, 255]);
                }
                if (55..(350 + index as u32 * 40)).contains(&x) && (245..266).contains(&y) {
                    *pixel = image::Rgba([222, 220, 200, 255]);
                }
                if (30..330).contains(&x) && (337..359).contains(&y) {
                    *pixel = image::Rgba([61, 60, 55, 255]);
                }
                if (30..600).contains(&x) && ((376..386).contains(&y) || (398..408).contains(&y)) {
                    *pixel = image::Rgba([190, 186, 175, 255]);
                }
                // A different number of square marks makes thumbnails
                // distinguishable without relying on color alone.
                for mark in 0..=index as u32 {
                    let left = 55 + mark * 62;
                    if (left..left + 40).contains(&x) && (112..152).contains(&y) {
                        *pixel = image::Rgba([240, 236, 221, 255]);
                    }
                }
            }
            let mut encoded = std::io::Cursor::new(Vec::new());
            image::DynamicImage::ImageRgba8(bitmap)
                .write_to(&mut encoded, image::ImageFormat::Png)
                .expect("encode synthetic image");
            let image = Arc::new(gpui::Image::from_bytes(
                gpui::ImageFormat::Png,
                encoded.into_inner(),
            ));
            let reference = GeneratedImageRef {
                path: format!("/synthetic/gallery-{index}.png"),
                name: format!("Concept {}.png", index + 1),
                mime_type: "image/png".into(),
            };
            crate::attachments::store_loaded_for(
                &crate::attachments::AttachmentKey::new(OWNER, &reference.path, Some("image/png")),
                reference.name.clone().into(),
                image.clone(),
            );
            previews.push(crate::attachments::PreviewImage::new(
                reference.name.clone(),
                image,
            ));
            images.push(reference);
        }
        Self {
            transcript,
            images,
            previews,
            phase: "comparison".into(),
            _subscription: subscription,
        }
    }

    pub fn set_phase(&mut self, phase: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.phase = phase.into();
        for (index, (reference, preview)) in self.images.iter_mut().zip(&self.previews).enumerate()
        {
            reference.path = format!("/synthetic/gallery-{index}.png");
            crate::attachments::store_loaded_for(
                &crate::attachments::AttachmentKey::new(OWNER, &reference.path, Some("image/png")),
                reference.name.clone().into(),
                preview.image.clone(),
            );
        }
        if phase == "unavailable" {
            crate::attachments::store_error_for(&crate::attachments::AttachmentKey::new(
                OWNER,
                &self.images[0].path,
                Some("image/png"),
            ));
        }
        if phase == "loading" {
            self.images[0].path = format!(
                "/synthetic/gallery-loading-{}.png",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            );
            crate::attachments::begin_load_for(&crate::attachments::AttachmentKey::new(
                OWNER,
                &self.images[0].path,
                Some("image/png"),
            ));
        }
        let mut signature = OWNER.as_bytes().to_vec();
        for image in &self.images {
            for value in [&image.path, &image.name, &image.mime_type] {
                signature.push(0);
                signature.extend_from_slice(value.as_bytes());
            }
        }
        let signature = fnv1a(&signature);
        let images = self.images.clone();
        self.transcript.update(cx, |transcript, cx| {
            transcript.attachment_gallery_preview = None;
            transcript.gallery_thumbnails.clear(cx);
            transcript.gallery_save.clear();
            if phase == "save-partial" {
                transcript.gallery_save.insert(
                    GALLERY.into(),
                    gallery::GallerySaveState {
                        signature,
                        request_id: 0,
                        progress: gallery::GallerySaveProgress::Finished(
                            crate::attachments::GallerySaveReport::fixture_partial(2, 4),
                        ),
                    },
                );
            }
            transcript
                .gallery_selection
                .insert(GALLERY.into(), if phase == "selected" { 2 } else { 0 });
            if phase == "lightbox" {
                transcript.open_gallery_preview(OWNER.into(), images, 2, window, cx);
            }
            cx.notify();
        });
        cx.notify();
    }

    /// Assert the actual row accumulator consumes both image runs once and
    /// preserves the text between them. This also feeds the boundary screenshot.
    fn boundary_rows(&self) -> Vec<Row> {
        let mut rows = Vec::new();
        for (index, image) in self.images.iter().enumerate() {
            if index == 2 {
                rows.push(Row {
                    id: "fixture-text".into(),
                    version: 1,
                    turn_start: false,
                    kind: RowKind::Markdown {
                        tree: Arc::new(parse_full("Here are two more directions.")),
                        block_ix: 0,
                    },
                    entry_id: "fixture-response".into(),
                    timestamp: None,
                    copy_text: None,
                    compact_fold: None,
                    final_answer: None,
                });
            }
            rows.push(Row {
                id: format!("fixture-image-{index}").into(),
                version: 1,
                turn_start: index == 0,
                kind: RowKind::GeneratedImage {
                    owner: OWNER.into(),
                    path: image.path.clone(),
                    name: image.name.clone(),
                    mime_type: image.mime_type.clone(),
                    viewed: false,
                },
                entry_id: "fixture-response".into(),
                timestamp: None,
                copy_text: None,
                compact_fold: None,
                final_answer: None,
            });
        }
        let rows = merge_generated_image_runs(rows);
        assert_eq!(rows.len(), 3, "two galleries and one text boundary");
        assert!(
            matches!(&rows[0].kind, RowKind::GeneratedImageGallery { images, .. } if images.len() == 2)
        );
        assert!(matches!(&rows[1].kind, RowKind::Markdown { .. }));
        assert!(
            matches!(&rows[2].kind, RowKind::GeneratedImageGallery { images, .. } if images.len() == 2)
        );
        rows
    }

    fn heading(title: &str, subtitle: &str, theme: &Theme) -> gpui::Div {
        div()
            .flex()
            .flex_col()
            .gap(px(6.0))
            .child(
                div()
                    .text_size(crate::typography::ui_rems(18.0))
                    .child(title.to_owned()),
            )
            .child(
                div()
                    .text_size(crate::typography::ui_rems(12.0))
                    .text_color(theme.text_muted)
                    .child(subtitle.to_owned()),
            )
    }

    fn gallery(&self, cx: &mut Context<Self>) -> AnyElement {
        self.transcript.update(cx, |transcript, cx| {
            transcript.render_generated_image_gallery(&GALLERY.into(), OWNER, &self.images, cx)
        })
    }
}

impl Render for GalleryReview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        if self.phase == "lightbox" {
            return self.transcript.clone().into_any_element();
        }
        let mut body = div()
            .id("gallery-review-content")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .gap(px(32.0));
        if self.phase == "comparison" {
            let mut baseline = div()
                .w(px(512.0))
                .flex_shrink_0()
                .flex()
                .flex_col()
                .gap(px(20.0))
                .child(Self::heading(
                    "Separate images",
                    "Upstream 0.2.155 presentation",
                    &theme,
                ));
            for (index, image) in self.images.iter().enumerate() {
                baseline = baseline.child(self.transcript.update(cx, |transcript, cx| {
                    transcript.render_generated_image(
                        &format!("baseline-{index}").into(),
                        OWNER,
                        &image.path,
                        &image.name,
                        &image.mime_type,
                        false,
                        cx,
                    )
                }));
            }
            body = body.child(baseline).child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(20.0))
                    .child(Self::heading(
                        "Your gallery",
                        "One preview with thumbnails and Save all",
                        &theme,
                    ))
                    .child(self.gallery(cx)),
            );
        } else if self.phase == "boundary" {
            let mut groups = div().w_full().flex().flex_col().gap(px(18.0));
            for row in self.boundary_rows() {
                match row.kind {
                    RowKind::GeneratedImageGallery { owner, images } => {
                        groups = groups.child(self.transcript.update(cx, |transcript, cx| {
                            transcript.render_generated_image_gallery(&row.id, &owner, &images, cx)
                        }))
                    }
                    _ => {
                        groups = groups.child(
                            div()
                                .text_size(crate::typography::ui_rems(15.0))
                                .child("Here are two more directions."),
                        )
                    }
                }
            }
            body = body.child(groups);
        } else if self.phase == "single" {
            let image = &self.images[0];
            body = body.child(self.transcript.update(cx, |transcript, cx| {
                transcript.render_generated_image(
                    &"single".into(),
                    OWNER,
                    &image.path,
                    &image.name,
                    &image.mime_type,
                    false,
                    cx,
                )
            }));
        } else {
            body = body.child(self.gallery(cx));
        }
        div()
            .size_full()
            .bg(theme.surface)
            .text_color(theme.text)
            .font_family(crate::typography::effective_family_name(cx))
            .p(px(28.0))
            .flex()
            .flex_col()
            .gap(px(28.0))
            .child(Self::heading(
                if self.phase == "comparison" {
                    "Four images from one response"
                } else if self.phase == "boundary" {
                    "Text separates the two image groups"
                } else if self.phase == "single" {
                    "A single image stays simple"
                } else {
                    "Generated images"
                },
                "Native component review · synthetic image fixtures",
                &theme,
            ))
            .child(body)
            .into_any_element()
    }
}
