use gpui::{
    App, ClickEvent, InteractiveElement, Stateful, StatefulInteractiveElement, Styled, Window,
};

pub trait InteractiveElementExt: InteractiveElement {
    /// Locks scrolling to the gesture's dominant axis, where the platform
    /// supports it. The Comet GPUI fork exposes this as a style field rather
    /// than the upstream `OngoingScroll` helper.
    fn lock_scroll_axis(mut self) -> Self
    where
        Self: Sized + StatefulInteractiveElement + Styled,
    {
        #[cfg(target_family = "wasm")]
        {
            self
        }
        #[cfg(not(target_family = "wasm"))]
        {
            self.style().restrict_scroll_to_axis = Some(true);
            self
        }
    }

    /// Set the listener for a double click event.
    fn on_double_click(
        mut self,
        listener: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self
    where
        Self: Sized,
    {
        self.interactivity().on_click(move |event, window, cx| {
            if event.click_count() == 2 {
                listener(event, window, cx);
            }
        });
        self
    }
}

impl<E: InteractiveElement> InteractiveElementExt for Stateful<E> {}
