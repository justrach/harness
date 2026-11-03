//! A rolled-back prepaint must not replay ranges from that aborted attempt.
use super::*;
use gpui::{
    App, Bounds, Element, ElementId, GlobalElementId, InspectorElementId, LayoutId, Pixels,
};

struct Retry {
    child: Entity<Node>,
    abort_first: bool,
}

impl Retry {
    fn element(&self) -> AnyElement {
        self.child
            .clone()
            .cached_measured(StyleRefinement::default().w(px(100.)))
            .into_any_element()
    }
}

impl IntoElement for Retry {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

impl Element for Retry {
    type RequestLayoutState = AnyElement;
    type PrepaintState = Option<AnyElement>;

    fn id(&self) -> Option<ElementId> {
        Some("retry-wrapper".into())
    }
    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, AnyElement) {
        let mut child = self.element();
        (child.request_layout(window, cx), child)
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        first: &mut AnyElement,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<AnyElement> {
        if !self.abort_first {
            first.prepaint(window, cx);
            return None;
        }
        let result: Result<(), ()> = window.transact(|window| {
            first.prepaint(window, cx);
            Err(())
        });
        assert!(result.is_err());
        // Retry the same entity IDs and bounds, not a new cache identity.
        let mut second = self.element();
        second.layout_as_root(bounds.size.into(), window, cx);
        second.prepaint_at(bounds.origin, window, cx);
        Some(second)
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        first: &mut AnyElement,
        second: &mut Option<AnyElement>,
        window: &mut Window,
        cx: &mut App,
    ) {
        second.as_mut().unwrap_or(first).paint(window, cx);
    }
}

struct RetryHost {
    child: Entity<Node>,
    abort_first: bool,
    prefix: usize,
}

impl Render for RetryHost {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .relative()
            .children((0..self.prefix).map(|index| {
                div()
                    .id(("prefix", index))
                    .absolute()
                    .size(px(0.))
                    .overflow_hidden()
                    .child(LayoutState {
                        id: "prefix-state",
                        retained: Rc::default(),
                    })
            }))
            .child(Retry {
                child: self.child.clone(),
                abort_first: self.abort_first,
            })
    }
}

#[gpui::test]
fn measured_cache_retry_after_rollback_preserves_state_and_rejects_current_frame_ranges(
    cx: &mut TestAppContext,
) {
    let retained = Rc::new(RefCell::new(Vec::new()));
    let (host, visual) = cx.add_window_view({
        let retained = retained.clone();
        move |_, cx| RetryHost {
            child: cx.new(|_| Node::new(None, CacheKind::Measured, retained)),
            abort_first: false,
            prefix: 0,
        }
    });
    visual.run_until_parked();
    retained.borrow_mut().clear();
    for prefix in [30, 1, 45, 0] {
        retained.borrow_mut().clear();
        host.update(visual, |host, cx| {
            host.prefix = prefix;
            host.abort_first = true;
            cx.notify();
        });
        visual.run_until_parked();
        assert!(
            !retained.borrow().is_empty() && retained.borrow().iter().all(|state| *state),
            "rolled-back cache replay expired layout state: {:?}",
            retained.borrow()
        );
    }
}
