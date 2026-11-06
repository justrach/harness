//! "Show me this agent": the composer's agents card asks the transcript to
//! bring an agent's spawn chip into view and ring it for a moment.
//!
//! - [`agent_reveal_target`] maps the agent (its spawn's part id) to the
//!   row that shows its chip. A chip inside a collapsed work group is
//!   revealed by opening that group first; no separate UI mode is introduced.
//! - A row already inside the reading band (below the titlebar, above the
//!   composer) only gets the ring. Otherwise the list glides to the row's
//!   index ([`Transcript::scroll_to_row_at`]), which works for rows the
//!   virtual list hasn't laid out yet.
//! - The ring holds, then fades ([`agent_flash_alpha`]). Reduced motion
//!   jumps instead of gliding and shows the ring without the fade.
use std::time::{Duration, Instant};

use gpui::{AnyElement, Context, Hsla, IntoElement, SharedString, Styled, div, px};

use super::{OWN_SEND_TOP_INSET_PX, Row, RowKind, Transcript};
use crate::motion;

/// How long the ring stays at full strength once the row has landed.
pub(crate) const FLASH_HOLD_MS: i64 = 600;
/// How long it then takes to fade out.
pub(crate) const FLASH_FADE_MS: i64 = 240;

/// The ringed agent and when its row lands (after the glide).
#[derive(Debug, Clone)]
pub(crate) struct AgentFlash {
    pub part_id: String,
    pub lands_at: Instant,
}

/// The row that shows an agent's chip.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentRevealTarget {
    pub row_ix: usize,
    /// The Compact-mode work fold the chip lives under, if any. For a
    /// closed fold `row_ix` is the fold's header row, the one visible row
    /// that holds the agent.
    pub fold: Option<SharedString>,
}

fn holds(row: &Row, part_id: &str) -> bool {
    matches!(&row.kind, RowKind::ToolGroup { tools, .. }
        if tools.iter().any(|tool| tool.part_id == part_id))
}

fn is_work_header(row: &Row) -> bool {
    matches!(
        row.kind,
        RowKind::ToolGroup {
            compact_shell: true,
            ..
        }
    )
}

/// Which row shows the agent whose spawn is part `part_id`: the chip's own
/// row when it is one, otherwise the Compact work header it folds under.
pub(crate) fn agent_reveal_target(rows: &[Row], part_id: &str) -> Option<AgentRevealTarget> {
    if let Some(row_ix) = rows
        .iter()
        .position(|row| !is_work_header(row) && holds(row, part_id))
    {
        return Some(AgentRevealTarget {
            row_ix,
            fold: rows[row_ix].compact_fold.clone(),
        });
    }
    let row_ix = rows
        .iter()
        .position(|row| is_work_header(row) && holds(row, part_id))?;
    Some(AgentRevealTarget {
        row_ix,
        fold: Some(rows[row_ix].id.clone()),
    })
}

/// The ring's strength `ms` after the row landed (negative while the list
/// is still gliding there); `None` once it is over.
pub(crate) fn agent_flash_alpha(ms: i64, reduced_motion: bool) -> Option<f32> {
    if ms >= FLASH_HOLD_MS + FLASH_FADE_MS {
        return None;
    }
    if reduced_motion || ms <= FLASH_HOLD_MS {
        return Some(1.0);
    }
    let t = (ms - FLASH_HOLD_MS) as f32 / FLASH_FADE_MS as f32;
    Some(1.0 - motion::EASE_IN_OUT.eval(t))
}

/// Where a revealed row's top lands, from the viewport top: a third of the
/// way down the band that isn't under the titlebar or the composer, so the
/// lines before the chip stay in view.
pub(crate) fn reveal_inset(viewport_height: f32, bottom_clearance: f32) -> f32 {
    let band = (viewport_height - OWN_SEND_TOP_INSET_PX - bottom_clearance).max(0.0);
    OWN_SEND_TOP_INSET_PX + band / 3.0
}

/// Whether a row (`top..bottom`, window coordinates) is wholly readable:
/// below the titlebar the viewport runs under and above the composer.
pub(crate) fn in_reading_band(
    top: f32,
    bottom: f32,
    viewport_top: f32,
    viewport_bottom: f32,
    bottom_clearance: f32,
) -> bool {
    top >= viewport_top + OWN_SEND_TOP_INSET_PX && bottom <= viewport_bottom - bottom_clearance
}

/// The reveal ring, laid over a chip's card (which clips it to its
/// corners): an accent border and wash at `alpha`.
pub(crate) fn flash_ring(alpha: f32, color: Hsla) -> AnyElement {
    div()
        .absolute()
        .inset_0()
        .rounded(px(9.0))
        .border_2()
        .border_color(color.opacity(0.9 * alpha))
        .bg(color.opacity(0.12 * alpha))
        .into_any_element()
}

impl Transcript {
    /// A part id is scoped to a chat, including in detached workspace windows.
    pub(crate) fn reveal_agent_in_chat(
        &mut self,
        chat_id: &str,
        part_id: &str,
        cx: &mut Context<Self>,
    ) {
        self.sync(cx);
        if self.chat_id.as_deref() == Some(chat_id) {
            self.reveal_agent(part_id, cx);
        }
    }

    /// Bring the chip of the agent spawned by part `part_id` into view and
    /// ring it. A no-op when no row shows that agent.
    pub fn reveal_agent(&mut self, part_id: &str, cx: &mut Context<Self>) {
        let Some(mut target) = agent_reveal_target(&self.rows, part_id) else {
            return;
        };
        if let Some(work_id) = target.fold.clone()
            && self.folds.get(&work_id).and_then(|fold| fold.open) != Some(true)
        {
            // Opening a work fold mounts its rows synchronously.
            self.toggle_fold(work_id, 0.0, false, cx);
            match agent_reveal_target(&self.rows, part_id) {
                Some(opened) => target = opened,
                None => return,
            }
        }
        let ix = target.row_ix;
        let viewport = self.list.viewport_bounds();
        let readable = self.list.bounds_for_item(ix).is_some_and(|row| {
            in_reading_band(
                f32::from(row.top()),
                f32::from(row.bottom()),
                f32::from(viewport.top()),
                f32::from(viewport.bottom()),
                self.bottom_clearance,
            )
        });
        let glide = if readable {
            Duration::ZERO
        } else {
            let inset = reveal_inset(f32::from(viewport.size.height), self.bottom_clearance);
            self.scroll_to_row_at(ix, inset, cx);
            if motion::reduced_motion(cx) {
                Duration::ZERO
            } else {
                motion::SCROLL_GLIDE.total().mul_f32(motion::speed_scale())
            }
        };
        self.agent_flash = Some(AgentFlash {
            part_id: part_id.to_owned(),
            lands_at: Instant::now() + glide,
        });
        let moved = !readable;
        self.agent_flash_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(glide).await;
            if moved {
                // Programmatic scrolls skip the user-scroll handler: refresh
                // the jump-to-bottom pill once the glide has landed.
                this.update(cx, |this, cx| {
                    this.viewport_finalize_pending = true;
                    cx.notify();
                })
                .ok();
            }
            cx.background_executor()
                .timer(Duration::from_millis(
                    (FLASH_HOLD_MS + FLASH_FADE_MS) as u64,
                ))
                .await;
            this.update(cx, |this, cx| {
                this.agent_flash = None;
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    /// The ringed agent's part id and the ring's strength now.
    pub(crate) fn agent_flash_now(&self, reduced_motion: bool) -> Option<(String, f32)> {
        let flash = self.agent_flash.as_ref()?;
        let now = Instant::now();
        let ms = if now >= flash.lands_at {
            (now - flash.lands_at).as_millis() as i64
        } else {
            -((flash.lands_at - now).as_millis() as i64)
        };
        agent_flash_alpha(ms, reduced_motion).map(|alpha| (flash.part_id.clone(), alpha))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markdown::parser::parse_full;
    use gpui::ParentElement as _;
    use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry};
    use std::sync::Arc;

    fn spawn(id: &str, title: &str) -> MessagePart {
        serde_json::from_value(serde_json::json!({
            "id": id, "kind": "tool", "resolved": true,
            "call": {"kind": "unknown", "name": format!("Agent: {title}")},
            "subagentStatus": "running",
            "subagentRef": format!("doc-{id}"),
        }))
        .unwrap()
    }

    fn text(id: &str, text: &str) -> MessagePart {
        MessagePart::Text {
            id: id.into(),
            text: text.into(),
        }
    }

    fn turn(parts: Vec<MessagePart>) -> SessionMessageEntry {
        SessionMessageEntry {
            id: "a".into(),
            role: MessageRole::Assistant,
            parts,
            created_at: 0,
            device_id: "dev".into(),
            status: Some(MessageStatus::Complete),
            continuation_of: None,
            duration_ms: None,
        }
    }

    fn rows(entry: &SessionMessageEntry, compact: bool) -> Vec<Row> {
        super::super::rows_for_entry(entry, false, compact, &mut |_, text| {
            Arc::new(parse_full(text))
        })
    }

    fn entry() -> SessionMessageEntry {
        turn(vec![
            text("t1", "Splitting the work in two."),
            spawn("s1", "Compare the two renderers"),
            spawn("s2", "Audit token flows"),
            text("t2", "Both agents are on it."),
        ])
    }

    #[test]
    fn an_agent_maps_to_the_row_that_shows_its_chip() {
        let rows = rows(&entry(), false);
        let target = agent_reveal_target(&rows, "s2").unwrap();
        assert!(holds(&rows[target.row_ix], "s2"));
        assert_eq!(target.fold, None);
        // Spawned together, both agents share one chip row.
        assert_eq!(
            agent_reveal_target(&rows, "s1").unwrap().row_ix,
            target.row_ix
        );
        assert_eq!(agent_reveal_target(&rows, "nope"), None);
        assert_eq!(agent_reveal_target(&rows, "t1"), None);
    }

    #[test]
    fn a_compact_agent_maps_to_its_work_fold() {
        // `rows_for_entry` emits the fold's body; the transcript drops it
        // while the fold is closed (`Transcript::rows_for`).
        let open = rows(&entry(), true);
        let closed: Vec<Row> = open
            .iter()
            .filter(|row| row.compact_fold.is_none())
            .cloned()
            .collect();
        // Closed: only the work header holds the agent; the reveal opens it.
        let header = agent_reveal_target(&closed, "s1").unwrap();
        assert!(is_work_header(&closed[header.row_ix]));
        assert_eq!(header.fold.as_ref(), Some(&closed[header.row_ix].id));
        // Open: the chip's own row inside the fold wins over the header.
        let inside = agent_reveal_target(&open, "s1").unwrap();
        assert!(!is_work_header(&open[inside.row_ix]));
        assert!(holds(&open[inside.row_ix], "s1"));
        assert_eq!(inside.fold, header.fold);
    }

    #[test]
    fn the_ring_holds_then_fades_and_reduced_motion_holds_it() {
        assert_eq!(agent_flash_alpha(-200, false), Some(1.0), "still gliding");
        assert_eq!(agent_flash_alpha(0, false), Some(1.0));
        assert_eq!(agent_flash_alpha(FLASH_HOLD_MS, false), Some(1.0));
        let mid = agent_flash_alpha(FLASH_HOLD_MS + FLASH_FADE_MS / 2, false).unwrap();
        assert!(mid > 0.2 && mid < 0.8, "{mid}");
        assert_eq!(
            agent_flash_alpha(FLASH_HOLD_MS + FLASH_FADE_MS, false),
            None
        );
        // Reduced motion: the same span, a steady ring, no fade.
        assert_eq!(
            agent_flash_alpha(FLASH_HOLD_MS + FLASH_FADE_MS / 2, true),
            Some(1.0)
        );
        assert_eq!(agent_flash_alpha(FLASH_HOLD_MS + FLASH_FADE_MS, true), None);
        assert!(FLASH_HOLD_MS + FLASH_FADE_MS <= 1500, "brief");
    }

    /// The transcript under a composer-like footer that carries the agents
    /// chip, wired the way the shell wires the composer's event.
    struct Host {
        transcript: gpui::Entity<Transcript>,
        state: gpui::Entity<crate::state::AppState>,
    }

    impl gpui::Render for Host {
        fn render(
            &mut self,
            _: &mut gpui::Window,
            cx: &mut gpui::Context<Self>,
        ) -> impl IntoElement {
            use gpui::InteractiveElement as _;
            let theme = crate::theme::Theme::of(cx).clone();
            let transcript = self.transcript.clone();
            let reveal: crate::agent_work::RevealAgent = std::rc::Rc::new(move |id, _, cx| {
                transcript.update(cx, |t, cx| t.reveal_agent(id, cx));
            });
            let chip = crate::agent_work::footer_chip(
                self.state.clone(),
                &theme,
                cx.entity_id(),
                Some(reveal),
                cx,
            );
            div()
                .size_full()
                .relative()
                .child(self.transcript.clone())
                .child(
                    div()
                        .id("footer")
                        .absolute()
                        .bottom(px(12.0))
                        .right(px(24.0))
                        .h(px(36.0))
                        .flex()
                        .items_center()
                        .children(chip),
                )
        }
    }

    /// A long chat whose first turn spawned two agents that still run, then
    /// a long answer, so the spawn chips start far above the viewport.
    fn long_chat() -> Vec<SessionMessageEntry> {
        let user = |id: &str, said: &str| SessionMessageEntry {
            role: MessageRole::User,
            status: None,
            ..turn(vec![text(&format!("{id}-t"), said)])
        };
        let mut first = turn(vec![
            text("t1", "Splitting the work in two."),
            spawn("s1", "Compare the two renderers"),
            spawn("s2", "Audit token flows"),
            text("t2", "Both agents are on it."),
        ]);
        first.id = "a1".into();
        let mut chat = vec![
            SessionMessageEntry {
                id: "u1".into(),
                ..user("u1", "Compare the renderers and audit the flows.")
            },
            first,
        ];
        for turn_ix in 0..4 {
            chat.push(SessionMessageEntry {
                id: format!("u{}", turn_ix + 2),
                ..user(
                    &format!("u{}", turn_ix + 2),
                    "And meanwhile, explain the fee model.",
                )
            });
            let body: String = (0..10)
                .map(|p| format!("Paragraph {p} of answer {turn_ix}, long enough to wrap twice in a column of ordinary width.\n\n"))
                .collect();
            let mut answer = turn(vec![text("b", &body)]);
            answer.id = format!("r{turn_ix}");
            chat.push(answer);
        }
        chat
    }

    #[gpui::test]
    fn clicking_an_agent_in_the_card_scrolls_to_its_chip_and_rings_it(
        cx: &mut gpui::TestAppContext,
    ) {
        click_an_agent_in_the_card(cx, false);
    }

    /// Reduced motion jumps instead of gliding; the rows above still paint.
    #[gpui::test]
    fn clicking_an_agent_under_reduced_motion_jumps_to_its_chip(cx: &mut gpui::TestAppContext) {
        click_an_agent_in_the_card(cx, true);
    }

    fn click_an_agent_in_the_card(cx: &mut gpui::TestAppContext, reduced: bool) {
        use gpui::{AppContext as _, Modifiers, point, size};
        let dir = tempfile::tempdir().unwrap();
        let state = cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(crate::theme::Theme::dark());
            crate::settings::init(crate::settings::UiSettings::expanded(), dir.path(), cx);
            crate::motion::set_reduced_motion(cx, reduced);
            cx.new(|_| crate::state::AppState::new())
        });
        let window = cx.add_window(|_, cx| Host {
            transcript: cx.new(|cx| Transcript::new(state.clone(), cx)),
            state: state.clone(),
        });
        let transcript = window
            .update(cx, |host, _, _| host.transcript.clone())
            .unwrap();
        window
            .update(cx, |_, window, _| window.resize(size(px(720.0), px(800.0))))
            .unwrap();
        state.update(cx, |state, _| {
            state.selected_chat = Some("chat".into());
            state.transcript_replayed = true;
            state.transcript = long_chat();
            state.transcript_revision += 1;
        });
        transcript.update(cx, |t, cx| t.sync(cx));
        let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
        // Tests have no display link: deliver the frame callbacks the glide
        // steps on, then draw.
        let draw = |visual: &mut gpui::VisualTestContext| {
            visual.update(|window, cx| {
                window.simulate_next_frame(cx);
                window.refresh();
                window.draw(cx).clear();
            });
        };
        for _ in 0..3 {
            draw(&mut visual);
        }
        let readable = |visual: &mut gpui::VisualTestContext| {
            transcript.read_with(visual, |t, _| {
                let ix = agent_reveal_target(&t.rows, "s2").unwrap().row_ix;
                let viewport = t.list.viewport_bounds();
                t.list.bounds_for_item(ix).is_some_and(|row| {
                    in_reading_band(
                        f32::from(row.top()),
                        f32::from(row.bottom()),
                        f32::from(viewport.top()),
                        f32::from(viewport.bottom()),
                        t.bottom_clearance,
                    )
                })
            })
        };
        assert!(
            !readable(&mut visual),
            "the chat opens at its end, away from the agents"
        );

        // Hover the chip: the card opens after the tooltip delay.
        let chip = visual
            .debug_bounds("agent-work-chip")
            .expect("the chip shows");
        visual.simulate_mouse_move(chip.center(), None, Modifiers::none());
        visual.executor().advance_clock(Duration::from_millis(700));
        visual.run_until_parked();
        draw(&mut visual);
        let row = visual
            .debug_bounds("agent-row-1")
            .expect("hovering the chip opens the card");

        // Into the card: it stays open along the way and while resting there.
        let from = chip.center();
        let to = row.center();
        for step in 1..=8 {
            let t = step as f32 / 8.0;
            let at = point(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
            visual.simulate_mouse_move(at, None, Modifiers::none());
            draw(&mut visual);
            assert!(
                visual.debug_bounds("agent-row-1").is_some(),
                "the card closed on the way into it (step {step})"
            );
        }
        visual
            .executor()
            .advance_clock(Duration::from_millis(1_000));
        visual.run_until_parked();
        draw(&mut visual);
        let row = visual
            .debug_bounds("agent-row-1")
            .expect("the card stays open under the pointer");

        // Click the second agent: the card closes and the ring is set.
        visual.simulate_click(row.center(), Modifiers::none());
        draw(&mut visual);
        assert!(
            visual.debug_bounds("agent-row-1").is_none(),
            "the card closes after the click"
        );
        let flash = transcript.read_with(&visual, |t, _| t.agent_flash_now(reduced));
        assert_eq!(flash.map(|(id, _)| id), Some("s2".to_owned()));

        // The list glides to the chip's row, laying out rows it had not.
        // Advance the glide's wall-clock origin without sleeping; delivery
        // still happens through display callbacks and actual list layout.
        transcript.update(&mut visual, |t, _| {
            if let Some(glide) = t.row_glide.as_mut() {
                glide.started = Instant::now() - glide.total;
            }
        });
        for _ in 0..80 {
            visual.executor().advance_clock(Duration::from_millis(32));
            draw(&mut visual);
        }
        assert!(readable(&mut visual), "the agent's chip is in view");
        // The lines before the chip are painted too, not left blank above it.
        let above = transcript.read_with(&visual, |t, _| {
            let ix = agent_reveal_target(&t.rows, "s2").unwrap().row_ix;
            t.list.bounds_for_item(ix - 1)
        });
        assert!(above.is_some(), "the row before the chip is laid out");
        assert!(
            !transcript.read_with(&visual, |t, _| t.pinned),
            "the reveal leaves the bottom pin"
        );
    }

    #[gpui::test]
    fn a_compact_reveal_opens_the_work_fold_to_show_the_chip(cx: &mut gpui::TestAppContext) {
        use gpui::AppContext as _;
        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(crate::theme::Theme::dark());
            crate::settings::init(crate::settings::UiSettings::expanded(), dir.path(), cx);
            crate::motion::set_reduced_motion(cx, true);
            let state = cx.new(|_| crate::state::AppState::new());
            state.update(cx, |state, _| {
                state.selected_chat = Some("chat".into());
                state.transcript_replayed = true;
                state.transcript = long_chat();
                state.transcript_revision += 1;
            });
            let transcript = cx.new(|cx| Transcript::new(state.clone(), cx));
            transcript.update(cx, |t, cx| {
                t.compact_mode = true;
                t.last_source = None;
                t.sync(cx);
                let closed = agent_reveal_target(&t.rows, "s1").unwrap();
                assert!(is_work_header(&t.rows[closed.row_ix]), "folded away");
                t.reveal_agent("s1", cx);
                let work_id = closed.fold.unwrap();
                assert_eq!(t.folds.get(&work_id).and_then(|f| f.open), Some(true));
                let shown = agent_reveal_target(&t.rows, "s1").unwrap();
                assert!(!is_work_header(&t.rows[shown.row_ix]), "the chip's own row");
                assert_eq!(t.agent_flash_now(true).map(|(id, _)| id), Some("s1".into()));
                // Reduced motion jumps straight to the row.
                assert_eq!(t.list.logical_scroll_top().item_ix, shown.row_ix);
            });
        });
    }

    #[test]
    fn a_revealed_row_lands_below_the_titlebar_and_above_the_composer() {
        let inset = reveal_inset(900.0, 150.0);
        assert!(inset > OWN_SEND_TOP_INSET_PX);
        assert!(inset < 900.0 - 150.0);
        // A viewport shorter than the chrome still clears the titlebar.
        assert_eq!(reveal_inset(40.0, 150.0), OWN_SEND_TOP_INSET_PX);
        // Readable only between the titlebar and the composer.
        let top = OWN_SEND_TOP_INSET_PX;
        assert!(in_reading_band(top, top + 40.0, 0.0, 900.0, 150.0));
        assert!(!in_reading_band(top - 1.0, top + 40.0, 0.0, 900.0, 150.0));
        assert!(!in_reading_band(700.0, 760.0, 0.0, 900.0, 150.0));
    }

    #[gpui::test]
    fn an_agent_reveal_is_scoped_to_its_chat_and_cleared_on_switch(cx: &mut gpui::TestAppContext) {
        use gpui::AppContext as _;
        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(crate::theme::Theme::dark());
            crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
            crate::motion::set_reduced_motion(cx, true);
            let state = cx.new(|_| crate::state::AppState::new());
            state.update(cx, |state, _| {
                state.selected_chat = Some("origin".into());
                state.transcript_replayed = true;
                state.transcript = long_chat();
                state.transcript_revision += 1;
            });
            let transcript = cx.new(|cx| Transcript::new(state.clone(), cx));
            transcript.update(cx, |t, cx| {
                t.reveal_agent_in_chat("other", "s1", cx);
                assert!(t.agent_flash.is_none());
                t.reveal_agent_in_chat("origin", "s1", cx);
                assert_eq!(t.agent_flash_now(true).map(|(id, _)| id), Some("s1".into()));
            });
            state.update(cx, |state, _| {
                state.selected_chat = Some("other".into());
                state.transcript_revision += 1;
            });
            transcript.update(cx, |t, cx| {
                t.sync(cx);
                assert!(
                    t.agent_flash.is_none(),
                    "same-named parts in another chat must not inherit the highlight"
                );
                let before = t.list.logical_scroll_top();
                t.reveal_agent_in_chat("origin", "s1", cx);
                t.reveal_agent_in_chat("other", "missing", cx);
                assert!(t.agent_flash.is_none());
                let after = t.list.logical_scroll_top();
                assert_eq!(
                    (after.item_ix, after.offset_in_item),
                    (before.item_ix, before.offset_in_item),
                    "stale or missing targets must not move the view"
                );
            });
        });
    }
}
