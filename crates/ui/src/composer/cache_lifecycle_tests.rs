//! Exercise state retention when measured caches are themselves cached.
use super::cache_state_tests::LayoutState;
use gpui::prelude::*;
use gpui::{
    AnyElement, AppContext, Context, Entity, InteractiveElement, IntoElement, ParentElement,
    Render, StyleRefinement, Styled, TestAppContext, VisualTestContext, Window, div, px,
};
use std::{cell::RefCell, rc::Rc};

#[path = "cache_retry_tests.rs"]
mod retry_tests;

#[derive(Clone, Copy, Debug)]
enum CacheKind {
    Sized,
    Measured,
    Uncached,
}

struct Node {
    child: Option<Entity<Node>>,
    cache: CacheKind,
    prefix: usize,
    width: f32,
    font_size: f32,
    clip: bool,
    retained: Rc<RefCell<Vec<bool>>>,
}

impl Node {
    fn new(
        child: Option<Entity<Node>>,
        cache: CacheKind,
        retained: Rc<RefCell<Vec<bool>>>,
    ) -> Self {
        Self {
            child,
            cache,
            prefix: 0,
            width: 100.,
            font_size: 14.,
            clip: false,
            retained,
        }
    }
}

impl Render for Node {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let child: Option<AnyElement> = self.child.as_ref().map(|child| {
            let style = StyleRefinement::default().w(px(self.width));
            match self.cache {
                CacheKind::Sized => child.clone().cached(style.h(px(120.))).into_any_element(),
                CacheKind::Measured => child.clone().cached_measured(style).into_any_element(),
                CacheKind::Uncached => child.clone().into_any_element(),
            }
        });
        div()
            .relative()
            .flex()
            .flex_col()
            .text_size(px(self.font_size))
            .when(self.clip, |el| el.size(px(90.)).overflow_hidden())
            // Shift state-table offsets without moving the cached subtree.
            .children((0..self.prefix).map(|index| {
                div()
                    .id(("layout-prefix", index))
                    .absolute()
                    .size(px(0.))
                    .overflow_hidden()
                    .child(LayoutState {
                        id: "prefix-state",
                        retained: self.retained.clone(),
                    })
            }))
            .child(LayoutState {
                id: "node-state",
                retained: self.retained.clone(),
            })
            .children(child)
    }
}

fn nested_host(
    cx: &mut TestAppContext,
    outer_kind: CacheKind,
) -> (Entity<Node>, Rc<RefCell<Vec<bool>>>, &mut VisualTestContext) {
    let retained = Rc::new(RefCell::new(Vec::new()));
    let (root, visual) = cx.add_window_view({
        let retained = retained.clone();
        move |_, cx| {
            let leaf = cx.new(|_| Node::new(None, CacheKind::Measured, retained));
            let branch = cx.new(|_| Node::new(Some(leaf), CacheKind::Measured, Rc::default()));
            Node::new(Some(branch), outer_kind, Rc::default())
        }
    });
    visual.run_until_parked();
    retained.borrow_mut().clear();
    (root, retained, visual)
}

fn replay_with_shifted_indices(
    root: &Entity<Node>,
    retained: &Rc<RefCell<Vec<bool>>>,
    visual: &mut VisualTestContext,
) {
    for prefix in [12, 1, 24] {
        root.update(visual, |root, cx| {
            root.prefix = prefix;
            cx.notify();
        });
        visual.run_until_parked();
        assert!(
            retained.borrow().is_empty(),
            "outer cache did not reuse its subtree"
        );
    }
}

#[gpui::test]
fn nested_measured_cache_survives_ancestor_replay_and_shifted_state_indices(
    cx: &mut TestAppContext,
) {
    for outer_kind in [CacheKind::Sized, CacheKind::Measured] {
        let (root, retained, visual) = nested_host(cx, outer_kind);
        let branch = root.read_with(visual, |root, _| root.child.clone().unwrap());
        let leaf = branch.read_with(visual, |branch, _| branch.child.clone().unwrap());
        replay_with_shifted_indices(&root, &retained, visual);
        branch.update(visual, |_, cx| cx.notify());
        visual.run_until_parked();
        leaf.update(visual, |_, cx| cx.notify());
        visual.run_until_parked();
        assert!(
            !retained.borrow().is_empty() && retained.borrow().iter().all(|retained| *retained),
            "nested measured cache lost layout state after {outer_kind:?} ancestor replay: {:?}",
            retained.borrow()
        );
    }
}

#[gpui::test]
fn nested_measured_cache_survives_cached_to_uncached_ancestor_transition(cx: &mut TestAppContext) {
    for outer_kind in [CacheKind::Sized, CacheKind::Measured] {
        let (root, retained, visual) = nested_host(cx, outer_kind);
        let branch = root.read_with(visual, |root, _| root.child.clone().unwrap());
        let leaf = branch.read_with(visual, |branch, _| branch.child.clone().unwrap());
        replay_with_shifted_indices(&root, &retained, visual);
        // Re-enter a previously replayed descendant without notifying it or
        // changing its geometry. Its old frame-relative ranges must not replay.
        root.update(visual, |root, cx| {
            root.cache = CacheKind::Uncached;
            cx.notify();
        });
        visual.run_until_parked();
        leaf.update(visual, |_, cx| cx.notify());
        visual.run_until_parked();
        assert!(
            !retained.borrow().is_empty() && retained.borrow().iter().all(|retained| *retained),
            "nested state expired after {outer_kind:?} -> uncached transition: {:?}",
            retained.borrow()
        );
    }
}

#[gpui::test]
fn measured_cache_preserves_state_on_invalidation_but_releases_it_on_unmount(
    cx: &mut TestAppContext,
) {
    let (root, retained, visual) = nested_host(cx, CacheKind::Measured);
    let branch = root.read_with(visual, |root, _| root.child.clone().unwrap());
    for step in 0..5 {
        retained.borrow_mut().clear();
        root.update(visual, |root, cx| {
            match step {
                0 => root.width = 180.,
                1 => root.font_size = 18.,
                2 => root.clip = true,
                3 => root.cache = CacheKind::Sized,
                _ => root.cache = CacheKind::Measured,
            }
            cx.notify();
        });
        visual.run_until_parked();
        assert!(
            !retained.borrow().is_empty() && retained.borrow().iter().all(|retained| *retained),
            "invalidation did not redraw with retained state at step {step}"
        );
    }
    root.update(visual, |root, cx| {
        root.child = None;
        cx.notify();
    });
    visual.run_until_parked();
    retained.borrow_mut().clear();
    root.update(visual, |root, cx| {
        root.child = Some(branch);
        cx.notify();
    });
    visual.run_until_parked();
    assert!(
        retained.borrow().iter().any(|retained| !retained),
        "a true unmount must release old state"
    );
}
