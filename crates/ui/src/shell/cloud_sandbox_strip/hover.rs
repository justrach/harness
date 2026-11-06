//! Non-modal preview: delayed pointer entry, a grace period for crossing to the
//! card, and focus-based access without taking the keyboard from the composer.
use super::*;
use std::time::Duration;

impl Shell {
    pub(in crate::shell) fn cloud_preview_has_keyboard_focus(
        &self,
        window: &Window,
        cx: &App,
    ) -> bool {
        self.cloud_computers.is_open()
            && (self
                .cloud_computers
                .focus
                .as_ref()
                .is_some_and(|f| f.contains_focused(window, cx))
                || self
                    .cloud_computers
                    .anchor_id
                    .as_ref()
                    .and_then(|id| self.cloud_computers.controls.get(id))
                    .is_some_and(|f| f.is_focused(window)))
    }

    pub(super) fn observe_cloud_focus(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.cloud_computers.focus.is_none() {
            let focus = cx.focus_handle();
            let entered = cx.on_focus_in(&focus, window, |this, _, _| {
                this.cloud_computers.focused_detail = true;
                this.cloud_computers.hide_task = None;
            });
            let left = cx.on_focus_out(&focus, window, |this, _, _, cx| {
                this.cloud_computers.focused_detail = false;
                this.hide_cloud_preview_soon(cx);
            });
            self.cloud_computers
                .focus_subscriptions
                .insert("detail".into(), vec![entered, left]);
            self.cloud_computers.focus = Some(focus);
        }
        let mut controls: Vec<_> = self
            .state
            .read(cx)
            .cloud_sandboxes()
            .into_iter()
            .flat_map(|list| list.sandboxes.iter())
            .filter_map(|s| {
                self.cloud_computers
                    .controls
                    .get(&s.id)
                    .map(|focus| (s.id.clone(), focus.clone()))
            })
            .collect();
        if let Some(focus) = self.cloud_computers.controls.get(HEADER_TRIGGER) {
            controls.push((HEADER_TRIGGER.to_string(), focus.clone()));
        }
        for (id, focus) in controls {
            if self.cloud_computers.focus_subscriptions.contains_key(&id) {
                continue;
            }
            let enter_id = id.clone();
            let leave_id = id.clone();
            let entered = cx.on_focus(&focus, window, move |this, _, cx| {
                this.cloud_computers.focused_trigger = Some(enter_id.clone());
                this.show_cloud_preview(enter_id.clone(), cx);
            });
            let left = cx.on_blur(&focus, window, move |this, _, cx| {
                if this.cloud_computers.focused_trigger.as_ref() == Some(&leave_id) {
                    this.cloud_computers.focused_trigger = None;
                }
                if this.cloud_computers.dismissed.as_ref() == Some(&leave_id) {
                    this.cloud_computers.dismissed = None;
                }
                this.hide_cloud_preview_soon(cx);
            });
            self.cloud_computers
                .focus_subscriptions
                .insert(id, vec![entered, left]);
        }
    }

    pub(super) fn show_cloud_preview(&mut self, id: String, cx: &mut Context<Self>) {
        if !matches!(self.route, Route::Chat)
            || self.cloud_computers.dismissed.as_ref() == Some(&id)
        {
            return;
        }
        self.cloud_computers.hide_task = None;
        let selected = if id == HEADER_TRIGGER {
            let Some(list) = self
                .state
                .read(cx)
                .cloud_sandboxes()
                .filter(|list| list.enabled)
            else {
                return;
            };
            if list.sandboxes.len() == 1 {
                list.sandboxes[0].id.clone()
            } else {
                id.clone()
            }
        } else {
            id.clone()
        };
        if self.cloud_computers.selected.as_ref() != Some(&selected) {
            self.cloud_computers.error = None;
        }
        self.cloud_computers.return_focus = self.cloud_computers.controls.get(&id).cloned();
        self.cloud_computers.anchor_id = Some(id.clone());
        self.cloud_computers.selected = Some(selected);
        cx.notify();
    }

    pub(super) fn cloud_trigger_hover(
        &mut self,
        id: String,
        entered: bool,
        cx: &mut Context<Self>,
    ) {
        if entered {
            self.cloud_computers.hovered_trigger = Some(id.clone());
            self.cloud_computers.dismissed = None;
            self.cloud_computers.hide_task = None;
            self.cloud_computers.hover_task = Some(cx.spawn(async move |this, cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(350))
                    .await;
                let _ = this.update(cx, |this, cx| {
                    if this.cloud_computers.hovered_trigger.as_ref() == Some(&id) {
                        this.show_cloud_preview(id, cx);
                    }
                });
            }));
        } else if self.cloud_computers.hovered_trigger.as_ref() == Some(&id) {
            self.cloud_computers.hovered_trigger = None;
            self.cloud_computers.hover_task = None;
            self.hide_cloud_preview_soon(cx);
        }
    }

    pub(super) fn hide_cloud_preview_soon(&mut self, cx: &mut Context<Self>) {
        self.cloud_computers.hide_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(240))
                .await;
            let _ = this.update(cx, |this, cx| {
                let cloud = &mut this.cloud_computers;
                if cloud.hovered_trigger.is_none()
                    && !cloud.hovered_detail
                    && cloud.focused_trigger.is_none()
                    && !cloud.focused_detail
                {
                    cloud.selected = None;
                    cx.notify();
                }
            });
        }));
    }
}
