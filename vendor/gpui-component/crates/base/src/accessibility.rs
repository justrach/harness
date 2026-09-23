use gpui::{
    A11ySubtreeBuilder, App, Bounds, Element, ElementId, GlobalElementId, InspectorElementId,
    IntoElement, LayoutId, Pixels, SharedString, Window, accesskit,
};

/// Adds an author-provided accessibility identifier to an element.
///
/// The Comet GPUI fork does not expose the `accessibility_id` fluent builder
/// available in upstream GPUI, so gpui-base preserves that component API at
/// the element boundary instead.
pub(crate) struct AccessibilityId<E> {
    element: E,
    id: Option<SharedString>,
}

impl<E> AccessibilityId<E> {
    pub(crate) fn new(element: E, id: Option<SharedString>) -> Self {
        Self { element, id }
    }
}

impl<E> IntoElement for AccessibilityId<E>
where
    E: Element,
{
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl<E> Element for AccessibilityId<E>
where
    E: Element,
{
    type RequestLayoutState = E::RequestLayoutState;
    type PrepaintState = E::PrepaintState;

    fn id(&self) -> Option<ElementId> {
        self.element.id()
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        self.element.source_location()
    }

    fn request_layout(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        self.element.request_layout(id, inspector_id, window, cx)
    }

    fn prepaint(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        request_layout: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        self.element
            .prepaint(id, inspector_id, bounds, request_layout, window, cx)
    }

    fn paint(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        request_layout: &mut Self::RequestLayoutState,
        prepaint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        self.element.paint(
            id,
            inspector_id,
            bounds,
            request_layout,
            prepaint,
            window,
            cx,
        );
    }

    fn a11y_role(&self) -> Option<accesskit::Role> {
        self.element.a11y_role()
    }

    fn write_a11y_info(&self, node: &mut accesskit::Node) {
        self.element.write_a11y_info(node);
        if let Some(id) = &self.id {
            node.set_author_id(id.to_string());
        }
    }

    fn a11y_synthetic_children(
        &mut self,
        prepaint: &mut Self::PrepaintState,
        builder: &mut A11ySubtreeBuilder,
    ) {
        self.element.a11y_synthetic_children(prepaint, builder);
    }
}
