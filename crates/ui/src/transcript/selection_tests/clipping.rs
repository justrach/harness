use super::*;
use crate::markdown::selection;

fn message(id: &str, role: MessageRole, text: &str) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts: vec![MessagePart::Text {
            id: "text".into(),
            text: text.into(),
        }],
        created_at: 0,
        device_id: "fixture".into(),
        status: Some(MessageStatus::Complete),
        continuation_of: None,
        duration_ms: None,
    }
}

fn draw(transcript: &Entity<Transcript>, cx: &mut gpui::VisualTestContext) {
    transcript.update(cx, |this, cx| this.sync(cx));
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
}

fn with_transcript(
    cx: &mut gpui::TestAppContext,
    prompt: &str,
    reply: &str,
    test: impl FnOnce(Entity<Transcript>, Entity<AppState>, &mut gpui::VisualTestContext),
) {
    struct Host(Entity<Transcript>);
    impl Render for Host {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().child(self.0.clone())
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let state = cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        cx.new(|_| AppState::new())
    });
    let (host, cx) =
        cx.add_window_view(|_, cx| Host(cx.new(|cx| Transcript::new(state.clone(), cx))));
    cx.simulate_resize(size(px(900.0), px(800.0)));
    let transcript = host.read_with(cx, |host, _| host.0.clone());
    state.update(cx, |state, _| {
        state.selected_chat = Some("clipping-fixture".into());
        state.transcript_replayed = true;
        state.transcript = vec![
            message("prompt", MessageRole::User, prompt),
            message("reply", MessageRole::Assistant, reply),
        ];
        state.transcript_revision += 1;
    });
    for _ in 0..3 {
        draw(&transcript, cx);
    }
    test(transcript, state, cx);
}

fn entry(needle: &str) -> (String, String, gpui::TextLayout) {
    let (key, text, _) = render::selection_test_entries()
        .into_iter()
        .find(|(_, text, _)| text.contains(needle))
        .unwrap_or_else(|| panic!("missing painted text {needle:?}"));
    let (_, layout, _) = render::selection_test_snapshot(&key);
    (key, text, layout)
}

fn at(layout: &gpui::TextLayout, ix: usize) -> Point<Pixels> {
    layout.position_for_index(ix).unwrap() + point(px(0.1), px(8.0))
}

fn drag(
    cx: &mut gpui::VisualTestContext,
    key: &str,
    count: usize,
    start: Point<Pixels>,
    end: Point<Pixels>,
    expected: &str,
) {
    cx.simulate_event(gpui::MouseDownEvent {
        button: MouseButton::Left,
        position: start,
        click_count: count,
        ..Default::default()
    });
    assert_eq!(selection::anchor_key().as_deref(), Some(key));
    cx.simulate_event(MouseMoveEvent {
        position: end,
        pressed_button: Some(MouseButton::Left),
        ..Default::default()
    });
    assert_eq!(selection::selected_text().as_deref(), Some(expected));
    cx.simulate_event(MouseUpEvent {
        button: MouseButton::Left,
        position: end,
        ..Default::default()
    });
    assert_eq!(selection::selected_text().as_deref(), Some(expected));
    selection::clear_if_owner(key);
}

#[gpui::test]
fn collapsed_prompt_selection_handles_wrap_unicode_reverse_drags_and_resize(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    let prompt = "Hidden prompt content with a wide line for synthetic overlap. ".repeat(40);
    let reply = "Reply alpha café beta gamma delta epsilon zeta eta theta iota kappa lambda.\n\nSecond paragraph stays selectable.";
    with_transcript(cx, &prompt, reply, |transcript, _, cx| {
        for width in [900.0, 320.0, 600.0, 900.0] {
            cx.simulate_resize(size(px(width), px(800.0)));
            draw(&transcript, cx);
            let (key, text, layout) = entry("Reply alpha");
            let cafe = text.find("café").unwrap();
            for count in [2, 3] {
                let expected = if count == 2 { "café" } else { &text };
                drag(
                    cx,
                    &key,
                    count,
                    at(&layout, cafe + 1),
                    at(&layout, cafe + 2),
                    expected,
                );
            }
            for (from, to) in [(0, text.len()), (text.len(), 0)] {
                drag(cx, &key, 1, at(&layout, from), at(&layout, to), &text);
            }
            let (second_key, second, second_layout) = entry("Second paragraph");
            drag(
                cx,
                &second_key,
                2,
                at(&second_layout, 2),
                at(&second_layout, 2),
                "Second",
            );
            drag(
                cx,
                &second_key,
                3,
                at(&second_layout, 2),
                at(&second_layout, 2),
                &second,
            );
        }
    });
}

#[gpui::test]
fn collapsed_prompt_selection_rejects_hidden_blank_hits_and_preserves_gutter_drags(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    let prompt = "Hidden prompt words with enough width to overlap output.\n".repeat(40);
    with_transcript(cx, &prompt, "Reply alpha beta gamma.", |_, _, cx| {
        let (key, text, layout) = entry("Reply alpha");
        let y = at(&layout, 0).y;
        drag(cx, &key, 1, point(px(1.0), y), at(&layout, 5), &text[..5]);
        drag(cx, &key, 1, point(px(899.0), y), at(&layout, 5), &text[5..]);
        let (_, _, prompt_layout) = entry("Hidden prompt");
        let blank = point(prompt_layout.bounds().left() + px(10.0), y + px(70.0));
        assert!(prompt_layout.bounds().contains(&blank));
        for count in [1, 2, 3] {
            cx.simulate_event(gpui::MouseDownEvent {
                button: MouseButton::Left,
                position: blank,
                click_count: count,
                ..Default::default()
            });
            assert!(
                !selection::is_dragging(),
                "hidden prompt captured blank click {count}"
            );
            assert!(selection::selected_text().is_none());
            cx.simulate_event(MouseUpEvent {
                button: MouseButton::Left,
                position: blank,
                ..Default::default()
            });
        }
    });
}

#[gpui::test]
fn collapsed_prompt_selection_refreshes_after_expand_collapse_and_stream_repaint(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    let prompt = (1..=9)
        .map(|i| format!("Prompt line {i} with selectable words.\n"))
        .collect::<String>();
    let reply = "Reply alpha beta gamma.";
    with_transcript(cx, &prompt, reply, |transcript, state, cx| {
        let (prompt_key, _, _) = entry("Prompt line 1");
        let row: SharedString = prompt_key.strip_suffix(":u").unwrap().to_owned().into();
        for expanded in [true, false, true, false] {
            transcript.update(cx, |this, cx| {
                let row_ix = this.rows.iter().position(|item| item.id == row).unwrap();
                let full_h = this.user_heights[&row].get();
                this.toggle_user_fold(row.clone(), row_ix, 132.0, full_h, true);
                let fold = this.user_folds.get_mut(&row).unwrap();
                assert_eq!(fold.open, Some(expanded));
                fold.toggled_at = None; // Check settled fold endpoints deterministically.
                cx.notify();
            });
            draw(&transcript, cx);
            if expanded {
                let (key, text, layout) = entry("Prompt line 1");
                let ix = text.find("line 8").unwrap();
                drag(
                    cx,
                    &key,
                    2,
                    at(&layout, ix + 1),
                    at(&layout, ix + 1),
                    "line",
                );
            }
            transcript.update(cx, |this, cx| {
                this.list.scroll_to_end();
                cx.notify();
            });
            for _ in 0..3 {
                draw(&transcript, cx);
            }
            let (key, _, layout) = entry("Reply alpha");
            assert!(transcript.read_with(cx, |this, _| {
                this.list.viewport_bounds().contains(&at(&layout, 7))
            }));
            cx.simulate_event(gpui::MouseDownEvent {
                button: MouseButton::Left,
                position: at(&layout, 7),
                click_count: 2,
                ..Default::default()
            });
            assert_eq!(
                selection::anchor_key().as_deref(),
                Some(key.as_str()),
                "expanded={expanded}, reply position={:?}, entries={:?}",
                at(&layout, 7),
                render::selection_test_entries(),
            );
            state.update(cx, |state, _| {
                state.transcript[1].status = Some(MessageStatus::Streaming);
                state.transcript[1].parts = vec![MessagePart::Text {
                    id: "text".into(),
                    text: format!("{reply} More streaming output."),
                }];
                state.transcript_revision += 1;
            });
            draw(&transcript, cx);
            let (_, _, layout) = entry("Reply alpha");
            cx.simulate_event(MouseMoveEvent {
                position: at(&layout, 7),
                pressed_button: Some(MouseButton::Left),
                ..Default::default()
            });
            cx.simulate_event(MouseUpEvent {
                button: MouseButton::Left,
                position: at(&layout, 7),
                ..Default::default()
            });
            assert_eq!(selection::selected_text().as_deref(), Some("alpha"));
            state.update(cx, |state, _| {
                state.transcript[1].status = Some(MessageStatus::Complete);
                state.transcript_revision += 1;
            });
            draw(&transcript, cx);
            assert_eq!(selection::selected_text().as_deref(), Some("alpha"));
            selection::clear_if_owner(&key);
        }
    });
}

#[gpui::test]
fn collapsed_prompt_selection_targets_the_actual_markdown_table_cell(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    let prompt = "Hidden prompt words that must not capture output selection.\n".repeat(40);
    let reply = "| Left header | Middle header | Right header |\n| --- | --- | --- |\n| left alpha end | middle beta end | right gamma end |";
    with_transcript(cx, &prompt, reply, |_, _, cx| {
        for (needle, word) in [
            ("left alpha", "alpha"),
            ("middle beta", "beta"),
            ("right gamma", "gamma"),
        ] {
            let (key, text, layout) = entry(needle);
            let start = text.find(word).unwrap();
            for count in [1, 2, 3] {
                let from = if count == 1 { start } else { start + 1 };
                let to = if count == 1 {
                    start + word.len()
                } else {
                    start + 1
                };
                let expected = if count == 3 { &text } else { word };
                drag(
                    cx,
                    &key,
                    count,
                    at(&layout, from),
                    at(&layout, to),
                    expected,
                );
            }
        }
    });
}

struct PagingSelectionHost {
    tail: bool,
}

impl Render for PagingSelectionHost {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let rows = if self.tail {
            [
                ("paging-middle", "middle selectable"),
                ("paging-last", "last selectable"),
            ]
        } else {
            [
                ("paging-first", "first selectable"),
                ("paging-middle", "middle selectable"),
            ]
        };
        div()
            .size_full()
            .text_size(px(14.0))
            .line_height(px(22.0))
            .child(render::selection_owner_reset(cx.entity_id().as_u64()))
            .children(rows.into_iter().map(|(key, text)| {
                render::selectable_autolinked_text(
                    key.into(),
                    text.into(),
                    gpui::font(theme.font_sans.clone()),
                    theme.text,
                    None,
                    &theme,
                )
            }))
            .child(render::selection_owner_end())
    }
}

#[gpui::test]
fn clipped_selection_keeps_its_owner_when_the_anchor_is_virtualized(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    let (host, cx) = cx.add_window_view(|_, _| PagingSelectionHost { tail: false });
    cx.simulate_resize(size(px(500.0), px(300.0)));
    for forward in [true, false] {
        host.update(cx, |host, cx| {
            host.tail = !forward;
            cx.notify();
        });
        cx.update(|window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        });
        let (anchor, text, layout) = entry(if forward {
            "first selectable"
        } else {
            "last selectable"
        });
        cx.simulate_event(gpui::MouseDownEvent {
            button: MouseButton::Left,
            position: at(&layout, if forward { 0 } else { text.len() }),
            click_count: 1,
            ..Default::default()
        });
        let (_, middle, middle_layout) = entry("middle selectable");
        cx.simulate_event(MouseMoveEvent {
            position: at(&middle_layout, if forward { middle.len() } else { 0 }),
            pressed_button: Some(MouseButton::Left),
            ..Default::default()
        });
        assert!(
            selection::selected_text()
                .unwrap()
                .contains("middle selectable")
        );
        host.update(cx, |host, cx| {
            host.tail = forward;
            cx.notify();
        });
        cx.update(|window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        });
        assert!(
            !render::selection_test_entries()
                .iter()
                .any(|(key, _, _)| key == &anchor)
        );
        let (_, text, layout) = entry(if forward {
            "last selectable"
        } else {
            "first selectable"
        });
        let head = at(&layout, if forward { text.len() } else { 0 });
        assert!(
            render::update_drag_at(head),
            "selection must extend after its anchor unmounts"
        );
        let expected = "first selectable\nmiddle selectable\nlast selectable";
        assert_eq!(selection::selected_text().as_deref(), Some(expected));
        assert_eq!(selection::end_active_drag().as_deref(), Some(expected));
        selection::clear_if_owner(&anchor);
    }
}

#[gpui::test]
fn collapsed_prompt_selection_survives_other_cached_pane_repaints(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    struct Split(Entity<Transcript>, Entity<Transcript>);
    impl Render for Split {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            let cached = || gpui::StyleRefinement::default().size_full();
            div()
                .size_full()
                .flex()
                .flex_row()
                .child(
                    div()
                        .w(px(450.0))
                        .h_full()
                        .child(self.0.clone().cached(cached())),
                )
                .child(
                    div()
                        .w(px(450.0))
                        .h_full()
                        .child(self.1.clone().cached(cached())),
                )
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let (left_state, right_state) = cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        (cx.new(|_| AppState::new()), cx.new(|_| AppState::new()))
    });
    let (split, cx) = cx.add_window_view(|_, cx| {
        Split(
            cx.new(|cx| Transcript::new(left_state.clone(), cx)),
            cx.new(|cx| Transcript::new(right_state.clone(), cx)),
        )
    });
    cx.simulate_resize(size(px(900.0), px(800.0)));
    let (left, right) = split.read_with(cx, |split, _| (split.0.clone(), split.1.clone()));
    for (state, side) in [(&left_state, "left"), (&right_state, "right")] {
        state.update(cx, |state, _| {
            state.selected_chat = Some(side.into());
            state.transcript_replayed = true;
            state.transcript = vec![
                message(
                    &format!("{side}-prompt"),
                    MessageRole::User,
                    &"Hidden prompt words. ".repeat(100),
                ),
                message(
                    &format!("{side}-reply"),
                    MessageRole::Assistant,
                    &format!("{side} alpha beta reply"),
                ),
            ];
            state.transcript_revision += 1;
        });
    }
    for _ in 0..3 {
        left.update(cx, |this, cx| this.sync(cx));
        right.update(cx, |this, cx| this.sync(cx));
        cx.run_until_parked();
        cx.update(|window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        });
    }
    for (changing, changed, untouched) in [
        (&left_state, &left, "right alpha"),
        (&right_state, &right, "left alpha"),
    ] {
        changing.update(cx, |state, _| {
            state.transcript[1].parts = vec![MessagePart::Text {
                id: "text".into(),
                text: format!(
                    "{} alpha beta reply with new streaming text",
                    state.selected_chat.as_deref().unwrap()
                ),
            }];
            state.transcript_revision += 1;
        });
        changed.update(cx, |this, cx| this.sync(cx));
        cx.run_until_parked();
        cx.update(|window, cx| {
            let _ = window.draw(cx);
        }); // No global refresh: the other pane stays cached.
        let (key, text, layout) = entry(untouched);
        let ix = text.find("alpha").unwrap() + 1;
        drag(cx, &key, 2, at(&layout, ix), at(&layout, ix), "alpha");
    }
}

#[gpui::test]
fn selection_ignores_secondary_button_releases_during_a_primary_drag(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    with_transcript(
        cx,
        "A short synthetic prompt.",
        "Reply alpha beta gamma.",
        |_, _, cx| {
            let (key, text, layout) = entry("Reply alpha");
            for button in [MouseButton::Right, MouseButton::Middle] {
                cx.simulate_event(gpui::MouseDownEvent {
                    button: MouseButton::Left,
                    position: at(&layout, 0),
                    click_count: 1,
                    ..Default::default()
                });
                cx.simulate_event(MouseMoveEvent {
                    position: at(&layout, 5),
                    pressed_button: Some(MouseButton::Left),
                    ..Default::default()
                });
                assert_eq!(selection::selected_text().as_deref(), Some(&text[..5]));
                cx.simulate_event(gpui::MouseDownEvent {
                    button,
                    position: at(&layout, 5),
                    click_count: 1,
                    ..Default::default()
                });
                cx.simulate_event(MouseUpEvent {
                    button,
                    position: at(&layout, 5),
                    ..Default::default()
                });
                assert!(
                    selection::is_dragging(),
                    "{button:?} release must not end a primary drag"
                );
                cx.simulate_event(MouseMoveEvent {
                    position: at(&layout, text.len()),
                    pressed_button: Some(MouseButton::Left),
                    ..Default::default()
                });
                assert_eq!(selection::selected_text().as_deref(), Some(text.as_str()));
                cx.simulate_event(MouseUpEvent {
                    button: MouseButton::Left,
                    position: at(&layout, text.len()),
                    ..Default::default()
                });
                assert!(!selection::is_dragging());
                selection::clear_if_owner(&key);
            }
        },
    );
}

#[gpui::test]
fn selection_keeps_original_link_offsets_through_ellipsis_and_resize(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    let prompt = "Hidden prompt text. ".repeat(100);
    let reply = format!(
        "Prefix https://example.invalid/{} suffix",
        "synthetic-long-segment/".repeat(30)
    );
    with_transcript(cx, &prompt, &reply, |transcript, _, cx| {
        transcript.update(cx, |this, cx| {
            this.set_workspace_link_handler(render::LinkUi {
                source_session: Some("clipping-fixture".into()),
                handler: Rc::new(|_, _, _| render::LinkOutcome::Internal),
            });
            cx.notify();
        });
        for width in [900.0, 320.0, 600.0, 900.0] {
            cx.simulate_resize(size(px(width), px(800.0)));
            draw(&transcript, cx);
            let (key, original, layout) = entry("Prefix https://example.invalid/");
            let (_, _, offsets) = render::selection_test_snapshot(&key);
            assert!(
                offsets
                    .as_ref()
                    .is_some_and(|offsets| !offsets.omissions.is_empty())
            );
            let displayed = layout.text();
            assert!(displayed.contains('…'));
            assert_eq!(original, reply);
            for (start, end) in [(0, displayed.len()), (displayed.len(), 0)] {
                drag(cx, &key, 1, at(&layout, start), at(&layout, end), &original);
            }
            drag(cx, &key, 3, at(&layout, 2), at(&layout, 2), &original);
            let suffix = displayed.find("suffix").unwrap() + 2;
            drag(
                cx,
                &key,
                2,
                at(&layout, suffix),
                at(&layout, suffix),
                "suffix",
            );
        }
    });
}

struct HorizontalSelectionClip {
    width: f32,
}

impl Render for HorizontalSelectionClip {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        div()
            .size_full()
            .text_size(px(14.0))
            .line_height(px(22.0))
            .child(render::selection_owner_reset(cx.entity_id().as_u64()))
            .child(div().h(px(40.0)))
            .child(
                div()
                    .ml(px(40.0))
                    .w(px(self.width))
                    .h(px(44.0))
                    .overflow_hidden()
                    .child(
                        div()
                            .ml(px(20.0))
                            .w(px(120.0))
                            .h(px(44.0))
                            .overflow_hidden()
                            .child(div().relative().left(px(-70.0)).w(px(400.0)).child(
                                render::selectable_autolinked_text(
                                    "horizontal-clip".into(),
                                    "prefixprefix visibleword suffixsuffix".into(),
                                    gpui::font(theme.font_sans.clone()),
                                    theme.text,
                                    None,
                                    &theme,
                                ),
                            )),
                    ),
            )
            .child(render::selection_owner_end())
    }
}

#[gpui::test]
fn selection_respects_nested_horizontal_masks_and_zero_width_clips(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    let (host, cx) = cx.add_window_view(|_, _| HorizontalSelectionClip { width: 120.0 });
    cx.simulate_resize(size(px(500.0), px(300.0)));
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    let (key, text, layout) = entry("prefixprefix visibleword");
    let ix = text.find("visibleword").unwrap() + 2;
    let visible = at(&layout, ix);
    assert!(visible.x >= px(60.0) && visible.x < px(160.0));
    for count in [2, 3] {
        drag(
            cx,
            &key,
            count,
            visible,
            visible,
            if count == 2 { "visibleword" } else { &text },
        );
    }
    for width in [120.0, 0.0, 120.0] {
        host.update(cx, |host, cx| {
            host.width = width;
            cx.notify();
        });
        cx.update(|window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        });
        for x in [40.0, 59.9, 160.0, 160.1, 200.0] {
            for count in [1, 2, 3] {
                let position = point(px(x), px(48.0));
                cx.simulate_event(gpui::MouseDownEvent {
                    button: MouseButton::Left,
                    position,
                    click_count: count,
                    ..Default::default()
                });
                assert!(
                    !selection::is_dragging(),
                    "clip width {width}, hidden x={x}, count={count}"
                );
                assert!(selection::selected_text().is_none());
                cx.simulate_event(MouseUpEvent {
                    button: MouseButton::Left,
                    position,
                    ..Default::default()
                });
            }
        }
    }
}

struct ClipHost {
    height: f32,
    offset: f32,
}

impl Render for ClipHost {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        div()
            .size_full()
            .text_size(px(14.0))
            .line_height(px(22.0))
            .child(render::selection_owner_reset(cx.entity_id().as_u64()))
            .child(div().h(px(40.0)))
            .child(
                div().h(px(self.height)).overflow_hidden().child(
                    div().relative().top(px(self.offset)).child(
                        render::selectable_autolinked_text(
                            "clip-prompt".into(),
                            "first\nsecond\nthird\nfourth\nfifth".into(),
                            gpui::font(theme.font_sans.clone()),
                            theme.text,
                            None,
                            &theme,
                        ),
                    ),
                ),
            )
            .child(div().h(px(120.0)))
            .child(render::selectable_autolinked_text(
                "clip-reply".into(),
                "visible reply".into(),
                gpui::font(theme.font_sans.clone()),
                theme.text,
                None,
                &theme,
            ))
            .child(render::selection_owner_end())
    }
}

#[gpui::test]
fn clipped_selection_drag_clamps_to_visible_lines_above_and_below(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    let (host, cx) = cx.add_window_view(|_, _| ClipHost {
        height: 44.0,
        offset: 0.0,
    });
    cx.simulate_resize(size(px(500.0), px(400.0)));
    for (offset, start_ix, end_y, expected) in [
        (0.0, 0, 92.0, "first\nsecond"),
        (-22.0, "first\nsecond\nthird".len(), 32.0, "second\nthird"),
    ] {
        host.update(cx, |host, cx| {
            host.offset = offset;
            cx.notify();
        });
        cx.update(|window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        });
        let (key, _, layout) = entry("first\nsecond");
        // Outside the vertical band, x must not truncate the boundary line.
        let x = if offset == 0.0 { px(0.0) } else { px(499.0) };
        drag(
            cx,
            &key,
            1,
            at(&layout, start_ix),
            point(x, px(end_y)),
            expected,
        );
    }
}

#[gpui::test]
fn fully_clipped_selection_cannot_capture_clicks_or_whitespace(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    let (host, cx) = cx.add_window_view(|_, _| ClipHost {
        height: 0.0,
        offset: 0.0,
    });
    cx.simulate_resize(size(px(500.0), px(400.0)));
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    let owner = host.entity_id().as_u64();
    for count in [1, 2, 3] {
        for y in [39.9, 40.0, 40.1, 60.0] {
            let position = point(px(10.0), px(y));
            cx.simulate_event(gpui::MouseDownEvent {
                button: MouseButton::Left,
                position,
                click_count: count,
                ..Default::default()
            });
            assert!(!selection::is_dragging());
            assert!(!render::begin_drag_in_whitespace(
                owner,
                point(px(499.0), px(y))
            ));
            cx.simulate_event(MouseUpEvent {
                button: MouseButton::Left,
                position,
                ..Default::default()
            });
        }
    }
}
