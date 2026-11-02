use crate::{
    AnyElement, AnyEntity, AnyWeakEntity, App, Bounds, ContentMask, Context, DefiniteLength,
    Element, ElementId, Entity, EntityId, GlobalElementId, InspectorElementId, IntoElement,
    LayoutId, Length, PaintIndex, Pixels, PrepaintStateIndex, Render, RenderOnce, Size, Style,
    StyleRefinement, TextStyle, WeakEntity,
};
use crate::{Empty, Window};
use anyhow::Result;
use collections::FxHashSet;
use refineable::Refineable;
use std::mem;
use std::{any::TypeId, fmt, ops::Range};

/// A dynamically-typed view handle that can be downcast to a specific `Entity<V>`.
///
/// This is the type-erased counterpart to [`ViewElement`]: it holds an entity plus
/// a function pointer to its render, and is itself a [`View`], so embedding it as an
/// element goes through the same [`ViewElement`] machinery as any other view.
#[derive(Clone, Debug)]
pub struct AnyView {
    entity: AnyEntity,
    render: fn(&AnyView, &mut Window, &mut App) -> AnyElement,
}

impl<V: Render> From<Entity<V>> for AnyView {
    fn from(value: Entity<V>) -> Self {
        AnyView {
            entity: value.into_any(),
            render: any_view::render::<V>,
        }
    }
}

impl AnyView {
    /// Embed this view as a cached [`ViewElement`] laid out at `style`.
    ///
    /// The rendered subtree is recycled from the previous frame unless
    /// [Context::notify] was called on the backing entity since it was rendered
    /// (or [Window::refresh] is called, which ignores caching).
    pub fn cached(self, style: StyleRefinement) -> ViewElement<AnyView> {
        ViewElement::new(self).cached(style)
    }

    /// Convert this to a weak handle.
    pub fn downgrade(&self) -> AnyWeakView {
        AnyWeakView {
            entity: self.entity.downgrade(),
            render: self.render,
        }
    }

    /// Convert this to a [Entity] of a specific type.
    /// If this handle does not contain a view of the specified type, returns itself in an `Err` variant.
    pub fn downcast<T: 'static>(self) -> Result<Entity<T>, Self> {
        match self.entity.downcast() {
            Ok(entity) => Ok(entity),
            Err(entity) => Err(Self {
                entity,
                render: self.render,
            }),
        }
    }

    /// Gets the [TypeId] of the underlying view.
    pub fn entity_type(&self) -> TypeId {
        self.entity.entity_type
    }

    /// The [`EntityId`] of this view.
    pub fn entity_id(&self) -> EntityId {
        self.entity.entity_id()
    }
}

impl PartialEq for AnyView {
    fn eq(&self, other: &Self) -> bool {
        self.entity == other.entity
    }
}

impl Eq for AnyView {}

/// `AnyView` is the type-erased [`View`]: its `render` is a function pointer rather
/// than a concrete type, but it participates in the reactive graph exactly like any
/// other view via [`ViewElement`].
impl View for AnyView {
    fn entity_id(&self) -> Option<EntityId> {
        Some(self.entity.entity_id())
    }

    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        (self.render)(&self, window, cx)
    }
}

impl<V: 'static + Render> IntoElement for Entity<V> {
    type Element = ViewElement<Entity<V>>;

    fn into_element(self) -> Self::Element {
        ViewElement::new(self)
    }
}

impl IntoElement for AnyView {
    type Element = ViewElement<AnyView>;

    fn into_element(self) -> Self::Element {
        ViewElement::new(self)
    }
}

/// A weak, dynamically-typed view handle.
pub struct AnyWeakView {
    entity: AnyWeakEntity,
    render: fn(&AnyView, &mut Window, &mut App) -> AnyElement,
}

impl AnyWeakView {
    /// Upgrade to a strong `AnyView` handle, if the view is still alive.
    pub fn upgrade(&self) -> Option<AnyView> {
        let entity = self.entity.upgrade()?;
        Some(AnyView {
            entity,
            render: self.render,
        })
    }
}

impl<V: 'static + Render> From<WeakEntity<V>> for AnyWeakView {
    fn from(view: WeakEntity<V>) -> Self {
        AnyWeakView {
            entity: view.into(),
            render: any_view::render::<V>,
        }
    }
}

impl PartialEq for AnyWeakView {
    fn eq(&self, other: &Self) -> bool {
        self.entity == other.entity
    }
}

impl std::fmt::Debug for AnyWeakView {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AnyWeakView")
            .field("entity_id", &self.entity.entity_id)
            .finish_non_exhaustive()
    }
}

mod any_view {
    use crate::{AnyElement, AnyView, App, IntoElement, Render, Window};

    pub(crate) fn render<V: 'static + Render>(
        view: &AnyView,
        window: &mut Window,
        cx: &mut App,
    ) -> AnyElement {
        let view = view.clone().downcast::<V>().unwrap();
        // Record the view's Render type name so the accessibility debug dump can
        // attribute nodes to the view that produced them.
        #[cfg(debug_assertions)]
        window
            .a11y
            .view_type_names
            .insert(view.entity_id(), std::any::type_name::<V>());
        view.update(cx, |view, cx| view.render(window, cx).into_any_element())
    }
}

/// A renderable that participates in GPUI's reactive graph — the unifying model
/// behind [`Render`] and [`RenderOnce`].
///
/// When `entity_id()` returns `Some`, that id becomes the view's identity: it gets
/// a unique element-id space (so internal `use_state` / `.id(..)` never collide
/// across siblings) and `cx.notify()` on that entity re-renders only this view's
/// subtree. `None` behaves like a stateless component.
///
/// You rarely implement `View` directly. `Entity<T: Render>` and any `T: RenderOnce`
/// get a blanket impl below; implement it by hand only when a component needs both
/// parent-supplied props *and* a backing entity for identity.
pub trait View: 'static + Sized {
    /// This view's identity, if it has one. A view typically holds the backing
    /// entity as a field and returns its [`EntityId`] here.
    ///
    /// The id becomes this view's [`ElementId`], so two views keyed on the same
    /// entity must not be rendered at the same position in the element tree
    /// (e.g. as siblings under the same parent): their internal element state
    /// (`use_state`, scroll offsets, etc.) would silently collide. Nesting is
    /// fine — the id is scoped by the parent path.
    fn entity_id(&self) -> Option<EntityId>;

    /// Render this view into an element tree, consuming `self`.
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement;
}

/// A stateless component (`RenderOnce`) is a `View` with no identity.
impl<T: RenderOnce> View for T {
    fn entity_id(&self) -> Option<EntityId> {
        None
    }

    #[inline]
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        RenderOnce::render(self, window, cx)
    }
}

/// An entity that renders itself (`Render`) is a `View` keyed on its own id.
impl<T: Render> View for Entity<T> {
    fn entity_id(&self) -> Option<EntityId> {
        Some(Entity::entity_id(self))
    }

    #[inline]
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        self.update(cx, |this, cx| {
            Render::render(this, window, cx).into_any_element()
        })
    }
}

impl<T: Render> Entity<T> {
    /// Embed this entity as a cached [`ViewElement`] laid out at `style`.
    ///
    /// The rendered subtree is reused until the entity is notified (or the
    /// cached bounds / text style change). Caching requires a definite size:
    /// a cached view is laid out from `style` and is *not* measured from its
    /// contents. Use [`ViewElement::new`] (or `.child(entity)`) for the
    /// uncached case.
    #[track_caller]
    pub fn cached(self, style: StyleRefinement) -> ViewElement<Entity<T>> {
        ViewElement::new(self).cached(style)
    }

    /// Like [`Entity::cached`], for a view whose height follows its content
    /// (a text box that grows as it is typed into). A frame that renders the
    /// view lays it out from its content inside `style`, like an uncached
    /// child; a frame that reuses it keeps the size it measured then.
    ///
    /// `style` must give the view a definite width: the reused height is only
    /// valid for the width it was measured at. Without one, or when `style`
    /// changes, the view renders again.
    #[track_caller]
    pub fn cached_measured(self, style: StyleRefinement) -> ViewElement<Entity<T>> {
        let mut element = ViewElement::new(self).cached(style);
        element.measured = true;
        element
    }
}

/// The element type for [`View`] implementations. Wraps a `View` and hooks it
/// into layout, prepaint, and paint. Constructed via [`ViewElement::new`].
#[doc(hidden)]
pub struct ViewElement<V: View> {
    view: Option<V>,
    entity_id: Option<EntityId>,
    cached_style: Option<StyleRefinement>,
    /// Cached, but sized from its content (see [`Entity::cached_measured`]).
    measured: bool,
    #[cfg(debug_assertions)]
    source: &'static core::panic::Location<'static>,
}

impl<V: View> ViewElement<V> {
    /// Wrap a [`View`] as an element.
    #[track_caller]
    pub fn new(view: V) -> Self {
        let entity_id = view.entity_id();
        ViewElement {
            entity_id,
            cached_style: None,
            measured: false,
            view: Some(view),
            #[cfg(debug_assertions)]
            source: core::panic::Location::caller(),
        }
    }

    /// Enable caching of this view's rendered subtree, laid out at `style`.
    /// The composer supplies the layout style because caching skips rendering
    /// the contents to measure them.
    ///
    /// Crate-private on purpose: caching is only sound for entity-backed views,
    /// where [`Context::notify`] is the contract that busts the cache. A stateless
    /// view has no such contract, so a frozen subtree could never be invalidated.
    /// Reach this through [`Entity::cached`] or [`AnyView::cached`], which are
    /// entity-backed by construction.
    pub(crate) fn cached(mut self, style: StyleRefinement) -> Self {
        self.cached_style = Some(style);
        self
    }
}

impl<V: View> IntoElement for ViewElement<V> {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

struct ViewElementState {
    prepaint_range: Range<PrepaintStateIndex>,
    paint_range: Range<PaintIndex>,
    cache_key: ViewElementCacheKey,
    accessed_entities: FxHashSet<EntityId>,
}

/// A measured view's style and the size its content was laid out at.
#[derive(Default)]
struct MeasuredViewSize(Option<(StyleRefinement, Size<Pixels>)>);

/// Whether a reused measured view's size still holds: only for a fixed width.
fn has_definite_width(style: &StyleRefinement) -> bool {
    matches!(
        style.size.width,
        Some(Length::Definite(DefiniteLength::Absolute(_)))
    )
}

struct ViewElementCacheKey {
    bounds: Bounds<Pixels>,
    content_mask: ContentMask<Pixels>,
    text_style: TextStyle,
}

/// What [`ViewElement::request_layout`] hands to prepaint: the element when
/// it was rendered during layout, and, for a measured view rendered there,
/// the entities that render read.
type ViewLayoutState = (Option<AnyElement>, Option<FxHashSet<EntityId>>);

impl<V: View> Element for ViewElement<V> {
    type RequestLayoutState = ViewLayoutState;
    type PrepaintState = Option<AnyElement>;

    fn id(&self) -> Option<ElementId> {
        self.entity_id.map(ElementId::View)
    }

    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        #[cfg(debug_assertions)]
        return Some(self.source);

        #[cfg(not(debug_assertions))]
        return None;
    }

    fn request_layout(
        &mut self,
        id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        if let Some(entity_id) = self.entity_id {
            // Stateful path: create a reactive boundary.
            window.with_rendered_view(entity_id, |window| {
                let caching_disabled = window.is_inspector_picking(cx);
                match self.cached_style.as_ref() {
                    Some(style) if !caching_disabled && self.measured => {
                        let mut root_style = Style::default();
                        root_style.refine(style);
                        let measured = window.with_element_state::<MeasuredViewSize, _>(
                            id.unwrap(),
                            |state, _| {
                                let state = state.unwrap_or_default();
                                let size = state
                                    .0
                                    .as_ref()
                                    .filter(|(measured_style, _)| measured_style == style)
                                    .map(|(_, size)| *size);
                                (size, state)
                            },
                        );
                        let notified = window.take_notified_while_drawing(entity_id);
                        let reused = measured.filter(|_| {
                            has_definite_width(style)
                                && !notified
                                && !window.dirty_views.contains(&entity_id)
                                && !window.refreshing
                        });
                        if let Some(size) = reused {
                            root_style.size = size.map(Into::into);
                            let layout_id = window.request_layout(root_style, None, cx);
                            return (layout_id, (None, None));
                        }
                        // Render now and lay the content out inside `style`;
                        // prepaint records the result for later frames.
                        let refreshing = mem::replace(&mut window.refreshing, true);
                        let ((layout_id, element), accessed) = cx.detect_accessed_entities(|cx| {
                            let mut element = self
                                .view
                                .take()
                                .unwrap()
                                .render(window, cx)
                                .into_any_element();
                            let child = element.request_layout(window, cx);
                            let layout_id = window.request_layout(root_style, [child], cx);
                            (layout_id, element)
                        });
                        window.refreshing = refreshing;
                        (layout_id, (Some(element), Some(accessed)))
                    }
                    Some(style) if !caching_disabled => {
                        let mut root_style = Style::default();
                        root_style.refine(style);
                        let layout_id = window.request_layout(root_style, None, cx);
                        (layout_id, (None, None))
                    }
                    _ => {
                        let mut element = self
                            .view
                            .take()
                            .unwrap()
                            .render(window, cx)
                            .into_any_element();
                        let layout_id = element.request_layout(window, cx);
                        (layout_id, (Some(element), None))
                    }
                }
            })
        } else {
            // Stateless path: isolate subtree via type name (no entity identity).
            window.with_id(
                ElementId::Name(std::any::type_name::<V>().into()),
                |window| {
                    let mut element = self
                        .view
                        .take()
                        .unwrap()
                        .render(window, cx)
                        .into_any_element();
                    let layout_id = element.request_layout(window, cx);
                    (layout_id, (Some(element), None))
                },
            )
        }
    }

    fn prepaint(
        &mut self,
        global_id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        (element, measured_render): &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<AnyElement> {
        if let Some(entity_id) = self.entity_id {
            // Stateful path.
            window.set_view_id(entity_id);
            window.with_rendered_view(entity_id, |window| {
                if let Some(accessed) = measured_render.take() {
                    // A measured view rendered during layout: prepaint it and
                    // keep the result for the frames that reuse it.
                    let mut element = element.take().unwrap();
                    let style = self.cached_style.clone().unwrap_or_default();
                    window.with_element_state::<MeasuredViewSize, _>(global_id.unwrap(), |_, _| {
                        ((), MeasuredViewSize(Some((style, bounds.size))))
                    });
                    return window.with_element_state::<ViewElementState, _>(
                        global_id.unwrap(),
                        |_, window| {
                            let content_mask = window.content_mask();
                            let text_style = window.text_style();
                            let refreshing = mem::replace(&mut window.refreshing, true);
                            let prepaint_start = window.prepaint_index();
                            let (_, mut accessed_entities) =
                                cx.detect_accessed_entities(|cx| element.prepaint(window, cx));
                            let prepaint_end = window.prepaint_index();
                            window.refreshing = refreshing;
                            accessed_entities.extend(accessed);
                            (
                                Some(element),
                                ViewElementState {
                                    accessed_entities,
                                    prepaint_range: prepaint_start..prepaint_end,
                                    paint_range: PaintIndex::default()..PaintIndex::default(),
                                    cache_key: ViewElementCacheKey {
                                        bounds,
                                        content_mask,
                                        text_style,
                                    },
                                },
                            )
                        },
                    );
                }
                if let Some(mut element) = element.take() {
                    element.prepaint(window, cx);
                    return Some(element);
                }

                // A parent's render may have notified this view earlier in
                // this same frame (handing it a new size or state); render it
                // now rather than show last frame's content. A measured view
                // took that notification during layout.
                let notified = !self.measured && window.take_notified_while_drawing(entity_id);
                window.with_element_state::<ViewElementState, _>(
                    global_id.unwrap(),
                    |element_state, window| {
                        let content_mask = window.content_mask();
                        let text_style = window.text_style();

                        if let Some(mut element_state) = element_state
                            && element_state.cache_key.bounds == bounds
                            && element_state.cache_key.content_mask == content_mask
                            && element_state.cache_key.text_style == text_style
                            && !notified
                            && !window.dirty_views.contains(&entity_id)
                            && !window.refreshing
                        {
                            let prepaint_start = window.prepaint_index();
                            window.reuse_prepaint(element_state.prepaint_range.clone());
                            cx.entities
                                .extend_accessed(&element_state.accessed_entities);
                            let prepaint_end = window.prepaint_index();
                            element_state.prepaint_range = prepaint_start..prepaint_end;

                            return (None, element_state);
                        }

                        let refreshing = mem::replace(&mut window.refreshing, true);
                        let prepaint_start = window.prepaint_index();
                        let (mut element, accessed_entities) = cx.detect_accessed_entities(|cx| {
                            let mut element = self
                                .view
                                .take()
                                .unwrap()
                                .render(window, cx)
                                .into_any_element();
                            element.layout_as_root(bounds.size.into(), window, cx);
                            element.prepaint_at(bounds.origin, window, cx);
                            element
                        });

                        let prepaint_end = window.prepaint_index();
                        window.refreshing = refreshing;

                        (
                            Some(element),
                            ViewElementState {
                                accessed_entities,
                                prepaint_range: prepaint_start..prepaint_end,
                                paint_range: PaintIndex::default()..PaintIndex::default(),
                                cache_key: ViewElementCacheKey {
                                    bounds,
                                    content_mask,
                                    text_style,
                                },
                            },
                        )
                    },
                )
            })
        } else {
            // Stateless path: just prepaint the element.
            window.with_id(
                ElementId::Name(std::any::type_name::<V>().into()),
                |window| {
                    element.as_mut().unwrap().prepaint(window, cx);
                },
            );
            Some(element.take().unwrap())
        }
    }

    fn paint(
        &mut self,
        global_id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        _bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        element: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        if let Some(entity_id) = self.entity_id {
            // Stateful path.
            window.with_rendered_view(entity_id, |window| {
                let caching_disabled = window.is_inspector_picking(cx);
                if self.cached_style.is_some() && !caching_disabled {
                    window.with_element_state::<ViewElementState, _>(
                        global_id.unwrap(),
                        |element_state, window| {
                            let mut element_state = element_state.unwrap();

                            let paint_start = window.paint_index();

                            if let Some(element) = element {
                                let refreshing = mem::replace(&mut window.refreshing, true);
                                element.paint(window, cx);
                                window.refreshing = refreshing;
                            } else {
                                window.reuse_paint(element_state.paint_range.clone());
                            }

                            let paint_end = window.paint_index();
                            element_state.paint_range = paint_start..paint_end;

                            ((), element_state)
                        },
                    )
                } else {
                    element.as_mut().unwrap().paint(window, cx);
                }
            });
        } else {
            // Stateless path: just paint the element.
            window.with_id(
                ElementId::Name(std::any::type_name::<V>().into()),
                |window| {
                    element.as_mut().unwrap().paint(window, cx);
                },
            );
        }
    }
}

/// A view that renders nothing
pub struct EmptyView;

impl Render for EmptyView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        Empty
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        self as gpui, AppContext as _, Bounds, Context, Entity, IntoElement, ParentElement as _,
        Pixels, Render, StyleRefinement, Styled as _, Window, canvas, div, px,
    };
    use std::{cell::Cell, rc::Rc};

    /// A view as tall as its lines, counting its renders.
    struct Lines {
        lines: usize,
        renders: Rc<Cell<usize>>,
    }

    impl Render for Lines {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            self.renders.set(self.renders.get() + 1);
            div()
                .flex()
                .flex_col()
                .children((0..self.lines).map(|_| div().h(px(10.))))
        }
    }

    /// Hosts `Lines` as a measured cached view and records the height it
    /// was given. `hand_over` is set in `Lines` during this view's render.
    struct Host {
        lines: Entity<Lines>,
        hand_over: Option<usize>,
        height: Rc<Cell<f32>>,
    }

    impl Render for Host {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            if let Some(lines) = self.hand_over.take() {
                self.lines.update(cx, |view, cx| {
                    view.lines = lines;
                    cx.notify();
                });
            }
            let height = self.height.clone();
            div().size_full().child(
                div()
                    .relative()
                    .w(px(100.))
                    .child(
                        self.lines
                            .clone()
                            .cached_measured(StyleRefinement::default().w(px(100.))),
                    )
                    .child(
                        canvas(
                            move |bounds: Bounds<Pixels>, _, _| {
                                height.set(f32::from(bounds.size.height))
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .inset_0(),
                    ),
            )
        }
    }

    fn host(
        cx: &mut gpui::TestAppContext,
    ) -> (
        Entity<Host>,
        Rc<Cell<usize>>,
        Rc<Cell<f32>>,
        &mut gpui::VisualTestContext,
    ) {
        let renders = Rc::new(Cell::new(0));
        let height = Rc::new(Cell::new(0.0));
        let (host, cx) = cx.add_window_view({
            let (renders, height) = (renders.clone(), height.clone());
            move |_, cx| Host {
                lines: cx.new(|_| Lines { lines: 3, renders }),
                hand_over: None,
                height,
            }
        });
        cx.run_until_parked();
        (host, renders, height, cx)
    }

    #[gpui::test]
    fn a_measured_view_keeps_its_height_while_reused(cx: &mut gpui::TestAppContext) {
        let (host, renders, height, cx) = host(cx);
        assert_eq!((renders.get(), height.get()), (1, 30.0));
        host.update(cx, |_, cx| cx.notify());
        cx.run_until_parked();
        assert_eq!(
            (renders.get(), height.get()),
            (1, 30.0),
            "the parent redrew; the cached view kept its render and measured height"
        );
    }

    #[gpui::test]
    fn a_notified_measured_view_is_laid_out_from_its_content(cx: &mut gpui::TestAppContext) {
        let (host, renders, height, cx) = host(cx);
        let lines = host.read_with(cx, |host, _| host.lines.clone());
        lines.update(cx, |view, cx| {
            view.lines = 5;
            cx.notify();
        });
        cx.run_until_parked();
        assert_eq!((renders.get(), height.get()), (2, 50.0));
    }

    /// A parent handing a cached child new state in its render sees it drawn
    /// in that frame, not the next one (which nothing may ever request).
    #[gpui::test]
    fn a_view_notified_by_its_parents_render_redraws_in_that_frame(cx: &mut gpui::TestAppContext) {
        let (host, renders, height, cx) = host(cx);
        host.update(cx, |host, cx| {
            host.hand_over = Some(2);
            cx.notify();
        });
        cx.run_until_parked();
        assert_eq!((renders.get(), height.get()), (2, 20.0));
    }
}