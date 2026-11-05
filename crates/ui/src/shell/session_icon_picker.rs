//! Compact, searchable session symbols. The grid is virtualized by eight-cell
//! rows so the full emoji catalogue has the cost of the visible rows.
use super::*;

const ROW_HEIGHT: f32 = 36.0;

pub(super) fn picker_placeholder(tab: IconPickerTab) -> &'static str {
    match tab {
        IconPickerTab::Emoji => "Search emojis",
        IconPickerTab::Icons => "Search icons",
    }
}

impl Shell {
    pub(super) fn refresh_workspace_session_icon_choices(&mut self, cx: &mut Context<Self>) {
        let Some(menu) = self.session_sidebar.menu.as_mut() else {
            return;
        };
        let query = menu.search_input.read(cx).text();
        if !query.trim().is_empty() {
            menu.category = None;
        }
        let mut choices = session_icon_catalog::choices(menu.picker_tab, query);
        if let Some(category) = &menu.category {
            choices.retain(|choice| choice.category.as_ref() == Some(category));
        }
        menu.grid = Rc::new(IconPickerGrid::new(
            &choices,
            menu.picker_tab,
            !query.trim().is_empty(),
        ));
        menu.choices = Rc::new(choices);
        menu.selected = 0;
        menu.scroll.scroll_to_item(0, gpui::ScrollStrategy::Top);
        cx.notify();
    }

    pub(super) fn set_workspace_session_picker_tab(
        &mut self,
        tab: IconPickerTab,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self.session_sidebar.menu.as_mut() else {
            return;
        };
        menu.picker_tab = tab;
        menu.category = None;
        let input = menu.search_input.clone();
        input.update(cx, |input, cx| {
            input.set_placeholder(picker_placeholder(tab), cx);
            input.set_text("", cx);
        });
        self.refresh_workspace_session_icon_choices(cx);
        window.focus(&input.focus_handle(cx), cx);
    }

    pub(super) fn apply_workspace_session_icon_choice(
        &mut self,
        index: usize,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self.session_sidebar.menu.as_ref().filter(|menu| menu.icons) else {
            return;
        };
        let Some(choice) = menu.choices.get(index) else {
            return;
        };
        let (id, key) = (menu.id.clone(), choice.key.clone());
        self.set_workspace_session_icon(&id, Some(&key), cx);
        self.session_sidebar.menu = None;
        self.session_sidebar.focus_row = Some(id);
        cx.notify();
    }

    pub(super) fn clear_workspace_session_icon(&mut self, cx: &mut Context<Self>) {
        let Some(menu) = self.session_sidebar.menu.as_ref() else {
            return;
        };
        let id = menu.id.clone();
        self.set_workspace_session_icon(&id, None, cx);
        self.session_sidebar.menu = None;
        self.session_sidebar.focus_row = Some(id);
        cx.notify();
    }

    pub(super) fn workspace_session_menu_key_down(
        &mut self,
        event: &gpui::KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self.session_sidebar.menu.as_mut() else {
            return;
        };
        let key = event.keystroke.key.as_str();
        if menu.icons && menu.search_input.read(cx).has_marked_text() {
            return;
        }
        if key == "escape" {
            self.dismiss_workspace_session_menu(window, cx);
            cx.stop_propagation();
            return;
        }
        let search_focused = menu.search_input.focus_handle(cx).is_focused(window);
        if !menu.focus.is_focused(window) && !search_focused {
            return; // Tab/Clear buttons retain their own keyboard actions.
        }
        if search_focused && matches!(key, "left" | "right") {
            let action: Box<dyn gpui::Action> = if key == "left" {
                Box::new(crate::composer::Left)
            } else {
                Box::new(crate::composer::Right)
            };
            window.dispatch_action(action, cx);
            cx.stop_propagation();
            return;
        }
        let count = if menu.icons { menu.choices.len() } else { 4 };
        if count == 0 {
            return;
        }
        if menu.icons && search_focused && matches!(key, "down" | "arrowdown") {
            menu.selected = 0;
            menu.scroll.scroll_to_item(0, gpui::ScrollStrategy::Top);
            window.focus(&menu.focus, cx);
            cx.stop_propagation();
            cx.notify();
            return;
        }
        if menu.icons
            && !search_focused
            && matches!(key, "up" | "arrowup")
            && menu.grid.row_for_choice(menu.selected) == menu.grid.first_choice_row()
        {
            window.focus(&menu.search_input.focus_handle(cx), cx);
            cx.stop_propagation();
            cx.notify();
            return;
        }
        let modifiers = event.keystroke.modifiers;
        if menu.icons
            && !search_focused
            && !modifiers.control
            && !modifiers.platform
            && !modifiers.alt
            && !modifiers.function
            && key.chars().count() == 1
        {
            let text = event.keystroke.key_char.as_deref().unwrap_or(key);
            let input = menu.search_input.clone();
            let query = format!("{}{}", input.read(cx).text(), text);
            input.update(cx, |input, cx| input.set_text(query, cx));
            self.refresh_workspace_session_icon_choices(cx);
            window.focus(&input.focus_handle(cx), cx);
            cx.stop_propagation();
            return;
        }
        let step = if menu.icons { COLUMNS } else { 1 };
        match key {
            "down" | "arrowdown" => {
                menu.selected = if menu.icons {
                    menu.grid.vertical_neighbor(menu.selected, true)
                } else {
                    (menu.selected + step) % count
                }
            }
            "up" | "arrowup" => {
                menu.selected = if menu.icons {
                    menu.grid.vertical_neighbor(menu.selected, false)
                } else {
                    (menu.selected + count - step) % count
                }
            }
            "right" if menu.icons && !search_focused => {
                menu.selected = (menu.selected + 1).min(count - 1)
            }
            "left" if menu.icons && !search_focused => {
                menu.selected = menu.selected.saturating_sub(1)
            }
            "home" if !search_focused => menu.selected = 0,
            "end" if !search_focused => menu.selected = count - 1,
            "enter" | "space" if key == "enter" || !search_focused => {
                let selected = menu.selected;
                self.activate_workspace_session_menu(selected, window, cx);
                cx.stop_propagation();
                return;
            }
            _ => return,
        }
        if menu.icons {
            let row = menu.grid.row_for_choice(menu.selected).unwrap_or(0);
            let heading_above =
                row > 0 && matches!(menu.grid.rows[row - 1], IconPickerRow::Heading { .. });
            menu.scroll.scroll_to_item_with_offset(
                row,
                gpui::ScrollStrategy::Nearest,
                usize::from(heading_above),
            );
        }
        cx.stop_propagation();
        cx.notify();
    }

    pub(super) fn render_workspace_session_icon_picker(
        &mut self,
        menu: &SessionMenu,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut tabs = div().flex().items_center().gap(px(4.0));
        for (tab, key, label) in [
            (IconPickerTab::Emoji, "emoji", "Emoji"),
            (IconPickerTab::Icons, "icons", "Icons"),
        ] {
            let focus = self.session_sidebar_focus(format!("session-icon-tab-{key}"), cx);
            tabs = tabs.child(
                div()
                    .id(SharedString::from(format!("session-icon-tab-{key}")))
                    .debug_selector(move || format!("session-icon-tab-{key}"))
                    .role(gpui::Role::Button)
                    .aria_label(label)
                    .aria_selected(menu.picker_tab == tab)
                    .track_focus(&focus)
                    .h(px(28.0))
                    .px(px(11.0))
                    .rounded(px(7.0))
                    .flex()
                    .items_center()
                    .text_size(crate::typography::ui_rems(12.0))
                    .text_color(if menu.picker_tab == tab {
                        theme.text
                    } else {
                        theme.text_muted
                    })
                    .when(menu.picker_tab == tab, |el| el.bg(theme.element_active))
                    .hover(|el| el.bg(theme.element_hover))
                    .focus_visible(|el| el.border_1().border_color(theme.accent))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.set_workspace_session_picker_tab(tab, window, cx)
                    }))
                    .on_key_down(cx.listener(
                        move |this, event: &gpui::KeyDownEvent, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                this.set_workspace_session_picker_tab(tab, window, cx);
                                cx.stop_propagation();
                            }
                        },
                    ))
                    .child(label),
            );
        }
        let clear_focus = self.session_sidebar_focus("session-icon-clear".into(), cx);
        let header = div()
            .flex()
            .items_center()
            .justify_between()
            .px(px(8.0))
            .pt(px(5.0))
            .pb(px(7.0))
            .child(tabs)
            .child(
                div()
                    .id("session-icon-clear")
                    .debug_selector(|| "session-icon-clear".into())
                    .role(gpui::Role::Button)
                    .aria_label("Clear session icon")
                    .track_focus(&clear_focus)
                    .h(px(28.0))
                    .px(px(8.0))
                    .rounded(px(6.0))
                    .flex()
                    .items_center()
                    .text_size(crate::typography::ui_rems(12.0))
                    .text_color(theme.text_muted)
                    .hover(|el| el.bg(theme.element_hover).text_color(theme.text))
                    .focus_visible(|el| el.border_1().border_color(theme.accent))
                    .cursor_pointer()
                    .on_click(cx.listener(|this, _, _, cx| this.clear_workspace_session_icon(cx)))
                    .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                            this.clear_workspace_session_icon(cx);
                            cx.stop_propagation();
                        }
                    }))
                    .child("Clear"),
            );
        let search = div().px(px(8.0)).pb(px(6.0)).child(
            div()
                .id("session-icon-search")
                .debug_selector(|| "session-icon-search".into())
                .h(px(32.0))
                .px(px(8.0))
                .rounded(px(7.0))
                .border_1()
                .border_color(theme.border)
                .bg(theme.bg)
                .flex()
                .items_center()
                .gap(px(7.0))
                .child(
                    icon(icons::PALETTE_SEARCH)
                        .size(px(14.0))
                        .flex_none()
                        .text_color(theme.text_muted),
                )
                .child(div().flex_1().min_w_0().child(menu.search_input.clone())),
        );
        let mut content = div().flex().flex_col().child(header).child(search);
        if menu.picker_tab == IconPickerTab::Emoji {
            let mut categories = div()
                .flex()
                .items_center()
                .justify_between()
                .px(px(8.0))
                .pb(px(6.0));
            for (index, (category, label)) in std::iter::once(("", "All emoji"))
                .chain(session_icon_catalog::emoji_categories().iter().copied())
                .enumerate()
            {
                let chosen = menu.category.as_deref().unwrap_or("") == category;
                let focus =
                    self.session_sidebar_focus(format!("session-icon-category-{category}"), cx);
                let mut button = div()
                    .id(SharedString::from(format!(
                        "session-icon-category-{category}"
                    )))
                    .debug_selector(move || format!("session-icon-category-{category}"))
                    .size(px(30.0))
                    .rounded(px(6.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .role(gpui::Role::Button)
                    .aria_label(label)
                    .aria_selected(chosen)
                    .track_focus(&focus)
                    .when(chosen, |el| el.bg(theme.element_active))
                    .hover(|el| el.bg(theme.element_hover))
                    .focus_visible(|el| el.border_1().border_color(theme.accent))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.set_workspace_session_icon_category(category, window, cx)
                    }))
                    .on_key_down(cx.listener(
                        move |this, event: &gpui::KeyDownEvent, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                this.set_workspace_session_icon_category(category, window, cx);
                                cx.stop_propagation();
                            }
                        },
                    ))
                    .tooltip(move |_, cx| {
                        cx.new(|_| SurfaceTabTooltip { text: label.into() }).into()
                    });
                if index == 0 {
                    button = button.child(
                        icon(icons::WIDGET)
                            .size(px(14.0))
                            .text_color(theme.text_muted),
                    );
                } else {
                    let glyph = ["😀", "👋", "🐻", "🍔", "🚗", "⚽", "💡", "❤️", "🏁"][index - 1];
                    button = button.child(div().text_size(px(14.0)).child(glyph));
                }
                categories = categories.child(button);
            }
            content = content.child(categories);
        }
        let choices = menu.choices.clone();
        let rows = menu.grid.clone();
        let row_count = rows.rows.len();
        let height = if menu.picker_tab == IconPickerTab::Emoji {
            216.0
        } else {
            (row_count.max(2) as f32 * ROW_HEIGHT).min(216.0)
        };
        let grid = if choices.is_empty() {
            div()
                .h(px(height))
                .flex()
                .items_center()
                .justify_center()
                .text_size(crate::typography::ui_rems(12.0))
                .text_color(theme.text_muted)
                .child("No matches. Try another search.")
                .into_any_element()
        } else {
            let entity = cx.entity();
            let heading_color = theme.text_muted;
            gpui::uniform_list("session-icon-grid", row_count, move |range, _, app| {
                entity.update(app, |this, cx| {
                    range
                        .map(|row| match &rows.rows[row] {
                            IconPickerRow::Heading { category, label } => {
                                let key = category.as_deref().unwrap_or("search").to_owned();
                                div()
                                    .id(SharedString::from(format!("session-icon-heading-{key}")))
                                    .debug_selector(move || format!("session-icon-heading-{key}"))
                                    .w_full()
                                    .h(px(ROW_HEIGHT))
                                    .px(px(4.0))
                                    .pb(px(8.0))
                                    .flex()
                                    .items_end()
                                    .role(gpui::Role::Heading)
                                    .aria_label(label.clone())
                                    .text_size(crate::typography::ui_rems(12.0))
                                    .text_color(heading_color)
                                    .child(label.clone())
                                    .into_any_element()
                            }
                            IconPickerRow::Choices { start, len } => {
                                let mut line = div().w_full().h(px(ROW_HEIGHT)).flex().gap(px(4.0));
                                for column in 0..COLUMNS {
                                    let cell = if column < *len {
                                        let index = start + column;
                                        this.render_workspace_session_icon_choice(
                                            index,
                                            &choices[index],
                                            cx,
                                        )
                                    } else {
                                        div().flex_1().min_w(px(32.0)).into_any_element()
                                    };
                                    line = line.child(cell);
                                }
                                line.into_any_element()
                            }
                        })
                        .collect::<Vec<_>>()
                })
            })
            .h(px(height))
            .w_full()
            .px(px(8.0))
            .track_scroll(&menu.scroll)
            .into_any_element()
        };
        content
            .child(
                div()
                    .id("session-icon-scroll-viewport")
                    .debug_selector(|| "session-icon-scroll-viewport".into())
                    .h(px(height))
                    .w_full()
                    .overflow_hidden()
                    .child(grid),
            )
            .into_any_element()
    }

    pub(super) fn set_workspace_session_icon_category(
        &mut self,
        category: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self.session_sidebar.menu.as_mut() else {
            return;
        };
        let input = menu.search_input.clone();
        input.update(cx, |input, cx| input.set_text("", cx));
        self.session_sidebar.menu.as_mut().unwrap().category =
            (!category.is_empty()).then(|| category.to_owned());
        self.refresh_workspace_session_icon_choices(cx);
        window.focus(&input.focus_handle(cx), cx);
    }

    fn render_workspace_session_icon_choice(
        &mut self,
        index: usize,
        choice: &IconChoice,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::of(cx).for_popup();
        let Some(menu) = self.session_sidebar.menu.as_ref() else {
            return div().into_any_element();
        };
        let current = self
            .chat_tabs
            .iter()
            .find(|tab| tab.id == menu.id)
            .and_then(|tab| tab.session_icon.as_deref())
            .unwrap_or("workspace")
            == choice.key;
        let label = choice.label.clone();
        let glyph_size = match choice.icon {
            super::super::session_icon::SessionIcon::Emoji(_) => 22.0,
            _ => 18.0,
        };
        div()
            .id(("session-icon-choice", index))
            .debug_selector(move || format!("session-icon-choice-{index}"))
            .flex_1()
            .min_w(px(32.0))
            .h(px(32.0))
            .rounded(px(6.0))
            .flex()
            .items_center()
            .justify_center()
            .role(gpui::Role::Button)
            .aria_label(label.clone())
            .aria_selected(current)
            .when(menu.selected == index, |el| el.bg(theme.element_hover))
            .when(current, |el| el.border_1().border_color(theme.accent))
            .hover(|el| el.bg(theme.element_hover))
            .cursor_pointer()
            .on_mouse_move(cx.listener(move |this, _, _, cx| {
                if let Some(menu) = this.session_sidebar.menu.as_mut()
                    && menu.selected != index
                {
                    menu.selected = index;
                    cx.notify();
                }
            }))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.apply_workspace_session_icon_choice(index, cx)
            }))
            .tooltip(move |_, cx| {
                cx.new(|_| SurfaceTabTooltip {
                    text: label.clone().into(),
                })
                .into()
            })
            .child(choice.icon.render(glyph_size, theme.text))
            .into_any_element()
    }
}
