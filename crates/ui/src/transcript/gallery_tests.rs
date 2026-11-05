use super::*;

fn image(id: &str) -> MessagePart {
    MessagePart::Image {
        id: id.into(),
        path: format!("/gallery-test/{id}.png"),
        name: format!("{id}.png"),
        mime_type: "image/png".into(),
    }
}
fn text(id: &str) -> MessagePart {
    MessagePart::Text {
        id: id.into(),
        text: format!("Text boundary {id}"),
    }
}
fn entry(parts: Vec<MessagePart>, streaming: bool) -> SessionMessageEntry {
    SessionMessageEntry {
        id: "gallery-entry".into(),
        role: MessageRole::Assistant,
        parts,
        created_at: 12,
        device_id: "gallery-owner".into(),
        status: Some(if streaming {
            MessageStatus::Streaming
        } else {
            MessageStatus::Complete
        }),
        continuation_of: None,
        duration_ms: None,
    }
}
fn rows(entry: &SessionMessageEntry) -> Vec<Row> {
    rows_for_entry(entry, false, false, &mut |_, text| {
        Arc::new(parse_full(text))
    })
}
fn paths(rows: &[Row]) -> Vec<String> {
    rows.iter()
        .flat_map(|row| match &row.kind {
            RowKind::GeneratedImage { path, .. } => vec![path.clone()],
            RowKind::GeneratedImageGallery { images, .. } => {
                images.iter().map(|image| image.path.clone()).collect()
            }
            _ => Vec::new(),
        })
        .collect()
}

#[test]
fn gallery_flush_consumes_each_batch_and_preserves_intervening_text() {
    let entry = entry(
        vec![
            image("a"),
            image("b"),
            text("between"),
            image("c"),
            image("d"),
            text("after"),
        ],
        false,
    );
    let result = rows(&entry);
    assert_eq!(result.len(), 4);
    assert!(matches!(
        result[0].kind,
        RowKind::GeneratedImageGallery { .. }
    ));
    assert!(matches!(result[1].kind, RowKind::Markdown { .. }));
    assert!(matches!(
        result[2].kind,
        RowKind::GeneratedImageGallery { .. }
    ));
    assert!(matches!(result[3].kind, RowKind::Markdown { .. }));
    assert_eq!(
        paths(&result),
        ["a", "b", "c", "d"].map(|id| format!("/gallery-test/{id}.png"))
    );
    assert!(result[0].turn_start);
    assert!(result[3].timestamp.is_some());
    assert_eq!(
        result.iter().filter(|row| row.copy_text.is_some()).count(),
        1
    );
    let again = merge_generated_image_runs(result.clone());
    assert_eq!(paths(&again), paths(&result));
    assert_eq!(again.len(), result.len());
}

#[test]
fn gallery_streaming_append_retains_identity_and_invalidates_content() {
    let mut source = entry(vec![image("a"), image("b")], true);
    let initial = rows(&source);
    source.parts.push(image("c"));
    let appended = rows(&source);
    assert_eq!(initial[0].id, appended[0].id);
    assert_ne!(initial[0].version, appended[0].version);
    assert_eq!(paths(&appended).len(), 3);
    assert_eq!(rows(&source)[0].version, appended[0].version);
    source.status = Some(MessageStatus::Complete);
    let complete = rows(&source);
    assert_eq!(complete[0].id, appended[0].id);
    assert!(complete[0].timestamp.is_some());
    if let MessagePart::Image { name, .. } = &mut source.parts[1] {
        *name = "corrected.png".into();
    }
    assert_ne!(rows(&source)[0].version, complete[0].version);
}

#[test]
fn gallery_single_images_and_viewed_inputs_remain_plain() {
    let single = rows(&entry(vec![image("a")], false));
    assert!(matches!(
        single[0].kind,
        RowKind::GeneratedImage { viewed: false, .. }
    ));
    let mut viewed = single[0].clone();
    if let RowKind::GeneratedImage { viewed, .. } = &mut viewed.kind {
        *viewed = true;
    }
    let result = merge_generated_image_runs(vec![
        single[0].clone(),
        viewed.clone(),
        single[0].clone(),
        viewed,
    ]);
    assert_eq!(result.len(), 4);
    assert!(
        result
            .iter()
            .all(|row| matches!(row.kind, RowKind::GeneratedImage { .. }))
    );
}

#[test]
fn gallery_never_crosses_owner_entry_or_fold_boundaries() {
    let original = rows(&entry(vec![image("a")], false))[0].clone();
    for boundary in 0..3 {
        let mut different = original.clone();
        different.id = "different".into();
        match boundary {
            0 => {
                if let RowKind::GeneratedImage { owner, .. } = &mut different.kind {
                    *owner = "other-owner".into();
                }
            }
            1 => different.entry_id = "other-entry".into(),
            _ => different.compact_fold = Some("fold".into()),
        }
        let result = merge_generated_image_runs(vec![original.clone(), different]);
        assert_eq!(result.len(), 2);
        assert!(
            result
                .iter()
                .all(|row| matches!(row.kind, RowKind::GeneratedImage { .. }))
        );
    }
}

#[test]
fn gallery_does_not_duplicate_viewed_images_or_override_markdown_placement() {
    let read:MessagePart=serde_json::from_value(serde_json::json!({"id":"read","kind":"tool","resolved":true,"call":serde_json::to_value(ToolCall::ReadFile {path:"/gallery-test/viewed.png".into()}).unwrap()})).unwrap();
    let mut source = entry(vec![image("a"), image("b"), read], false);
    let result = rows(&source);
    assert!(
        result
            .iter()
            .any(|row| matches!(row.kind, RowKind::GeneratedImageGallery { .. }))
    );
    assert_eq!(
        result
            .iter()
            .filter(|row| matches!(row.kind, RowKind::GeneratedImage { viewed: true, .. }))
            .count(),
        1
    );
    source.parts.push(MessagePart::Text {
        id: "reply".into(),
        text: "![Image](/gallery-test/viewed.png)".into(),
    });
    assert!(
        !rows(&source)
            .iter()
            .any(|row| matches!(row.kind, RowKind::GeneratedImage { viewed: true, .. }))
    );
}

fn seed_image(index: usize) -> GeneratedImageRef {
    let path = format!("/gallery-interaction/{index}.png");
    let mut encoded = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgba8(80, 60)
        .write_to(&mut encoded, image::ImageFormat::Png)
        .unwrap();
    crate::attachments::store_loaded_for(
        &crate::attachments::AttachmentKey::new("gallery-ui-owner", &path, Some("image/png")),
        format!("image-{index}.png").into(),
        Arc::new(gpui::Image::from_bytes(
            gpui::ImageFormat::Png,
            encoded.into_inner(),
        )),
    );
    GeneratedImageRef {
        path,
        name: format!("image-{index}.png"),
        mime_type: "image/png".into(),
    }
}

#[gpui::test]
fn gallery_thumbnail_keyboard_lightbox_and_focus_recovery(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
    });
    let state = cx.new(|_| AppState::new());
    let transcript = cx.new(|cx| Transcript::new(state, cx));
    let images = (0..9).map(seed_image).collect::<Vec<_>>();
    struct Fixture {
        transcript: Entity<Transcript>,
        images: Vec<GeneratedImageRef>,
    }
    impl Render for Fixture {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            if self
                .transcript
                .read(cx)
                .attachment_gallery_preview
                .is_some()
            {
                return self.transcript.clone().into_any_element();
            }
            self.transcript
                .update(cx, |this, cx| {
                    div()
                        .w(px(480.0))
                        .p(px(12.0))
                        .child(this.render_generated_image_gallery(
                            &"test-gallery".into(),
                            "gallery-ui-owner",
                            &self.images,
                            cx,
                        ))
                })
                .into_any_element()
        }
    }
    let (_fixture, cx) = cx.add_window_view(|_, _| Fixture {
        transcript: transcript.clone(),
        images,
    });
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    let thumb = cx.debug_bounds("test-gallery-thumb-2").unwrap();
    cx.simulate_click(thumb.center(), gpui::Modifiers::default());
    cx.run_until_parked();
    transcript.read_with(cx, |this, _| {
        assert_eq!(this.gallery_selection.get("test-gallery"), Some(&2))
    });
    cx.simulate_keystrokes("end");
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    transcript.read_with(cx, |this, _| {
        assert_eq!(this.gallery_selection.get("test-gallery"), Some(&8));
        let scroll = &this.gallery_scroll["test-gallery"];
        assert!(
            scroll.offset().y < px(0.0),
            "keyboard scroll keeps last thumbnail visible"
        );
    });
    cx.simulate_keystrokes("home down enter");
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    let focus = transcript.read_with(cx, |this, _| {
        let preview = this
            .attachment_gallery_preview
            .as_ref()
            .expect("Enter opens the selected image");
        assert_eq!(preview.index, 1);
        assert_eq!(preview.images.len(), 9);
        assert!(
            preview
                .preview
                .as_ref()
                .is_some_and(|image| image.annotate.is_some()),
            "gallery previews retain annotation support"
        );
        this.attachment_preview_return_focus.clone().unwrap()
    });
    cx.simulate_keystrokes("right");
    cx.run_until_parked();
    transcript.read_with(cx, |this, _| {
        assert_eq!(this.attachment_gallery_preview.as_ref().unwrap().index, 2)
    });
    cx.simulate_keystrokes("escape");
    cx.run_until_parked();
    transcript.read_with(cx, |this, _| {
        assert!(this.attachment_gallery_preview.is_none())
    });
    cx.update(|window, _| assert!(focus.is_focused(window)));
}

#[gpui::test]
fn gallery_streaming_change_rejects_an_old_save_completion(cx: &mut gpui::TestAppContext) {
    use super::gallery::{GallerySaveProgress, GallerySaveState, source_signature};
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
    });
    let state = cx.new(|_| AppState::new());
    let transcript = cx.new(|cx| Transcript::new(state, cx));
    let first = vec![seed_image(31), seed_image(32)];
    let mut grown = first.clone();
    grown.push(seed_image(33));
    let id: SharedString = "streaming-save".into();
    let old = source_signature("gallery-ui-owner", &first);
    let new = source_signature("gallery-ui-owner", &grown);
    let report = || crate::attachments::GallerySaveReport {
        directory: dir.path().into(),
        total: 2,
        saved: Vec::new(),
        failures: Vec::new(),
    };
    transcript.update(cx, |this, cx| {
        this.gallery_save.insert(
            id.clone(),
            GallerySaveState {
                signature: old,
                request_id: 100,
                progress: GallerySaveProgress::Saving,
            },
        );
        // Actual gallery rendering observes a newly streamed image and clears
        // stale feedback, while the old asynchronous save can still finish.
        let _ = this.render_generated_image_gallery(&id, "gallery-ui-owner", &grown, cx);
        assert!(!this.gallery_save.contains_key(&id));
        this.gallery_save.insert(
            id.clone(),
            GallerySaveState {
                signature: new,
                request_id: 101,
                progress: GallerySaveProgress::Picking,
            },
        );
        this.finish_generated_gallery_save(&id, old, 100, report(), cx);
        assert!(matches!(
            this.gallery_save[&id].progress,
            GallerySaveProgress::Picking
        ));
        // Even if the source returns to its old shape, an earlier request
        // cannot overwrite feedback from a later save of that same shape.
        this.gallery_save.insert(
            id.clone(),
            GallerySaveState {
                signature: old,
                request_id: 102,
                progress: GallerySaveProgress::Saving,
            },
        );
        this.finish_generated_gallery_save(&id, old, 100, report(), cx);
        assert!(matches!(
            this.gallery_save[&id].progress,
            GallerySaveProgress::Saving
        ));
        this.finish_generated_gallery_save(&id, old, 102, report(), cx);
        assert!(matches!(
            this.gallery_save[&id].progress,
            GallerySaveProgress::Finished(_)
        ));
    });
}

#[gpui::test]
fn gallery_large_previews_do_not_reload_the_batch_or_block_export(cx: &mut gpui::TestAppContext) {
    use crate::attachments::{
        AttachmentKey, AttachmentSnapshot, attachment_snapshot_for, store_loaded_for,
    };
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
    });
    let owner = "gallery-large-cache-regression";
    let mut encoded = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgba8(2048, 2048)
        .write_to(&mut encoded, image::ImageFormat::Png)
        .unwrap();
    let bytes = encoded.into_inner();
    let images: Vec<_> = (0..2)
        .map(|index| GeneratedImageRef {
            path: format!("/gallery-large-cache/{index}.png"),
            name: format!("{index}.png"),
            mime_type: "image/png".into(),
        })
        .collect();
    for image in &images {
        store_loaded_for(
            &AttachmentKey::new(owner, &image.path, Some(&image.mime_type)),
            image.name.clone().into(),
            Arc::new(gpui::Image::from_bytes(
                gpui::ImageFormat::Png,
                bytes.clone(),
            )),
        );
    }
    // Two 2048px decoded previews exceed the shared64MiB budget even though
    // these compressed PNGs are small. The earlier one has been evicted.
    let evicted = AttachmentKey::new(owner, &images[0].path, Some("image/png"));
    let selected = AttachmentKey::new(owner, &images[1].path, Some("image/png"));
    assert!(matches!(
        attachment_snapshot_for(&evicted),
        AttachmentSnapshot::Loading
    ));
    assert!(matches!(
        attachment_snapshot_for(&selected),
        AttachmentSnapshot::Loaded(_)
    ));
    let state = cx.new(|_| AppState::new());
    let transcript = cx.new(|cx| Transcript::new(state, cx));
    transcript.update(cx, |this, _| {
        this.gallery_selection.insert("large-gallery".into(), 1);
    });
    struct Fixture {
        transcript: Entity<Transcript>,
        images: Vec<GeneratedImageRef>,
    }
    impl Render for Fixture {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            self.transcript.update(cx, |this, cx| {
                this.render_generated_image_gallery(
                    &"large-gallery".into(),
                    "gallery-large-cache-regression",
                    &self.images,
                    cx,
                )
            })
        }
    }
    let (_fixture, cx) = cx.add_window_view(|_, _| Fixture {
        transcript: transcript.clone(),
        images,
    });
    cx.run_until_parked();
    for _ in 0..3 {
        cx.update(|window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        });
    }
    assert!(
        matches!(
            attachment_snapshot_for(&evicted),
            AttachmentSnapshot::Loading
        ),
        "offscreen/nonselected full previews never receive new load claims"
    );
    assert!(
        matches!(
            attachment_snapshot_for(&selected),
            AttachmentSnapshot::Loaded(_)
        ),
        "the visible stage is not evicted by its thumbnails"
    );
    let save = cx.debug_bounds("large-gallery-save-all").unwrap();
    cx.simulate_click(save.center(), gpui::Modifiers::default());
    cx.run_until_parked();
    transcript.read_with(cx,|this,_|assert!(matches!(&this.gallery_save["large-gallery"].progress,
        super::gallery::GallerySaveProgress::Error(message) if message.contains("Connect")),"Save all remains usable with an unloaded thumbnail; original readback reports the actual missing connection"));
}
