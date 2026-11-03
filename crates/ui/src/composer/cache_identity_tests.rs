//! Cache replay must preserve mounted identities without reviving absent state.
use super::cache_state_tests::LayoutState;
use gpui::{
    AppContext, Context, Entity, IntoElement, ParentElement, Render, StyleRefinement, Styled,
    TestAppContext, Window, WindowHandle, div, px,
};
use std::{cell::RefCell, rc::Rc};

type Samples = Rc<RefCell<Vec<bool>>>;

struct Leaf {
    persistent: Samples,
    optional: Samples,
    show_optional: bool,
}

impl Render for Leaf {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .h(px(60.))
            .child(LayoutState {
                id: "persistent-clock",
                retained: self.persistent.clone(),
            })
            .children(self.show_optional.then(|| LayoutState {
                id: "optional-clock",
                retained: self.optional.clone(),
            }))
    }
}

struct Host {
    children: Vec<Entity<Leaf>>,
}

impl Render for Host {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .flex_col()
            .children(self.children.iter().map(|child| {
                child
                    .clone()
                    .cached_measured(StyleRefinement::default().w(px(100.)))
            }))
    }
}

fn leaf(cx: &mut TestAppContext) -> (Entity<Leaf>, Samples, Samples) {
    let persistent = Samples::default();
    let optional = Samples::default();
    let entity = cx.update(|cx| {
        cx.new(|_| Leaf {
            persistent: persistent.clone(),
            optional: optional.clone(),
            show_optional: true,
        })
    });
    (entity, persistent, optional)
}

fn draw(cx: &mut TestAppContext, window: WindowHandle<Host>) {
    cx.update_window(window.into(), |_, window, cx| window.draw(cx).clear())
        .unwrap();
}

fn mount(cx: &mut TestAppContext, children: Vec<Entity<Leaf>>) -> WindowHandle<Host> {
    let window = cx.add_window(|_, _| Host { children });
    draw(cx, window);
    window
}

fn replay(cx: &mut TestAppContext, window: WindowHandle<Host>, samples: &Samples) {
    samples.borrow_mut().clear();
    for _ in 0..3 {
        window.update(cx, |_, _, cx| cx.notify()).unwrap();
        draw(cx, window);
    }
    assert!(
        samples.borrow().is_empty(),
        "expected actual cache-only frames"
    );
}

fn assert_retained(samples: &Samples) {
    let samples = samples.borrow();
    assert!(
        !samples.is_empty() && samples.iter().all(|state| *state),
        "{samples:?}"
    );
}

#[gpui::test]
fn measured_sibling_reorder_and_replacement_preserve_only_matching_identities(
    cx: &mut TestAppContext,
) {
    let (a, a_samples, _) = leaf(cx);
    let (b, b_samples, _) = leaf(cx);
    let window = mount(cx, vec![a.clone(), b.clone()]);
    assert!(a_samples.borrow().iter().any(|state| !state));
    assert!(b_samples.borrow().iter().any(|state| !state));
    replay(cx, window, &a_samples);
    b_samples.borrow_mut().clear();
    window
        .update(cx, |host, _, cx| {
            host.children.swap(0, 1);
            cx.notify();
        })
        .unwrap();
    draw(cx, window);
    a.update(cx, |_, cx| cx.notify());
    b.update(cx, |_, cx| cx.notify());
    draw(cx, window);
    assert_retained(&a_samples);
    assert_retained(&b_samples);

    // The new entity occupies B's old position and uses identical local
    // element IDs, but must not inherit B's animation/layout state.
    let (replacement, replacement_samples, _) = leaf(cx);
    a_samples.borrow_mut().clear();
    window
        .update(cx, |host, _, cx| {
            host.children[0] = replacement.clone();
            cx.notify();
        })
        .unwrap();
    draw(cx, window);
    assert_eq!(replacement_samples.borrow().first(), Some(&false));
    replacement_samples.borrow_mut().clear();
    replacement.update(cx, |_, cx| cx.notify());
    a.update(cx, |_, cx| cx.notify());
    draw(cx, window);
    assert_retained(&replacement_samples);
    assert_retained(&a_samples);
}

#[gpui::test]
fn measured_cache_forgets_removed_layout_state_without_resetting_its_sibling(
    cx: &mut TestAppContext,
) {
    let (entity, persistent, optional) = leaf(cx);
    let window = mount(cx, vec![entity.clone()]);
    replay(cx, window, &persistent);
    optional.borrow_mut().clear();
    entity.update(cx, |leaf, cx| {
        leaf.show_optional = false;
        cx.notify();
    });
    draw(cx, window);
    assert_retained(&persistent);
    assert!(optional.borrow().is_empty());
    // The parent and leaf stay mounted and cache hits really occur while
    // just one layout-phase state ID is absent from the tree.
    replay(cx, window, &persistent);
    entity.update(cx, |_, cx| cx.notify());
    draw(cx, window);
    assert_retained(&persistent);
    assert!(optional.borrow().is_empty());
    persistent.borrow_mut().clear();
    entity.update(cx, |leaf, cx| {
        leaf.show_optional = true;
        cx.notify();
    });
    draw(cx, window);
    assert_retained(&persistent);
    assert_eq!(optional.borrow().first(), Some(&false));
    optional.borrow_mut().clear();
    entity.update(cx, |_, cx| cx.notify());
    draw(cx, window);
    assert_retained(&optional);
}

#[gpui::test]
fn measured_layout_state_is_isolated_between_windows_sharing_the_same_entity(
    cx: &mut TestAppContext,
) {
    let (entity, persistent, _) = leaf(cx);
    let first = mount(cx, vec![entity.clone()]);
    assert_eq!(persistent.borrow().first(), Some(&false));
    persistent.borrow_mut().clear();
    let second = mount(cx, vec![entity.clone()]);
    assert_eq!(
        persistent.borrow().first(),
        Some(&false),
        "a new window must have a fresh clock"
    );
    replay(cx, first, &persistent);
    replay(cx, second, &persistent);
    persistent.borrow_mut().clear();
    entity.update(cx, |_, cx| cx.notify());
    // Notifications can draw windows during effect flushing, so collect
    // across the notification and both draws instead of clearing mid-update.
    draw(cx, first);
    draw(cx, second);
    assert_retained(&persistent);
    assert!(persistent.borrow().len() >= 2, "both windows must redraw");

    // Unmounting in one window must neither expire nor resurrect the
    // independent state belonging to the other window.
    first
        .update(cx, |host, _, cx| {
            host.children.clear();
            cx.notify();
        })
        .unwrap();
    draw(cx, first);
    persistent.borrow_mut().clear();
    entity.update(cx, |_, cx| cx.notify());
    draw(cx, second);
    assert_retained(&persistent);
    persistent.borrow_mut().clear();
    first
        .update(cx, |host, _, cx| {
            host.children.push(entity);
            cx.notify();
        })
        .unwrap();
    draw(cx, first);
    assert_eq!(persistent.borrow().first(), Some(&false));
}
