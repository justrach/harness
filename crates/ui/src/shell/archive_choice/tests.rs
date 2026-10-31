use super::*;
use crate::shell::chat_tabs::navigation_tests::fixture;
use crate::shell::chat_tabs::pane_reopen_tests::{mutations, press, reply};

fn chosen(cx: &mut gpui::TestAppContext) -> (bool, bool) {
    cx.update(|cx| {
        (
            settings::archive_on_close_chosen(cx),
            settings::archive_sessions_on_close(cx),
        )
    })
}

fn prompt_and_selection(
    cx: &mut gpui::TestAppContext,
    window: gpui::WindowHandle<Shell>,
) -> (bool, Option<String>) {
    window
        .update(cx, |shell, _, cx| {
            (
                shell.archive_choice_prompt,
                shell.state.read(cx).selected_chat.clone(),
            )
        })
        .unwrap()
}

#[test]
fn copy_names_both_shortcuts_and_the_remembered_default() {
    let (title, body) = archive_choice_copy("⌘W", "⌥⌘W");
    assert_eq!(title, "What should ⌘W do when you close a chat?");
    assert!(body.contains("⌥⌘W always just closes"), "{body}");
    assert!(body.contains("Your choice becomes the default"), "{body}");
    assert!(
        body.contains("Settings \u{2192} Archived sessions"),
        "{body}"
    );
    assert_eq!(SettingsSection::Archived.label(), "Archived sessions");
}

#[gpui::test]
fn cmd_w_asks_and_escape_cancels(cx: &mut gpui::TestAppContext) {
    let (dir, window) = fixture(cx, false, None);
    assert_eq!(chosen(cx), (false, false));
    press(cx, window, "mod-w");
    assert_eq!(
        prompt_and_selection(cx, window),
        (true, Some("current".into())),
        "⌘W asks and closes nothing yet"
    );
    press(cx, window, "mod-w");
    assert_eq!(
        prompt_and_selection(cx, window),
        (true, Some("current".into())),
        "repeating ⌘W while the question is open still closes nothing"
    );
    press(cx, window, "escape");
    assert_eq!(
        prompt_and_selection(cx, window),
        (false, Some("current".into())),
        "Escape cancels: nothing closes"
    );
    assert_eq!(chosen(cx), (false, false), "and nothing is saved");
    assert!(!settings::UiSettings::load(dir.path()).archive_on_close_chosen);
    // Cancelled questions are asked again.
    press(cx, window, "mod-w");
    assert!(prompt_and_selection(cx, window).0);
    press(cx, window, "escape");
    // ⌘⌥W never asks; it just closes.
    press(cx, window, "mod-alt-w");
    assert_eq!(prompt_and_selection(cx, window), (false, None));
    assert_eq!(chosen(cx), (false, false));
}

struct ArchiveChoiceHost {
    shell: Entity<Shell>,
    _updates: Subscription,
}

impl Render for ArchiveChoiceHost {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.shell.update(cx, |shell, cx| {
            let theme = Theme::of(cx).clone();
            shell
                .render_archive_choice_dialog(window.viewport_size(), &theme, cx)
                .unwrap_or_else(|| gpui::Empty.into_any_element())
        })
    }
}

#[gpui::test]
fn top_right_dismiss_keeps_chat_open_and_saves_nothing(cx: &mut gpui::TestAppContext) {
    let (dir, window) = fixture(cx, false, None);
    press(cx, window, "mod-w");
    let shell = window.root(cx).unwrap();
    let (_host, visual) = cx.add_window_view(|_, cx| ArchiveChoiceHost {
        _updates: cx.observe(&shell, |_, _, cx| cx.notify()),
        shell,
    });
    visual.run_until_parked();
    let dismiss = visual
        .debug_bounds("archive-choice-dismiss")
        .expect("the setup dialog has a dismiss control");
    let card = visual.debug_bounds("archive-choice-card").unwrap();
    let inset = px(9.0); // 8px inset inside the card's 1px border.
    assert_eq!(dismiss.top(), card.top() + inset);
    assert_eq!(dismiss.right(), card.right() - inset);
    visual.simulate_click(dismiss.center(), gpui::Modifiers::none());
    visual.run_until_parked();
    assert_eq!(
        prompt_and_selection(cx, window),
        (false, Some("current".into()))
    );
    assert_eq!(chosen(cx), (false, false));
    assert!(!settings::UiSettings::load(dir.path()).archive_on_close_chosen);
    press(cx, window, "mod-w");
    assert!(
        prompt_and_selection(cx, window).0,
        "dismiss did not choose a default"
    );
    press(cx, window, "escape");
}

#[gpui::test]
fn close_buttons_never_ask(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = fixture(cx, true, None);
    window
        .update(cx, |shell, window, cx| {
            assert!(shell.close_chat_pane(0, window, cx));
            assert!(!shell.archive_choice_prompt);
        })
        .unwrap();
    assert_eq!(chosen(cx), (false, false));

    // A tab's ✕ closes the whole tab without asking either.
    let (_dir, window) = fixture(cx, false, Some(false));
    window
        .update(cx, |shell, window, cx| {
            assert!(shell.close_chat_tab_at(1, window, cx));
            // One tab left: the strip collapses.
            assert!(shell.chat_tabs.is_empty());
            assert!(!shell.archive_choice_prompt);
        })
        .unwrap();
    assert_eq!(chosen(cx), (false, false));
}

#[gpui::test]
fn first_close_answer_is_saved_and_reused(cx: &mut gpui::TestAppContext) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let _guard = runtime.enter();
    for archive in [false, true] {
        let (dir, window) = fixture(cx, false, None);
        let (out, mut requests) = tokio::sync::mpsc::channel(128);
        let (replies, inbound) = tokio::sync::mpsc::channel(128);
        let engine =
            crate::state::EngineHandle::from_test_client(harness_rpc::RpcClient::new(out, inbound));
        window
            .update(cx, |shell, _, cx| {
                shell
                    .state
                    .update(cx, |state, _| state.set_test_engine(engine));
            })
            .unwrap();
        press(cx, window, "mod-w");
        assert!(prompt_and_selection(cx, window).0);
        assert!(
            mutations(&mut requests).is_empty(),
            "nothing archives before the answer"
        );
        window
            .update(cx, |shell, window, cx| {
                assert!(shell.choose_close_archiving(archive, window, cx));
                assert!(!shell.choose_close_archiving(!archive, window, cx));
            })
            .unwrap();
        cx.run_until_parked();
        assert_eq!(
            prompt_and_selection(cx, window),
            (false, None),
            "archive={archive}"
        );
        let closing = mutations(&mut requests);
        assert_eq!(closing.len(), usize::from(archive), "archive={archive}");
        if archive {
            assert_eq!(closing[0]["params"]["chatId"], "current");
            assert_eq!(closing[0]["params"]["archived"], true);
            reply(&runtime, &replies, &closing[0]);
            cx.run_until_parked();
        }
        assert_eq!(chosen(cx), (true, archive));
        let saved = settings::UiSettings::load(dir.path());
        assert!(saved.archive_on_close_chosen);
        assert_eq!(saved.archive_sessions_on_close, archive);

        // Reload the persisted settings, as on a later app launch.
        cx.update(|cx| settings::init(saved, dir.path(), cx));
        // The next ⌘W follows the default without asking.
        window
            .update(cx, |shell, _, cx| {
                shell.open_chat("peer".into(), cx);
                shell.chat_split_on_state_changed(cx);
            })
            .unwrap();
        press(cx, window, "mod-w");
        assert_eq!(
            prompt_and_selection(cx, window),
            (false, None),
            "archive={archive}"
        );
        let closing = mutations(&mut requests);
        assert_eq!(closing.len(), usize::from(archive), "archive={archive}");
        if archive {
            assert_eq!(closing[0]["params"]["chatId"], "peer");
            reply(&runtime, &replies, &closing[0]);
            cx.run_until_parked();
        }
        assert_eq!(chosen(cx), (true, archive));
        window
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
    }
}

#[gpui::test]
fn a_saved_close_preference_skips_the_question(cx: &mut gpui::TestAppContext) {
    for preference in [false, true] {
        let (dir, window) = fixture(cx, false, None);
        cx.update(|cx| settings::set_archive_sessions_on_close(preference, cx));
        assert_eq!(chosen(cx), (true, preference));
        assert!(settings::UiSettings::load(dir.path()).archive_on_close_chosen);
        press(cx, window, "mod-w");
        assert_eq!(
            prompt_and_selection(cx, window),
            (false, None),
            "a saved close preference must skip the question"
        );
        window
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
    }
}

#[gpui::test]
fn an_existing_install_with_archiving_enabled_is_not_asked(cx: &mut gpui::TestAppContext) {
    let (dir, window) = fixture(cx, false, None);
    // A settings file from before the question existed, with the toggle on.
    std::fs::write(
        settings::UiSettings::path(dir.path()),
        serde_json::json!({ "archiveSessionsOnClose": true }).to_string(),
    )
    .unwrap();
    let loaded = settings::UiSettings::load(dir.path());
    assert!(loaded.archive_on_close_chosen);
    cx.update(|cx| settings::update(settings::SavePolicy::Immediate, cx, |s| *s = loaded));
    press(cx, window, "mod-w");
    assert_eq!(prompt_and_selection(cx, window), (false, None));
    assert_eq!(chosen(cx), (true, true));
}
