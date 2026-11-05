//! Search-only address completions. The typed query stays the default action;
//! a late response must never replace a newer edit or reopen a dismissed list.
#[cfg(feature = "browser-fixture")]
use std::cell::RefCell;
use std::{cell::Cell, rc::Rc, time::Duration};

use gpui::{
    AnyElement, Bounds, Context, Focusable, IntoElement, KeyDownEvent, MouseButton, Pixels, Window,
    div, prelude::*, px,
};

use super::{BrowserSurface, model, search_suggestions};
use crate::{icons, popover, theme::Theme};

#[derive(Default)]
pub(super) struct SearchSuggestions {
    pub(super) focused: bool,
    pub(super) composing: bool,
    query: Option<String>,
    values: Vec<String>,
    selected: usize,
    generation: u64,
    task: Option<gpui::Task<()>>,
    pub(super) address_bounds: Rc<Cell<Bounds<Pixels>>>,
    #[cfg(feature = "browser-fixture")]
    fixture_values: Option<Vec<String>>,
    #[cfg(feature = "browser-fixture")]
    row_bounds: Rc<RefCell<Vec<Bounds<Pixels>>>>,
}

impl BrowserSurface {
    pub(super) fn dismiss_search_suggestions(&mut self, cx: &mut Context<Self>) {
        self.search.generation = self.search.generation.wrapping_add(1);
        self.search.task = None;
        self.search.query = None;
        self.search.values.clear();
        self.search.selected = 0;
        #[cfg(feature = "browser-fixture")]
        self.search.row_bounds.borrow_mut().clear();
        cx.notify();
    }

    pub(super) fn update_search_suggestions(&mut self, cx: &mut Context<Self>) {
        self.search.composing = self.address.read(cx).has_marked_text();
        let query = (self.search.focused
            && self.view.is_none()
            && self.preview_request.is_none()
            && !self.search.composing)
            .then(|| model::search_query(self.address.read(cx).text()))
            .flatten();
        if query == self.search.query {
            return;
        }
        self.dismiss_search_suggestions(cx);
        let Some(query) = query else {
            return;
        };
        self.search.query = Some(query.clone());
        let generation = self.search.generation;
        #[cfg(feature = "browser-fixture")]
        let fixture_values = self.search.fixture_values.clone();
        self.search.task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(180))
                .await;
            let request_query = query.clone();
            let Ok(request) = this.update(cx, |_, cx| {
                gpui_tokio::Tokio::spawn(cx, async move {
                    #[cfg(feature = "browser-fixture")]
                    if let Some(values) = fixture_values {
                        return values;
                    }
                    search_suggestions::fetch(&request_query).await
                })
            }) else {
                return;
            };
            let Ok(values) = request.await else {
                return;
            };
            let _ = this.update(cx, |this, cx| {
                if this.search.generation != generation
                    || this.search.query.as_deref() != Some(query.as_str())
                    || !this.search.focused
                {
                    return;
                }
                this.search.values = values
                    .into_iter()
                    .take(search_suggestions::MAX_SUGGESTIONS)
                    .collect();
                cx.notify();
            });
        }));
    }

    pub(super) fn search_suggestions_open(&self, window: &Window, cx: &Context<Self>) -> bool {
        self.search.query.is_some() && self.address.focus_handle(cx).is_focused(window)
    }

    fn accept_search_suggestion(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let query = if index == 0 {
            self.search.query.clone()
        } else {
            self.search.values.get(index - 1).cloned()
        };
        if let Some(query) = query {
            // A provider completion that looks like a domain is still a search.
            self.navigate(&model::search_url(&query), window, cx);
        }
    }

    pub(super) fn search_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.address.focus_handle(cx).is_focused(window)
            || self.address.read(cx).has_marked_text()
            || event.keystroke.modifiers.platform
            || event.keystroke.modifiers.control
            || event.keystroke.modifiers.alt
        {
            return;
        }
        let key = event.keystroke.key.as_str();
        if self.search.query.is_none() && matches!(key, "down" | "up") {
            self.update_search_suggestions(cx);
        }
        if self.search.query.is_none() {
            return;
        }
        match key {
            "down" | "up" => {
                self.search.selected = popover::menu_step(
                    Some(self.search.selected),
                    self.search.values.len() + 1,
                    if key == "down" { 1 } else { -1 },
                )
                .unwrap_or(0);
                cx.notify();
            }
            "enter" if !event.keystroke.modifiers.shift => {
                self.accept_search_suggestion(self.search.selected, window, cx);
            }
            "escape" => self.dismiss_search_suggestions(cx),
            _ => return,
        }
        window.prevent_default();
        cx.stop_propagation();
    }

    pub(super) fn render_search_suggestions(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.search_suggestions_open(window, cx) {
            return None;
        }
        let theme = Theme::of(cx).clone();
        let query = self.search.query.as_ref()?;
        let width = self.search.address_bounds.get().size.width;
        if width <= px(0.0) {
            return None;
        }
        let rows =
            std::iter::once(query)
                .chain(self.search.values.iter())
                .enumerate()
                .map(|(index, text)| {
                    let selected = index == self.search.selected;
                    let picked = text.clone();
                    let completion =
                        (index > 0 && text.starts_with(query.as_str()) && text.len() > query.len())
                            .then(|| {
                                (
                                    query.len()..text.len(),
                                    gpui::HighlightStyle {
                                        font_weight: Some(gpui::FontWeight::SEMIBOLD),
                                        ..Default::default()
                                    },
                                )
                            });
                    div()
                        .id(("browser-search-suggestion", index))
                        .role(gpui::Role::ListBoxOption)
                        .aria_label(format!("Search Google for {text}"))
                        .aria_selected(selected)
                        .h(px(32.0))
                        .w_full()
                        .flex_none()
                        .px(px(8.0))
                        .rounded(px(5.0))
                        .flex()
                        .items_center()
                        .gap(px(8.0))
                        .cursor_pointer()
                        .when(selected, |row| row.bg(theme.element_hover))
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(move |this, _, window, cx| {
                                // The input can blur during capture. Retain this row's
                                // query and accept the press before it unmounts.
                                window.prevent_default();
                                this.navigate(&model::search_url(&picked), window, cx);
                                cx.stop_propagation();
                            }),
                        )
                        .on_mouse_move(cx.listener(move |this, _, _, cx| {
                            if this.search.selected != index {
                                this.search.selected = index;
                                cx.notify();
                            }
                        }))
                        .child(
                            icons::icon(icons::MAGNIFER)
                                .size(px(14.0))
                                .flex_none()
                                .text_color(theme.text_muted),
                        )
                        .child(
                            div().flex_1().min_w_0().truncate().child(
                                gpui::StyledText::new(text.clone()).with_highlights(completion),
                            ),
                        )
                        .when(index == 0, |row| {
                            row.child(
                                div()
                                    .flex_none()
                                    .text_size(crate::typography::ui_rems(11.0))
                                    .text_color(theme.text_muted)
                                    .child("Google"),
                            )
                        })
                });
        let content = popover::popover_card(&theme)
            .map(|content| {
                #[cfg(feature = "browser-fixture")]
                {
                    let rows = self.search.row_bounds.clone();
                    return content.on_children_prepainted(move |bounds, _, _| {
                        *rows.borrow_mut() = bounds.to_vec();
                    });
                }
                #[cfg(not(feature = "browser-fixture"))]
                content
            })
            .id("browser-search-suggestions")
            .role(gpui::Role::ListBox)
            .aria_label("Search suggestions")
            .w(width)
            .flex()
            .flex_col()
            .gap_0()
            .text_size(crate::typography::ui_rems(super::BROWSER_ADDRESS_TEXT_SIZE))
            .on_mouse_down_out(cx.listener(|this, event: &gpui::MouseDownEvent, _, cx| {
                if !this.search.address_bounds.get().contains(&event.position) {
                    this.dismiss_search_suggestions(cx);
                }
            }))
            .children(rows);
        Some(popover::anchored_menu_below_gap(
            "browser-search-suggestions-menu",
            content.into_any_element(),
            None,
            4.0,
        ))
    }

    #[cfg(feature = "browser-fixture")]
    pub fn fixture_search_provider(&mut self, values: Vec<String>) {
        self.search.fixture_values = Some(values);
    }

    #[cfg(feature = "browser-fixture")]
    pub fn fixture_search_input(
        &mut self,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.focus_address(window, cx);
        self.search.focused = true;
        self.address
            .update(cx, |input, cx| input.set_text(text, cx));
        self.update_search_suggestions(cx);
        cx.notify();
    }

    #[cfg(feature = "browser-fixture")]
    pub fn fixture_search_state(&self) -> (Option<String>, Vec<String>, usize) {
        (
            self.search.query.clone(),
            self.search.values.clone(),
            self.search.selected,
        )
    }

    #[cfg(feature = "browser-fixture")]
    pub fn fixture_search_bounds(&self) -> Vec<Bounds<Pixels>> {
        self.search.row_bounds.borrow().clone()
    }
}
