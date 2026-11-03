//! Settings → Archived (feature-inventory §1.5): archived chats across
//! devices, with Unarchive (Mutate setChatArchived false) and a confirmed
//! Delete all (Mutate deleteChat per archived chat).

use gpui::{
    AnyElement, Context, Entity, SharedString, Subscription, Task, Window, div, prelude::*, px,
};

use harness_proto::Chat;
use harness_rpc::methods;

use crate::popover;
use crate::settings::widgets;
use crate::state::AppState;
use crate::theme::Theme;

/// The archive-on-close row's description, given the close shortcut and the
/// close-without-archiving one as displayed ("⌘W", "⌥⌘W").
pub(crate) fn archive_on_close_copy(close: &str, close_only: &str) -> String {
    format!(
        "Closing a session tab or pane with {close} or its \u{2715} button archives it if idle, \
         unless it is still open in another tab or pane in this app. The first {close} asks \
         you to choose this default. {close_only} always closes without archiving. Running \
         sessions and sessions waiting for input remain in the sidebar. Closing the app \
         or a window does not archive sessions."
    )
}

/// Archived rows in sidebar (recency) order. Pure.
pub fn archived_chats(chats: &[Chat]) -> Vec<&Chat> {
    chats.iter().filter(|c| c.archived).collect()
}

pub struct ArchivedPage {
    state: Entity<AppState>,
    scroll: widgets::PageScroll,
    error: Option<SharedString>,
    /// Chat with an in-flight unarchive (button shows working state).
    busy: Option<String>,
    /// Row index under the pointer — drives the original's `group-hover`
    /// Unarchive reveal (`opacity-0 group-hover:opacity-100`).
    hovered: Option<usize>,
    /// Archived ids captured when Delete all was clicked. The dialog deletes
    /// exactly these, never a chat archived while it was open.
    delete_all_confirm: Option<Vec<String>>,
    /// In-flight Delete all; held so repeat clicks can't start a second run.
    delete_all_task: Option<Task<()>>,
    task: Option<Task<()>>,
    _observe: Subscription,
}

impl ArchivedPage {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&state, |_, _, cx| cx.notify());
        Self {
            state,
            scroll: widgets::PageScroll::default(),
            error: None,
            busy: None,
            hovered: None,
            delete_all_confirm: None,
            delete_all_task: None,
            task: None,
            _observe: observe,
        }
    }

    fn toggle_archive_on_close(&mut self, cx: &mut Context<Self>) {
        let enabled = crate::settings::archive_sessions_on_close(cx);
        crate::settings::set_archive_sessions_on_close(!enabled, cx);
        cx.notify();
    }

    fn unarchive(&mut self, chat_id: String, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.busy = Some(chat_id.clone());
        self.error = None;
        let params = serde_json::json!({
            "op": "setChatArchived",
            "chatId": chat_id,
            "archived": false,
        });
        self.task = Some(cx.spawn(async move |this, cx| {
            let result = engine.client().call(methods::MUTATE, params).await;
            this.update(cx, |page, cx| {
                page.busy = None;
                if let Err(err) = result {
                    page.error = Some(format!("Unarchive failed: {err}").into());
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn request_delete_all(&mut self, cx: &mut Context<Self>) {
        if self.delete_all_task.is_some() {
            return;
        }
        let ids: Vec<String> = archived_chats(&self.state.read(cx).chats)
            .into_iter()
            .map(|chat| chat.id.clone())
            .collect();
        if !ids.is_empty() {
            self.delete_all_confirm = Some(ids);
            cx.notify();
        }
    }

    /// Escape closes the Delete all dialog (the shell routes it here while
    /// Settings → Archived is open). False when no dialog was open.
    pub(crate) fn dismiss_on_escape(&mut self, cx: &mut Context<Self>) -> bool {
        if self.delete_all_confirm.take().is_none() {
            return false;
        }
        cx.notify();
        true
    }

    fn delete_all(&mut self, cx: &mut Context<Self>) {
        let Some(ids) = self.delete_all_confirm.take() else {
            return;
        };
        if self.delete_all_task.is_some() {
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.error = Some("Engine not connected".into());
            cx.notify();
            return;
        };
        self.error = None;
        // One request per chat, the same `deleteChat` the sidebar's Delete
        // sends: the registry tombstones each row, so it leaves this list and
        // the sidebar's Archived shelf as soon as its delete lands.
        self.delete_all_task = Some(cx.spawn(async move |this, cx| {
            let mut failed = 0;
            for chat_id in ids {
                // Unarchived since the confirmation (here, or on another
                // device): no longer part of what the user agreed to delete.
                let still_archived = this
                    .update(cx, |page, cx| {
                        page.state
                            .read(cx)
                            .chats
                            .iter()
                            .any(|chat| chat.id == chat_id && chat.archived)
                    })
                    .unwrap_or(false);
                if !still_archived {
                    continue;
                }
                let params = serde_json::json!({ "op": "deleteChat", "chatId": chat_id });
                if engine.client().call(methods::MUTATE, params).await.is_err() {
                    failed += 1;
                }
            }
            this.update(cx, |page, cx| {
                page.delete_all_task = None;
                if failed > 0 {
                    page.error = Some(delete_all_failure(failed).into());
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn render_delete_all_dialog(
        &mut self,
        viewport: gpui::Size<gpui::Pixels>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let count = self.delete_all_confirm.as_ref()?.len();
        let theme = Theme::of(cx).clone();
        // Same card as the sidebar's single "Delete session?" confirmation.
        let card = popover::dialog_card(&theme)
            .child(popover::dialog_title(
                &theme,
                "Delete all archived sessions?",
            ))
            .child(
                div()
                    .mt(px(6.0))
                    .child(popover::dialog_body(&theme, delete_all_body(count))),
            )
            .child(
                div()
                    .mt(px(16.0))
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        popover::btn_ghost(&theme, "Cancel", "delete-archived-cancel")
                            .id("delete-archived-cancel")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.delete_all_confirm = None;
                                cx.notify();
                            })),
                    )
                    .child(
                        popover::btn_danger(&theme, "Delete all")
                            .id("delete-archived-confirm")
                            .on_click(cx.listener(|this, _, _, cx| this.delete_all(cx))),
                    ),
            )
            .into_any_element();
        Some(popover::modal("delete-archived-dialog", viewport, card))
    }

    fn on_scroll_hovered(&mut self, hovered: &bool, _: &mut Window, cx: &mut Context<Self>) {
        if self.scroll.set_list_hovered(*hovered) {
            cx.notify();
        }
    }
}

impl popover::ScrollRailHost for ArchivedPage {
    fn rail_bar(&mut self) -> &mut popover::MenuScrollbarState {
        self.scroll.rail_bar()
    }

    fn rail_scroll(&self) -> Option<gpui::ScrollHandle> {
        self.scroll.rail_scroll()
    }
}

impl Render for ArchivedPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dialog = self.render_delete_all_dialog(window.viewport_size(), cx);
        let theme = Theme::of(cx).clone();
        let accent = theme.accent;
        let archive_sessions_on_close = crate::settings::archive_sessions_on_close(cx);
        let (close, close_only) = crate::settings::close_shortcut_badges(cx);
        let now = chrono::Utc::now();
        let (rows, device_names): (Vec<Chat>, std::collections::HashMap<String, String>) = {
            let state = self.state.read(cx);
            let rows = archived_chats(&state.chats).into_iter().cloned().collect();
            let names = state
                .devices
                .iter()
                .map(|d| (d.id.clone(), d.name.clone()))
                .collect();
            (rows, names)
        };
        let busy = self.busy.clone();
        let count = rows.len();

        let items: Vec<AnyElement> = rows
            .into_iter()
            .enumerate()
            .map(|(ix, chat)| {
                let title: SharedString = chat
                    .title
                    .clone()
                    .unwrap_or_else(|| "Untitled session".into())
                    .into();
                // Unknown device → no fragment at all (harness renders the
                // device span only when the name resolves).
                let device: Option<SharedString> =
                    device_names.get(&chat.device_id).cloned().map(Into::into);
                let time_ago: SharedString = crate::state::format_time_ago(
                    chat.last_message_at.unwrap_or(chat.created_at),
                    now,
                )
                .into();
                let location: Option<SharedString> =
                    crate::state::chat_location(&chat).map(Into::into);
                let is_busy = busy.as_deref() == Some(chat.id.as_str());
                let row_hovered = self.hovered == Some(ix);
                let chat_id = chat.id.clone();
                // harness settings.archived.tsx row: archive tile, medium title
                // + tabular time, quiet device · location meta, Unarchive.
                div()
                    .id(("archived-row", ix))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(12.0))
                    .rounded(px(8.0))
                    .px(px(12.0))
                    .py(px(8.0))
                    .hover(|s| s.bg(crate::theme::ink(0.03)))
                    .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                        if *hovered {
                            this.hovered = Some(ix);
                        } else if this.hovered == Some(ix) {
                            this.hovered = None;
                        }
                        cx.notify();
                    }))
                    .child(
                        div()
                            .flex_none()
                            .size(px(32.0))
                            .rounded(px(6.0))
                            .border_1()
                            .border_color(theme.border)
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(
                                crate::icons::icon(crate::icons::ARCHIVE_MINIMALISTIC)
                                    .size(px(16.0))
                                    .text_color(theme.text_muted.opacity(0.6)),
                            ),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(px(8.0))
                                    .child(
                                        div()
                                            .min_w_0()
                                            .truncate()
                                            .text_size(crate::typography::ui_rems(13.0))
                                            .font_weight(gpui::FontWeight::MEDIUM)
                                            .text_color(theme.text)
                                            .child(title),
                                    )
                                    .child(
                                        div()
                                            .flex_none()
                                            .text_size(crate::typography::ui_rems(11.0))
                                            .text_color(theme.text_muted.opacity(0.5))
                                            .child(time_ago),
                                    ),
                            )
                            .child({
                                // device · location, separator at the line's
                                // own tone (harness: a plain span inheriting
                                // `text-muted-foreground/55`).
                                let mut meta = div()
                                    .mt(px(2.0))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(px(6.0))
                                    .text_size(crate::typography::ui_rems(11.0))
                                    .text_color(theme.text_muted.opacity(0.55));
                                let both = device.is_some() && location.is_some();
                                if let Some(device) = device {
                                    meta = meta.child(device);
                                }
                                if both {
                                    meta = meta.child(SharedString::from("·"));
                                }
                                if let Some(location) = location {
                                    meta = meta.child(div().min_w_0().truncate().child(location));
                                }
                                meta
                            }),
                    )
                    .child(
                        // Hidden until the row is hovered (harness `opacity-0
                        // group-hover:opacity-100`); hover fill is the solid
                        // accent tone (`hover:bg-accent`).
                        div()
                            .id(("unarchive", ix))
                            .flex_none()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(6.0))
                            .px(px(10.0))
                            .py(px(4.0))
                            .rounded(px(6.0))
                            .border_1()
                            .border_color(theme.border)
                            .text_size(crate::typography::ui_rems(12.0))
                            .text_color(theme.text_muted)
                            .opacity(if row_hovered || is_busy { 1.0 } else { 0.0 })
                            .when(is_busy, |el| el.opacity(0.4))
                            .cursor_pointer()
                            .hover(|s| s.bg(theme.surface_raised).text_color(theme.text))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.unarchive(chat_id.clone(), cx);
                            }))
                            .child(
                                crate::icons::icon(crate::icons::ARCHIVE_UP_MINIMALISTIC)
                                    .size(px(14.0))
                                    .text_color(theme.text_muted),
                            )
                            .child(SharedString::from(if is_busy {
                                "Unarchiving…"
                            } else {
                                "Unarchive"
                            })),
                    )
                    .into_any_element()
            })
            .collect();

        let body: AnyElement = if items.is_empty() {
            // Centered empty state (harness settings.archived.tsx).
            div()
                .mt(px(96.0))
                .flex()
                .flex_col()
                .items_center()
                .text_center()
                .text_color(theme.text_muted.opacity(0.5))
                .child(
                    // `opacity-40` on top of the inherited muted/50 — an
                    // effectively ~20% glyph (harness settings.archived.tsx).
                    crate::icons::icon(crate::icons::ARCHIVE_MINIMALISTIC)
                        .size(px(28.0))
                        .text_color(theme.text_muted.opacity(0.2)),
                )
                .child(
                    div()
                        .mt(px(12.0))
                        .text_size(crate::typography::ui_rems(14.0))
                        .child(SharedString::from("Nothing archived")),
                )
                .child(
                    div()
                        .mt(px(4.0))
                        .text_size(crate::typography::ui_rems(12.0))
                        .text_color(theme.text_muted.opacity(0.4))
                        .child(SharedString::from(
                            "Right-click a session in the sidebar to archive it.",
                        )),
                )
                .into_any_element()
        } else {
            div()
                .mt(px(24.0))
                .flex()
                .flex_col()
                .gap(px(2.0))
                .children(items)
                .into_any_element()
        };

        let deleting = self.delete_all_task.is_some();
        // The dialogs' destructive fill (`popover::btn_danger`) with the
        // trash glyph; hidden when nothing is archived.
        let delete_all = (count > 0).then(|| {
            div()
                .id("archived-delete-all")
                .flex_none()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(6.0))
                .px(px(12.0))
                .py(px(6.0))
                .rounded(px(8.0))
                .bg(theme.danger_strong)
                .text_size(crate::typography::ui_rems(13.0))
                .font_weight(gpui::FontWeight::MEDIUM)
                .text_color(gpui::white())
                .when(deleting, |el| el.opacity(0.5))
                .when(!deleting, |el| {
                    el.cursor_pointer().hover(|s| s.opacity(0.9))
                })
                .tab_index(0)
                .role(gpui::Role::Button)
                .focus_visible(move |style| style.border_2().border_color(accent))
                .on_click(cx.listener(|this, _, _, cx| this.request_delete_all(cx)))
                .child(
                    crate::icons::icon(crate::icons::TRASH_BIN_MINIMALISTIC)
                        .size(px(14.0))
                        .text_color(gpui::white()),
                )
                .child(SharedString::from(if deleting {
                    "Deleting…"
                } else {
                    "Delete all"
                }))
        });
        let scrollbar = popover::rail(self, "archived-page-scrollbar", &theme, cx);
        div()
            .id("archived-page-host")
            .relative()
            .size_full()
            .on_hover(cx.listener(Self::on_scroll_hovered))
            .child(
                div()
                    .id("archived-page")
                    .size_full()
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll.scroll)
                    .child(
                        widgets::page_column()
                            .child(
                                // Delete all sits bottom-right, level with the
                                // subtitle rather than the title.
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_end()
                                    .gap(px(16.0))
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .child(widgets::page_header(
                                                &theme,
                                                "Archived sessions",
                                                (count > 0).then_some(count),
                                            ))
                                            .child(widgets::page_subtitle(
                                                &theme,
                                                "Hidden from the sidebar until you unarchive or delete them. Unarchiving puts a session back on its device.",
                                            )),
                                    )
                                    .children(delete_all),
                            )
                            .child(
                                widgets::section_card(&theme).child(
                                    widgets::card_row(&theme, true)
                                        .child(
                                            div()
                                                .flex_1()
                                                .min_w_0()
                                                .child(widgets::row_title(
                                                    &theme,
                                                    "Archive sessions when closing tabs or panes",
                                                ))
                                                .child(
                                                    div()
                                                        .mt(px(4.0))
                                                        .text_size(crate::typography::ui_rems(12.0))
                                                        .text_color(theme.text_muted)
                                                        .child(archive_on_close_copy(&close, &close_only)),
                                                ),
                                        )
                                        .child(
                                            div()
                                                .id("archive-on-close-toggle")
                                                .flex_none()
                                                .size(px(40.0))
                                                .flex()
                                                .items_center()
                                                .justify_center()
                                                .role(gpui::Role::Switch)
                                                .aria_label("Archive sessions when closing tabs or panes")
                                                .aria_toggled(if archive_sessions_on_close {
                                                    gpui::Toggled::True
                                                } else {
                                                    gpui::Toggled::False
                                                })
                                                .tab_index(0)
                                                .focus_visible(move |style| style.border_2().border_color(accent))
                                                .cursor_pointer()
                                                .on_click(cx.listener(|this, _, _, cx| {
                                                    this.toggle_archive_on_close(cx);
                                                }))
                                                .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                                                    if !event.is_held && matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                                        cx.stop_propagation();
                                                        this.toggle_archive_on_close(cx);
                                                    }
                                                }))
                                                .child(widgets::toggle_switch(
                                                    &theme,
                                                    archive_sessions_on_close,
                                                )),
                                        ),
                                ),
                            )
                            .when_some(self.error.clone(), |el, message| {
                                el.child(
                                    widgets::error_strip(&theme, message)
                                        .id("archived-error")
                                        .cursor_pointer()
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.error = None;
                                            cx.notify();
                                        })),
                                )
                            })
                            .child(body),
                    ),
            )
            .children(scrollbar)
            .children(dialog)
    }
}

fn delete_all_body(count: usize) -> String {
    match count {
        1 => "1 archived session will be permanently deleted. This can\u{2019}t be undone.".into(),
        n => format!(
            "{n} archived sessions will be permanently deleted. This can\u{2019}t be undone."
        ),
    }
}

fn delete_all_failure(failed: usize) -> String {
    match failed {
        1 => "Couldn\u{2019}t delete 1 archived session. Try again.".into(),
        n => format!("Couldn\u{2019}t delete {n} archived sessions. Try again."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn chat(id: &str, archived: bool) -> Chat {
        Chat {
            last_prompt_at: None,
            id: id.into(),
            device_id: "d".into(),
            title: None,
            archived,
            cwd: None,
            branch: None,
            checkout_id: None,
            source_context: None,
            config: None,
            last_message_preview: None,
            last_message_at: None,
            created_at: Utc::now(),
            harness_session_id: None,
            harness_session_cwd: None,
            parent_chat_id: None,
            space_id: None,
            last_seen_at: None,
            room_gen: None,
            source_context_unavailable_at: None,
        }
    }

    #[test]
    fn only_archived_rows_show() {
        let chats = vec![chat("a", false), chat("b", true), chat("c", true)];
        let rows = archived_chats(&chats);
        let ids: Vec<&str> = rows.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["b", "c"]);
    }

    #[test]
    fn archive_on_close_copy_names_what_the_toggle_covers() {
        let copy = archive_on_close_copy("⌘W", "⌥⌘W");
        assert!(copy.starts_with("Closing a session tab or pane with ⌘W or its \u{2715} button"));
        assert!(
            copy.contains("The first ⌘W asks you to choose this default"),
            "{copy}"
        );
        assert!(
            copy.contains("⌥⌘W always closes without archiving."),
            "{copy}"
        );
        assert!(!copy.contains("Explicitly"), "{copy}");
    }

    #[gpui::test]
    fn delete_all_deletes_the_confirmed_archived_chats_and_reports_failures(
        cx: &mut gpui::TestAppContext,
    ) {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _guard = runtime.enter();
        let (out, mut requests) = tokio::sync::mpsc::channel::<String>(16);
        let (replies, inbound) = tokio::sync::mpsc::channel::<String>(16);
        let engine =
            crate::state::EngineHandle::from_test_client(harness_rpc::RpcClient::new(out, inbound));
        let state = cx.new(|_| {
            let mut state = AppState::new();
            state.chats = vec![
                chat("live", false),
                chat("b", true),
                chat("c", true),
                chat("restored", true),
            ];
            state.set_test_engine(engine);
            state
        });
        let page = cx.new(|cx| ArchivedPage::new(state.clone(), cx));
        page.update(cx, |page, cx| {
            // Escape closes the dialog, and reports nothing when none is open.
            page.request_delete_all(cx);
            assert!(page.dismiss_on_escape(cx));
            assert!(page.delete_all_confirm.is_none());
            assert!(!page.dismiss_on_escape(cx));
            page.request_delete_all(cx);
            assert_eq!(
                page.delete_all_confirm.as_deref(),
                Some(&["b".to_string(), "c".to_string(), "restored".to_string()][..])
            );
        });
        // Archived while the dialog was open: not part of what the user
        // confirmed, so it must survive.
        state.update(cx, |state, _| state.chats.push(chat("late", true)));
        page.update(cx, |page, cx| {
            page.delete_all(cx);
            assert!(page.delete_all_confirm.is_none());
        });
        for (index, expected) in ["b", "c"].into_iter().enumerate() {
            cx.run_until_parked();
            let request: serde_json::Value = serde_json::from_str(
                &requests
                    .try_recv()
                    .expect("each confirmed archived chat must be deleted"),
            )
            .unwrap();
            assert_eq!(request["method"], methods::MUTATE);
            assert_eq!(request["params"]["op"], "deleteChat");
            assert_eq!(request["params"]["chatId"], expected);
            if index == 0 {
                // Unarchived mid-run (e.g. on another device): spared.
                state.update(cx, |state, _| {
                    state
                        .chats
                        .iter_mut()
                        .filter(|chat| chat.id == "restored")
                        .for_each(|chat| chat.archived = false)
                });
            }
            let reply = if index == 0 {
                serde_json::json!({"id": request["id"], "err": "rejected"})
            } else {
                serde_json::json!({"id": request["id"], "ok": {"ok": true}})
            };
            runtime.block_on(async {
                replies.send(reply.to_string()).await.unwrap();
                while replies.capacity() < replies.max_capacity() {
                    tokio::task::yield_now().await;
                }
            });
        }
        cx.run_until_parked();
        assert!(
            requests.try_recv().is_err(),
            "only the confirmed, still-archived chats are deleted"
        );
        page.update(cx, |page, _| {
            assert!(page.delete_all_task.is_none());
            assert_eq!(
                page.error.as_deref(),
                Some("Couldn\u{2019}t delete 1 archived session. Try again.")
            );
        });
    }

    #[test]
    fn delete_all_copy_handles_one_and_many() {
        assert!(delete_all_body(1).starts_with("1 archived session will"));
        assert!(delete_all_body(146).starts_with("146 archived sessions will"));
        assert_eq!(
            delete_all_failure(3),
            "Couldn\u{2019}t delete 3 archived sessions. Try again."
        );
    }
}
