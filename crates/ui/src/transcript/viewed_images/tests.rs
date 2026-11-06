use super::*;

fn setup(cx: &mut gpui::TestAppContext) -> Entity<Transcript> {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
    });
    let state = cx.new(|_| AppState::new());
    cx.new(|cx| Transcript::new(state, cx))
}

fn seed(owner: &str, path: &str) {
    let mut encoded = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(96, 64)
        .write_to(&mut encoded, image::ImageFormat::Png)
        .unwrap();
    crate::attachments::store_loaded_for(
        &AttachmentKey::new(owner, path, Some("image/png")),
        "image.png".into(),
        Arc::new(gpui::Image::from_bytes(
            gpui::ImageFormat::Png,
            encoded.into_inner(),
        )),
    );
}

fn entry(parts: Vec<MessagePart>, owner: &str) -> SessionMessageEntry {
    SessionMessageEntry {
        id: "viewed-test".into(),
        role: MessageRole::Assistant,
        parts,
        created_at: 0,
        device_id: owner.into(),
        status: Some(MessageStatus::Streaming),
        continuation_of: None,
        duration_ms: None,
    }
}

fn read(id: &str, path: &str) -> MessagePart {
    MessagePart::Tool {
        id: id.into(),
        call: ToolCall::ReadFile { path: path.into() },
        is_error: false,
        resolved: true,
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
    }
}

fn rows(entry: &SessionMessageEntry) -> Vec<Row> {
    rows_for_entry(entry, false, false, &mut |_, text| {
        Arc::new(parse_full(text))
    })
}

#[test]
fn viewed_image_source_never_substitutes_another_computers_same_path() {
    let source = ViewedImageSource::new("remote", "/shared/image.png", "image.png", "image/png");
    assert_eq!(source.devices(&["local".into(), "host".into()]), ["remote"]);
    let unknown = ViewedImageSource::new("", "/shared/image.png", "image.png", "image/png");
    assert_eq!(
        unknown.devices(&["local".into(), "local".into(), "host".into()]),
        ["local", "host"]
    );
    let other = ViewedImageSource::new("other", "/shared/image.png", "image.png", "image/png");
    assert_ne!(source, other);
}

#[gpui::test]
fn viewed_image_disclosure_loads_only_after_expansion_and_prunes_source_changes(
    cx: &mut gpui::TestAppContext,
) {
    let transcript = setup(cx);
    let owner = "viewed-lazy-owner";
    let path = "/viewed-tests/lazy.png";
    let source = ViewedImageSource::new(owner, path, "image.png", "image/png");
    let row: SharedString = "viewed-test#read#viewed".into();
    transcript.update(cx, |this, cx| {
        let _ = this.render_viewed_image(&row, owner, path, "image.png", "image/png", cx);
        assert!(!this.viewed_images[&row].open);
        assert!(
            matches!(
                this.gallery_thumbnail_state(&[owner.into()], &source.image, false, cx),
                AttachmentSnapshot::Loading
            ),
            "closed disclosure must not create a thumbnail request"
        );
        assert!(this.attachment_loads.is_empty());
        this.toggle_viewed_image(&row, cx);
        let _ = this.render_viewed_image(&row, owner, path, "image.png", "image/png", cx);
        assert!(this.viewed_images[&row].open);
        assert!(
            matches!(
                this.gallery_thumbnail_state(&[owner.into()], &source.image, false, cx),
                AttachmentSnapshot::Error { .. }
            ),
            "expanded disclosure truthfully reports no source engine"
        );
        this.pending_viewed_image = Some(ViewedImagePreview {
            row: row.clone(),
            source: source.clone(),
            failed: false,
        });
        let changed = rows(&entry(vec![read("read", path)], "different-owner"));
        prune_viewed_images(
            &mut this.viewed_images,
            &mut this.pending_viewed_image,
            &changed,
        );
        assert!(this.viewed_images.is_empty());
        assert!(
            this.pending_viewed_image.is_none(),
            "an in-flight preview must not outlive a corrected source"
        );
    });
}

#[gpui::test]
fn viewed_image_thumbnail_does_not_use_another_owner_cached_image(cx: &mut gpui::TestAppContext) {
    let transcript = setup(cx);
    let path = "/viewed-tests/owner-collision.png";
    seed("wrong-computer", path);
    transcript.update(cx, |this, cx| {
        this.state.update(cx, |state, _| {
            state.local_device_id = Some("wrong-computer".into())
        });
        let row: SharedString = "owner-collision".into();
        let _ =
            this.render_viewed_image(&row, "right-computer", path, "image.png", "image/png", cx);
        this.toggle_viewed_image(&row, cx);
        let _ =
            this.render_viewed_image(&row, "right-computer", path, "image.png", "image/png", cx);
        let source = ViewedImageSource::new("right-computer", path, "image.png", "image/png");
        assert!(matches!(
            this.gallery_thumbnail_state(&["right-computer".into()], &source.image, false, cx),
            AttachmentSnapshot::Error { .. }
        ));
        assert!(this.attachment_preview.is_none());
    });
}

#[test]
fn viewed_image_rows_keep_generated_results_and_gallery_boundaries() {
    let generated = |id: &str| MessagePart::Image {
        id: id.into(),
        path: format!("/viewed-tests/{id}.png"),
        name: format!("{id}.png"),
        mime_type: "image/png".into(),
    };
    let result = rows(&entry(
        vec![
            generated("a"),
            generated("b"),
            read("read", "/viewed-tests/upload.png"),
        ],
        "owner",
    ));
    assert!(result.iter().any(
        |r| matches!(&r.kind, RowKind::GeneratedImageGallery { images, .. } if images.len()==2)
    ));
    assert_eq!(
        result
            .iter()
            .filter(|r| matches!(r.kind, RowKind::GeneratedImage { viewed: true, .. }))
            .count(),
        1
    );
    assert!(
        !result
            .iter()
            .filter_map(
                |r| if let RowKind::GeneratedImageGallery { images, .. } = &r.kind {
                    Some(images)
                } else {
                    None
                }
            )
            .flat_map(|images| images.iter())
            .any(|i| i.path.ends_with("upload.png"))
    );
    assert_eq!(
        result
            .iter()
            .map(|r| r.id.clone())
            .collect::<HashSet<_>>()
            .len(),
        result.len()
    );
}

#[gpui::test]
fn viewed_image_keyboard_disclosure_preview_escape_and_annotation_hook(
    cx: &mut gpui::TestAppContext,
) {
    let transcript = setup(cx);
    const OWNER: &str = "viewed-interaction-owner";
    const PATH: &str = "/viewed-tests/interaction.png";
    seed(OWNER, PATH);
    struct Fixture(Entity<Transcript>);
    impl Render for Fixture {
        fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            self.0
                .update(cx, |this, cx| this.resolve_viewed_image_preview(window, cx));
            if self.0.read(cx).attachment_preview.is_some() {
                return self.0.clone().into_any_element();
            }
            self.0.update(cx, |this, cx| {
                this.render_viewed_image(
                    &"interaction".into(),
                    OWNER,
                    PATH,
                    "image.png",
                    "image/png",
                    cx,
                )
            })
        }
    }
    let (_, cx) = cx.add_window_view(|_, cx| {
        let entity = transcript.clone();
        cx.observe(&entity, |_, _, cx| cx.notify()).detach();
        Fixture(transcript.clone())
    });
    cx.run_until_parked();
    let focus = transcript.read_with(cx, |this, _| {
        this.viewed_images[&SharedString::from("interaction")]
            .focus
            .clone()
    });
    cx.update(|window, cx| window.focus(&focus, cx));
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    transcript.read_with(cx, |this, _| {
        assert!(this.viewed_images[&SharedString::from("interaction")].open)
    });
    let thumbnail = transcript.read_with(cx, |this, _| {
        this.viewed_images[&SharedString::from("interaction")]
            .thumbnail_focus
            .clone()
    });
    cx.update(|window, cx| window.focus(&thumbnail, cx));
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    transcript.read_with(cx, |this, _| {
        assert!(
            this.attachment_preview
                .as_ref()
                .is_some_and(|p| p.annotate.is_some()),
            "existing Markup/Comment hook is retained"
        )
    });
    cx.simulate_keystrokes("escape");
    cx.run_until_parked();
    transcript.read_with(cx, |this, _| assert!(this.attachment_preview.is_none()));
    cx.update(|window, _| assert!(thumbnail.is_focused(window)));
    cx.update(|window, cx| window.focus(&focus, cx));
    cx.simulate_keystrokes("space");
    cx.run_until_parked();
    transcript.read_with(cx, |this, _| {
        assert!(!this.viewed_images[&SharedString::from("interaction")].open)
    });
}

#[gpui::test]
fn mac_tool_activity_stays_condensed_until_the_person_opens_it(cx: &mut gpui::TestAppContext) {
    let transcript = setup(cx);
    let mut call = read("read", "/viewed-tests/source.rs");
    if let MessagePart::Tool { resolved, .. } = &mut call {
        *resolved = false;
    }
    let mut result = rows(&entry(vec![call.clone()], "owner"));
    transcript.update(cx, |this, cx| {
        let render = |this: &mut Transcript, row: &Row, cx: &mut Context<Transcript>| {
            let RowKind::ToolGroup {
                tools,
                summary,
                auto_open,
                ..
            } = &row.kind
            else {
                panic!("tool group")
            };
            let _ = this.render_tool_group(
                &row.id,
                tools,
                summary,
                *auto_open,
                None,
                false,
                &Theme::dark(),
                cx,
            );
        };
        render(this, &result[0], cx);
        assert_eq!(
            this.tool_group_reveals[&result[0].id].rendered_open,
            Some(false)
        );
        this.toggle_fold(result[0].id.clone(), 0.0, false, cx);
        render(this, &result[0], cx);
        assert_eq!(
            this.tool_group_reveals[&result[0].id].rendered_open,
            Some(true)
        );
        let mut failed = read("failed", "/viewed-tests/missing.rs");
        if let MessagePart::Tool { is_error, .. } = &mut failed {
            *is_error = true;
        }
        result = rows(&entry(vec![call, failed], "owner"));
        render(this, &result[0], cx);
        assert_eq!(
            this.tool_group_reveals[&result[0].id].rendered_open,
            Some(true),
            "new work preserves explicit expansion"
        );
        let RowKind::ToolGroup { summary, .. } = &result[0].kind else {
            unreachable!()
        };
        assert!(
            summary.contains("failed"),
            "condensation keeps the failure count visible"
        );
        this.toggle_fold(result[0].id.clone(), 0.0, false, cx);
        render(this, &result[0], cx);
        assert_eq!(
            this.tool_group_reveals[&result[0].id].rendered_open,
            Some(false)
        );
    });
}

#[gpui::test]
fn viewed_image_late_load_cannot_replace_a_newer_preview(cx: &mut gpui::TestAppContext) {
    let transcript = setup(cx);
    const OWNER: &str = "viewed-preview-ownership";
    const LATE: &str = "/viewed-tests/late-a.png";
    const NEWER: &str = "/viewed-tests/newer-b.png";
    seed(OWNER, NEWER);
    struct Fixture(Entity<Transcript>);
    impl Render for Fixture {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            self.0.update(cx, |this, cx| {
                div()
                    .debug_selector(|| "newer-preview-target".into())
                    .w(px(96.0))
                    .h(px(64.0))
                    .child(this.render_generated_image(
                        &"newer-preview".into(),
                        OWNER,
                        NEWER,
                        "newer-b.png",
                        "image/png",
                        false,
                        cx,
                    ))
            })
        }
    }
    let (_, cx) = cx.add_window_view(|_, _| Fixture(transcript.clone()));
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
        transcript.update(cx, |this, cx| {
            let focus = this.attachment_preview_focus.clone();
            this.begin_viewed_image_preview(
                "late-a".into(),
                ViewedImageSource::new(OWNER, LATE, "late-a.png", "image/png"),
                &focus,
                window,
                cx,
            );
        });
    });
    let target = cx.debug_bounds("newer-preview-target").unwrap();
    cx.simulate_click(target.center(), gpui::Modifiers::default());
    transcript.read_with(cx, |this, _| {
        assert!(this.pending_viewed_image.is_none());
        assert_eq!(
            this.attachment_preview.as_ref().unwrap().name,
            "newer-b.png"
        );
    });
    // A finishes only after the actual newer-image pointer interaction.
    seed(OWNER, LATE);
    cx.update(|window, cx| {
        transcript.update(cx, |this, cx| {
            this.resolve_viewed_image_preview(window, cx);
            assert_eq!(
                this.attachment_preview.as_ref().unwrap().name,
                "newer-b.png"
            );
            this.attachment_preview = None;
            this.resolve_viewed_image_preview(window, cx);
            assert!(
                this.attachment_preview.is_none(),
                "A must not reopen after B closes"
            );

            let focus = this.attachment_preview_focus.clone();
            this.begin_viewed_image_preview(
                "late-a".into(),
                ViewedImageSource::new(OWNER, LATE, "late-a.png", "image/png"),
                &focus,
                window,
                cx,
            );
            this.open_gallery_preview(
                OWNER.into(),
                vec![GeneratedImageRef {
                    path: NEWER.into(),
                    name: "newer-b.png".into(),
                    mime_type: "image/png".into(),
                }],
                0,
                window,
                cx,
            );
            assert!(this.pending_viewed_image.is_none());
            this.resolve_viewed_image_preview(window, cx);
            assert!(
                this.attachment_preview.is_none(),
                "A must not open behind the gallery"
            );
            assert!(this.attachment_gallery_preview.is_some());
            this.attachment_gallery_preview = None;
            this.resolve_viewed_image_preview(window, cx);
            assert!(
                this.attachment_preview.is_none(),
                "A must not reopen after the gallery closes"
            );
        });
    });
}
