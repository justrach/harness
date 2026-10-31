//! Per-range hit targets share the text's shaped geometry, including wrapped links.
use super::{
    links::*,
    render::{LinkUi, activate_link, range_rects},
};
use crate::{icons, popover, theme::Theme};
use gpui::{
    AnyElement, App, AvailableSpace, Bounds, ClickEvent, DispatchPhase, Element, ElementId,
    FocusHandle, GlobalElementId, InspectorElementId, LayoutId, MouseButton, Pixels, Point, Role,
    ScrollWheelEvent, SharedString, TextLayout, Window, div, prelude::*, px,
};
use std::{
    cell::{Cell, RefCell},
    ops::Range,
    rc::Rc,
};

#[cfg(feature = "browser-fixture")]
thread_local! {
    static FIXTURE_LINKS: RefCell<std::collections::HashMap<String, (Point<Pixels>, FocusHandle)>> = RefCell::default();
}
#[cfg(feature = "browser-fixture")]
pub(crate) fn fixture_link(target: &str) -> Option<(Point<Pixels>, FocusHandle)> {
    FIXTURE_LINKS.with(|links| links.borrow().get(target).cloned())
}

pub struct LinkRanges {
    pub id: SharedString,
    pub child: AnyElement,
    /// Shaped text ranges, or the child's whole visible box for an equation.
    pub layout: Option<TextLayout>,
    /// Selection belongs to this rendered text, not every transcript/window.
    pub selection_key: Option<std::sync::Arc<str>>,
    pub links: Vec<(Range<usize>, LinkTarget)>,
    pub ui: Option<LinkUi>,
}
impl LinkRanges {
    fn rects(
        &self,
        range: &Range<usize>,
        bounds: Bounds<Pixels>,
        window: &Window,
    ) -> Vec<Bounds<Pixels>> {
        if let Some(layout) = &self.layout {
            range_rects(layout, range, 0., 0.)
        } else {
            let visible = bounds.intersect(&window.content_mask().bounds);
            if visible.size.width > px(0.) && visible.size.height > px(0.) {
                vec![visible]
            } else {
                vec![]
            }
        }
    }
}

struct Interaction {
    targets: Vec<LinkTarget>,
    focus: Vec<FocusHandle>,
    menu_focus: [FocusHandle; 4],
    menu_focus_pending: Rc<Cell<bool>>,
    menu: Rc<RefCell<Option<(usize, Point<Pixels>)>>>,
    bounds: Bounds<Pixels>,
    epoch: Rc<Cell<u64>>,
    dismissed: Rc<Cell<bool>>,
    tooltip_bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    focused: Option<usize>,
}
impl IntoElement for LinkRanges {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}
impl Element for LinkRanges {
    type RequestLayoutState = ();
    type PrepaintState = (
        Vec<AnyElement>,
        Rc<RefCell<Option<(usize, Point<Pixels>)>>>,
        Rc<Cell<u64>>,
        Rc<Cell<bool>>,
        Rc<Cell<Option<Bounds<Pixels>>>>,
    );
    fn id(&self) -> Option<ElementId> {
        Some(self.id.clone().into())
    }
    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }
    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        (self.child.request_layout(window, cx), ())
    }
    fn prepaint(
        &mut self,
        id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        self.child.prepaint(window, cx);
        window.with_element_state::<Interaction, _>(id.unwrap(), |previous, window| {
            let targets: Vec<_> = self.links.iter().map(|(_, t)| t.clone()).collect();
            let mut state = previous
                .filter(|s| s.targets == targets)
                .unwrap_or_else(|| Interaction {
                    focus: targets
                        .iter()
                        .map(|_| cx.focus_handle().tab_stop(true))
                        .collect(),
                    targets,
                    menu_focus: std::array::from_fn(|_| cx.focus_handle().tab_stop(true)),
                    menu_focus_pending: Rc::default(),
                    menu: Rc::default(),
                    bounds,
                    epoch: Rc::default(),
                    dismissed: Rc::default(),
                    tooltip_bounds: Rc::default(),
                    focused: None,
                });
            if state.bounds != bounds {
                state.menu.borrow_mut().take();
                state.epoch.set(state.epoch.get().wrapping_add(1));
                state.dismissed.set(true);
            }
            let focused = state
                .focus
                .iter()
                .position(|focus| focus.is_focused(window));
            if focused != state.focused {
                state.dismissed.set(false);
            }
            state.focused = focused;
            // Pointer focus must not mount a second disclosure between mouse
            // down and up: window-edge snapping can put it over the hit target.
            let disclosure_focus = focused.filter(|_| window.last_input_was_keyboard());
            state.bounds = bounds;
            state.tooltip_bounds.set(None);
            #[cfg(test)]
            tests::TOOLTIP_BOUNDS.with(|bounds| {
                *bounds.borrow_mut() = Some(state.tooltip_bounds.clone());
            });
            #[cfg(all(test, any(target_os = "linux", windows)))]
            rendered_tests::TOOLTIP_BOUNDS.with(|bounds| {
                *bounds.borrow_mut() = Some(state.tooltip_bounds.clone());
            });
            let theme = Theme::of(cx).clone();
            let mut overlays = Vec::new();
            for (index, (range, target)) in self.links.iter().enumerate() {
                let rects = self.rects(range, bounds, window);
                for (part, rect) in rects.into_iter().enumerate() {
                    #[cfg(feature = "browser-fixture")]
                    if part == 0 {
                        FIXTURE_LINKS.with(|links| {
                            links.borrow_mut().insert(
                                target.original.clone(),
                                (rect.center(), state.focus[index].clone()),
                            )
                        });
                    }
                    let menu = state.menu.clone();
                    let keyboard_menu = menu.clone();
                    let focus = state.focus[index].clone();
                    let click_target = target.clone();
                    let destination = target.original.clone();
                    let tooltip_bounds = state.tooltip_bounds.clone();
                    let click_ui = self.ui.clone();
                    let selection_key = self.selection_key.clone();
                    let menu_focus_pending = state.menu_focus_pending.clone();
                    let pointer_focus_pending = menu_focus_pending.clone();
                    let keyboard_dismissed = state.dismissed.clone();
                    let keyboard_epoch = state.epoch.clone();
                    let hit = div()
                        .id(format!("link-{index}-{part}-{}", state.epoch.get()))
                        // Removing the builder cancels both visible tooltips
                        // and GPUI's delayed show task while the menu or the
                        // keyboard disclosure owns input.
                        .when(
                            state.menu.borrow().is_none() && disclosure_focus != Some(index),
                            |hit| {
                                hit.hoverable_tooltip(move |_, cx| {
                                    let url = destination.clone();
                                    let bounds = tooltip_bounds.clone();
                                    cx.new(|_| super::link_destination::Destination(url, bounds))
                                        .into()
                                })
                            },
                        )
                        .w(rect.size.width)
                        .h(rect.size.height)
                        .cursor_pointer()
                        .role(Role::Link)
                        .aria_label(target.label.clone())
                        .when(part == 0, |el| el.track_focus(&focus))
                        .focus_visible(|s| {
                            s.bg(theme.selection).border_1().border_color(theme.accent)
                        })
                        .on_click(move |event, window, cx| {
                            if click_is_activation(event)
                                && (matches!(event, ClickEvent::Keyboard(_))
                                    || selection_key.as_ref().is_none_or(|key| {
                                        super::selection::wash_range(key).is_none()
                                    }))
                            {
                                activate_link(
                                    click_target.clone(),
                                    LinkAction::Primary,
                                    click_ui.as_ref(),
                                    window,
                                    cx,
                                );
                            }
                        })
                        .on_mouse_down(MouseButton::Right, move |event, window, cx| {
                            *menu.borrow_mut() = Some((index, event.position));
                            pointer_focus_pending.set(true);
                            cx.stop_propagation();
                            window.refresh();
                        })
                        .on_key_down(move |event, window, cx| {
                            match event.keystroke.key.as_str() {
                                "tab" => {
                                    if event.keystroke.modifiers.shift {
                                        window.focus_prev(cx);
                                    } else {
                                        window.focus_next(cx);
                                    }
                                }
                                "f10" if event.keystroke.modifiers.shift => {
                                    *keyboard_menu.borrow_mut() = Some((index, rect.bottom_left()));
                                    menu_focus_pending.set(true);
                                    window.refresh();
                                }
                                "escape" => {
                                    keyboard_menu.borrow_mut().take();
                                    keyboard_dismissed.set(true);
                                    keyboard_epoch.set(keyboard_epoch.get().wrapping_add(1));
                                    window.refresh();
                                }
                                _ => {
                                    cx.propagate();
                                    return;
                                }
                            }
                            cx.stop_propagation();
                        });
                    let mut hit = hit.into_any_element();
                    hit.prepaint_as_root(
                        rect.origin,
                        rect.size.map(AvailableSpace::Definite),
                        window,
                        cx,
                    );
                    overlays.push(hit);
                }
            }
            if state.menu.borrow().is_none() && !state.dismissed.get() {
                if let Some(index) = disclosure_focus {
                    let source = self
                        .rects(&self.links[index].0, bounds, window)
                        .into_iter()
                        .reduce(|bounds, rect| bounds.union(&rect));
                    if let Some((card, position, anchor)) = source.and_then(|source| {
                        super::link_destination::focused_destination_card(
                            &state.targets[index].original,
                            state.tooltip_bounds.clone(),
                            source,
                            window,
                            cx,
                        )
                    }) {
                        let dismissed = state.dismissed.clone();
                        // This disclosure is not a menu: menu_at consumes every
                        // outside press, preventing other controls from receiving it.
                        let mut popup = gpui::deferred(
                            gpui::anchored()
                                .position(position)
                                .anchor(anchor)
                                .snap_to_window_with_margin(px(8.))
                                .child(
                                    div()
                                        .id("focused-link-destination")
                                        .occlude()
                                        .on_mouse_down_out(move |_, window, _| {
                                            // Keep the link's pending press alive until
                                            // mouse-up; dismissal must not change its ID.
                                            dismissed.set(true);
                                            window.refresh();
                                        })
                                        .child(card),
                                ),
                        )
                        .priority(1)
                        .into_any_element();
                        popup.prepaint_as_root(
                            bounds.origin,
                            window.viewport_size().map(AvailableSpace::Definite),
                            window,
                            cx,
                        );
                        overlays.push(popup);
                    }
                }
            }
            if let Some((index, position)) = *state.menu.borrow() {
                let theme = theme.for_popup();
                let menu = state.menu.clone();
                let dismiss_menu = state.menu.clone();
                let return_focus = state.focus[index].clone();
                let menu_focus = state.menu_focus.clone();
                let pending = state.menu_focus_pending.clone();
                let initial_focus = state.menu_focus[0].clone();
                let mut card = crate::popover::popover_card(&theme)
                    .child(
                        gpui::canvas(
                            move |_, window, cx| {
                                // Claim focus only when the deferred menu mounts. The
                                // shell recovers focus from handles that are not mounted.
                                if pending.replace(false) {
                                    window.focus(&initial_focus, cx);
                                }
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .w(px(0.))
                        .h(px(0.)),
                    )
                    .id("link-actions")
                    .on_key_down(move |event, window, cx| {
                        match event.keystroke.key.as_str() {
                            "escape" => {
                                dismiss_menu.borrow_mut().take();
                                window.focus(&return_focus, cx);
                                window.refresh();
                            }
                            "tab" | "down" | "up" => {
                                let current = menu_focus
                                    .iter()
                                    .position(|focus| focus.is_focused(window))
                                    .unwrap_or(0);
                                let backwards = event.keystroke.key == "up"
                                    || (event.keystroke.key == "tab"
                                        && event.keystroke.modifiers.shift);
                                let next = if backwards {
                                    (current + menu_focus.len() - 1) % menu_focus.len()
                                } else {
                                    (current + 1) % menu_focus.len()
                                };
                                window.focus(&menu_focus[next], cx);
                            }
                            _ => return,
                        }
                        cx.stop_propagation();
                    })
                    .w(px(260.))
                    .flex()
                    .flex_col()
                    .on_mouse_down_out(move |_, window, _| {
                        menu.borrow_mut().take();
                        window.refresh();
                    });
                for (action_ix, (action, label, icon)) in [
                    (LinkAction::Internal, "Open in Harness", icons::GLOBE),
                    (
                        LinkAction::External,
                        "Open in external browser",
                        icons::ARROW_UP_RIGHT,
                    ),
                    (LinkAction::Copy, "Copy link address", icons::COPY),
                ]
                .into_iter()
                .enumerate()
                {
                    let target = state.targets[index].clone();
                    let ui = self.ui.clone();
                    let menu = state.menu.clone();
                    let enabled = action == LinkAction::Copy || target.navigation.is_ok();
                    card = card.child(
                        popover::menu_row(
                            &theme,
                            false,
                            format!("{}-link-{index}-action-{action_ix}", self.id),
                        )
                        .id(label)
                        .when(cfg!(test), |row| row.debug_selector(move || label.into()))
                        .child(icons::icon(icon).size(px(16.)).text_color(theme.text_muted))
                        .child(label)
                        .track_focus(&state.menu_focus[action_ix])
                        .role(Role::Button)
                        .aria_label(label)
                        .when(!enabled, |el| el.opacity(0.45))
                        .focus_visible(|s| s.bg(crate::theme::card_selected_bg()))
                        .on_click(move |_, window, cx| {
                            if enabled {
                                activate_link(target.clone(), action, ui.as_ref(), window, cx);
                            }
                            menu.borrow_mut().take();
                            window.refresh();
                        }),
                    );
                }
                let open_in_harness =
                    crate::settings::with_current(cx, |s| s.open_web_links_in_harness);
                let menu = state.menu.clone();
                card = card.child(popover::menu_separator()).child(
                    popover::menu_row(
                        &theme,
                        false,
                        format!("{}-link-{index}-default-destination", self.id),
                    )
                    .id("Open links in Harness")
                    .child(div().w(px(16.)).flex_none().when(open_in_harness, |el| {
                        el.child(
                            icons::icon(icons::CHECK)
                                .size(px(16.))
                                .text_color(theme.text_muted),
                        )
                    }))
                    .child("Open links in Harness")
                    .track_focus(&state.menu_focus[3])
                    .role(Role::Button)
                    .aria_label(if open_in_harness {
                        "Open links in Harness, checked"
                    } else {
                        "Open links in Harness, unchecked"
                    })
                    .focus_visible(|s| s.bg(crate::theme::card_selected_bg()))
                    .on_click(move |_, window, cx| {
                        crate::settings::update(
                            crate::settings::SavePolicy::Immediate,
                            cx,
                            |settings| {
                                settings.open_web_links_in_harness = !open_in_harness;
                            },
                        );
                        menu.borrow_mut().take();
                        cx.refresh_windows();
                        window.refresh();
                    }),
                );
                let mut popup = crate::popover::menu_at(
                    "transcript-link-actions",
                    position,
                    card.into_any_element(),
                    None,
                );
                popup.prepaint_as_root(
                    bounds.origin,
                    window.viewport_size().map(AvailableSpace::Definite),
                    window,
                    cx,
                );
                overlays.push(popup);
            }
            (
                (
                    overlays,
                    state.menu.clone(),
                    state.epoch.clone(),
                    state.dismissed.clone(),
                    state.tooltip_bounds.clone(),
                ),
                state,
            )
        })
    }
    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        paint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let menu = paint.1.clone();
        let epoch = paint.2.clone();
        let dismissed = paint.3.clone();
        let tooltip_bounds = paint.4.clone();
        window.on_mouse_event(move |event: &ScrollWheelEvent, phase, window, _| {
            if phase == DispatchPhase::Capture
                && !tooltip_bounds
                    .get()
                    .is_some_and(|rect| rect.contains(&event.position))
            {
                menu.borrow_mut().take();
                epoch.set(epoch.get().wrapping_add(1));
                dismissed.set(true);
                window.refresh();
            }
        });
        self.child.paint(window, cx);
        for overlay in &mut paint.0 {
            overlay.paint(window, cx);
        }
    }
}
fn click_is_activation(event: &ClickEvent) -> bool {
    match event {
        ClickEvent::Mouse(event) => {
            event.down.button == MouseButton::Left
                && event.down.click_count == 1
                && (event.up.position - event.down.position).magnitude() <= 4.
        }
        ClickEvent::Keyboard(_) | ClickEvent::Touch(_) => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{MouseClickEvent, MouseDownEvent, MouseUpEvent, TestAppContext, point};
    thread_local! {
        pub(super) static TOOLTIP_BOUNDS: RefCell<Option<Rc<Cell<Option<Bounds<Pixels>>>>>> = RefCell::default();
    }
    #[test]
    fn selection_drags_and_secondary_clicks_do_not_navigate() {
        let mut event = MouseClickEvent {
            down: MouseDownEvent {
                button: MouseButton::Left,
                click_count: 1,
                ..Default::default()
            },
            up: MouseUpEvent::default(),
        };
        assert!(click_is_activation(&ClickEvent::Mouse(event.clone())));
        event.up.position = point(px(20.), px(0.));
        assert!(!click_is_activation(&ClickEvent::Mouse(event.clone())));
        event.up.position = event.down.position;
        event.down.button = MouseButton::Right;
        assert!(!click_is_activation(&ClickEvent::Mouse(event.clone())));
        event.down.button = MouseButton::Left;
        event.down.click_count = 2;
        assert!(!click_is_activation(&ClickEvent::Mouse(event)));
    }
    struct BottomLink {
        layout: TextLayout,
        activations: Rc<Cell<usize>>,
    }
    impl gpui::Render for BottomLink {
        fn render(&mut self, _: &mut Window, _: &mut gpui::Context<Self>) -> impl IntoElement {
            let text = gpui::StyledText::new("Docs");
            self.layout = text.layout().clone();
            let activations = self.activations.clone();
            div()
                .size_full()
                .flex()
                .flex_col()
                .justify_end()
                .child(LinkRanges {
                    id: "bottom-link".into(),
                    child: text.into_any_element(),
                    layout: Some(self.layout.clone()),
                    selection_key: None,
                    links: vec![(0..4, LinkTarget::new("Docs", "https://example.com/docs"))],
                    ui: Some(LinkUi {
                        source_session: None,
                        handler: Rc::new(move |_, _, _| {
                            activations.set(activations.get() + 1);
                            LinkOutcome::Rejected
                        }),
                    }),
                })
        }
    }
    #[gpui::test]
    fn pointer_focus_at_window_bottom_does_not_block_link_click(cx: &mut TestAppContext) {
        let _selection = super::super::selection::test_state_lock();
        cx.update(|cx| cx.set_global(Theme::dark()));
        let activations = Rc::new(Cell::new(0));
        let window = cx.open_window(gpui::size(px(400.), px(240.)), |_, _| BottomLink {
            layout: TextLayout::default(),
            activations: activations.clone(),
        });
        let view = window.root(cx).unwrap();
        cx.update_window(window.into(), |_, window, cx| {
            let _ = window.draw(cx);
            let position = range_rects(&view.read(cx).layout, &(0..4), 0., 0.)[0].center();
            for expected in 1..=2 {
                window.dispatch_event(
                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                        position,
                        ..Default::default()
                    }),
                    cx,
                );
                window.dispatch_event(
                    gpui::PlatformInput::MouseDown(MouseDownEvent {
                        button: MouseButton::Left,
                        position,
                        click_count: 1,
                        ..Default::default()
                    }),
                    cx,
                );
                // A frame between down and up used to mount a focused
                // disclosure, snapped over the link at the window edge.
                window.refresh();
                let _ = window.draw(cx);
                window.dispatch_event(
                    gpui::PlatformInput::MouseUp(MouseUpEvent {
                        button: MouseButton::Left,
                        position,
                        click_count: 1,
                        ..Default::default()
                    }),
                    cx,
                );
                assert_eq!(activations.get(), expected);
                window.refresh();
                let _ = window.draw(cx);
            }
        })
        .unwrap();
    }
    fn pointer_click(position: Point<Pixels>, window: &mut Window, cx: &mut App) {
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(MouseDownEvent {
                button: MouseButton::Left,
                position,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
        window.refresh();
        let _ = window.draw(cx);
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(MouseUpEvent {
                button: MouseButton::Left,
                position,
                click_count: 1,
                ..Default::default()
            }),
            cx,
        );
    }
    fn key(key: &str, window: &mut Window, cx: &mut App) {
        window.dispatch_event(
            gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                keystroke: gpui::Keystroke::parse(key).unwrap(),
                is_held: false,
                prefer_character_input: false,
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::KeyUp(gpui::KeyUpEvent {
                keystroke: gpui::Keystroke::parse(key).unwrap(),
            }),
            cx,
        );
        window.refresh();
        let _ = window.draw(cx);
    }
    #[gpui::test]
    fn settled_selection_from_unmounted_text_does_not_block_plain_link(cx: &mut TestAppContext) {
        let _selection = super::super::selection::test_state_lock();
        cx.update(|cx| cx.set_global(Theme::dark()));
        let activations = Rc::new(Cell::new(0));
        let window = cx.open_window(gpui::size(px(400.), px(240.)), |_, _| BottomLink {
            layout: TextLayout::default(),
            activations: activations.clone(),
        });
        let view = window.root(cx).unwrap();
        super::super::selection::begin_with_span("unmounted-text", "selected", 0..8);
        super::super::selection::end_active_drag();
        cx.update_window(window.into(), |_, window, cx| {
            let _ = window.draw(cx);
            let position = range_rects(&view.read(cx).layout, &(0..4), 0., 0.)[0].center();
            pointer_click(position, window, cx);
        })
        .unwrap();
        super::super::selection::clear_if_owner("unmounted-text");
        assert_eq!(activations.get(), 1);
    }
    #[gpui::test]
    fn keyboard_disclosure_does_not_cover_pointer_activation(cx: &mut TestAppContext) {
        let _selection = super::super::selection::test_state_lock();
        cx.update(|cx| cx.set_global(Theme::dark()));
        let activations = Rc::new(Cell::new(0));
        let window = cx.open_window(gpui::size(px(400.), px(240.)), |_, _| BottomLink {
            layout: TextLayout::default(),
            activations: activations.clone(),
        });
        let view = window.root(cx).unwrap();
        cx.update_window(window.into(), |_, window, cx| {
            let _ = window.draw(cx);
            window.focus_next(cx);
            key("enter", window, cx);
            assert_eq!(activations.get(), 1);
            let position = range_rects(&view.read(cx).layout, &(0..4), 0., 0.)[0].center();
            let tooltip =
                TOOLTIP_BOUNDS.with(|bounds| bounds.borrow().as_ref().unwrap().get().unwrap());
            assert!(
                !tooltip.contains(&position),
                "keyboard disclosure must not cover its source"
            );
            // The pointer need not move after a keyboard action. The existing
            // disclosure hitbox must not swallow the first mouse-down.
            pointer_click(position, window, cx);
            assert_eq!(activations.get(), 2);
        })
        .unwrap();
    }
    struct SelectableLink(Rc<Cell<usize>>);
    impl gpui::Render for SelectableLink {
        fn render(
            &mut self,
            window: &mut Window,
            cx: &mut gpui::Context<Self>,
        ) -> impl IntoElement {
            let mut opts = super::super::render::RenderOptions::settled("gesture-link".into());
            let activations = self.0.clone();
            opts.link = Some(LinkUi {
                source_session: None,
                handler: Rc::new(move |_, _, _| {
                    activations.set(activations.get() + 1);
                    LinkOutcome::Rejected
                }),
            });
            div()
                .w(px(320.))
                .child(super::super::render::selection_frame_reset())
                .child(super::super::render::render_tree(
                    &super::super::parser::parse_full("[Documentation](https://example.com/docs)"),
                    &opts,
                    &Theme::of(cx).clone(),
                    window,
                    &|_| None,
                ))
        }
    }
    fn pointer_gesture(
        start: Point<Pixels>,
        end: Point<Pixels>,
        count: usize,
        window: &mut Window,
        cx: &mut App,
    ) {
        window.dispatch_event(
            gpui::PlatformInput::MouseDown(MouseDownEvent {
                button: MouseButton::Left,
                position: start,
                click_count: count,
                ..Default::default()
            }),
            cx,
        );
        window.refresh();
        let _ = window.draw(cx);
        window.dispatch_event(
            gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                position: end,
                pressed_button: Some(MouseButton::Left),
                ..Default::default()
            }),
            cx,
        );
        window.refresh();
        let _ = window.draw(cx);
        window.dispatch_event(
            gpui::PlatformInput::MouseUp(MouseUpEvent {
                button: MouseButton::Left,
                position: end,
                click_count: count,
                ..Default::default()
            }),
            cx,
        );
    }
    #[gpui::test]
    fn markdown_selection_distinguishes_clicks_jitter_and_selection_gestures(
        cx: &mut TestAppContext,
    ) {
        let _selection = super::super::selection::test_state_lock();
        cx.update(|cx| cx.set_global(Theme::dark()));
        let activations = Rc::new(Cell::new(0));
        let window = cx.open_window(gpui::size(px(400.), px(240.)), |_, _| {
            SelectableLink(activations.clone())
        });
        cx.update_window(window.into(), |_, window, cx| {
            let _ = window.draw(cx);
            let (_, layout, _) = super::super::render::selection_test_snapshot("gesture-link:0");
            let rect = range_rects(&layout, &(0..13), 0., 0.)[0];
            let start = point(rect.left() + px(0.1), rect.center().y);
            pointer_gesture(start, start + point(px(1.), px(0.)), 1, window, cx);
            assert!(super::super::selection::selected_text().is_none());
            assert_eq!(
                activations.get(),
                1,
                "unselected pointer jitter remains a click"
            );
            // Find a two-pixel gesture crossing a real shaped-character boundary.
            let (start, end) = (1..f32::from(rect.size.width) as usize - 2)
                .find_map(|x| {
                    let start = point(rect.left() + px(x as f32), rect.center().y);
                    let end = start + point(px(2.), px(0.));
                    (layout.index_for_position(start) != layout.index_for_position(end))
                        .then_some((start, end))
                })
                .expect("link has selectable character boundaries");
            pointer_gesture(start, end, 1, window, cx);
            assert!(super::super::selection::selected_text().is_some());
            assert_eq!(
                activations.get(),
                1,
                "even short text-selection gestures must not navigate"
            );
            key("enter", window, cx);
            assert_eq!(
                activations.get(),
                2,
                "keyboard activation ignores selected text"
            );
            pointer_gesture(rect.center(), rect.center(), 2, window, cx);
            assert_eq!(
                activations.get(),
                2,
                "double-click selects rather than navigates"
            );
            pointer_gesture(start, rect.center(), 1, window, cx);
            assert_eq!(activations.get(), 2, "selection drags must not navigate");
            pointer_click(rect.center(), window, cx);
            assert_eq!(
                activations.get(),
                3,
                "a fresh click clears settled selection"
            );
        })
        .unwrap();
        super::super::selection::clear_if_owner("gesture-link:0");
    }
    #[gpui::test]
    fn visible_hover_and_dismissed_context_menu_do_not_block_link(cx: &mut TestAppContext) {
        let _selection = super::super::selection::test_state_lock();
        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::dark());
            crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        });
        let activations = Rc::new(Cell::new(0));
        let window = cx.open_window(gpui::size(px(400.), px(240.)), |_, _| BottomLink {
            layout: TextLayout::default(),
            activations: activations.clone(),
        });
        let view = window.root(cx).unwrap();
        let source = cx
            .update_window(window.into(), |_, window, cx| {
                let _ = window.draw(cx);
                let source = range_rects(&view.read(cx).layout, &(0..4), 0., 0.)[0];
                let position = source.bottom_left() + point(px(2.), px(-2.));
                window.dispatch_event(
                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                        position,
                        ..Default::default()
                    }),
                    cx,
                );
                window.refresh();
                let _ = window.draw(cx);
                source
            })
            .unwrap();
        cx.run_until_parked();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(650));
        cx.run_until_parked();
        cx.update_window(window.into(), |_, window, cx| {
            window.refresh();
            let _ = window.draw(cx);
            let tooltip = TOOLTIP_BOUNDS.with(|bounds| {
                bounds
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .get()
                    .expect("hover disclosure is visible")
            });
            let left = source.left().max(tooltip.left());
            let right = source.right().min(tooltip.right());
            let top = source.top().max(tooltip.top());
            let bottom = source.bottom().min(tooltip.bottom());
            assert!(
                left < right && top < bottom,
                "hover card overlaps the source"
            );
            let position = point((left + right) / 2., (top + bottom) / 2.);
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position,
                    ..Default::default()
                }),
                cx,
            );
            window.refresh();
            let _ = window.draw(cx);
            pointer_click(position, window, cx);
            assert_eq!(
                activations.get(),
                1,
                "a hover card over the source is not a click blocker"
            );
            window.dispatch_event(
                gpui::PlatformInput::MouseDown(MouseDownEvent {
                    button: MouseButton::Right,
                    position: source.center(),
                    click_count: 1,
                    ..Default::default()
                }),
                cx,
            );
            window.refresh();
            let _ = window.draw(cx);
            assert!(
                TOOLTIP_BOUNDS.with(|bounds| bounds.borrow().as_ref().unwrap().get().is_none())
            );
            key("escape", window, cx);
            pointer_click(source.center(), window, cx);
            assert_eq!(
                activations.get(),
                2,
                "menu dismissal must restore link activation"
            );
        })
        .unwrap();
    }
    #[gpui::test]
    fn pointer_context_menu_actions_reach_the_activation_handler(cx: &mut TestAppContext) {
        struct MenuLink {
            seen: Rc<RefCell<Vec<LinkActivation>>>,
            top: f32,
        }
        impl gpui::Render for MenuLink {
            fn render(&mut self, _: &mut Window, _: &mut gpui::Context<Self>) -> impl IntoElement {
                let seen = self.seen.clone();
                div().size_full().child(
                    div()
                        .absolute()
                        .top(px(self.top))
                        .left(px(20.))
                        .w(px(350.))
                        .debug_selector(|| "context-menu-source".into())
                        .child(
                            super::super::render::autolinked_text(
                                "menu-source".into(),
                                "https://github.com/justrach/harness/issues/447".into(),
                                Some(LinkUi {
                                    source_session: Some("owner".into()),
                                    handler: Rc::new(move |activation, _, _| {
                                        seen.borrow_mut().push(activation.clone());
                                        LinkOutcome::Rejected
                                    }),
                                }),
                                &Theme::dark(),
                            )
                            .expect("fixture URL is linked"),
                        ),
                )
            }
        }
        let _selection = super::super::selection::test_state_lock();
        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::dark());
            crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        });
        let seen = Rc::new(RefCell::new(Vec::new()));
        let (view, cx) = cx.add_window_view(|_, _| MenuLink {
            seen: seen.clone(),
            top: 20.,
        });
        cx.simulate_resize(gpui::size(px(400.), px(300.)));
        for top in [20., 240.] {
            view.update(cx, |view, cx| {
                view.top = top;
                cx.notify();
            });
            cx.run_until_parked();
            let bounds = cx.debug_bounds("context-menu-source").unwrap();
            let source = bounds.origin + point(px(6.), px(13.));
            for (label, action) in [
                ("Open in Harness", LinkAction::Internal),
                ("Open in external browser", LinkAction::External),
                ("Copy link address", LinkAction::Copy),
            ] {
                cx.simulate_event(gpui::MouseMoveEvent {
                    position: source,
                    ..Default::default()
                });
                cx.run_until_parked();
                cx.executor()
                    .advance_clock(std::time::Duration::from_millis(650));
                cx.run_until_parked();
                cx.simulate_event(MouseDownEvent {
                    button: MouseButton::Right,
                    position: source,
                    click_count: 1,
                    ..Default::default()
                });
                cx.simulate_event(MouseUpEvent {
                    button: MouseButton::Right,
                    position: source,
                    click_count: 1,
                    ..Default::default()
                });
                cx.run_until_parked();
                cx.executor()
                    .advance_clock(std::time::Duration::from_millis(200));
                cx.run_until_parked();
                let row = cx
                    .debug_bounds(label)
                    .expect("context-menu action is rendered");
                let before = seen.borrow().len();
                cx.simulate_click(row.center(), gpui::Modifiers::default());
                cx.run_until_parked();
                if action == LinkAction::Copy {
                    cx.update(|_, cx| {
                        assert_eq!(
                            cx.read_from_clipboard().unwrap().text().as_deref(),
                            Some("https://github.com/justrach/harness/issues/447")
                        )
                    });
                } else {
                    let seen = seen.borrow();
                    assert_eq!(
                        seen.len(),
                        before + 1,
                        "pointer click on {label} at y={top} must deliver an activation"
                    );
                    assert_eq!(seen.last().unwrap().action, action);
                    assert_eq!(
                        seen.last().unwrap().source_session.as_deref(),
                        Some("owner")
                    );
                }
            }
        }
    }
    #[gpui::test]
    fn all_actions_keep_the_destination(cx: &mut TestAppContext) {
        let window = cx.add_window(|_, _| gpui::Empty);
        window
            .update(cx, |_, window, cx| {
                let target = LinkTarget::new(
                    "A misleading label",
                    "https://example.com/full?query=yes#fragment",
                );
                activate_link(target.clone(), LinkAction::Copy, None, window, cx);
                assert_eq!(
                    cx.read_from_clipboard().unwrap().text().as_deref(),
                    Some(target.original.as_str())
                );
                for action in [LinkAction::Internal, LinkAction::External] {
                    let seen = Rc::new(RefCell::new(None));
                    let captured = seen.clone();
                    let ui = LinkUi {
                        source_session: Some("parent".into()),
                        handler: Rc::new(move |a, _, _| {
                            *captured.borrow_mut() =
                                Some((a.target.clone(), a.action, a.source_session.clone()));
                            LinkOutcome::Rejected
                        }),
                    };
                    activate_link(target.clone(), action, Some(&ui), window, cx);
                    assert_eq!(
                        *seen.borrow(),
                        Some((target.clone(), action, Some("parent".into())))
                    );
                }
            })
            .unwrap();
    }
}

#[cfg(all(test, any(target_os = "linux", windows)))]
mod rendered_tests {
    use super::*;
    use gpui::{Context, Render};
    #[cfg(windows)]
    use gpui_platform::application as test_application;
    #[cfg(target_os = "linux")]
    use gpui_platform::headless as test_application;
    thread_local! {
        pub(super) static TOOLTIP_BOUNDS: RefCell<Option<Rc<Cell<Option<Bounds<Pixels>>>>>> = RefCell::default();
    }
    fn draw_has_tooltip(window: &mut Window, cx: &mut App) -> bool {
        TOOLTIP_BOUNDS.with(|bounds| {
            if let Some(bounds) = bounds.borrow().as_ref() {
                bounds.set(None);
            }
        });
        window.refresh();
        let _ = window.draw(cx);
        TOOLTIP_BOUNDS.with(|bounds| bounds.borrow().as_ref().is_some_and(|b| b.get().is_some()))
    }
    fn key(window: &mut Window, key: &str, cx: &mut App) {
        window.dispatch_event(
            gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                keystroke: gpui::Keystroke::parse(key).unwrap(),
                is_held: false,
                prefer_character_input: false,
            }),
            cx,
        );
        window.dispatch_event(
            gpui::PlatformInput::KeyUp(gpui::KeyUpEvent {
                keystroke: gpui::Keystroke::parse(key).unwrap(),
            }),
            cx,
        );
        window.refresh();
        let _ = window.draw(cx);
    }
    struct Fixture {
        markdown: String,
        width: f32,
        activated: Rc<RefCell<Vec<LinkActivation>>>,
    }
    impl Render for Fixture {
        fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let mut opts = super::super::render::RenderOptions::settled("link-fixture".into());
            let activated = self.activated.clone();
            opts.link = Some(LinkUi {
                source_session: Some("session".into()),
                handler: Rc::new(move |a, _, _| {
                    activated.borrow_mut().push(a.clone());
                    LinkOutcome::Rejected
                }),
            });
            let tree = super::super::parser::parse_full(&self.markdown);
            div()
                .w(px(self.width))
                .child(super::super::render::selection_frame_reset())
                .child(super::super::render::render_tree(
                    &tree,
                    &opts,
                    &Theme::of(cx).clone(),
                    window,
                    &|_| None,
                ))
        }
    }
    #[test]
    #[cfg_attr(
        windows,
        ignore = "requires a native desktop; run with --ignored --test-threads=1"
    )]
    fn escape_dismisses_focused_destination() {
        test_application().run(|cx| {
            cx.set_global(Theme::dark());
            let window = cx
                .open_window(Default::default(), |_, cx| {
                    cx.new(|_| Fixture {
                        markdown: "[Docs](https://example.com/docs)".into(),
                        width: 320.,
                        activated: Rc::default(),
                    })
                })
                .unwrap();
            cx.update_window(window.into(), |_, window, cx| {
                draw_has_tooltip(window, cx);
                key(window, "tab", cx);
                window.focus_next(cx);
                assert!(
                    draw_has_tooltip(window, cx),
                    "focused link shows destination"
                );
                key(window, "escape", cx);
                assert!(
                    !draw_has_tooltip(window, cx),
                    "Escape must dismiss destination"
                );
            })
            .unwrap();
            cx.spawn(async move |cx| {
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    }
    struct OutsideClickFixture {
        link: gpui::Entity<Fixture>,
        clicks: Rc<Cell<usize>>,
    }
    impl Render for OutsideClickFixture {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            let clicks = self.clicks.clone();
            div().size_full().child(self.link.clone()).child(
                div()
                    .id("outside-button")
                    .absolute()
                    .left(px(400.))
                    .top(px(100.))
                    .size(px(50.))
                    .on_click(move |_, _, _| clicks.set(clicks.get() + 1)),
            )
        }
    }
    #[test]
    #[cfg_attr(
        windows,
        ignore = "requires a native desktop; run with --ignored --test-threads=1"
    )]
    fn focused_destination_does_not_block_other_controls() {
        test_application().run(|cx| {
            cx.set_global(Theme::dark());
            let clicks = Rc::new(Cell::new(0));
            let window = cx
                .open_window(Default::default(), |_, cx| {
                    let link = cx.new(|_| Fixture {
                        markdown: "[Docs](https://example.com/docs)".into(),
                        width: 320.,
                        activated: Rc::default(),
                    });
                    cx.new(|_| OutsideClickFixture {
                        link,
                        clicks: clicks.clone(),
                    })
                })
                .unwrap();
            cx.update_window(window.into(), |_, window, cx| {
                draw_has_tooltip(window, cx);
                let (_, layout, _) =
                    super::super::render::selection_test_snapshot("link-fixture:0");
                let link_position = range_rects(&layout, &(0..4), 0., 0.)[0].center();
                window.dispatch_event(
                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                        position: link_position,
                        ..Default::default()
                    }),
                    cx,
                );
                draw_has_tooltip(window, cx);
                window.dispatch_event(
                    gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                        button: MouseButton::Left,
                        position: link_position,
                        click_count: 1,
                        ..Default::default()
                    }),
                    cx,
                );
                draw_has_tooltip(window, cx);
                window.dispatch_event(
                    gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                        button: MouseButton::Left,
                        position: link_position,
                        click_count: 1,
                        ..Default::default()
                    }),
                    cx,
                );
                assert!(
                    !draw_has_tooltip(window, cx),
                    "pointer focus must not mount a keyboard disclosure"
                );
                key(window, "tab", cx);
                assert!(draw_has_tooltip(window, cx));
                let position = gpui::point(px(425.), px(125.));
                window.dispatch_event(
                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                        position,
                        ..Default::default()
                    }),
                    cx,
                );
                draw_has_tooltip(window, cx);
                window.dispatch_event(
                    gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                        button: MouseButton::Left,
                        position,
                        click_count: 1,
                        ..Default::default()
                    }),
                    cx,
                );
                window.dispatch_event(
                    gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                        button: MouseButton::Left,
                        position,
                        click_count: 1,
                        ..Default::default()
                    }),
                    cx,
                );
                assert_eq!(
                    clicks.get(),
                    1,
                    "destination must not swallow other controls' clicks"
                );
                assert!(
                    !draw_has_tooltip(window, cx),
                    "outside click dismisses destination"
                );
            })
            .unwrap();
            cx.spawn(async move |cx| {
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    }
    #[test]
    #[cfg_attr(
        windows,
        ignore = "requires a native desktop; run with --ignored --test-threads=1"
    )]
    fn context_menu_cancels_visible_and_pending_hover_tooltips() {
        let dir = tempfile::tempdir().unwrap();
        test_application().run(move |cx| {
            cx.set_global(Theme::dark());
            crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
            // Keep the headless event loop alive between scenario windows.
            cx.open_window(Default::default(), |_, cx| cx.new(|_| gpui::Empty))
                .unwrap();
            cx.spawn(async move |cx| {
                for visible in [true, false] {
                    for keyboard in [false, true] {
                        let activated = Rc::new(RefCell::new(Vec::new()));
                        let window = cx.update(|cx| {
                            cx.open_window(Default::default(), |_, cx| {
                                cx.new(|_| Fixture {
                                    markdown: "[Docs](https://example.com/docs)".into(),
                                    width: 320.,
                                    activated: activated.clone(),
                                })
                            })
                            .unwrap()
                        });
                        let position = cx
                            .update_window(window.into(), |_, window, cx| {
                                draw_has_tooltip(window, cx);
                                let (_, layout, _) =
                                    super::super::render::selection_test_snapshot("link-fixture:0");
                                let position = range_rects(&layout, &(0..4), 0., 0.)[0].center();
                                window.dispatch_event(
                                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                        position,
                                        ..Default::default()
                                    }),
                                    cx,
                                );
                                draw_has_tooltip(window, cx);
                                position
                            })
                            .unwrap();
                        if visible {
                            cx.background_executor()
                                .timer(std::time::Duration::from_millis(650))
                                .await;
                            cx.update_window(window.into(), |_, window, cx| {
                                assert!(
                                    draw_has_tooltip(window, cx),
                                    "hover should show the destination"
                                );
                            })
                            .unwrap();
                        }
                        cx.update_window(window.into(), |_, window, cx| {
                            if keyboard {
                                key(window, "tab", cx);
                                window.focus_next(cx);
                                draw_has_tooltip(window, cx);
                                key(window, "shift-f10", cx);
                            } else {
                                window.dispatch_event(
                                    gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                        button: MouseButton::Right,
                                        position,
                                        click_count: 1,
                                        ..Default::default()
                                    }),
                                    cx,
                                );
                                window.dispatch_event(
                                    gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                        button: MouseButton::Right,
                                        position,
                                        click_count: 1,
                                        ..Default::default()
                                    }),
                                    cx,
                                );
                            }
                            assert!(
                                !draw_has_tooltip(window, cx),
                                "menu must hide an already visible tooltip"
                            );
                        })
                        .unwrap();
                        // Leave the pointer over the link beyond the show delay.
                        cx.background_executor()
                            .timer(std::time::Duration::from_millis(650))
                            .await;
                        cx.update_window(window.into(), |_, window, cx| {
                            assert!(
                                !draw_has_tooltip(window, cx),
                                "pending hover must not appear over the menu"
                            );
                            let before = crate::settings::current(cx).open_web_links_in_harness;
                            key(window, "down", cx);
                            key(window, "down", cx);
                            key(window, "down", cx);
                            key(window, "enter", cx);
                            assert_ne!(
                                crate::settings::current(cx).open_web_links_in_harness,
                                before,
                                "the fourth menu row toggles the default destination"
                            );
                            assert!(activated.borrow().is_empty());
                            window.remove_window();
                        })
                        .unwrap();
                    }
                }
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    }
    #[test]
    #[cfg_attr(
        windows,
        ignore = "requires a native desktop; run with --ignored --test-threads=1"
    )]
    fn keyboard_visits_each_range_and_opens_the_link_menu() {
        test_application().run(|cx| {
            cx.set_global(Theme::dark());
            let activated = Rc::new(RefCell::new(Vec::new()));
            let log = activated.clone();
            let window = cx
                .open_window(Default::default(), |_, cx| {
                    cx.new(|_| Fixture {
                        activated,
                        width: 320.,
                        markdown:
                            "[first](https://example.com/one) and [second](https://example.org/two)"
                                .into(),
                    })
                })
                .unwrap();
            cx.update_window(window.into(), |_, window, cx| {
                window.refresh();
                let _ = window.draw(cx);
                key(window, "tab", cx);
                window.focus_next(cx);
                window.refresh();
                let _ = window.draw(cx);
                for key in ["enter", "tab", "enter", "shift-f10"] {
                    window.dispatch_event(
                        gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                            keystroke: gpui::Keystroke::parse(key).unwrap(),
                            is_held: false,
                            prefer_character_input: false,
                        }),
                        cx,
                    );
                    window.dispatch_event(
                        gpui::PlatformInput::KeyUp(gpui::KeyUpEvent {
                            keystroke: gpui::Keystroke::parse(key).unwrap(),
                        }),
                        cx,
                    );
                    window.refresh();
                    let _ = window.draw(cx);
                }
                assert_eq!(log.borrow().len(), 2);
                assert_eq!(log.borrow()[0].target.original, "https://example.com/one");
                assert_eq!(log.borrow()[1].target.original, "https://example.org/two");
                // Menu starts on Open in Harness; choose the external action.
                for key in ["down", "enter"] {
                    window.dispatch_event(
                        gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                            keystroke: gpui::Keystroke::parse(key).unwrap(),
                            is_held: false,
                            prefer_character_input: false,
                        }),
                        cx,
                    );
                    window.dispatch_event(
                        gpui::PlatformInput::KeyUp(gpui::KeyUpEvent {
                            keystroke: gpui::Keystroke::parse(key).unwrap(),
                        }),
                        cx,
                    );
                    window.refresh();
                    let _ = window.draw(cx);
                }
                assert_eq!(log.borrow().len(), 3);
                assert_eq!(log.borrow()[2].action, LinkAction::External);
                assert_eq!(log.borrow()[2].target.original, "https://example.org/two");
            })
            .unwrap();
            cx.spawn(async move |cx| {
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    }
    #[test]
    #[cfg_attr(
        windows,
        ignore = "requires a native desktop; run with --ignored --test-threads=1"
    )]
    fn rendered_truncation_resizes_and_selects_the_original_url() {
        test_application().run(|cx| {
            cx.set_global(Theme::dark());
            let url = format!("https://example.com/{}", "long-segment-🙂/".repeat(20));
            let markdown = format!("[{url}]({url})");
            let window = cx
                .open_window(Default::default(), |_, cx| {
                    cx.new(|_| Fixture {
                        activated: Rc::default(),
                        width: 180.,
                        markdown,
                    })
                })
                .unwrap();
            let view = window.entity(cx).unwrap();
            for width in [180., 420., 100.] {
                view.update(cx, |view, cx| {
                    view.width = width;
                    cx.notify();
                });
                cx.update_window(window.into(), |_, window, cx| {
                    window.refresh();
                    let _ = window.draw(cx);
                    let (original, layout, offsets) =
                        super::super::render::selection_test_snapshot("link-fixture:0");
                    assert_eq!(original.as_ref(), url);
                    let offsets = offsets.unwrap();
                    assert_eq!(offsets.omissions.len(), 1);
                    assert!(layout.bounds().size.width <= px(width));
                    assert!(layout.bounds().size.height <= px(23.));
                    let shown_end = offsets.displayed(url.len());
                    let start =
                        layout.position_for_index(0).unwrap() + gpui::point(px(0.1), px(8.));
                    let end = layout.position_for_index(shown_end).unwrap()
                        + gpui::point(px(0.1), px(8.));
                    window.dispatch_event(
                        gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                            button: MouseButton::Left,
                            position: start,
                            click_count: 1,
                            ..Default::default()
                        }),
                        cx,
                    );
                    window.refresh();
                    let _ = window.draw(cx);
                    window.dispatch_event(
                        gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                            position: end,
                            pressed_button: Some(MouseButton::Left),
                            ..Default::default()
                        }),
                        cx,
                    );
                    window.dispatch_event(
                        gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                            button: MouseButton::Left,
                            position: end,
                            click_count: 1,
                            ..Default::default()
                        }),
                        cx,
                    );
                    assert_eq!(
                        super::super::selection::selected_text().as_deref(),
                        Some(url.as_str())
                    );
                    assert!(view.read(cx).activated.borrow().is_empty());
                    super::super::selection::clear_if_owner("link-fixture:0");
                })
                .unwrap();
            }
            view.update(cx, |view, cx| {
                view.width = 220.;
                view.markdown =
                    format!("| [{url}]({url}) | Notes |\n| --- | --- |\n| short | cell |");
                cx.notify();
            });
            cx.update_window(window.into(), |_, window, cx| {
                window.refresh();
                let _ = window.draw(cx);
                let (original, layout, offsets) =
                    super::super::render::selection_test_snapshot("link-fixture:0");
                assert_eq!(original.as_ref(), url);
                assert_eq!(offsets.unwrap().omissions.len(), 1);
                assert!(layout.bounds().size.width < px(220.));
                assert!(layout.bounds().size.height <= px(23.));
            })
            .unwrap();
            cx.spawn(async move |cx| {
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    }
}
