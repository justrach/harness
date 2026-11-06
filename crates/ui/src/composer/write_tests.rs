//! The Write page: it edits the composer's own draft, gives it back intact,
//! and sends through the composer's send path.
use super::*;
use std::cell::RefCell;

/// What the shell does: the page in place of the composer while it's open.
struct WriteHost {
    composer: Entity<Composer>,
}

impl Render for WriteHost {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let page = self.composer.read(cx).write_open().then(|| {
            self.composer.update(cx, |composer, cx| {
                composer.render_write_page(0.0, window, cx)
            })
        });
        let open = page.is_some();
        div()
            .size_full()
            .flex()
            .flex_col()
            // The real shell owns native Tab traversal after inputs have had
            // a chance to accept a completion or indent a list.
            .on_key_down(|event: &KeyDownEvent, window, cx| {
                let modifiers = event.keystroke.modifiers;
                if event.keystroke.key == "tab"
                    && !modifiers.control
                    && !modifiers.alt
                    && !modifiers.platform
                {
                    if modifiers.shift {
                        window.focus_prev(cx);
                    } else {
                        window.focus_next(cx);
                    }
                    cx.stop_propagation();
                }
            })
            .children(page)
            .when(!open, |el| el.child(self.composer.clone()))
    }
}

fn host(
    cx: &mut gpui::TestAppContext,
    state: impl FnOnce(&mut AppState) + 'static,
) -> (tempfile::TempDir, gpui::WindowHandle<WriteHost>) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::light());
        crate::app_menus::init(cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        crate::settings::init(crate::settings::UiSettings::expanded(), dir.path(), cx);
        crate::motion::set_reduced_motion(cx, true);
        // Enter sends in the composer; the page must still take it as a newline.
        crate::composer::init(cx, ComposerSendBehavior::Enter);
    });
    let handle = cx.add_window(|_, cx| {
        let app_state = cx.new(|_| {
            let mut app_state = AppState::new();
            state(&mut app_state);
            app_state
        });
        let composer = cx.new(|cx| {
            let mut composer = Composer::new(app_state, cx);
            composer.set_available_width(640.0, cx);
            composer.set_available_height(600.0, cx);
            composer
        });
        WriteHost { composer }
    });
    draw(cx, handle);
    (dir, handle)
}

fn draw(cx: &mut gpui::TestAppContext, handle: gpui::WindowHandle<WriteHost>) {
    cx.update_window(handle.into(), |_, window, cx| window.draw(cx).clear())
        .unwrap();
}

fn composer(
    cx: &mut gpui::TestAppContext,
    handle: gpui::WindowHandle<WriteHost>,
) -> Entity<Composer> {
    handle
        .read_with(cx, |host, _| host.composer.clone())
        .unwrap()
}

fn set_draft(cx: &mut gpui::TestAppContext, handle: gpui::WindowHandle<WriteHost>, text: &str) {
    let text = text.to_string();
    handle
        .update(cx, |host, window, cx| {
            host.composer.update(cx, |composer, cx| {
                composer
                    .input
                    .update(cx, |input, cx| input.set_text(text, cx));
                window.focus(&composer.input.focus_handle(cx), cx);
            });
        })
        .unwrap();
    draw(cx, handle);
}

fn text(cx: &mut gpui::TestAppContext, composer: &Entity<Composer>) -> String {
    composer.read_with(cx, |composer, cx| {
        composer.input.read(cx).text().to_string()
    })
}

#[gpui::test]
fn the_shortcut_opens_the_draft_on_the_page_and_escape_brings_it_back(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let composer = composer(cx, handle);
    set_draft(
        cx,
        handle,
        "# Renderer notes\nFrame pacing follows the audio clock.",
    );

    cx.simulate_keystrokes(handle.into(), &platform_combo(write::toggle_combo()));
    draw(cx, handle);
    composer.read_with(cx, |composer, cx| {
        assert!(composer.write_open());
        assert_eq!(
            composer.input.read(cx).write_face(),
            Some(WriteFace { serif: false })
        );
    });
    assert_eq!(
        text(cx, &composer),
        "# Renderer notes\nFrame pacing follows the audio clock."
    );

    // Enter sends from the composer under this profile; on the page it is a
    // newline, and typing lands in the same draft.
    cx.simulate_keystrokes(handle.into(), "enter");
    cx.simulate_input(handle.into(), "Next");
    draw(cx, handle);
    assert!(composer.read_with(cx, |composer, _| composer.write_open()));
    assert_eq!(
        text(cx, &composer),
        "# Renderer notes\nFrame pacing follows the audio clock.\nNext"
    );

    cx.simulate_keystrokes(handle.into(), "escape");
    draw(cx, handle);
    composer.read_with(cx, |composer, cx| {
        assert!(!composer.write_open());
        assert_eq!(composer.input.read(cx).write_face(), None);
    });
    assert_eq!(
        text(cx, &composer),
        "# Renderer notes\nFrame pacing follows the audio clock.\nNext"
    );

    // And the shortcut works from the page too.
    cx.simulate_keystrokes(handle.into(), &platform_combo(write::toggle_combo()));
    draw(cx, handle);
    assert!(composer.read_with(cx, |composer, _| composer.write_open()));
    cx.simulate_keystrokes(handle.into(), &platform_combo(write::toggle_combo()));
    draw(cx, handle);
    assert!(!composer.read_with(cx, |composer, _| composer.write_open()));
}

#[gpui::test]
fn the_page_keeps_markers_and_gives_headings_taller_rows(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let composer = composer(cx, handle);
    let draft = "# Title\nSome **bold** words\n- a list item";
    set_draft(cx, handle, draft);
    // In the composer, the heading's `# ` is hidden off the caret's line.
    composer.update(cx, |composer, cx| {
        composer
            .input
            .update(cx, |input, cx| input.move_to(draft.len(), cx));
    });
    draw(cx, handle);
    composer.read_with(cx, |composer, cx| {
        assert_ne!(composer.input.read(cx).projection.display, draft);
    });

    composer.update(cx, |composer, cx| composer.open_write(cx));
    draw(cx, handle);
    composer.read_with(cx, |composer, cx| {
        let input = composer.input.read(cx);
        assert_eq!(input.projection.display, draft, "every marker stays");
        assert_eq!(input.line_heights.len(), 3);
        assert!(input.line_heights[0] > input.line_heights[1]);
        assert_eq!(input.line_heights[1], input.line_heights[2]);
        // The body row is the page's, not the composer's.
        assert!(f32::from(input.line_heights[1]) > INPUT_LINE_HEIGHT);
        // The caret on the second line sits below the taller heading row.
        let second = input.point_for_index("# Title\n".len()).unwrap();
        assert_eq!(second.y, input.line_heights[0]);
    });

    composer.update(cx, |composer, cx| composer.close_write(cx));
    draw(cx, handle);
    composer.read_with(cx, |composer, cx| {
        let input = composer.input.read(cx);
        assert!(
            input
                .line_heights
                .iter()
                .all(|height| *height == px(INPUT_LINE_HEIGHT))
        );
    });
}

#[gpui::test]
fn mod_enter_on_the_page_sends_the_draft_and_returns_to_the_chat(cx: &mut gpui::TestAppContext) {
    send_page(cx, false, false);
}

#[gpui::test]
fn opposite_follow_up_shortcut_on_the_page_queues_and_returns_to_the_chat(
    cx: &mut gpui::TestAppContext,
) {
    send_page(cx, true, false);
}

#[gpui::test]
fn send_now_in_the_toolbar_sends_the_original_draft_and_returns_to_chat(
    cx: &mut gpui::TestAppContext,
) {
    send_page(cx, false, true);
}

fn send_page(cx: &mut gpui::TestAppContext, opposite_follow_up: bool, click_send: bool) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    let (out, mut requests) = tokio::sync::mpsc::channel::<String>(64);
    let (_replies, inbound) = tokio::sync::mpsc::channel::<String>(64);
    let (_dir, handle) = host(cx, move |state| {
        state.set_test_engine(
            crate::state::EngineHandle::from_test_client_with_capabilities(
                harness_rpc::RpcClient::new(out, inbound),
                vec![harness_proto::capabilities::MESSAGE_QUEUE_V1.into()],
            ),
        );
        state.chats = vec![
            serde_json::from_value(serde_json::json!({
                "id": "chat",
                "deviceId": "local",
                "archived": false,
                "cwd": "/fixture-project",
                "createdAt": chrono::Utc::now(),
                "config": { "harness": "codex", "sandbox": "workspace-write" }
            }))
            .unwrap(),
        ];
        state.local_device_id = Some("local".into());
        state.selected_chat = Some("chat".into());
        if opposite_follow_up {
            state.begin_pending_send("chat", "current-turn", chrono::Utc::now());
        }
    });
    if opposite_follow_up {
        cx.update(|cx| {
            crate::settings::update(crate::settings::SavePolicy::Immediate, cx, |settings| {
                // The alternate shortcut should queue while the saved default steers.
                settings.follow_up_behavior = crate::settings::FollowUpBehavior::Steer;
            });
        });
    }
    let composer = composer(cx, handle);
    let draft = "# Plan\n\n- Cap the reel at `30s`\n- **Never** re-encode";
    set_draft(cx, handle, draft);
    composer.update(cx, |composer, cx| {
        composer.open_write(cx);
        if opposite_follow_up {
            assert_eq!(composer.button_mode(cx), SendButtonMode::Queue);
        }
    });
    draw(cx, handle);

    let shortcut = if opposite_follow_up {
        "mod-alt-enter"
    } else {
        "mod-enter"
    };
    let input = composer.read_with(cx, |composer, _| composer.input.clone());
    let input_events = Rc::new(RefCell::new(Vec::<ComposerInputEvent>::new()));
    let captured_events = input_events.clone();
    let _input_events = cx.update(|cx| {
        cx.subscribe(&input, move |_, event: &ComposerInputEvent, _| {
            captured_events.borrow_mut().push(event.clone());
        })
    });
    if click_send {
        let mut visual = gpui::VisualTestContext::from_window(handle.into(), cx);
        let send = visual
            .debug_bounds("write-send")
            .expect("Send now is visible");
        visual.simulate_click(send.center(), gpui::Modifiers::none());
    } else {
        cx.simulate_keystrokes(handle.into(), &platform_combo(shortcut));
    }
    cx.run_until_parked();
    draw(cx, handle);

    let mut sent = None;
    let mut request_log = Vec::new();
    while let Ok(frame) = requests.try_recv() {
        let frame: harness_rpc::ClientFrame = serde_json::from_str(&frame).unwrap();
        request_log.push((frame.method.clone(), frame.params.clone()));
        if opposite_follow_up && frame.method.as_deref() == Some(methods::QUEUE_MESSAGE) {
            assert_eq!(frame.params["chatId"], "chat");
            assert_eq!(frame.params["holdForTurnEnd"], true);
            sent = frame.params["text"].as_str().map(str::to_owned);
        } else if frame.method.as_deref() == Some(methods::QUEUE_COMMAND) {
            assert!(
                !opposite_follow_up,
                "the alternate Queue action must enqueue an editable message, not start another run"
            );
            sent = frame.params["command"]["request"]["prompt"]
                .as_str()
                .map(str::to_owned);
        }
    }
    let outcome = composer.read_with(cx, |composer, cx| {
        (
            composer.input.read(cx).text().to_owned(),
            composer.write_open(),
            composer.failure.clone(),
            composer.button_mode(cx),
            composer.sending,
        )
    });
    let expected_event = if opposite_follow_up {
        ComposerInputEvent::FollowUpSubmitted
    } else {
        ComposerInputEvent::Submitted
    };
    if !click_send {
        assert!(
            input_events.borrow().contains(&expected_event),
            "{shortcut} must dispatch {expected_event:?}; events={:?}; state={outcome:?}; requests={request_log:?}",
            input_events.borrow()
        );
    }
    assert!(
        outcome.2.is_none(),
        "send was refused: state={outcome:?}; requests={request_log:?}"
    );
    assert_eq!(
        sent.as_deref(),
        Some(draft),
        "the page sends the draft as typed; shortcut={shortcut}; state={outcome:?}; events={:?}; requests={request_log:?}",
        input_events.borrow()
    );
    composer.read_with(cx, |composer, cx| {
        assert!(!composer.write_open());
        assert!(composer.input.read(cx).text().is_empty());
    });
}

#[gpui::test]
fn save_click_returns_text_selection_and_attachments_without_submitting_or_uploading(
    cx: &mut gpui::TestAppContext,
) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    let (out, mut requests) = tokio::sync::mpsc::channel::<String>(64);
    let (_replies, inbound) = tokio::sync::mpsc::channel::<String>(64);
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let composer = composer(cx, handle);
    let draft = "# A longer draft\n\nKeep **all** of this, including the attached file.";
    set_draft(cx, handle, draft);
    composer.update(cx, |composer, cx| {
        composer.attachments.insert(
            "chat".into(),
            vec![crate::attachments::StagedAttachment {
                #[cfg(target_os = "macos")]
                editable: None,
                #[cfg(target_os = "macos")]
                unavailable_editable: None,
                unavailable: None,
                annotations: None,
                id: "save-draft-file".into(),
                name: "notes.txt".into(),
                image: None,
                file: Some(std::sync::Arc::from(&b"Unsent notes"[..])),
            }],
        );
        composer.open_write(cx);
        composer
            .input
            .update(cx, |input, _| input.selected_range = 2..14);
        // Record engine calls while returning to the normal composer. Its
        // model picker may load metadata, but Save must never submit the draft
        // or upload its attachment.
        composer.state.update(cx, |state, _| {
            state.set_test_engine(crate::state::EngineHandle::from_test_client(
                harness_rpc::RpcClient::new(out, inbound),
            ));
        });
    });
    draw(cx, handle);
    let mut visual = gpui::VisualTestContext::from_window(handle.into(), cx);
    let save = visual.debug_bounds("write-save").expect("Save is visible");
    visual.simulate_click(save.center(), gpui::Modifiers::none());
    visual.run_until_parked();
    visual.update(|window, cx| window.draw(cx).clear());
    composer.read_with(&visual, |composer, cx| {
        assert!(!composer.write_open());
        assert_eq!(composer.input.read(cx).text(), draft);
        assert_eq!(composer.input.read(cx).selected_range, 2..14);
        assert_eq!(composer.staged().len(), 1);
        assert_eq!(composer.staged()[0].id, "save-draft-file");
        assert_eq!(
            composer.staged()[0].file.as_deref(),
            Some(&b"Unsent notes"[..])
        );
    });
    assert!(visual.debug_bounds("write-page").is_none());
    assert!(visual.debug_bounds("composer-footer").is_some());
    assert!(visual.debug_bounds("composer-write").is_some());
    visual.run_until_parked();
    while let Ok(frame) = requests.try_recv() {
        let frame: harness_rpc::ClientFrame = serde_json::from_str(&frame).unwrap();
        assert!(
            matches!(
                frame.method.as_deref(),
                Some(methods::LIST_HARNESSES | methods::LIST_MODELS)
            ),
            "Save may refresh the normal composer's model metadata, but must not send, queue, steer, upload, or mutate: method={:?}, params={:?}",
            frame.method,
            frame.params,
        );
    }
}

#[gpui::test]
fn a_refused_send_now_click_keeps_the_page_and_the_draft(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let composer = composer(cx, handle);
    set_draft(cx, handle, "Long thoughts on the renderer");
    composer.update(cx, |composer, cx| composer.open_write(cx));
    draw(cx, handle);
    let mut visual = gpui::VisualTestContext::from_window(handle.into(), cx);
    let send = visual
        .debug_bounds("write-send")
        .expect("Send now is visible");
    visual.simulate_click(send.center(), gpui::Modifiers::none());
    composer.read_with(&visual, |composer, _| {
        assert_eq!(composer.failure.as_deref(), Some("Engine not connected"));
        assert!(composer.write_open());
    });
    assert_eq!(text(cx, &composer), "Long thoughts on the renderer");
}

#[gpui::test]
fn switching_chats_closes_the_page_and_keeps_each_draft(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("first".into()));
    let composer = composer(cx, handle);
    set_draft(cx, handle, "First chat's long draft");
    composer.update(cx, |composer, cx| composer.open_write(cx));
    draw(cx, handle);

    let state = composer.read_with(cx, |composer, _| composer.state.clone());
    state.update(cx, |state, cx| state.select_chat(Some("second".into()), cx));
    draw(cx, handle);
    composer.read_with(cx, |composer, cx| {
        assert!(!composer.write_open());
        assert_eq!(composer.input.read(cx).write_face(), None);
        assert_eq!(composer.input.read(cx).text(), "");
    });

    state.update(cx, |state, cx| state.select_chat(Some("first".into()), cx));
    draw(cx, handle);
    assert_eq!(text(cx, &composer), "First chat's long draft");
}

#[gpui::test]
fn aa_switches_the_page_to_serif_and_remembers_it(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let composer = composer(cx, handle);
    set_draft(cx, handle, "Draft");
    composer.update(cx, |composer, cx| {
        composer.open_write(cx);
        composer.toggle_write_face(cx);
        assert_eq!(
            composer.input.read(cx).write_face(),
            Some(WriteFace { serif: true })
        );
        composer.close_write(cx);
        composer.open_write(cx);
        assert_eq!(
            composer.input.read(cx).write_face(),
            Some(WriteFace { serif: true })
        );
    });
    cx.update(|cx| assert!(!crate::settings::with_current(cx, |s| s.write_sans)));
}

#[gpui::test]
fn write_toolbar_font_and_save_are_reachable_and_activated_by_keyboard(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let composer = composer(cx, handle);
    let draft = "The same draft while choosing a typeface.";
    set_draft(cx, handle, draft);
    cx.simulate_keystrokes(handle.into(), &platform_combo(write::toggle_combo()));
    draw(cx, handle);

    // The toolbar order is Attach, Aa, Send now, Save, then the editor.
    cx.simulate_keystrokes(handle.into(), "shift-tab shift-tab shift-tab space");
    draw(cx, handle);
    composer.read_with(cx, |composer, cx| {
        assert!(composer.write_open());
        assert_eq!(
            composer.input.read(cx).write_face(),
            Some(WriteFace { serif: true })
        );
        assert_eq!(composer.input.read(cx).text(), draft);
    });
    cx.update(|cx| assert!(!crate::settings::with_current(cx, |s| s.write_sans)));

    // Enter activates the still-focused Aa control, rather than sending text.
    cx.simulate_keystrokes(handle.into(), "enter");
    draw(cx, handle);
    composer.read_with(cx, |composer, cx| {
        assert!(composer.write_open());
        assert_eq!(
            composer.input.read(cx).write_face(),
            Some(WriteFace { serif: false })
        );
        assert_eq!(composer.input.read(cx).text(), draft);
    });
    cx.simulate_keystrokes(handle.into(), "tab tab enter");
    draw(cx, handle);
    composer.read_with(cx, |composer, cx| {
        assert!(!composer.write_open(), "Save activates from the keyboard");
        assert_eq!(composer.input.read(cx).text(), draft);
    });
}

#[test]
fn existing_settings_start_the_write_page_in_the_interface_font() {
    let settings: crate::settings::UiSettings = serde_json::from_str("{}").unwrap();
    assert!(settings.write_sans);
}

#[gpui::test]
fn switching_blank_workspace_drafts_keeps_text_and_closes_the_old_page(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, handle) = host(cx, |state| state.no_project = true);
    let composer = composer(cx, handle);
    set_draft(cx, handle, "First panel's draft");
    let first = composer.update(cx, |composer, cx| {
        composer.open_write(cx);
        composer.canvas_input(cx)
    });
    let second = crate::pickers::CanvasInput {
        text: "Second panel's draft".into(),
        stage: Vec::new(),
    };
    composer.update(cx, |composer, cx| {
        composer.set_canvas_input(second, cx);
        assert!(!composer.write_open());
        assert_eq!(composer.input.read(cx).write_face(), None);
        assert_eq!(composer.input.read(cx).text(), "Second panel's draft");
        composer.open_write(cx);
        composer.set_canvas_input(first, cx);
        assert!(!composer.write_open());
        assert_eq!(composer.input.read(cx).text(), "First panel's draft");
    });
}

#[gpui::test]
fn write_page_draft_handoff_keeps_text_selection_and_attachments(cx: &mut gpui::TestAppContext) {
    let (_dir, source) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let original = composer(cx, source);
    set_draft(cx, source, "One **draft** across windows");
    let snapshot = original.update(cx, |composer, cx| {
        composer.attachments.insert(
            "chat".into(),
            vec![crate::attachments::StagedAttachment {
                #[cfg(target_os = "macos")]
                editable: None,
                #[cfg(target_os = "macos")]
                unavailable_editable: None,
                unavailable: None,
                annotations: None,
                id: "write-draft-file".into(),
                name: "notes.txt".into(),
                image: None,
                file: Some(std::sync::Arc::from(&b"Unsent file"[..])),
            }],
        );
        composer.open_write(cx);
        composer
            .input
            .update(cx, |input, _| input.selected_range = 4..13);
        composer.window_draft("chat", cx).unwrap()
    });
    let (_other_dir, destination) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let restored = composer(cx, destination);
    restored.update(cx, |composer, cx| {
        composer.adopt_window_draft("chat".into(), snapshot, cx);
        assert_eq!(
            composer.input.read(cx).text(),
            "One **draft** across windows"
        );
        assert_eq!(composer.input.read(cx).selected_range, 4..13);
        assert_eq!(composer.staged().len(), 1);
        assert_eq!(
            composer.staged()[0].file.as_deref(),
            Some(&b"Unsent file"[..])
        );
        assert!(!composer.write_open());
    });
    assert_eq!(
        text(cx, &original),
        "One **draft** across windows",
        "exporting is non-destructive until transfer succeeds"
    );
}

#[gpui::test]
fn write_toolbar_fits_narrow_panels_with_save_rightmost_and_no_bottom_dock(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    set_draft(cx, handle, "A draft to send");
    let visual = gpui::VisualTestContext::from_window(handle.into(), cx);
    for width in [320.0, 384.0, 560.0] {
        // A native resize request does not change TestWindow's actual size.
        // Deliver its platform resize event so we test a real narrow viewport.
        visual.simulate_resize(size(px(width), px(720.0)));
        handle
            .update(cx, |host, _, cx| {
                host.composer.update(cx, |composer, cx| {
                    composer.set_available_width(width, cx);
                    composer.set_available_height(720.0, cx);
                    composer.open_write(cx);
                });
            })
            .unwrap();
        draw(cx, handle);
        handle
            .update(cx, |_, window, _| {
                let toolbar = window.debug_bounds("write-toolbar").unwrap();
                assert_eq!(
                    toolbar.size.width,
                    px(width),
                    "the fixture must use the requested viewport width"
                );
                assert!(toolbar.size.height <= px(48.0), "compact top toolbar");
                assert!(toolbar.origin.y <= px(1.0));
                let controls =
                    ["write-attach", "write-font", "write-send", "write-save"].map(|id| {
                        window
                            .debug_bounds(id)
                            .unwrap_or_else(|| panic!("{id} missing at {width}"))
                    });
                for bounds in controls {
                    assert!(bounds.origin.x >= px(0.0));
                    assert!(
                        bounds.right() <= px(width),
                        "control clips at {width}: {bounds:?}"
                    );
                    assert!(bounds.origin.y >= toolbar.origin.y);
                    assert!(bounds.bottom() <= toolbar.bottom());
                }
                for pair in controls.windows(2) {
                    assert!(
                        pair[0].right() <= pair[1].origin.x,
                        "toolbar controls overlap at {width}"
                    );
                }
                let save = controls[3];
                assert!(
                    px(width) - save.right() <= px(16.0),
                    "Save belongs at the right edge"
                );
                let body = window.debug_bounds("write-page-body").unwrap();
                assert!(body.origin.y >= toolbar.bottom());
                assert!(
                    body.bottom() >= px(704.0),
                    "editor keeps the space formerly occupied by the bottom dock"
                );
                for id in [
                    "write-dock",
                    "write-bottom-dock",
                    "composer-footer",
                    "composer-write",
                    "write-done",
                ] {
                    assert!(
                        window.debug_bounds(id).is_none(),
                        "old bottom controls must not render: {id}"
                    );
                }
            })
            .unwrap();
    }
}

#[gpui::test]
fn write_page_thumbnail_opens_preview_and_escape_returns_to_the_same_draft(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let composer = composer(cx, handle);
    let draft = "Keep this draft while inspecting the attached image.";
    set_draft(cx, handle, draft);
    composer.update(cx, |composer, cx| {
        let png = base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1cAAAAASUVORK5CYII=",
        )
        .unwrap();
        composer.attachments.insert(
            "chat".into(),
            vec![attachments::stage_png_bytes("preview.png".into(), png)],
        );
        composer.open_write(cx);
    });
    let mut visual = gpui::VisualTestContext::from_window(handle.into(), cx);
    let draw = |visual: &mut gpui::VisualTestContext| {
        visual.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
    };
    draw(&mut visual);
    let thumbnail = visual.debug_bounds("composer-att-thumb-0").unwrap();
    visual.simulate_click(thumbnail.center(), gpui::Modifiers::none());
    draw(&mut visual);
    assert!(
        visual.debug_bounds("attachment-lightbox-frame").is_some(),
        "the expanded editor must actually draw the clicked image's preview"
    );
    composer.read_with(&visual, |composer, cx| {
        assert!(composer.write_open());
        assert!(composer.preview.is_some());
        assert_eq!(composer.input.read(cx).text(), draft);
        assert_eq!(composer.staged().len(), 1);
    });

    visual.simulate_keystrokes("escape");
    draw(&mut visual);
    assert!(visual.debug_bounds("attachment-lightbox-frame").is_none());
    handle
        .update(&mut visual, |host, window, cx| {
            let composer = host.composer.read(cx);
            assert!(
                composer.write_open(),
                "the first Escape closes only the image"
            );
            assert!(composer.preview.is_none());
            assert!(composer.input.focus_handle(cx).is_focused(window));
        })
        .unwrap();
    visual.simulate_keystrokes("escape");
    draw(&mut visual);
    assert!(visual.debug_bounds("attachment-lightbox-frame").is_none());
    composer.read_with(&visual, |composer, cx| {
        assert!(!composer.write_open());
        assert!(
            composer.preview.is_none(),
            "no deferred preview after closing the editor"
        );
        assert_eq!(composer.input.read(cx).text(), draft);
        assert_eq!(composer.staged().len(), 1);
    });
}
