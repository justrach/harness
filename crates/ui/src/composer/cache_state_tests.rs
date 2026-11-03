//! Request-layout state must survive measured-cache replay, just like the
//! question and queue entrance clocks that live in that phase.
use gpui::{
    AnyElement, App, AppContext, Bounds, Context, Element, ElementId, Entity, GlobalElementId,
    InspectorElementId, IntoElement, LayoutId, ParentElement, Pixels, Render, StyleRefinement,
    Styled, TestAppContext, Window, div, px,
};
use std::{cell::RefCell, rc::Rc};

pub(super) struct LayoutState {
    pub(super) id: &'static str,
    pub(super) retained: Rc<RefCell<Vec<bool>>>,
}

impl IntoElement for LayoutState {
    type Element = Self;

    fn into_element(self) -> Self {
        self
    }
}

impl Element for LayoutState {
    type RequestLayoutState = AnyElement;
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        Some(self.id.into())
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, AnyElement) {
        window.with_element_state(id.unwrap(), |state: Option<()>, _| {
            self.retained.borrow_mut().push(state.is_some());
            ((), ())
        });
        let mut child = div().h(px(30.)).into_any_element();
        (child.request_layout(window, cx), child)
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        child: &mut AnyElement,
        window: &mut Window,
        cx: &mut App,
    ) {
        child.prepaint(window, cx);
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        child: &mut AnyElement,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        child.paint(window, cx);
    }
}

struct Child {
    id: &'static str,
    retained: Rc<RefCell<Vec<bool>>>,
}

impl Render for Child {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        LayoutState {
            id: self.id,
            retained: self.retained.clone(),
        }
    }
}

struct Host {
    child: Entity<Child>,
    measured: bool,
}

impl Render for Host {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let style = StyleRefinement::default().w(px(100.));
        let child = if self.measured {
            self.child.clone().cached_measured(style)
        } else {
            self.child.clone().cached(style.h(px(30.)))
        };
        div().size_full().child(child)
    }
}

#[gpui::test]
fn measured_cache_preserves_question_and_queue_layout_state(cx: &mut TestAppContext) {
    // A fixed-size cached view is the control. Both panel entrances store
    // their clocks during request_layout, not prepaint or paint.
    for measured in [false, true] {
        for id in ["composer-wizard", "composer-queue"] {
            let retained = Rc::new(RefCell::new(Vec::new()));
            let (host, visual) = cx.add_window_view({
                let retained = retained.clone();
                move |_, cx| Host {
                    child: cx.new(|_| Child { id, retained }),
                    measured,
                }
            });
            visual.run_until_parked();
            let child = host.read_with(visual, |host, _| host.child.clone());
            retained.borrow_mut().clear();
            child.update(visual, |_, cx| cx.notify());
            visual.run_until_parked();
            assert!(retained.borrow().iter().all(|state| *state));
            let renders = retained.borrow().len();
            assert!(renders > 0);
            for _ in 0..3 {
                host.update(visual, |_, cx| cx.notify());
                visual.run_until_parked();
            }
            assert_eq!(
                retained.borrow().len(),
                renders,
                "parent-only frames must reuse {id}"
            );
            child.update(visual, |_, cx| cx.notify());
            visual.run_until_parked();
            assert!(
                retained.borrow().len() > renders && retained.borrow().iter().all(|state| *state),
                "{id} lost request-layout state after cache replay; measured={measured}: {:?}",
                retained.borrow()
            );
        }
    }
}
