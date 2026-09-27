//! Publishes this desktop's appearance choice (mode + light/dark theme ids) to
//! the synced registry, where phones pick it up to match the desktop. Local
//! workspaces have no registry and keep the choice to themselves.

use super::*;
use crate::appearance::{self, AppearanceMode};
use crate::state::EngineHandle;

/// What was last sent, and to which engine — a reconnect or profile switch
/// lands on a different engine and republishes.
#[derive(Clone)]
pub(super) struct PublishedAppearance {
    engine: EngineHandle,
    mode: AppearanceMode,
    light: String,
    dark: String,
}

impl PartialEq for PublishedAppearance {
    fn eq(&self, other: &Self) -> bool {
        self.engine.same_connection(&other.engine)
            && (self.mode, &self.light, &self.dark) == (other.mode, &other.light, &other.dark)
    }
}

impl Shell {
    /// Called on every app-state change and every appearance change; sends
    /// only when the choice (or the engine) differs from the last send.
    pub(super) fn publish_appearance(&mut self, cx: &mut Context<Self>) {
        let state = self.state.read(cx);
        if !matches!(
            state.workspace_scope,
            Some(WorkspaceScope::Synced | WorkspaceScope::Development)
        ) {
            return;
        }
        let Some(engine) = state.engine().cloned() else {
            return;
        };
        let themes = appearance::themes(cx);
        let next = PublishedAppearance {
            engine: engine.clone(),
            mode: appearance::mode(cx),
            light: themes.light,
            dark: themes.dark,
        };
        if self.published_appearance.as_ref() == Some(&next) {
            return;
        }
        self.published_appearance = Some(next.clone());
        let params = serde_json::json!({
            "op": "setAppearance", "mode": next.mode, "light": next.light, "dark": next.dark,
        });
        self.appearance_task = Some(cx.spawn(async move |this, cx| {
            if let Err(err) = engine.client().call(methods::MUTATE, params).await {
                tracing::warn!(%err, "appearance: publish failed; retrying on next change");
                this.update(cx, |shell, _| {
                    if shell.published_appearance.as_ref() == Some(&next) {
                        shell.published_appearance = None;
                    }
                })
                .ok();
            }
        }));
    }
}
