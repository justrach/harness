use super::*;
use gpui::AppContext;

#[gpui::test]
fn shared_doc_feed_survives_either_consumer_closing(cx: &mut gpui::TestAppContext) {
    for close_child_first in [false, true] {
        let state = cx.new(|_| AppState::new());
        state.update(cx, |state, cx| {
            // Synthetic completed task stands in for an engine watch. Both public
            // acquisition paths must share it without sharing their lifetime.
            state
                .sub_watch_tasks
                .insert("shared".into(), Task::ready(()));
            state.watch_peer_chat("shared".into(), cx);
            state.watch_subagent_doc("shared".into(), cx);
            state.sub_transcripts.insert("shared".into(), Vec::new());
            state.transcript_baselines.insert(
                "shared".into(),
                Arc::new(harness_doc::TranscriptBaseline::capture(&[])),
            );
            if close_child_first {
                state.unwatch_subagent_doc("shared");
            } else {
                state.unwatch_peer_chat("shared");
            }
            assert!(
                state.sub_watch_tasks.contains_key("shared"),
                "surviving consumer lost watch"
            );
            assert!(
                state.sub_transcripts.contains_key("shared"),
                "surviving consumer lost rows"
            );
            assert!(state.transcript_baselines.contains_key("shared"));
            if close_child_first {
                state.unwatch_peer_chat("shared");
            } else {
                state.unwatch_subagent_doc("shared");
            }
            assert!(!state.sub_watch_tasks.contains_key("shared"));
            assert!(!state.sub_transcripts.contains_key("shared"));
            assert!(!state.transcript_baselines.contains_key("shared"));
        });
    }
}

#[gpui::test]
fn promoting_a_shared_document_keeps_the_child_rows_and_primary_baseline(
    cx: &mut gpui::TestAppContext,
) {
    let state = cx.new(|_| AppState::new());
    state.update(cx, |state, cx| {
        state.set_subagent_snapshot("shared".into(), Vec::new());
        state.watch_subagent_doc("shared".into(), cx);
        state.watch_peer_chat("shared".into(), cx);
        state.select_split_chat(Some("shared".into()), cx);
        state.unwatch_peer_chat("shared");
        assert!(
            state.sub_transcripts.contains_key("shared"),
            "promotion moved rows out from under the surviving child"
        );
        assert!(state.transcript_baselines.contains_key("shared"));
        state.unwatch_subagent_doc("shared");
        assert!(!state.sub_transcripts.contains_key("shared"));
        assert!(
            state.transcript_baselines.contains_key("shared"),
            "closing the child removed the selected chat's baseline"
        );
    });
}

#[gpui::test]
fn frozen_snapshots_cannot_replace_a_shared_live_chat_feed(cx: &mut gpui::TestAppContext) {
    for selected in [false, true] {
        let state = cx.new(|_| AppState::new());
        state.update(cx, |state, cx| {
            state.watch_subagent_doc("shared".into(), cx);
            if selected {
                state.selected_chat = Some("shared".into());
            } else {
                state.watch_peer_chat("shared".into(), cx);
            }
            state
                .sub_watch_tasks
                .insert("shared".into(), Task::ready(()));
            state.set_subagent_snapshot("shared".into(), Vec::new());
            assert!(
                state.sub_watch_tasks.contains_key("shared"),
                "frozen child cancelled live chat watch"
            );
            let update = harness_doc::TranscriptUpdate {
                replay_baseline: Some(harness_doc::TranscriptBaseline::capture(&[])),
                frame: TranscriptFrame::Reset { reset: Vec::new() },
                context_usage: None,
            };
            let prepared = crate::transcript::TranscriptPreparation::default()
                .prepare(&update)
                .unwrap();
            state.set_prepared_subagent_snapshot("shared".into(), Vec::new(), prepared);
            assert!(state.sub_watch_tasks.contains_key("shared"));
            assert!(
                !state.prepared_transcripts.contains_key("shared"),
                "frozen rows replaced the live chat's preparation"
            );
            state.unwatch_subagent_doc("shared");
            if !selected {
                assert!(state.sub_watch_tasks.contains_key("shared"));
            }
        });
    }
}
