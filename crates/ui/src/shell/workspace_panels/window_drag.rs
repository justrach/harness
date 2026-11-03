//! Tab pickup, desktop preview, cancellation and outside-window release.
use super::*;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::Arc,
    time::Instant,
};
use window_drop_target::{ExistingWindowDrop, WindowRejoinTarget};
use window_preview::WindowPreview;

const DETACH_DISTANCE: f32 = 24.0;
const REENTER_DISTANCE: f32 = 8.0;

#[derive(Default)]
struct DragOrigin(Option<WindowDragOrigin>);
impl gpui::Global for DragOrigin {}

#[derive(Clone)]
struct WindowDragOrigin {
    shell: gpui::WeakEntity<Shell>,
    window: gpui::AnyWindowHandle,
}

pub(super) fn drag_source_window(cx: &App) -> Option<gpui::WindowId> {
    cx.try_global::<DragOrigin>()?
        .0
        .as_ref()
        .map(|origin| origin.window.window_id())
}

pub(super) struct TabWindowDrag {
    pub(super) payload: PanelTabDrag,
    pointer: Point<Pixels>,
    grab: Point<Pixels>,
    tab_width: f32,
    started: Instant,
    armed: bool,
    image: Option<Arc<gpui::RenderImage>>,
    preview: Option<WindowPreview>,
    rejoin: Option<WindowRejoinTarget>,
    over_existing_window: bool,
    _snapshot: Option<Task<()>>,
}

fn beyond_window(pointer: Point<Pixels>, size: gpui::Size<Pixels>, distance: f32) -> bool {
    let (x, y) = (f32::from(pointer.x), f32::from(pointer.y));
    x < -distance
        || y < -distance
        || x > f32::from(size.width) + distance
        || y > f32::from(size.height) + distance
}

fn reentered_window(pointer: Point<Pixels>, size: gpui::Size<Pixels>) -> bool {
    let (x, y) = (f32::from(pointer.x), f32::from(pointer.y));
    x >= REENTER_DISTANCE
        && y >= REENTER_DISTANCE
        && x <= f32::from(size.width) - REENTER_DISTANCE
        && y <= f32::from(size.height) - REENTER_DISTANCE
}

pub(super) struct WindowTabGhost {
    pub(super) title: SharedString,
    pub(super) icon: &'static str,
    pub(super) source: gpui::WindowId,
    pub(super) outside: Rc<Cell<bool>>,
    pub(super) width: f32,
}
impl Render for WindowTabGhost {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let hidden = self.outside.get() || window.window_handle().window_id() != self.source;
        let theme = Theme::of(cx);
        div()
            .when(hidden, |element| element.invisible())
            .flex()
            .items_center()
            .gap(px(8.0))
            .px(px(12.0))
            .h(px(PANEL_TAB_HEIGHT))
            .w(px(self.width))
            .rounded(px(8.0))
            .bg(theme.element_active)
            .border_1()
            .border_color(theme.border)
            .shadow(vec![gpui::BoxShadow {
                color: gpui::black().opacity(0.16),
                offset: point(px(0.0), px(5.0)),
                blur_radius: px(14.0),
                spread_radius: px(0.0),
                inset: false,
            }])
            .text_size(crate::typography::ui_rems(12.0))
            .text_color(theme.text)
            .child(icon(self.icon).size(px(14.0)))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .child(self.title.clone()),
            )
    }
}

impl Shell {
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_active_drag_tab_bounds(
        &self,
        panel: u64,
        cx: &App,
    ) -> Option<gpui::Bounds<Pixels>> {
        self.workspace_panels
            .active_tab_bounds
            .borrow()
            .get(&(self.workspace_layout_key(cx), panel))
            .copied()
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_drag_preview_window(&self) -> Option<gpui::AnyWindowHandle> {
        self.workspace_panels
            .window_drag
            .as_ref()?
            .preview
            .as_ref()
            .map(WindowPreview::fixture_handle)
    }

    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_drag_visual_status(&self, cx: &App) -> serde_json::Value {
        let drag = self.workspace_panels.window_drag.as_ref();
        serde_json::json!({
            "active": cx.has_active_drag(),
            "activeWindow": cx.active_window().map(|handle| handle.window_id().as_u64()),
            "overlayOwnsKeyboard": self.overlay_owns_keyboard(cx),
            "armed": drag.is_some_and(|drag| drag.armed),
            "pointer": drag.map(|drag| [f32::from(drag.pointer.x), f32::from(drag.pointer.y)]),
            "grab": drag.map(|drag| [f32::from(drag.grab.x), f32::from(drag.grab.y)]),
            "tabWidth": drag.map(|drag| drag.tab_width),
            "rejoinTarget": drag.and_then(|drag| drag.rejoin.as_ref()).map(|target| serde_json::json!({
                "window": target.window.window_id().as_u64(), "panel": target.hover.panel,
                "before": target.hover.before, "header": target.hover.header
            })),
            "preview": drag.and_then(|drag| drag.preview.as_ref()).map(|preview| preview.fixture_status(cx))
        })
    }

    pub(super) fn window_tab_drag_events(&self, cx: &Context<Self>) -> AnyElement {
        let source = cx.weak_entity();
        gpui::canvas(
            |_, _, _| (),
            move |_, _, window, _| {
                let source = source.clone();
                window.on_mouse_event(move |event: &MouseUpEvent, phase, window, cx| {
                    if phase == gpui::DispatchPhase::Capture && event.button == MouseButton::Left {
                        let _ = source.update(cx, |source, cx| {
                            if !source.forward_foreign_window_drag(event.position, true, window, cx)
                            {
                                source.release_window_tab_drag(event.position, window, cx);
                            }
                        });
                    }
                });
            },
        )
        .absolute()
        .inset_0()
        .into_any_element()
    }

    pub(super) fn begin_window_tab_drag(
        &mut self,
        payload: PanelTabDrag,
        grab: Point<Pixels>,
        tab_width: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.clear_window_tab_drag(cx);
        self.park_workspace_draft(cx);
        let started = Instant::now();
        self.workspace_panels.split_drag = Some(payload.clone());
        cx.set_global(DragOrigin(Some(WindowDragOrigin {
            shell: cx.weak_entity(),
            window: window.window_handle(),
        })));
        let pointer = window.mouse_position();
        let browser = if let PanelTab::Surface {
            surface: RightSurface::Browser(id),
            ..
        } = &payload.tab
        {
            self.browsers.get(id).cloned()
        } else {
            None
        };
        let selected = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(payload.panel))
            .and_then(|panel| panel.selected())
            == Some(&payload.tab);
        let image = if browser.is_none() && selected {
            self.panel_drag_snapshot(payload.panel, window)
        } else {
            None
        };
        self.workspace_panels.window_drag = Some(TabWindowDrag {
            payload,
            pointer,
            grab,
            tab_width,
            started,
            armed: false,
            image,
            preview: None,
            rejoin: None,
            over_existing_window: false,
            _snapshot: None,
        });
        if let Some(browser) = browser {
            browser.read(cx).prepare_window_drag();
            let capture = browser.update(cx, |browser, cx| browser.snapshot(cx));
            let task = cx.spawn_in(window, async move |this, cx| {
                let image = capture.await;
                let _ = this.update_in(cx, |this, window, cx| {
                    if let Some(drag) = this
                        .workspace_panels
                        .window_drag
                        .as_mut()
                        .filter(|drag| drag.started == started)
                    {
                        drag.image = image;
                        if let Some(preview) = &drag.preview {
                            preview.update(window, drag.pointer, drag.image.clone(), cx);
                        }
                    }
                });
            });
            if let Some(drag) = self.workspace_panels.window_drag.as_mut() {
                drag._snapshot = Some(task);
            }
        }
    }

    fn panel_drag_snapshot(&self, panel: u64, window: &Window) -> Option<Arc<gpui::RenderImage>> {
        let workspace = self.workspace_layout_key_for_snapshot();
        let bounds = *self
            .workspace_panels
            .panel_bounds
            .borrow()
            .get(&(workspace, panel))?;
        let image = window.capture_scene().ok()?;
        let scale = window.scale_factor();
        let x = (f32::from(bounds.origin.x).max(0.0) * scale) as u32;
        let y = ((f32::from(bounds.origin.y) + PANEL_HEADER_HEIGHT).max(0.0) * scale) as u32;
        let width = (f32::from(bounds.size.width) * scale) as u32;
        let height =
            ((f32::from(bounds.size.height) - PANEL_HEADER_HEIGHT).max(0.0) * scale) as u32;
        let width = width.min(image.width().saturating_sub(x));
        let height = height.min(image.height().saturating_sub(y));
        if width == 0 || height == 0 {
            return None;
        }
        let mut image = image::DynamicImage::ImageRgba8(
            image::imageops::crop_imm(&image, x, y, width, height).to_image(),
        )
        .thumbnail(704, 440)
        .into_rgba8();
        for pixel in image.pixels_mut() {
            pixel.0.swap(0, 2);
        }
        Some(Arc::new(gpui::RenderImage::new([image::Frame::new(image)])))
    }

    // The current session is already normalized before a tab can be dragged.
    fn workspace_layout_key_for_snapshot(&self) -> String {
        self.chat_tabs
            .get(self.chat_tab)
            .map(|tab| tab.id.clone())
            .unwrap_or_default()
    }

    /// True means the desktop representation owns feedback for this frame.
    pub(super) fn track_window_tab_drag(
        &mut self,
        pointer: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(mut drag) = self.workspace_panels.window_drag.take() else {
            return false;
        };
        if drag.payload.workspace != self.workspace_layout_key(cx)
            || !self
                .panel_layout(cx)
                .and_then(|layout| layout.panel(drag.payload.panel))
                .is_some_and(|panel| panel.tabs.contains(&drag.payload.tab))
        {
            if let Some(preview) = drag.preview.take() {
                preview.close(cx);
            }
            self.clear_window_tab_drag(cx);
            self.workspace_panels.split_drag = None;
            self.workspace_panels.split_drag_bounds.clear();
            self.update_panel_split_preview(None, cx);
            cx.stop_active_drag(window);
            return false;
        }
        drag.pointer = pointer;
        if beyond_window(pointer, window.viewport_size(), DETACH_DISTANCE) {
            drag.armed = true;
        } else if reentered_window(pointer, window.viewport_size()) {
            drag.armed = false;
        }
        let outside_bounds = beyond_window(pointer, window.viewport_size(), 0.0);
        let existing = outside_bounds
            .then(|| self.existing_window_drop(pointer, &drag.payload.tab, window, cx))
            .flatten();
        drag.over_existing_window = existing.is_some();
        drag.rejoin = match existing {
            Some(ExistingWindowDrop::Accept(target)) => Some(target),
            _ => None,
        };
        let cursor = if drag.over_existing_window && drag.rejoin.is_none() {
            gpui::CursorStyle::OperationNotAllowed
        } else {
            gpui::CursorStyle::ClosedHand
        };
        if cx.active_drag_cursor_style() != Some(cursor) {
            cx.set_active_drag_cursor_style(cursor, window);
        }
        self.update_window_drop_hover(drag.rejoin.as_ref(), cx);
        let carrying_outside = drag.armed || drag.rejoin.is_some();
        if outside_bounds || carrying_outside {
            self.update_panel_split_preview(None, cx);
        }
        if carrying_outside {
            let icon = self.panel_tab_label(&drag.payload.tab, cx).1;
            if drag.preview.is_none() {
                drag.preview = WindowPreview::open(
                    window,
                    pointer,
                    drag.grab,
                    drag.tab_width,
                    drag.payload.title.clone(),
                    icon,
                    drag.image.clone(),
                    cx,
                );
            }
            if let Some(preview) = &drag.preview {
                // A compact tab over a highlighted panel means it will join
                // that window; the expanded card continues to mean tear-off.
                preview.set_expanded(drag.rejoin.is_none(), cx);
                preview.update(window, pointer, drag.image.clone(), cx);
            }
        } else if let Some(preview) = &drag.preview {
            preview.set_expanded(false, cx);
            preview.update(window, pointer, None, cx);
        }
        self.workspace_panels.drag_outside.set(carrying_outside);
        self.workspace_panels
            .drag_preview_visible
            .set(drag.preview.is_some());
        let outside = outside_bounds || carrying_outside;
        if outside {
            self.workspace_panels.window_drop_hover = None;
        }
        self.workspace_panels.window_drag = Some(drag);
        cx.notify();
        outside
    }

    pub(crate) fn clear_window_tab_drag(&mut self, cx: &mut Context<Self>) {
        let owns_origin = cx
            .try_global::<DragOrigin>()
            .and_then(|origin| origin.0.as_ref())
            .is_some_and(|origin| origin.shell.entity_id() == cx.entity_id());
        if owns_origin {
            self.update_window_drop_hover(None, cx);
            self.workspace_panels.window_drop_hover = None;
        }
        if let Some(mut drag) = self.workspace_panels.window_drag.take()
            && let Some(preview) = drag.preview.take()
        {
            preview.close(cx);
        }
        self.workspace_panels.drag_outside.set(false);
        self.workspace_panels.drag_preview_visible.set(false);
        if owns_origin {
            cx.set_global(DragOrigin(None));
        }
    }

    pub(crate) fn cancel_window_tab_drag(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(tab) = self
            .workspace_panels
            .window_drag
            .as_ref()
            .map(|drag| drag.payload.tab.clone())
        else {
            return false;
        };
        self.clear_window_tab_drag(cx);
        self.workspace_panels.split_drag = None;
        self.workspace_panels.split_drag_bounds.clear();
        self.workspace_panels.blocked_split = false;
        self.update_panel_split_preview(None, cx);
        cx.stop_active_drag(window);
        self.restore_window_drag_browser_focus(&tab, window, cx);
        cx.notify();
        true
    }

    fn restore_window_drag_browser_focus(
        &self,
        tab: &PanelTab,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let PanelTab::Surface {
            surface: RightSurface::Browser(id),
            ..
        } = tab
        else {
            return;
        };
        let Some(browser) = self.browsers.get(id) else {
            return;
        };
        if !matches!(self.route, Route::Chat)
            || !window.is_window_active()
            || self.overlay_owns_keyboard(cx)
        {
            browser.read(cx).discard_page_focus_after_drag();
            return;
        }
        let selected = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(layout.focused))
            .and_then(|panel| panel.selected())
            == Some(tab);
        if selected {
            browser.update(cx, |browser, cx| {
                browser.restore_page_focus_after_drag(window, cx)
            });
        } else {
            browser.read(cx).discard_page_focus_after_drag();
        }
    }

    pub(super) fn reject_foreign_window_drag(&self, cx: &Context<Self>) -> bool {
        cx.try_global::<DragOrigin>()
            .and_then(|origin| origin.0.as_ref())
            .is_some_and(|origin| origin.shell.entity_id() != cx.entity_id())
    }

    /// Some platforms dispatch to the window under the pointer rather than
    /// the original mouse-down view. Run the same source transaction after
    /// the receiving window's event lease has ended.
    pub(super) fn forward_foreign_window_drag(
        &self,
        pointer: Point<Pixels>,
        release: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(origin) = cx
            .try_global::<DragOrigin>()
            .and_then(|origin| origin.0.as_ref())
            .filter(|origin| origin.shell.entity_id() != cx.entity_id())
            .cloned()
        else {
            return false;
        };
        let point = origin
            .window
            .update(cx, |_, source, _| {
                window_drop_target::convert_window_point(pointer, window, source)
            })
            .ok()
            .flatten();
        if let Some(point) = point {
            gpui::App::defer(cx, move |cx| {
                let _ = origin.window.update(cx, |_, window, cx| {
                    let _ = origin.shell.update(cx, |source, cx| {
                        if release {
                            source.release_window_tab_drag(point, window, cx);
                        } else {
                            source.track_window_tab_drag(point, window, cx);
                        }
                    });
                });
            });
        }
        cx.stop_propagation();
        true
    }

    pub(super) fn release_window_tab_drag(
        &mut self,
        pointer: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // on_mouse_up_out is hit-test based: an occluding panel can make the
        // root "outside" even while the pointer is geometrically inside it.
        // Internal drops must reach their normal bubble-phase drop target.
        if !beyond_window(pointer, window.viewport_size(), 0.0) {
            if self
                .workspace_panels
                .window_drag
                .as_ref()
                .is_some_and(|drag| drag.armed)
                && !reentered_window(pointer, window.viewport_size())
            {
                self.cancel_window_tab_drag(window, cx);
                cx.stop_propagation();
            }
            return;
        }
        if self.workspace_panels.window_drag.is_none() {
            return;
        }
        self.track_window_tab_drag(pointer, window, cx);
        let Some(mut drag) = self.workspace_panels.window_drag.take() else {
            return;
        };
        // Pickup already crossed GPUI's drag threshold. The preview expands
        // after a further deliberate exit, but every release outside the actual
        // window is a detach: requiring that extra distance here silently loses
        // drops near an edge (especially when it is close to the display edge).
        let valid =
            beyond_window(pointer, window.viewport_size(), 0.0) && !drag.over_existing_window;
        let preview = drag.preview.take();
        let returning_tab = drag.payload.tab.clone();
        self.clear_window_tab_drag(cx);
        self.workspace_panels.split_drag = None;
        self.workspace_panels.split_drag_bounds.clear();
        self.update_panel_split_preview(None, cx);
        cx.stop_active_drag(window);
        cx.stop_propagation();
        let rejoining = drag.rejoin.is_some();
        let moved = if let Some(target) = drag.rejoin {
            Some(
                self.move_workspace_tab_to_window(
                    drag.payload.panel,
                    drag.payload.tab,
                    target.window,
                    target.hover.panel,
                    target.hover.before,
                    window,
                    cx,
                )
                .map(|_| target.window),
            )
        } else if valid {
            Some(self.move_workspace_tab_to_new_window(
                drag.payload.panel,
                drag.payload.tab,
                Some((pointer, drag.grab)),
                window,
                cx,
            ))
        } else {
            None
        };
        if let Some(moved) = moved {
            match moved {
                Ok(destination) => {
                    if let Some(preview) = preview {
                        if rejoining {
                            preview.close(cx);
                            cx.notify();
                            return;
                        }
                        // A destination can close before its first frame. Keep
                        // one shared owner until either rendering or release
                        // takes the preview, and close on scheduling failure.
                        let pending = Rc::new(RefCell::new(Some(preview)));
                        let on_frame = pending.clone();
                        let on_release = pending.clone();
                        let scheduled = destination.update(cx, |_, window, cx| {
                            cx.on_release(move |_, cx| {
                                let preview = on_release.borrow_mut().take();
                                if let Some(preview) = preview {
                                    preview.close(cx);
                                }
                            })
                            .detach();
                            window.on_next_frame(move |window, cx| {
                                let preview = on_frame.borrow_mut().take();
                                if let Some(preview) = preview {
                                    preview.finish_at(window, cx);
                                }
                            });
                        });
                        if scheduled.is_err() {
                            let preview = pending.borrow_mut().take();
                            if let Some(preview) = preview {
                                preview.close(cx);
                            }
                        }
                    }
                }
                Err(error) => {
                    if let Some(preview) = preview {
                        preview.close(cx);
                    }
                    self.sidebar_notice = Some(error.into());
                    self.restore_window_drag_browser_focus(&returning_tab, window, cx);
                }
            }
        } else {
            if let Some(preview) = preview {
                preview.close(cx);
            }
            self.restore_window_drag_browser_focus(&returning_tab, window, cx);
        }
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn window_tab_drag_requires_deliberate_exit_on_every_edge() {
        let size = gpui::size(px(1000.0), px(700.0));
        for pointer in [
            point(px(-25.0), px(200.0)),
            point(px(1025.0), px(200.0)),
            point(px(200.0), px(-25.0)),
            point(px(200.0), px(725.0)),
        ] {
            assert!(beyond_window(pointer, size, DETACH_DISTANCE));
        }
        for pointer in [
            point(px(-23.0), px(200.0)),
            point(px(1023.0), px(200.0)),
            point(px(200.0), px(-23.0)),
            point(px(200.0), px(723.0)),
        ] {
            assert!(!beyond_window(pointer, size, DETACH_DISTANCE));
        }
    }
    #[test]
    fn window_tab_drag_reentry_has_a_separate_boundary() {
        let size = gpui::size(px(1000.0), px(700.0));
        assert!(!reentered_window(point(px(1.0), px(200.0)), size));
        assert!(reentered_window(point(px(9.0), px(200.0)), size));
        assert!(!reentered_window(point(px(200.0), px(699.0)), size));
        assert!(reentered_window(point(px(200.0), px(691.0)), size));
    }
}
