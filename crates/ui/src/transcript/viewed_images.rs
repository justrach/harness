//! Mac image-read disclosures: small thumbnails on demand, original preview on click.
//! A read is not a new generated result. Its source computer remains authoritative.
use super::*;
use crate::attachments::{AttachmentKey, AttachmentSnapshot, PreviewImage};

#[derive(Clone, Debug)]
pub(super) struct ViewedImageSource {
    owner: String,
    image: GeneratedImageRef,
}

impl PartialEq for ViewedImageSource {
    fn eq(&self, other: &Self) -> bool {
        self.owner == other.owner
            && self.image.path == other.image.path
            && self.image.name == other.image.name
            && self.image.mime_type == other.image.mime_type
    }
}
impl Eq for ViewedImageSource {}

impl ViewedImageSource {
    fn new(owner: &str, path: &str, name: &str, mime_type: &str) -> Self {
        Self {
            owner: owner.into(),
            image: GeneratedImageRef {
                path: path.into(),
                name: name.into(),
                mime_type: mime_type.into(),
            },
        }
    }

    fn from_row(row: &Row) -> Option<Self> {
        match &row.kind {
            RowKind::GeneratedImage {
                owner,
                path,
                name,
                mime_type,
                viewed: true,
            } => Some(Self::new(owner, path, name, mime_type)),
            _ => None,
        }
    }

    fn devices(&self, fallback: &[String]) -> Vec<String> {
        if self.owner.is_empty() {
            generated_image_devices("", fallback)
        } else {
            // A coincidentally identical path on a different computer is not
            // the image the agent read. Do not substitute it after a failure.
            vec![self.owner.clone()]
        }
    }
}

pub(super) struct ViewedImageDisclosure {
    source: ViewedImageSource,
    open: bool,
    focus: gpui::FocusHandle,
    thumbnail_focus: gpui::FocusHandle,
}

pub(super) struct ViewedImagePreview {
    row: SharedString,
    source: ViewedImageSource,
    failed: bool,
}

pub(super) fn prune_viewed_images(
    disclosures: &mut HashMap<SharedString, ViewedImageDisclosure>,
    pending: &mut Option<ViewedImagePreview>,
    rows: &[Row],
) {
    let sources: HashMap<_, _> = rows
        .iter()
        .filter_map(|row| ViewedImageSource::from_row(row).map(|source| (row.id.clone(), source)))
        .collect();
    disclosures.retain(|row, disclosure| sources.get(row) == Some(&disclosure.source));
    if pending
        .as_ref()
        .is_some_and(|preview| sources.get(&preview.row) != Some(&preview.source))
    {
        *pending = None;
    }
}

impl Transcript {
    fn toggle_viewed_image(&mut self, row: &SharedString, cx: &mut Context<Self>) {
        if let Some(disclosure) = self.viewed_images.get_mut(row) {
            disclosure.open = !disclosure.open;
            if !disclosure.open
                && self
                    .pending_viewed_image
                    .as_ref()
                    .is_some_and(|p| &p.row == row)
            {
                self.pending_viewed_image = None;
            }
            self.remeasure_row(row);
            cx.notify();
        }
    }

    fn begin_viewed_image_preview(
        &mut self,
        row: SharedString,
        source: ViewedImageSource,
        focus: &gpui::FocusHandle,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let devices = source.devices(&self.generated_attachment_device_ids(&source.owner, cx));
        for device in &devices {
            crate::attachments::retry_attachment_for(&AttachmentKey::new(
                device,
                &source.image.path,
                Some(&source.image.mime_type),
            ));
            self.attachment_retries
                .remove(&(device.clone(), source.image.path.clone()));
        }
        window.focus(focus, cx);
        self.attachment_preview_return_focus = Some(focus.clone());
        self.remeasure_row(&row);
        self.pending_viewed_image = Some(ViewedImagePreview {
            row,
            source,
            failed: false,
        });
        cx.notify();
    }

    pub(super) fn cancel_pending_viewed_image_preview(&mut self, cx: &mut Context<Self>) {
        if let Some(pending) = self.pending_viewed_image.take() {
            self.remeasure_row(&pending.row);
            cx.notify();
        }
    }

    pub(super) fn resolve_viewed_image_preview(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // A newer preview owns the lightbox. A delayed read must not replace it
        // or survive behind a gallery and appear when that gallery closes.
        if self.attachment_preview.is_some() || self.attachment_gallery_preview.is_some() {
            self.cancel_pending_viewed_image_preview(cx);
            return;
        }
        let Some(pending) = &self.pending_viewed_image else {
            return;
        };
        if pending.failed {
            return;
        }
        let source = pending.source.clone();
        let row = pending.row.clone();
        let devices = source.devices(&self.generated_attachment_device_ids(&source.owner, cx));
        match self.attachment_state(
            &devices,
            &source.image.path,
            Some(&source.image.mime_type),
            cx,
        ) {
            AttachmentSnapshot::Loaded(loaded) => {
                self.pending_viewed_image = None;
                self.remeasure_row(&row);
                self.attachment_preview = Some(PreviewImage::new(source.image.name, loaded.image));
                // The ordinary transcript render adds the existing annotation
                // hook; its close callback restores thumbnail focus.
                window.focus(&self.attachment_preview_focus, cx);
                cx.notify();
            }
            AttachmentSnapshot::Error { .. } => {
                if let Some(pending) = &mut self.pending_viewed_image {
                    pending.failed = true;
                }
                self.remeasure_row(&row);
                cx.notify();
            }
            AttachmentSnapshot::Loading => {}
        }
    }

    pub(super) fn render_viewed_image(
        &mut self,
        row: &SharedString,
        owner: &str,
        path: &str,
        name: &str,
        mime_type: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let source = ViewedImageSource::new(owner, path, name, mime_type);
        let disclosure =
            self.viewed_images
                .entry(row.clone())
                .or_insert_with(|| ViewedImageDisclosure {
                    source: source.clone(),
                    open: false,
                    focus: cx.focus_handle(),
                    thumbnail_focus: cx.focus_handle(),
                });
        if disclosure.source != source {
            disclosure.source = source.clone();
            disclosure.open = false;
        }
        let (open, focus, thumbnail_focus) = (
            disclosure.open,
            disclosure.focus.clone(),
            disclosure.thumbnail_focus.clone(),
        );
        let theme = Theme::of(cx).clone();
        let click_row = row.clone();
        let key_row = row.clone();
        let accent = theme.accent;
        let header = div()
            .id(SharedString::from(format!("{row}-viewed-toggle")))
            .debug_selector(|| "transcript-viewed-image-toggle".into())
            .track_focus(&focus)
            .tab_index(0)
            .role(gpui::Role::Button)
            .aria_label("Viewed an image")
            .aria_expanded(open)
            .h(px(28.0))
            .flex()
            .items_center()
            .gap(px(6.0))
            .self_start()
            .text_size(px(TOOL_LABEL_SIZE))
            .text_color(theme.text_muted)
            .cursor_pointer()
            .rounded(px(4.0))
            .hover(|s| s.text_color(theme.text))
            .focus_visible(move |s| s.border_1().border_color(accent))
            .child(
                crate::icons::icon(crate::icons::FILE_IMAGE)
                    .size(px(15.0))
                    .text_color(theme.text_muted),
            )
            .child("Viewed an image")
            .child(
                crate::icons::icon(if open {
                    crate::icons::ALT_ARROW_DOWN
                } else {
                    crate::icons::ALT_ARROW_RIGHT
                })
                .size(px(12.0))
                .text_color(theme.text_muted),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                this.toggle_viewed_image(&click_row, cx);
            }))
            .on_key_down(cx.listener(move |this, event: &gpui::KeyDownEvent, _, cx| {
                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                    cx.stop_propagation();
                    this.toggle_viewed_image(&key_row, cx);
                }
            }));
        let root = div().flex().flex_col().gap(px(6.0)).child(header);
        if !open {
            return root.into_any_element();
        }

        let devices = source.devices(&self.generated_attachment_device_ids(owner, cx));
        // Reuse the 128px/64-entry/two-load thumbnail cache. Merely opening a
        // disclosure does not load another full-size preview into the cache.
        let snapshot = self.gallery_thumbnail_state(&devices, &source.image, true, cx);
        let frame = div()
            .w(px(128.0))
            .h(px(96.0))
            .max_w_full()
            .rounded(px(8.0))
            .overflow_hidden()
            .flex()
            .items_center()
            .justify_center()
            .bg(crate::theme::ink(0.045));
        let body = match snapshot {
            AttachmentSnapshot::Loaded(loaded) => {
                let click_source = source.clone();
                let key_source = source.clone();
                let click_row = row.clone();
                let key_row = row.clone();
                let click_focus = thumbnail_focus.clone();
                let key_focus = thumbnail_focus.clone();
                frame
                    .id(SharedString::from(format!("{row}-viewed-thumbnail")))
                    .debug_selector(|| "transcript-viewed-image-thumbnail".into())
                    .track_focus(&thumbnail_focus)
                    .tab_index(0)
                    .role(gpui::Role::Button)
                    .aria_label(SharedString::from(format!("Preview {name}")))
                    .cursor_pointer()
                    .focus_visible(move |s| s.border_2().border_color(accent))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        cx.stop_propagation();
                        this.begin_viewed_image_preview(
                            click_row.clone(),
                            click_source.clone(),
                            &click_focus,
                            window,
                            cx,
                        );
                    }))
                    .on_key_down(cx.listener(
                        move |this, event: &gpui::KeyDownEvent, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                cx.stop_propagation();
                                this.begin_viewed_image_preview(
                                    key_row.clone(),
                                    key_source.clone(),
                                    &key_focus,
                                    window,
                                    cx,
                                );
                            }
                        },
                    ))
                    .child(
                        gpui::img(loaded.image)
                            .size_full()
                            .rounded(px(8.0))
                            .object_fit(gpui::ObjectFit::Contain),
                    )
                    .into_any_element()
            }
            AttachmentSnapshot::Loading => frame
                .text_size(px(12.0))
                .text_color(theme.text_muted)
                .child("Loading image…")
                .into_any_element(),
            AttachmentSnapshot::Error { .. } => {
                let retry_source = source.clone();
                let retry_devices = devices.clone();
                let key_source = source.clone();
                let key_devices = devices.clone();
                frame
                    .flex_col()
                    .gap(px(4.0))
                    .text_size(px(12.0))
                    .text_color(theme.text_muted)
                    .child("Image unavailable")
                    .child(
                        crate::popover::btn_ghost(
                            &theme,
                            "Retry",
                            SharedString::from(format!("{row}-retry")),
                        )
                        .id(SharedString::from(format!("{row}-viewed-retry")))
                        .debug_selector(|| "transcript-viewed-image-retry".into())
                        .role(gpui::Role::Button)
                        .aria_label("Retry image thumbnail")
                        .tab_index(0)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            cx.stop_propagation();
                            this.gallery_thumbnails
                                .retry(&retry_devices, &retry_source.image, cx);
                            cx.notify();
                        }))
                        .on_key_down(cx.listener(
                            move |this, event: &gpui::KeyDownEvent, _, cx| {
                                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                    cx.stop_propagation();
                                    this.gallery_thumbnails.retry(
                                        &key_devices,
                                        &key_source.image,
                                        cx,
                                    );
                                    cx.notify();
                                }
                            },
                        )),
                    )
                    .into_any_element()
            }
        };
        let opening = self
            .pending_viewed_image
            .as_ref()
            .filter(|p| p.row == *row && p.source == source);
        root.child(
            div()
                .pl(px(21.0))
                .flex()
                .flex_col()
                .gap(px(5.0))
                .child(body)
                .when_some(opening, |body, pending| {
                    body.child(
                        div()
                            .text_size(px(12.0))
                            .text_color(theme.text_muted)
                            .child(if pending.failed {
                                "Full-size image unavailable. Click the thumbnail to retry."
                            } else {
                                "Opening image…"
                            }),
                    )
                }),
        )
        .into_any_element()
    }
}

#[cfg(test)]
#[path = "viewed_images/tests.rs"]
mod tests;

#[cfg(feature = "appshots-fixture")]
#[path = "viewed_images/fixture.rs"]
pub mod fixture;
