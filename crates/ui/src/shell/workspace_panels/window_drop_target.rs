//! Existing-window destinations use panel geometry, including empty panels.
use super::*;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct WindowDropHover {
    pub(super) workspace: String,
    pub(super) panel: u64,
    pub(super) before: Option<usize>,
    pub(super) header: bool,
}

#[derive(Clone)]
pub(super) struct WindowRejoinTarget {
    pub(super) window: gpui::WindowHandle<Shell>,
    pub(super) hover: WindowDropHover,
}

pub(super) enum ExistingWindowDrop {
    Accept(WindowRejoinTarget),
    Reject,
}

impl Shell {
    pub(super) fn existing_window_drop(
        &self,
        pointer: Point<Pixels>,
        tab: &PanelTab,
        source: &Window,
        cx: &mut Context<Self>,
    ) -> Option<ExistingWindowDrop> {
        let runtime = AppState::runtime_owner(&self.state, cx).entity_id();
        let mut windows: Vec<_> = cx
            .windows()
            .into_iter()
            .filter(|handle| handle.window_id() != source.window_handle().window_id())
            .filter_map(|handle| handle.downcast::<Shell>())
            .collect();
        // The native hit test chooses the actual front window. The test and
        // non-AppKit fallback uses the most recently created matching window.
        windows.reverse();
        for handle in windows {
            let hit = handle.update(cx, |target, window, cx| {
                let point = pointer_over_window(pointer, source, window)?;
                if AppState::runtime_owner(&target.state, cx).entity_id() != runtime
                    || (matches!(tab, PanelTab::Chat(_))
                        && target.workspace_panels.layouts.values().any(|layout| {
                            layout.panels.iter().any(|panel| panel.tabs.contains(tab))
                        }))
                {
                    return Some(None);
                }
                Some(target.window_drop_at(point, window, cx))
            });
            match hit {
                Ok(Some(Some(hover))) => {
                    return Some(ExistingWindowDrop::Accept(WindowRejoinTarget {
                        window: handle,
                        hover,
                    }));
                }
                Ok(Some(None)) => return Some(ExistingWindowDrop::Reject),
                _ => {}
            }
        }
        None
    }

    pub(super) fn window_drop_at(
        &self,
        point: Point<Pixels>,
        window: &Window,
        cx: &App,
    ) -> Option<WindowDropHover> {
        if !matches!(self.route, Route::Chat)
            || self.session_overview
            || !self.boot_restored
            || self.chat_tabs.is_empty()
            || self.pending_exit.is_some()
            || self.window_transfer_preparing
            || self.overlay_owns_keyboard(cx)
            || !gpui::Bounds::new(point_zero(), window.viewport_size()).contains(&point)
        {
            return None;
        }
        self.panel_tab_drop_at(point, window, cx)
    }

    pub(super) fn panel_tab_drop_at(
        &self,
        point: Point<Pixels>,
        window: &Window,
        cx: &App,
    ) -> Option<WindowDropHover> {
        if !gpui::Bounds::new(point_zero(), window.viewport_size()).contains(&point) {
            return None;
        }
        let workspace = self.workspace_layout_key(cx);
        let layout = self.panel_layout(cx)?;
        let bounds = self.workspace_panels.panel_bounds.borrow();
        let tabs = self.workspace_panels.window_tab_bounds.borrow();
        for panel in &layout.panels {
            if layout.expanded.is_some_and(|expanded| expanded != panel.id) {
                continue;
            }
            let key = (workspace.clone(), panel.id);
            let Some(rect) = bounds.get(&key).filter(|rect| rect.contains(&point)) else {
                continue;
            };
            let header_height = self
                .workspace_panels
                .rendered_frames
                .get(&key)
                .map_or(PANEL_HEADER_HEIGHT, |frame| frame.header_height);
            let header = point.y < rect.top() + px(header_height);
            let strip = self
                .workspace_panels
                .header_tab_bounds
                .borrow()
                .get(&key)
                .copied();
            if header
                && strip.is_some_and(|strip| point.x < strip.left() || point.x > strip.right())
            {
                return None;
            }
            let before = header.then(|| {
                let mut visible: Vec<_> = tabs
                    .iter()
                    .filter(|((key, id, _), tab)| {
                        key == &workspace
                            && *id == panel.id
                            && tab.right() > strip.unwrap_or(*rect).left()
                            && tab.left() < strip.unwrap_or(*rect).right()
                    })
                    .map(|((_, _, index), tab)| (*index, *tab))
                    .collect();
                visible.sort_by_key(|(index, _)| *index);
                visible
                    .iter()
                    .find(|(_, tab)| point.x <= tab.center().x)
                    .map(|(index, _)| *index)
                    .or_else(|| visible.last().map(|(index, _)| index + 1))
                    .unwrap_or(panel.tabs.len())
                    .min(panel.tabs.len())
            });
            return Some(WindowDropHover {
                workspace,
                panel: panel.id,
                before,
                header,
            });
        }
        None
    }

    pub(super) fn update_internal_tab_drop_hover(
        &mut self,
        drag: &PanelTabDrag,
        pointer: Point<Pixels>,
        window: &Window,
        cx: &mut Context<Self>,
    ) {
        let splitting = self
            .workspace_panels
            .split_previews
            .iter()
            .any(|((key, _, _), preview)| key == &drag.workspace && preview.active);
        let hover = (!splitting && !self.workspace_panels.blocked_split)
            .then(|| self.panel_tab_drop_at(pointer, window, cx))
            .flatten()
            .filter(|hover| hover.header)
            .filter(|hover| {
                if hover.panel != drag.panel {
                    return true;
                }
                let source = self
                    .panel_layout(cx)
                    .and_then(|layout| layout.location(&drag.tab));
                !source.is_some_and(|(_, index)| {
                    hover.before == Some(index) || hover.before == Some(index + 1)
                })
            });
        if self.workspace_panels.window_drop_hover != hover {
            self.workspace_panels.window_drop_hover = hover;
            cx.notify();
        }
    }

    pub(super) fn update_window_drop_hover(
        &self,
        target: Option<&WindowRejoinTarget>,
        cx: &mut Context<Self>,
    ) {
        let source = window_drag::drag_source_window(cx);
        for handle in cx
            .windows()
            .into_iter()
            .filter(|handle| Some(handle.window_id()) != source)
            .filter_map(|h| h.downcast::<Shell>())
        {
            let wanted = target
                .filter(|target| target.window == handle)
                .map(|target| target.hover.clone());
            let _ = handle.update(cx, |shell, _, cx| {
                if shell.workspace_panels.window_drop_hover != wanted {
                    shell.workspace_panels.window_drop_hover = wanted;
                    cx.notify();
                }
            });
        }
    }

    pub(super) fn window_drop_cue(
        &self,
        workspace: &str,
        panel: u64,
        width: f32,
        header_height: f32,
        theme: &Theme,
    ) -> Option<AnyElement> {
        let hover = self
            .workspace_panels
            .window_drop_hover
            .as_ref()
            .filter(|hover| hover.workspace == workspace && hover.panel == panel)?;
        if hover.header {
            let tabs = self.workspace_panels.window_tab_bounds.borrow();
            let before = hover.before.unwrap_or(0);
            let panel_rect = self
                .workspace_panels
                .panel_bounds
                .borrow()
                .get(&(workspace.to_owned(), panel))
                .copied()?;
            let x = tabs
                .get(&(workspace.to_owned(), panel, before))
                .map(|rect| rect.left() - panel_rect.left())
                .or_else(|| {
                    before.checked_sub(1).and_then(|index| {
                        tabs.get(&(workspace.to_owned(), panel, index))
                            .map(|rect| rect.right() - panel_rect.left())
                    })
                })
                .unwrap_or_else(|| {
                    self.workspace_panels
                        .header_tab_bounds
                        .borrow()
                        .get(&(workspace.to_owned(), panel))
                        .map_or(px(8.0), |strip| strip.left() - panel_rect.left() + px(8.0))
                });
            let strip = self
                .workspace_panels
                .header_tab_bounds
                .borrow()
                .get(&(workspace.to_owned(), panel))
                .copied()
                .unwrap_or(panel_rect);
            let left = (strip.left() - panel_rect.left()).max(px(0.0));
            let right = (strip.right() - panel_rect.left() - px(2.0))
                .min(px(width - 2.0))
                .max(left);
            Some(
                div()
                    .debug_selector(move || format!("window-rejoin-tab-cue-{panel}"))
                    .absolute()
                    .left(x.clamp(left, right))
                    .top(px((header_height - PANEL_TAB_HEIGHT - STACKED_CLEARANCE)
                        .max(0.0)
                        + 4.0))
                    .w(px(2.0))
                    .h(px(PANEL_TAB_HEIGHT - 8.0))
                    .rounded(px(1.0))
                    .bg(theme.accent)
                    .into_any_element(),
            )
        } else {
            Some(
                div()
                    .debug_selector(move || format!("window-rejoin-body-cue-{panel}"))
                    .absolute()
                    .left(px(1.0))
                    .right(px(1.0))
                    .top(px(header_height + 1.0))
                    .bottom(px(1.0))
                    .rounded(px(9.0))
                    .border_1()
                    .border_color(theme.accent)
                    .bg(theme.accent.opacity(0.08))
                    .into_any_element(),
            )
        }
    }
}

fn point_zero() -> Point<Pixels> {
    point(px(0.0), px(0.0))
}

#[cfg(all(target_os = "macos", not(test)))]
pub(super) fn convert_window_point(
    pointer: Point<Pixels>,
    source: &Window,
    target: &Window,
) -> Option<Point<Pixels>> {
    use objc2_app_kit::NSView;
    use objc2_foundation::NSPoint;
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let view = |window: &Window| -> Option<&NSView> {
        let RawWindowHandle::AppKit(handle) = HasWindowHandle::window_handle(window).ok()?.as_raw()
        else {
            return None;
        };
        Some(unsafe { &*handle.ns_view.as_ptr().cast::<NSView>() })
    };
    let (source, target) = (view(source)?, view(target)?);
    let y = f64::from(f32::from(pointer.y));
    let source_point = NSPoint::new(
        f64::from(f32::from(pointer.x)),
        if source.isFlipped() {
            y
        } else {
            source.bounds().size.height - y
        },
    );
    let global = source
        .window()?
        .convertPointToScreen(source.convertPoint_toView(source_point, None));
    let point = target.convertPoint_fromView(target.window()?.convertPointFromScreen(global), None);
    Some(gpui::point(
        px(point.x as f32),
        px(if target.isFlipped() {
            point.y
        } else {
            target.bounds().size.height - point.y
        } as f32),
    ))
}

#[cfg(any(not(target_os = "macos"), test))]
pub(super) fn convert_window_point(
    pointer: Point<Pixels>,
    source: &Window,
    target: &Window,
) -> Option<Point<Pixels>> {
    Some(source.bounds().origin + pointer - target.bounds().origin)
}

fn pointer_over_window(
    pointer: Point<Pixels>,
    source: &Window,
    target: &Window,
) -> Option<Point<Pixels>> {
    let local = convert_window_point(pointer, source, target)?;
    if !gpui::Bounds::new(point_zero(), target.viewport_size()).contains(&local) {
        return None;
    }
    #[cfg(all(target_os = "macos", not(test)))]
    {
        use objc2::MainThreadOnly;
        use objc2_app_kit::{NSApplication, NSView, NSWindow};
        use objc2_foundation::NSPoint;
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        let RawWindowHandle::AppKit(handle) = HasWindowHandle::window_handle(target).ok()?.as_raw()
        else {
            return None;
        };
        let view = unsafe { &*handle.ns_view.as_ptr().cast::<NSView>() };
        let window = view.window()?;
        if !window.isVisible() || window.isMiniaturized() {
            return None;
        }
        let y = f64::from(f32::from(local.y));
        let point = NSPoint::new(
            f64::from(f32::from(local.x)),
            if view.isFlipped() {
                y
            } else {
                view.bounds().size.height - y
            },
        );
        let global = window.convertPointToScreen(view.convertPoint_toView(point, None));
        let app = NSApplication::sharedApplication(view.mtm());
        let mut below = 0;
        for _ in 0..16 {
            let hit = NSWindow::windowNumberAtPoint_belowWindowWithWindowNumber(
                global,
                below,
                view.mtm(),
            );
            if hit == window.windowNumber() {
                return Some(local);
            }
            if hit == 0 {
                return None;
            }
            if app
                .windowWithWindowNumber(hit)
                .is_some_and(|window| window.ignoresMouseEvents())
            {
                below = hit;
            } else {
                return None;
            }
        }
        return None;
    }
    #[cfg(any(not(target_os = "macos"), test))]
    Some(local)
}
