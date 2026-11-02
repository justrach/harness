//! The Write page: it edits the composer's own draft, gives it back intact,
//! and sends through the composer's send path.
use super::*;

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
            Some(WriteFace { serif: true })
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
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    let (out, mut requests) = tokio::sync::mpsc::channel::<String>(64);
    let (_replies, inbound) = tokio::sync::mpsc::channel::<String>(64);
    let (_dir, handle) = host(cx, move |state| {
        state.set_test_engine(crate::state::EngineHandle::from_test_client(
            harness_rpc::RpcClient::new(out, inbound),
        ));
        state.selected_chat = Some("chat".into());
    });
    let composer = composer(cx, handle);
    let draft = "# Plan\n\n- Cap the reel at `30s`\n- **Never** re-encode";
    set_draft(cx, handle, draft);
    composer.update(cx, |composer, cx| composer.open_write(cx));
    draw(cx, handle);

    cx.simulate_keystrokes(handle.into(), &platform_combo("mod-enter"));
    cx.run_until_parked();
    draw(cx, handle);

    let mut sent = None;
    while let Ok(frame) = requests.try_recv() {
        let frame: harness_rpc::ClientFrame = serde_json::from_str(&frame).unwrap();
        if frame.method.as_deref() == Some(methods::QUEUE_COMMAND) {
            sent = frame.params["command"]["request"]["prompt"]
                .as_str()
                .map(str::to_owned);
        }
    }
    assert_eq!(
        sent.as_deref(),
        Some(draft),
        "the page sends the draft as typed"
    );
    composer.read_with(cx, |composer, cx| {
        assert!(!composer.write_open());
        assert!(composer.input.read(cx).text().is_empty());
    });
}

#[gpui::test]
fn a_refused_send_keeps_the_page_and_the_draft(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let composer = composer(cx, handle);
    set_draft(cx, handle, "Long thoughts on the renderer");
    composer.update(cx, |composer, cx| {
        composer.open_write(cx);
        // The Send button's path, with no engine attached.
        composer.send_from_write(cx);
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
fn aa_switches_the_page_to_sans_and_remembers_it(cx: &mut gpui::TestAppContext) {
    let (_dir, handle) = host(cx, |state| state.selected_chat = Some("chat".into()));
    let composer = composer(cx, handle);
    set_draft(cx, handle, "Draft");
    composer.update(cx, |composer, cx| {
        composer.open_write(cx);
        composer.toggle_write_face(cx);
        assert_eq!(
            composer.input.read(cx).write_face(),
            Some(WriteFace { serif: false })
        );
        composer.close_write(cx);
        composer.open_write(cx);
        assert_eq!(
            composer.input.read(cx).write_face(),
            Some(WriteFace { serif: false })
        );
    });
    cx.update(|cx| assert!(crate::settings::with_current(cx, |s| s.write_sans)));
}
