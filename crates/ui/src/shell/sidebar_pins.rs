//! Optimistic pin writes are an overlay, never the authoritative watch state.
//! Serialize drops per attachment; old replies cannot undo a newer drop/profile.

use super::*;
use crate::state::EngineHandle;
use std::collections::VecDeque;
use zeron_proto::SidebarPreferencesState;

pub(super) struct PendingSidebarPins {
    pub id: u64,
    pub profile_key: String,
    pub engine: EngineHandle,
    pub queue: VecDeque<Vec<String>>,
    pub unconfirmed: bool,
}

pub(super) fn preferences_reply(
    value: serde_json::Value,
) -> Result<SidebarPreferencesState, String> {
    serde_json::from_value(value.get("sidebarPreferences").cloned().unwrap_or_default())
        .map_err(|_| "The engine did not confirm the saved pins".into())
}

impl Shell {
    fn pin_write_is_current(&self, pending: &PendingSidebarPins, cx: &App) -> bool {
        self.active_sidebar_pin_profile_key(cx).as_ref() == Some(&pending.profile_key)
            && self
                .state
                .read(cx)
                .engine()
                .is_some_and(|engine| engine.same_connection(&pending.engine))
    }

    pub(super) fn optimistic_sidebar_pins(&self, cx: &App) -> Option<&Vec<String>> {
        self.sidebar_pin_write
            .as_ref()
            .filter(|pending| !pending.unconfirmed && self.pin_write_is_current(pending, cx))
            .and_then(|pending| pending.queue.back())
    }

    pub(super) fn discard_stale_sidebar_pin_writes(&mut self, cx: &App) {
        if self
            .sidebar_pin_write
            .as_ref()
            .is_some_and(|pending| !self.pin_write_is_current(pending, cx))
        {
            self.sidebar_pin_write = None;
        }
    }

    pub(super) fn queue_sidebar_pin_write(
        &mut self,
        profile_key: String,
        pins: Vec<String>,
        cx: &mut Context<Self>,
    ) -> bool {
        self.discard_stale_sidebar_pin_writes(cx);
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.sidebar_notice = Some("Engine not connected. Pins were not changed.".into());
            cx.notify();
            return false;
        };
        if let Some(pending) = &mut self.sidebar_pin_write {
            if pending.unconfirmed {
                self.sidebar_notice =
                    Some("Waiting for the engine to confirm the previous pin change.".into());
                cx.notify();
                return false;
            }
            pending.queue.push_back(pins);
            cx.notify();
            return true;
        }
        self.sidebar_pin_write_generation += 1;
        let id = self.sidebar_pin_write_generation;
        self.sidebar_pin_write = Some(PendingSidebarPins {
            id,
            profile_key,
            engine: engine.clone(),
            queue: VecDeque::from([pins.clone()]),
            unconfirmed: false,
        });
        // Detached from generic sidebar mutations: rename/archive must not
        // cancel a pin write, and rapid drops must reach the engine in order.
        cx.spawn(async move |this, cx| {
            let mut next = pins;
            loop {
                let request = engine.client().call(
                    methods::MUTATE,
                    serde_json::json!({
                        "op": "setSidebarPinnedSessions", "pinnedSessionIds": next,
                    }),
                );
                let deadline = cx.background_executor().timer(Duration::from_secs(20));
                let result =
                    match futures::future::select(Box::pin(request), Box::pin(deadline)).await {
                        futures::future::Either::Left((result, _)) => result
                            .map_err(|error| error.to_string())
                            .and_then(preferences_reply),
                        futures::future::Either::Right((_, request)) => {
                            // The old request may still run. Do not send a later
                            // full-list write whose execution order is uncertain.
                            this.update(cx, |shell, cx| shell.mark_pin_write_unconfirmed(id, cx))
                                .ok();
                            // Keep observing the original request. No later user
                            // drop may overtake it until it resolves or disconnects.
                            request
                                .await
                                .map_err(|error| error.to_string())
                                .and_then(preferences_reply)
                        }
                    };
                let queued = this
                    .update(cx, |shell, cx| {
                        shell.finish_sidebar_pin_write(id, result, cx)
                    })
                    .ok()
                    .flatten();
                let Some(queued) = queued else { break };
                next = queued;
            }
        })
        .detach();
        cx.notify();
        true
    }

    pub(super) fn finish_sidebar_pin_write(
        &mut self,
        id: u64,
        result: Result<SidebarPreferencesState, String>,
        cx: &mut Context<Self>,
    ) -> Option<Vec<String>> {
        self.discard_stale_sidebar_pin_writes(cx);
        if self
            .sidebar_pin_write
            .as_ref()
            .is_none_or(|pending| pending.id != id)
        {
            return None;
        }
        match result {
            Ok(value) => {
                self.state.update(cx, |state, cx| {
                    if state.apply_sidebar_preferences(value) {
                        cx.notify();
                    }
                });
            }
            Err(error) => {
                self.sidebar_notice = Some(format!("Couldn't save pins: {error}").into());
            }
        }
        let pending = self.sidebar_pin_write.as_mut().unwrap();
        pending.queue.pop_front();
        let next = pending.queue.front().cloned();
        if next.is_none() {
            // Removing the overlay reveals the latest watch/ack, not a stale
            // pre-drag backup that could erase a concurrent remote update.
            self.sidebar_pin_write = None;
        }
        cx.notify();
        next
    }

    pub(super) fn mark_pin_write_unconfirmed(&mut self, id: u64, cx: &mut Context<Self>) {
        self.discard_stale_sidebar_pin_writes(cx);
        if self
            .sidebar_pin_write
            .as_ref()
            .is_some_and(|pending| pending.id == id)
        {
            let pending = self.sidebar_pin_write.as_mut().unwrap();
            pending.queue.clear();
            pending.unconfirmed = true;
            self.sidebar_notice = Some("Couldn't confirm pins. Queued edits were cancelled; waiting for the engine before allowing more pin changes.".into());
            cx.notify();
        }
    }

    pub(super) fn finish_sidebar_pin_migration(
        &mut self,
        profile_key: &str,
        engine: &EngineHandle,
        source: &[String],
        result: Result<SidebarPreferencesState, String>,
        cx: &mut Context<Self>,
    ) {
        let current = self.active_sidebar_pin_profile_key(cx).as_deref() == Some(profile_key)
            && self
                .state
                .read(cx)
                .engine()
                .is_some_and(|active| active.same_connection(engine));
        if let Ok(preferences) = result {
            if current {
                self.state.update(cx, |state, cx| {
                    if state.apply_sidebar_preferences(preferences) {
                        cx.notify();
                    }
                });
            }
            // Delete only the acknowledged source, even if the user switched
            // profiles or edited another source while this request was running.
            if self
                .settings
                .sidebar_pinned_session_ids_by_profile
                .get(profile_key)
                .map(Vec::as_slice)
                == Some(source)
            {
                self.settings
                    .sidebar_pinned_session_ids_by_profile
                    .remove(profile_key);
                self.schedule_save(cx);
            }
        } else if current {
            self.sidebar_notice =
                Some("Couldn't migrate pins. Local pins were kept; restart to retry.".into());
        }
        cx.notify();
    }
}
