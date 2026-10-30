use super::*;
use crate::markdown::render::LinkUi;

mod cached;
mod closure;
mod destinations;
mod guards;
mod lifecycle;
mod matrix;
mod menus;
mod race_edges;
mod revocations;
mod spawns;

const URL: &str = "https://example.com/docs?owner=current#details";

fn navigate(shell: &Entity<Shell>, chat: &str, cx: &mut gpui::VisualTestContext) {
    shell.update(cx, |shell, cx| {
        shell.state.update(cx, |state, cx| {
            if !state.chats.iter().any(|row| row.id == chat) {
                state.chats.push(
                    serde_json::from_value(serde_json::json!({
                        "id": chat, "deviceId": "local", "title": "Session",
                        "archived": false, "createdAt": Utc::now(),
                    }))
                    .unwrap(),
                );
            }
            state.select_chat(Some(chat.into()), cx);
            // This synthetic snapshot replaces any restored prepared rows.
            state.prepared_transcripts.remove(chat);
            let mut entry = reply(&format!("[Docs]({URL})"));
            entry.id = format!("{chat}-link-reply");
            state.transcript = vec![entry];
            state.transcript_replayed = true;
            state.transcript_revision += 1;
            cx.notify();
        });
    });
    draw(cx);
}

fn promote(shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext) {
    shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(0, cx)));
    draw(cx);
}

fn links(transcript: &Entity<Transcript>, cx: &mut gpui::VisualTestContext) -> LinkUi {
    transcript.read_with(cx, |transcript, _| transcript.link_ui().unwrap())
}

fn activation(link: &LinkUi, action: LinkAction) -> LinkActivation {
    LinkActivation {
        target: LinkTarget::new("Docs", URL),
        action,
        source_session: link.source_session.clone(),
    }
}

fn click_current_link(shell: &Entity<Shell>, chat: &str, cx: &mut gpui::VisualTestContext) {
    let (transcript, before) = shell.read_with(cx, |shell, _| {
        (shell.transcript.clone(), shell.browsers.len())
    });
    assert_eq!(links(&transcript, cx).source_session.as_deref(), Some(chat));
    cx.simulate_click(
        text_point(&transcript, &format!("{chat}-link-reply#text.0:0")),
        Default::default(),
    );
    draw(cx);
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.browsers.len(), before + 1);
        assert_eq!(shell.active_chat, chat);
        assert_eq!(
            shell.browsers[&shell.browser_seq]
                .read(cx)
                .page
                .url
                .as_deref(),
            Some(URL)
        );
        assert!(shell.right_tabs[chat].contains(&RightSurface::Browser(shell.browser_seq)));
    });
}

fn open_menu(transcript: &Entity<Transcript>, chat: &str, cx: &mut gpui::VisualTestContext) {
    let point = text_point(transcript, &format!("{chat}-link-reply#text.0:0"));
    cx.simulate_mouse_down(point, MouseButton::Right, Default::default());
    cx.simulate_mouse_up(point, MouseButton::Right, Default::default());
    draw(cx);
    assert!(cx.debug_bounds("Open in Harness").is_some());
}
