//! macOS generated-image batches. Viewed images retain their upstream rows.
use super::*;
use crate::attachments::{AttachmentSnapshot, GallerySaveReport, GallerySaveSource, PreviewImage};

#[derive(Clone, Debug)]
pub struct GeneratedImageRef {
    pub path: String,
    pub name: String,
    pub mime_type: String,
}

#[derive(Clone)]
pub struct GalleryLightboxState {
    pub owner: String,
    pub images: Arc<Vec<GeneratedImageRef>>,
    pub index: usize,
    pub preview: Option<PreviewImage>,
}

#[derive(Clone)]
pub(super) enum GallerySaveProgress {
    Picking,
    Saving,
    Finished(GallerySaveReport),
    Error(String),
}

#[derive(Clone)]
pub(super) struct GallerySaveState {
    pub(super) signature: u64,
    pub(super) request_id: u64,
    pub(super) progress: GallerySaveProgress,
}

/// Flush consumes the entire run, including successful gallery conversions.
/// The old implementation retained successful runs and repeated earlier images
/// after text boundaries. Owner/entry/fold boundaries are equally significant.
pub(super) fn merge_generated_image_runs(rows: Vec<Row>) -> Vec<Row> {
    fn flush(output: &mut Vec<Row>, run: &mut Vec<Row>) {
        let mut rows = std::mem::take(run);
        if rows.len() < 2 {
            output.append(&mut rows);
            return;
        }
        let head = rows[0].clone();
        let RowKind::GeneratedImage { owner, .. } = &head.kind else {
            unreachable!();
        };
        let mut fingerprint = owner.as_bytes().to_vec();
        let images = rows
            .iter()
            .map(|row| {
                let RowKind::GeneratedImage {
                    path,
                    name,
                    mime_type,
                    ..
                } = &row.kind
                else {
                    unreachable!();
                };
                fingerprint.extend_from_slice(&row.version.to_le_bytes());
                for value in [row.id.as_ref(), path, name, mime_type] {
                    fingerprint.extend_from_slice(value.as_bytes());
                    fingerprint.push(0);
                }
                GeneratedImageRef {
                    path: path.clone(),
                    name: name.clone(),
                    mime_type: mime_type.clone(),
                }
            })
            .collect();
        let tail = rows.last().unwrap();
        output.push(Row {
            id: format!("{}/gallery", head.id).into(),
            version: fnv1a(&fingerprint) | (1 << 63),
            turn_start: head.turn_start,
            kind: RowKind::GeneratedImageGallery {
                owner: owner.clone(),
                images: Arc::new(images),
            },
            entry_id: head.entry_id,
            timestamp: tail.timestamp,
            copy_text: tail.copy_text.clone(),
            compact_fold: head.compact_fold,
            final_answer: head.final_answer,
        });
    }
    let mut output = Vec::with_capacity(rows.len());
    let mut run: Vec<Row> = Vec::new();
    for row in rows {
        if let RowKind::GeneratedImage {
            owner,
            viewed: false,
            ..
        } = &row.kind
        {
            if run.last().is_some_and(|last| {
                let RowKind::GeneratedImage {
                    owner: previous_owner,
                    ..
                } = &last.kind
                else {
                    return true;
                };
                owner != previous_owner
                    || row.entry_id != last.entry_id
                    || row.compact_fold != last.compact_fold
            }) {
                flush(&mut output, &mut run);
            }
            run.push(row);
        } else {
            flush(&mut output, &mut run);
            output.push(row);
        }
    }
    flush(&mut output, &mut run);
    output
}

pub(super) fn source_signature(owner: &str, images: &[GeneratedImageRef]) -> u64 {
    let mut bytes = owner.as_bytes().to_vec();
    for image in images {
        for value in [&image.path, &image.name, &image.mime_type] {
            bytes.push(0);
            bytes.extend_from_slice(value.as_bytes());
        }
    }
    fnv1a(&bytes)
}

impl Transcript {
    pub(super) fn open_gallery_preview(
        &mut self,
        owner: String,
        images: Vec<GeneratedImageRef>,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if images.is_empty() {
            return;
        }
        let index = index.min(images.len() - 1);
        #[cfg(target_os = "macos")]
        self.cancel_pending_viewed_image_preview(cx);
        self.attachment_preview_return_focus = window.focused(cx);
        self.attachment_gallery_preview = Some(GalleryLightboxState {
            owner,
            images: Arc::new(images),
            index,
            preview: None,
        });
        window.focus(&self.attachment_preview_focus, cx);
        cx.notify();
    }

    pub(super) fn render_gallery_preview(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let gallery = self.attachment_gallery_preview.as_ref().unwrap().clone();
        let source = &gallery.images[gallery.index];
        let devices = self.generated_attachment_device_ids(&gallery.owner, cx);
        let mut error = false;
        if gallery.preview.is_none() {
            match self.attachment_state(&devices, &source.path, Some(&source.mime_type), cx) {
                AttachmentSnapshot::Loaded(loaded) => {
                    let weak = cx.weak_entity();
                    let preview = PreviewImage::new(source.name.clone(), loaded.image).annotatable(
                        move |annotated, _, cx| {
                            let _ = weak.update(cx, |this, cx| {
                                this.attachment_gallery_preview = None;
                                cx.emit(TranscriptEvent::StageAnnotated(annotated));
                                cx.notify();
                            });
                        },
                    );
                    // Retain the viewer while this page is open so normal
                    // rerenders preserve zoom, pan and annotation state.
                    self.attachment_gallery_preview.as_mut().unwrap().preview = Some(preview);
                }
                AttachmentSnapshot::Error { .. } => error = true,
                AttachmentSnapshot::Loading => {}
            }
        }
        let preview = self
            .attachment_gallery_preview
            .as_ref()
            .unwrap()
            .preview
            .clone();
        let weak = cx.weak_entity();
        let retry_weak = weak.clone();
        let close_weak = weak.clone();
        let source = source.clone();
        crate::attachments::gallery_lightbox(
            window,
            preview.as_ref(),
            gallery.index,
            gallery.images.len(),
            error,
            &self.attachment_preview_focus,
            move |index, _, cx| {
                let _ = weak.update(cx, |this, cx| {
                    if let Some(gallery) = &mut this.attachment_gallery_preview {
                        if gallery.index != index {
                            gallery.index = index.min(gallery.images.len().saturating_sub(1));
                            gallery.preview = None;
                        }
                    }
                    cx.notify();
                });
            },
            move |_, cx| {
                let _ = retry_weak.update(cx, |this, cx| {
                    this.retry_gallery_image(&devices, &source, cx);
                });
            },
            move |window, cx| {
                if let Ok(Some(focus)) = close_weak.update(cx, |this, cx| {
                    this.attachment_gallery_preview = None;
                    cx.notify();
                    this.attachment_preview_return_focus.take()
                }) {
                    window.focus(&focus, cx);
                }
            },
            cx,
        )
    }

    fn retry_gallery_image(
        &mut self,
        devices: &[String],
        image: &GeneratedImageRef,
        cx: &mut Context<Self>,
    ) {
        for device in devices {
            crate::attachments::retry_attachment_for(&crate::attachments::AttachmentKey::new(
                device,
                &image.path,
                Some(&image.mime_type),
            ));
            self.attachment_retries
                .remove(&(device.clone(), image.path.clone()));
        }
        self.gallery_thumbnails.retry(devices, image, cx);
        cx.notify();
    }

    fn save_generated_gallery(
        &mut self,
        row_id: SharedString,
        signature: u64,
        sources: Vec<GallerySaveSource>,
        new_directory: bool,
        cx: &mut Context<Self>,
    ) {
        if self.gallery_save.get(&row_id).is_some_and(|state| {
            state.signature == signature
                && matches!(
                    state.progress,
                    GallerySaveProgress::Picking | GallerySaveProgress::Saving
                )
        }) {
            return;
        }
        static NEXT_SAVE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let request_id = NEXT_SAVE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let previous = self
            .gallery_save
            .get(&row_id)
            .and_then(|state| match &state.progress {
                GallerySaveProgress::Finished(report)
                    if !new_directory && state.signature == signature && !report.complete() =>
                {
                    Some(report.clone())
                }
                _ => None,
            });
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.gallery_save.insert(
                row_id,
                GallerySaveState {
                    signature,
                    request_id,
                    progress: GallerySaveProgress::Error(
                        "Connect to the image’s computer, then try Save all again.".into(),
                    ),
                },
            );
            cx.notify();
            return;
        };
        let local = self.state.read(cx).local_device_id.clone();
        let receiver = previous.is_none().then(|| {
            cx.prompt_for_paths(gpui::PathPromptOptions {
                files: false,
                directories: true,
                multiple: false,
                prompt: Some("Choose where to save images".into()),
            })
        });
        self.gallery_save.insert(
            row_id.clone(),
            GallerySaveState {
                signature,
                request_id,
                progress: if receiver.is_some() {
                    GallerySaveProgress::Picking
                } else {
                    GallerySaveProgress::Saving
                },
            },
        );
        cx.notify();
        cx.spawn(async move |this, cx| {
            let directory = if let Some(previous) = &previous {
                Some(previous.directory.clone())
            } else {
                match receiver.unwrap().await {
                    Ok(Ok(Some(mut paths))) => paths.pop(),
                    Ok(Ok(None)) => None,
                    error => {
                        let message = format!("Couldn’t choose a save folder: {error:?}");
                        let _ = this.update(cx, |this, cx| {
                            if this.gallery_save.get(&row_id).is_some_and(|state| {
                                state.signature == signature && state.request_id == request_id
                            }) {
                                this.gallery_save.insert(
                                    row_id.clone(),
                                    GallerySaveState {
                                        signature,
                                        request_id,
                                        progress: GallerySaveProgress::Error(message),
                                    },
                                );
                                cx.notify();
                            }
                        });
                        return;
                    }
                }
            };
            let Some(directory) = directory else {
                let _ = this.update(cx, |this, cx| {
                    if this.gallery_save.get(&row_id).is_some_and(|state| {
                        state.signature == signature && state.request_id == request_id
                    }) {
                        this.gallery_save.remove(&row_id);
                        cx.notify();
                    }
                });
                return;
            };
            let proceed = this
                .update(cx, |this, cx| {
                    let Some(state) = this.gallery_save.get_mut(&row_id).filter(|state| {
                        state.signature == signature && state.request_id == request_id
                    }) else {
                        return false;
                    };
                    state.progress = GallerySaveProgress::Saving;
                    cx.notify();
                    true
                })
                .unwrap_or(false);
            if !proceed {
                return;
            }
            let report = crate::attachments::save_gallery_images(
                &engine,
                cx.background_executor(),
                local.as_deref(),
                sources,
                directory,
                previous,
            )
            .await;
            let _ = this.update(cx, |this, cx| {
                this.finish_generated_gallery_save(&row_id, signature, request_id, report, cx);
            });
        })
        .detach();
    }

    pub(super) fn finish_generated_gallery_save(
        &mut self,
        row_id: &SharedString,
        signature: u64,
        request_id: u64,
        report: GallerySaveReport,
        cx: &mut Context<Self>,
    ) {
        if let Some(state) = self
            .gallery_save
            .get_mut(row_id)
            .filter(|state| state.signature == signature && state.request_id == request_id)
        {
            state.progress = GallerySaveProgress::Finished(report);
            cx.notify();
        }
    }

    pub(super) fn render_generated_image_gallery(
        &mut self,
        row_id: &SharedString,
        owner: &str,
        images: &[GeneratedImageRef],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if images.is_empty() {
            return div().into_any_element();
        }
        let devices = self.generated_attachment_device_ids(owner, cx);
        let selected = self
            .gallery_selection
            .get(row_id)
            .copied()
            .unwrap_or(0)
            .min(images.len() - 1);
        let focus = self
            .gallery_focus
            .entry(row_id.clone())
            .or_insert_with(|| cx.focus_handle())
            .clone();
        let scroll = self
            .gallery_scroll
            .entry(row_id.clone())
            .or_default()
            .clone();
        // Only one full preview is requested; thumbnails have their own small
        // bounded cache and never evict/reload a whole batch of 2048px rasters.
        let selected_state = self.attachment_state(
            &devices,
            &images[selected].path,
            Some(&images[selected].mime_type),
            cx,
        );
        if matches!(selected_state, AttachmentSnapshot::Loaded(_)) {
            self.gallery_thumbnails
                .retry(&devices, &images[selected], cx);
        }
        let first_visible = scroll.top_item().saturating_sub(1);
        let last_visible = (first_visible + 8).min(images.len());
        let snapshots: Vec<_> = images
            .iter()
            .enumerate()
            .map(|(index, image)| {
                self.gallery_thumbnail_state(
                    &devices,
                    image,
                    (first_visible..last_visible).contains(&index),
                    cx,
                )
            })
            .collect();
        let signature = source_signature(owner, images);
        if self
            .gallery_save
            .get(row_id)
            .is_some_and(|state| state.signature != signature)
        {
            self.gallery_save.remove(row_id);
        }
        let theme = Theme::of(cx).clone();
        let total = images.len();
        let stage_row_id = row_id.clone();
        let mut stage = div()
            .id(SharedString::from(format!("{row_id}-stage")))
            .debug_selector(move || format!("{stage_row_id}-stage"))
            .relative()
            .flex_1()
            .min_w_0()
            .h_full()
            .rounded(px(12.0))
            .overflow_hidden()
            .bg(crate::theme::ink(0.045))
            .flex()
            .items_center()
            .justify_center();
        stage = match &selected_state {
            AttachmentSnapshot::Loaded(image) => {
                let sources = images.to_vec();
                let owner = owner.to_owned();
                stage
                    .role(gpui::Role::Button)
                    .aria_label(format!(
                        "Preview generated image {} of {}",
                        selected + 1,
                        total
                    ))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open_gallery_preview(
                            owner.clone(),
                            sources.clone(),
                            selected,
                            window,
                            cx,
                        );
                    }))
                    .child(
                        img(image.image.clone())
                            .size_full()
                            .object_fit(ObjectFit::Contain)
                            .rounded(px(12.0)),
                    )
            }
            AttachmentSnapshot::Loading => stage
                .text_color(theme.text_muted)
                .child("Loading generated image…"),
            AttachmentSnapshot::Error { .. } => {
                let source = images[selected].clone();
                let devices = devices.clone();
                let retry_id = row_id.clone();
                let retry_action =
                    Rc::new(move |this: &mut Transcript, cx: &mut Context<Transcript>| {
                        this.retry_gallery_image(&devices, &source, cx);
                    });
                let retry_key = retry_action.clone();
                stage
                    .flex_col()
                    .gap(px(12.0))
                    .px(px(12.0))
                    .text_color(theme.text_muted)
                    .child("Generated image unavailable")
                    .child(
                        div()
                            .id(SharedString::from(format!("{row_id}-retry")))
                            .debug_selector(move || format!("{retry_id}-retry"))
                            .role(gpui::Role::Button)
                            .aria_label("Retry loading image")
                            .tab_index(0)
                            .px(px(12.0))
                            .py(px(6.0))
                            .rounded(px(8.0))
                            .bg(theme.element_hover)
                            .cursor_pointer()
                            .child("Retry")
                            .focus_visible(move |style| style.border_1().border_color(theme.accent))
                            .on_click(cx.listener(move |this, _, _, cx| retry_action(this, cx)))
                            .on_key_down(cx.listener(
                                move |this, event: &gpui::KeyDownEvent, _, cx| {
                                    if matches!(
                                        event.keystroke.key.as_str(),
                                        "enter" | "return" | "space"
                                    ) {
                                        retry_key(this, cx);
                                        cx.stop_propagation();
                                    }
                                },
                            )),
                    )
            }
        };
        let count = div()
            .absolute()
            .top(px(8.0))
            .right(px(8.0))
            .rounded_full()
            .bg(crate::popover::scrim_alpha(0.6))
            .px(px(9.0))
            .py(px(3.0))
            .text_size(crate::typography::ui_rems(11.0))
            .text_color(gpui::white())
            .child(format!("{} / {}", selected + 1, total));
        let rail = div()
            .id(SharedString::from(format!("{row_id}-rail")))
            .flex()
            .flex_col()
            .gap(px(8.0))
            .w(px(56.0))
            .h_full()
            .flex_shrink_0()
            .overflow_y_scroll()
            .track_scroll(&scroll)
            .children(snapshots.iter().enumerate().map(|(index, snapshot)| {
                let id = row_id.clone();
                let debug_id = row_id.clone();
                let focus = focus.clone();
                let scroll = scroll.clone();
                let mut thumbnail = div()
                    .id(SharedString::from(format!("{row_id}-thumb-{index}")))
                    .debug_selector(move || format!("{debug_id}-thumb-{index}"))
                    .size(px(56.0))
                    .flex_shrink_0()
                    .rounded(px(10.0))
                    .overflow_hidden()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(crate::theme::ink(0.045))
                    .role(gpui::Role::Button)
                    .aria_label(format!(
                        "Show generated image {}: {}",
                        index + 1,
                        images[index].name
                    ))
                    .cursor_pointer()
                    .border_2()
                    .border_color(if index == selected {
                        theme.accent
                    } else {
                        crate::theme::ink(0.07)
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.gallery_selection.insert(id.clone(), index);
                        scroll.scroll_to_item(index);
                        window.focus(&focus, cx);
                        cx.notify();
                    }));
                thumbnail = match snapshot {
                    AttachmentSnapshot::Loaded(loaded) => thumbnail.child(
                        img(loaded.image.clone())
                            .size_full()
                            .object_fit(ObjectFit::Cover)
                            .rounded(px(8.0)),
                    ),
                    AttachmentSnapshot::Loading => {
                        thumbnail.text_color(theme.text_muted).child("…")
                    }
                    AttachmentSnapshot::Error { .. } => thumbnail
                        .text_color(theme.text_muted)
                        .child(format!("{}", index + 1)),
                };
                thumbnail
            }));
        let key_id = row_id.clone();
        let key_scroll = scroll;
        let key_sources = images.to_vec();
        let key_owner = owner.to_owned();
        let card = div()
            .id(SharedString::from(format!("{row_id}-card")))
            .w_full()
            .h(px(340.0))
            .min_w_0()
            .flex()
            .gap(px(8.0))
            .track_focus(&focus)
            .tab_index(0)
            .role(gpui::Role::Group)
            .aria_label(format!(
                "{} generated images; use arrow keys to choose and Enter to preview",
                total
            ))
            .focus_visible(move |style| {
                style
                    .rounded(px(12.0))
                    .border_1()
                    .border_color(theme.accent)
            })
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    let current = this
                        .gallery_selection
                        .get(&key_id)
                        .copied()
                        .unwrap_or(0)
                        .min(total - 1);
                    let next = match event.keystroke.key.as_str() {
                        "down" | "arrowdown" | "right" | "arrowright" => {
                            Some((current + 1).min(total - 1))
                        }
                        "up" | "arrowup" | "left" | "arrowleft" => Some(current.saturating_sub(1)),
                        "home" => Some(0),
                        "end" => Some(total - 1),
                        "enter" | "return" | "space" => {
                            this.open_gallery_preview(
                                key_owner.clone(),
                                key_sources.clone(),
                                current,
                                window,
                                cx,
                            );
                            cx.stop_propagation();
                            return;
                        }
                        _ => None,
                    };
                    if let Some(next) = next {
                        this.gallery_selection.insert(key_id.clone(), next);
                        key_scroll.scroll_to_item(next);
                        cx.stop_propagation();
                        cx.notify();
                    }
                }),
            )
            .child(stage.child(count))
            .child(rail);
        // Original-file export fetches each source independently. It must not
        // depend on every thumbnail being resident in the preview cache.
        let complete = true;
        let progress = self
            .gallery_save
            .get(row_id)
            .map(|state| state.progress.clone());
        let busy = matches!(
            progress,
            Some(GallerySaveProgress::Picking | GallerySaveProgress::Saving)
        );
        let retry =
            matches!(&progress, Some(GallerySaveProgress::Finished(report)) if !report.complete());
        let label = if busy {
            "Saving…"
        } else if retry {
            "Retry save"
        } else {
            "Save all"
        };
        let source_owner = owner.to_owned();
        let sources: Vec<_> = images
            .iter()
            .enumerate()
            .map(|(index, image)| GallerySaveSource {
                id: format!("{}\0{}\0{}", source_owner, index, image.path),
                path: image.path.clone(),
                name: image.name.clone(),
                mime_type: image.mime_type.clone(),
                device_ids: devices.clone(),
            })
            .collect();
        let save_id = row_id.clone();
        let on_save = Rc::new(
            move |this: &mut Transcript, new_directory, cx: &mut Context<Transcript>| {
                this.save_generated_gallery(
                    save_id.clone(),
                    signature,
                    sources.clone(),
                    new_directory,
                    cx,
                );
            },
        );
        let save_click = on_save.clone();
        let save_key = on_save.clone();
        let folder_click = on_save.clone();
        let folder_key = on_save;
        let debug_id = row_id.clone();
        let save = div()
            .id(SharedString::from(format!("{row_id}-save-all")))
            .debug_selector(move || format!("{debug_id}-save-all"))
            .role(gpui::Role::Button)
            .aria_label(if retry {
                "Retry saving remaining images".into()
            } else {
                format!("Save all {} original images", total)
            })
            .px(px(12.0))
            .py(px(6.0))
            .rounded(px(8.0))
            .text_size(crate::typography::ui_rems(12.0))
            .bg(theme.element_hover)
            .text_color(if complete && !busy {
                theme.text
            } else {
                theme.text_muted
            })
            .child(label)
            .when(complete && !busy, |button| {
                button
                    .cursor_pointer()
                    .tab_index(0)
                    .focus_visible(move |style| style.border_1().border_color(theme.accent))
                    .on_click(cx.listener(move |this, _, _, cx| save_click(this, false, cx)))
                    .on_key_down(cx.listener(move |this, event: &gpui::KeyDownEvent, _, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "return" | "space") {
                            save_key(this, false, cx);
                            cx.stop_propagation();
                        }
                    }))
            });
        let actions = div()
            .w_full()
            .flex()
            .flex_wrap()
            .gap(px(8.0))
            .child(save)
            .when(retry && !busy && complete, |actions| {
                actions.child(
                    div()
                        .id(SharedString::from(format!("{row_id}-save-elsewhere")))
                        .role(gpui::Role::Button)
                        .aria_label("Choose another folder")
                        .tab_index(0)
                        .px(px(10.0))
                        .py(px(6.0))
                        .rounded(px(8.0))
                        .text_size(crate::typography::ui_rems(12.0))
                        .text_color(theme.text_muted)
                        .cursor_pointer()
                        .child("Choose another folder")
                        .focus_visible(move |style| style.border_1().border_color(theme.accent))
                        .on_click(cx.listener(move |this, _, _, cx| folder_click(this, true, cx)))
                        .on_key_down(cx.listener(
                            move |this, event: &gpui::KeyDownEvent, _, cx| {
                                if matches!(
                                    event.keystroke.key.as_str(),
                                    "enter" | "return" | "space"
                                ) {
                                    folder_key(this, true, cx);
                                    cx.stop_propagation();
                                }
                            },
                        )),
                )
            });
        let status = match progress {
            Some(GallerySaveProgress::Finished(report)) if report.complete() => {
                format!("Saved {} images", report.saved.len())
            }
            Some(GallerySaveProgress::Finished(report)) => format!(
                "Saved {} of {} images. {}",
                report.saved.len(),
                report.total,
                report
                    .failures
                    .first()
                    .map(|failure| failure.message.as_str())
                    .unwrap_or("Some images couldn’t be saved.")
            ),
            Some(GallerySaveProgress::Error(message)) => message,
            Some(GallerySaveProgress::Picking) => {
                "Choose a folder to save the original images.".into()
            }
            Some(GallerySaveProgress::Saving) => "Saving original images…".into(),
            None => String::new(),
        };
        div()
            .w(px(512.0))
            .max_w_full()
            .min_w_0()
            .flex()
            .flex_col()
            .gap(px(8.0))
            .child(card)
            .child(actions)
            .when(!status.is_empty(), |root| {
                root.child(
                    div()
                        .w_full()
                        .min_w_0()
                        .text_size(crate::typography::ui_rems(12.0))
                        .text_color(theme.text_muted)
                        .child(status),
                )
            })
            .into_any_element()
    }
}
