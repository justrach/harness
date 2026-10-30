//! A presentation budget for visible, unfocused chat panes. Data keeps arriving
//! in AppState; only row synchronization and passive redraws are coalesced.
use super::*;

const BACKGROUND_FRAME_INTERVAL: Duration = Duration::from_millis(100);

pub(super) struct PaneCadence {
    pub(super) background: bool,
    visible: bool,
    last_update: Option<Instant>,
    pending: Option<Task<()>>,
    sync_pending: bool,
    animation_pending: bool,
    #[cfg(test)]
    renders: usize,
}

impl Default for PaneCadence {
    fn default() -> Self {
        Self {
            background: false,
            visible: true,
            last_update: None,
            pending: None,
            sync_pending: false,
            animation_pending: false,
            #[cfg(test)]
            renders: 0,
        }
    }
}

impl PaneCadence {
    fn remaining(&self, now: Instant) -> Duration {
        self.last_update.map_or(Duration::ZERO, |last| {
            BACKGROUND_FRAME_INTERVAL.saturating_sub(now.saturating_duration_since(last))
        })
    }

    pub(super) fn painted(&mut self, now: Instant) {
        self.last_update = Some(now);
        #[cfg(test)]
        {
            self.renders += 1;
        }
    }
}

impl Transcript {
    fn register_background_notifier(&self, cx: &mut Context<Self>) {
        let notifier = self.pane_cadence.background.then(|| {
            let weak = cx.weak_entity();
            Rc::new(move |cx: &mut gpui::App| {
                let _ = weak.update(cx, |this, cx| {
                    this.pane_cadence.animation_pending = true;
                    this.schedule_background_frame(cx);
                });
            }) as Rc<dyn Fn(&mut gpui::App)>
        });
        motion::set_background_notifier(cx.entity_id(), notifier, cx);
    }

    pub(super) fn set_background_pane(&mut self, background: bool, cx: &mut Context<Self>) {
        self.pane_cadence.pending = None;
        self.pane_cadence.background = background;
        self.pane_cadence.visible = true;
        self.pane_cadence.animation_pending = false;
        self.own_turn_scheduled = false;
        self.spring_scheduled = false;
        self.register_background_notifier(cx);
        if !background {
            // Role promotion must never wait for the old pane's deadline.
            self.pane_cadence.sync_pending = false;
            self.sync(cx);
            cx.notify();
        }
    }

    pub(crate) fn background_pane_visible(&self) -> bool {
        self.pane_cadence.visible
    }

    pub(crate) fn set_background_pane_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        if !self.pane_cadence.background || self.pane_cadence.visible == visible {
            return;
        }
        self.pane_cadence.visible = visible;
        self.pane_cadence.pending = None;
        self.pane_cadence.animation_pending = false;
        self.own_turn_scheduled = false;
        self.spring_scheduled = false;
        // Retire mounted-animation leases immediately, rather than waiting for
        // their normal expiry. Late paint callbacks still go through the gate.
        self.register_background_notifier(cx);
        if visible {
            self.pane_cadence.sync_pending = false;
            self.pane_cadence.last_update = None;
            self.sync(cx);
            cx.notify();
        }
    }

    pub(super) fn request_sync(&mut self, cx: &mut Context<Self>) {
        if !self.pane_cadence.background {
            self.sync(cx);
            return;
        }
        let state = self.state.read(cx);
        if self
            .last_source
            .as_ref()
            .is_some_and(|source| source.2 == state.transcript_revision)
            && self.reauth_generation == state.reauth.generation
        {
            return;
        }
        self.pane_cadence.sync_pending = true;
        self.schedule_background_frame(cx);
    }

    pub(super) fn schedule_background_frame(&mut self, cx: &mut Context<Self>) {
        if !self.pane_cadence.background
            || !self.pane_cadence.visible
            || self.pane_cadence.pending.is_some()
        {
            return;
        }
        let delay = self.pane_cadence.remaining(cx.background_executor().now());
        self.pane_cadence.pending = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(delay).await;
            let _ = this.update(cx, |this, cx| {
                this.pane_cadence.pending = None;
                if !this.pane_cadence.background || !this.pane_cadence.visible {
                    return;
                }
                let now = cx.background_executor().now();
                // Explicit input can paint immediately while a passive update
                // is pending. Keep that update, but honor the new paint time.
                if !this.pane_cadence.remaining(now).is_zero() {
                    this.schedule_background_frame(cx);
                    return;
                }
                this.pane_cadence.last_update = Some(now);
                if std::mem::take(&mut this.pane_cadence.sync_pending) {
                    this.sync(cx);
                }
                // The preceding paint has finished layout by this deadline.
                // Advance the existing elapsed-time drivers, not a new spring.
                if std::mem::take(&mut this.own_turn_scheduled) {
                    this.step_own_turn(cx);
                }
                if std::mem::take(&mut this.spring_scheduled) {
                    this.step_spring(cx);
                }
                if std::mem::take(&mut this.pane_cadence.animation_pending) {
                    cx.notify();
                }
            });
        }));
    }
}

#[cfg(test)]
mod tests;
