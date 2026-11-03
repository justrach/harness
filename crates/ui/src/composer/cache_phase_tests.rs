//! Measured-cache replay must retain state from every rendering phase.
use gpui::{
    AnyElement, App, AppContext, Bounds, Context, Element, ElementId, Entity, GlobalElementId,
    InspectorElementId, InteractiveElement, IntoElement, LayoutId, ParentElement, Pixels, Render,
    StyleRefinement, Styled, TestAppContext, Window, WindowHandle, deferred, div, px,
};
use std::{cell::RefCell, rc::Rc};

#[derive(Debug)]
struct Sample {
    phase: u8,
    previous: Option<u32>,
}

#[derive(Default)]
struct Clock<const PHASE: u8>(u32);

type Samples = Rc<RefCell<Vec<Sample>>>;
type Geometry = Rc<RefCell<Vec<Bounds<Pixels>>>>;

fn access<const PHASE: u8>(id: &GlobalElementId, samples: &Samples, window: &mut Window) {
    // The same element ID holds three different state types. Retaining only
    // layout keys, or confusing types at a shared ID, must fail this probe.
    window.with_element_state(id, |state: Option<Clock<PHASE>>, _| {
        let previous = state.map(|clock| clock.0);
        samples.borrow_mut().push(Sample {
            phase: PHASE,
            previous,
        });
        ((), Clock::<PHASE>(previous.unwrap_or(0) + 1))
    });
}

struct Probe {
    samples: Samples,
    geometry: Geometry,
}

impl IntoElement for Probe {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

impl Element for Probe {
    type RequestLayoutState = AnyElement;
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        Some("phase-clock".into())
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
        access::<0>(id.unwrap(), &self.samples, window);
        let mut child = div().w_full().h(px(30.)).into_any_element();
        (child.request_layout(window, cx), child)
    }

    fn prepaint(
        &mut self,
        id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        child: &mut AnyElement,
        window: &mut Window,
        cx: &mut App,
    ) {
        access::<1>(id.unwrap(), &self.samples, window);
        self.geometry.borrow_mut().push(bounds);
        child.prepaint(window, cx);
    }

    fn paint(
        &mut self,
        id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        child: &mut AnyElement,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        access::<2>(id.unwrap(), &self.samples, window);
        child.paint(window, cx);
    }
}

#[derive(Clone, Copy, Debug)]
enum Width {
    Fixed,
    Relative,
    Auto,
}

struct Panel {
    samples: Samples,
    geometry: Geometry,
    deferred: bool,
    populated: bool,
    renders: usize,
}

impl Render for Panel {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        self.renders += 1;
        let probe = self.populated.then(|| Probe {
            samples: self.samples.clone(),
            geometry: self.geometry.clone(),
        });
        let content = div().w_full().h(px(60.)).children(probe);
        if self.deferred {
            // A nested popover: request-layout runs inside the cache, while
            // prepaint/paint execute in later deferred rounds.
            div()
                .w_full()
                .h(px(60.))
                .child(
                    deferred(
                        div()
                            .id("outer-popover")
                            .w_full()
                            .child(deferred(content).priority(2)),
                    )
                    .priority(1),
                )
                .into_any_element()
        } else {
            content.into_any_element()
        }
    }
}

struct Host {
    panel: Entity<Panel>,
    width: Width,
    parent_width: f32,
}

impl Render for Host {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let style = match self.width {
            Width::Fixed => StyleRefinement::default().w(px(self.parent_width)),
            Width::Relative => StyleRefinement::default().w_full(),
            Width::Auto => StyleRefinement::default(),
        };
        div().size_full().child(
            div()
                .flex()
                .flex_col()
                .w(px(self.parent_width))
                .child(self.panel.clone().cached_measured(style)),
        )
    }
}

fn draw(cx: &mut TestAppContext, window: WindowHandle<Host>) {
    cx.update_window(window.into(), |_, window, cx| window.draw(cx).clear())
        .unwrap();
}

fn fixture(
    cx: &mut TestAppContext,
    deferred: bool,
    populated: bool,
) -> (WindowHandle<Host>, Entity<Panel>, Samples, Geometry) {
    let samples = Samples::default();
    let geometry = Geometry::default();
    let panel = cx.update(|cx| {
        cx.new(|_| Panel {
            samples: samples.clone(),
            geometry: geometry.clone(),
            deferred,
            populated,
            renders: 0,
        })
    });
    let window = cx.add_window(|_, _| Host {
        panel: panel.clone(),
        width: Width::Fixed,
        parent_width: 200.,
    });
    draw(cx, window);
    (window, panel, samples, geometry)
}

fn assert_phases(samples: &Samples, fresh: bool) {
    let samples = samples.borrow();
    for phase in 0..3 {
        let phase_samples: Vec<_> = samples
            .iter()
            .filter(|sample| sample.phase == phase)
            .collect();
        assert!(
            !phase_samples.is_empty(),
            "phase {phase} was never exercised: {samples:?}"
        );
        if fresh {
            assert_eq!(
                phase_samples[0].previous, None,
                "phase {phase} inherited an expired clock"
            );
        } else {
            assert!(
                phase_samples
                    .iter()
                    .all(|sample| sample.previous.is_some_and(|count| count > 0)),
                "phase {phase} lost its clock: {samples:?}"
            );
        }
    }
}

fn cache_only_frames(
    cx: &mut TestAppContext,
    window: WindowHandle<Host>,
    panel: &Entity<Panel>,
    samples: &Samples,
) {
    samples.borrow_mut().clear();
    let renders = panel.read_with(cx, |panel, _| panel.renders);
    for _ in 0..5 {
        window.update(cx, |_, _, cx| cx.notify()).unwrap();
        draw(cx, window);
    }
    assert_eq!(
        panel.read_with(cx, |panel, _| panel.renders),
        renders,
        "the cache was bypassed"
    );
    assert!(
        samples.borrow().is_empty(),
        "cache replay must not run the probe again"
    );
}

#[gpui::test]
fn measured_cache_retains_distinct_state_types_from_layout_prepaint_and_paint(
    cx: &mut TestAppContext,
) {
    let (window, panel, samples, _) = fixture(cx, false, true);
    assert_phases(&samples, true);
    for expected in 1..=4 {
        cache_only_frames(cx, window, &panel, &samples);
        panel.update(cx, |_, cx| cx.notify());
        draw(cx, window);
        assert_phases(&samples, false);
        assert!(
            samples
                .borrow()
                .iter()
                .all(|sample| sample.previous == Some(expected)),
            "cache replay restored an obsolete counter: {:?}",
            samples.borrow()
        );
    }
}

#[gpui::test]
fn measured_cache_retains_nested_deferred_phase_state_across_replay(cx: &mut TestAppContext) {
    let (window, panel, samples, _) = fixture(cx, true, true);
    assert_phases(&samples, true);
    for expected in 1..=4 {
        cache_only_frames(cx, window, &panel, &samples);
        panel.update(cx, |_, cx| cx.notify());
        draw(cx, window);
        assert_phases(&samples, false);
        assert!(
            samples
                .borrow()
                .iter()
                .all(|sample| sample.previous == Some(expected)),
            "cache replay restored an obsolete counter: {:?}",
            samples.borrow()
        );
    }
}

#[gpui::test]
fn measured_cache_relayouts_relative_and_auto_widths_without_losing_phase_state(
    cx: &mut TestAppContext,
) {
    let (window, panel, samples, geometry) = fixture(cx, false, true);
    for width in [
        Width::Relative,
        Width::Auto,
        Width::Fixed,
        Width::Relative,
        Width::Auto,
    ] {
        for parent_width in [320., 160., 240.] {
            samples.borrow_mut().clear();
            geometry.borrow_mut().clear();
            window
                .update(cx, |host, _, cx| {
                    host.width = width;
                    host.parent_width = parent_width;
                    cx.notify();
                })
                .unwrap();
            draw(cx, window);
            assert_phases(&samples, false);
            let bounds = geometry.borrow();
            assert!(!bounds.is_empty());
            assert!(
                bounds
                    .iter()
                    .all(|bounds| (f32::from(bounds.size.width) - parent_width).abs() < 0.1),
                "{width:?} used stale measurement at width {parent_width}: {bounds:?}"
            );
            drop(bounds);
            if matches!(width, Width::Fixed) {
                cache_only_frames(cx, window, &panel, &samples);
            } else {
                samples.borrow_mut().clear();
                let renders = panel.read_with(cx, |panel, _| panel.renders);
                window.update(cx, |_, _, cx| cx.notify()).unwrap();
                draw(cx, window);
                assert!(
                    panel.read_with(cx, |panel, _| panel.renders) > renders,
                    "non-fixed width must be remeasured"
                );
                assert_phases(&samples, false);
            }
        }
    }
}

#[gpui::test]
fn measured_cache_handles_empty_populated_and_empty_state_ranges(cx: &mut TestAppContext) {
    let (window, panel, samples, _) = fixture(cx, false, false);
    cache_only_frames(cx, window, &panel, &samples);
    for _ in 0..3 {
        panel.update(cx, |panel, cx| {
            panel.populated = true;
            cx.notify();
        });
        draw(cx, window);
        assert_phases(&samples, true);
        cache_only_frames(cx, window, &panel, &samples);
        panel.update(cx, |_, cx| cx.notify());
        draw(cx, window);
        assert_phases(&samples, false);
        samples.borrow_mut().clear();
        panel.update(cx, |panel, cx| {
            panel.populated = false;
            cx.notify();
        });
        draw(cx, window);
        assert!(samples.borrow().is_empty());
        cache_only_frames(cx, window, &panel, &samples);
    }
}
