//! A cached view replays last frame's output when nothing it read changed. These check that the
//! replay keeps what the view's content needs to persist (#715) and never replays output from a
//! frame that's gone.
use gpui::{
    App, AppContext as _, Bounds, Context, Element, ElementId, Entity, GlobalElementId,
    InspectorElementId, InteractiveElement as _, IntoElement, LayoutId, ParentElement as _, Pixels,
    Render, StatefulInteractiveElement as _, Style, StyleRefinement, Styled as _, Window, div, px,
};
use std::{cell::Cell, rc::Rc};

/// Element state made while laying out, the way an entrance animation keeps its clock.
struct LayoutState(Rc<Cell<usize>>);

impl IntoElement for LayoutState {
    type Element = Self;

    fn into_element(self) -> Self {
        self
    }
}

impl Element for LayoutState {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        Some("layout-state".into())
    }

    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        let created = self.0.clone();
        window.with_element_state::<(), _>(id.unwrap(), |state, _| {
            if state.is_none() {
                created.set(created.get() + 1);
            }
            ((), ())
        });
        (window.request_layout(Style::default(), None, cx), ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        _: &mut Window,
        _: &mut App,
    ) {
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        _: &mut (),
        _: &mut Window,
        _: &mut App,
    ) {
    }
}

struct Fading(Rc<Cell<usize>>);

impl Render for Fading {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child(LayoutState(self.0.clone()))
    }
}

struct FadingHost(Entity<Fading>);

impl Render for FadingHost {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(
            self.0
                .clone()
                .cached_measured(StyleRefinement::default().w(px(100.))),
        )
    }
}

/// #715: a measured view rendered in layout made element state there, before the range a
/// reused frame replays. Reusing the view dropped it, so the view's next render started
/// over: an entrance fade that restarted on every redraw.
#[gpui::test]
fn a_reused_measured_view_keeps_the_state_its_layout_made(cx: &mut gpui::TestAppContext) {
    let created = Rc::new(Cell::new(0));
    let (host, cx) = cx.add_window_view({
        let created = created.clone();
        move |_, cx| FadingHost(cx.new(|_| Fading(created)))
    });
    cx.run_until_parked();
    assert_eq!(created.get(), 1);
    for _ in 0..3 {
        host.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
    }
    let fading = host.read_with(cx, |host, _| host.0.clone());
    fading.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    assert_eq!(created.get(), 1, "the view's own redraw found its state");
}

/// A clickable view, cached inside a cached pane, after `before` clickable rows.
struct Button(Rc<Cell<usize>>);

impl Render for Button {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let clicks = self.0.clone();
        div()
            .id("button")
            .size(px(50.))
            .on_click(move |_, _, _| clicks.set(clicks.get() + 1))
    }
}

struct Pane(Entity<Button>);

impl Render for Pane {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(
            self.0
                .clone()
                .cached_measured(StyleRefinement::default().w(px(50.))),
        )
    }
}

struct Panes {
    before: usize,
    pane: Entity<Pane>,
    missed: Rc<Cell<usize>>,
}

impl Render for Panes {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let missed = self.missed.clone();
        div()
            .size_full()
            .children((0..self.before).map(|i| {
                let missed = missed.clone();
                // Out of the pane's way, so the pane's bounds hold and it's reused.
                div()
                    .id(i)
                    .absolute()
                    .left(px(100. + i as f32 * 10.))
                    .size(px(5.))
                    .on_click(move |_, _, _| missed.set(missed.get() + 1))
            }))
            .child(
                self.pane
                    .clone()
                    .cached(StyleRefinement::default().size(px(50.))),
            )
    }
}

/// A cached view whose paint carries atlas tiles must repaint when an image
/// retires; otherwise a sibling pane replays the freed (or reused) texture.
#[gpui::test]
fn atlas_eviction_invalidates_cached_view_paint(cx: &mut gpui::TestAppContext) {
    use std::cell::Cell;
    use std::rc::Rc;

    struct Cached(Rc<Cell<usize>>);
    impl Render for Cached {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            self.0.set(self.0.get() + 1);
            div().size_full()
        }
    }

    struct Host(Entity<Cached>);
    impl Render for Host {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().child(
                self.0
                    .clone()
                    .cached(StyleRefinement::default().size_full()),
            )
        }
    }

    let renders = Rc::new(Cell::new(0));
    let (host, cx) = cx.add_window_view({
        let renders = renders.clone();
        move |_, cx| Host(cx.new(|_| Cached(renders)))
    });
    cx.run_until_parked();
    let initially = renders.get();
    assert!(initially > 0, "the cached view painted once");

    host.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    assert_eq!(renders.get(), initially, "an unchanged cached view reuses paint");

    cx.update(|window, cx| {
        window.test_atlas_evicted();
        window.refresh();
        window.draw(cx).clear();
    });
    assert!(
        renders.get() > initially,
        "the cached view must rebuild after atlas eviction"
    );
}

/// A guard more than a regression: a pane that renders sets `refreshing`, so a view inside it
/// renders too. Its replay ranges are also tagged with the frame they index into, so a view
/// left behind by a replayed ancestor or a rolled-back prepaint can never replay them.
#[gpui::test]
fn a_view_in_a_replayed_cached_view_does_not_replay_ranges_from_an_older_frame(
    cx: &mut gpui::TestAppContext,
) {
    let (clicks, missed) = (Rc::new(Cell::new(0)), Rc::new(Cell::new(0)));
    let (panes, cx) = cx.add_window_view({
        let (clicks, missed) = (clicks.clone(), missed.clone());
        move |_, cx| {
            let button = cx.new(|_| Button(clicks));
            Panes {
                before: 0,
                pane: cx.new(|_| Pane(button)),
                missed,
            }
        }
    });
    cx.run_until_parked();
    // New rows before the pane, which is reused.
    panes.update(cx, |panes, cx| {
        panes.before = 3;
        cx.notify();
    });
    cx.run_until_parked();
    // The pane renders; the button inside it doesn't change.
    let pane = panes.read_with(cx, |panes, _| panes.pane.clone());
    pane.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    cx.simulate_click(gpui::point(px(25.), px(28.)), Default::default());
    assert_eq!(
        (clicks.get(), missed.get()),
        (1, 0),
        "the click reached the button"
    );
}
