//! Settings → Appearance: system behavior, independent light/dark variants,
//! and the optional interactive accent overlay.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use gpui::{
    AnyElement, Context, Entity, FocusHandle, Focusable, Hsla, IntoElement, Render, SharedString,
    Subscription, Window, div, prelude::*, px,
};
use zeron_theme::vscode::{ImportReport, SourceCompilation};
use zeron_theme::{
    AccentPreset, AccentSelection, CustomThemeEntry, CustomThemeStatus, InstallMode,
    SurfacePreference, SurfaceTreatment, ThemeRegistry, ThemeSelection,
};

use crate::appearance::{self, AppearanceMode};
use crate::composer::{ComposerInput, ComposerInputEvent};
use crate::icons;
use crate::popover::{self, Popup};
use crate::settings::widgets;
use crate::theme::{Appearance, Theme};
use crate::theme_library;

struct ImportDialog {
    input: Entity<ComposerInput>,
    _events: Subscription,
    focus: FocusHandle,
    focus_pending: bool,
    mode: InstallMode,
    compilation: Option<SourceCompilation>,
    selected: HashSet<String>,
    review_variant: Option<String>,
    error: Option<SharedString>,
}

pub struct AppearancePage {
    light_theme_menu: Popup<()>,
    dark_theme_menu: Popup<()>,
    import_dialog: Option<ImportDialog>,
    review_entry: Option<String>,
    library_error: Option<SharedString>,
}

impl AppearancePage {
    pub fn new(_cx: &mut Context<Self>) -> Self {
        Self {
            light_theme_menu: Popup::default(),
            dark_theme_menu: Popup::default(),
            import_dialog: None,
            review_entry: None,
            library_error: None,
        }
    }

    fn open_import(&mut self, cx: &mut Context<Self>) {
        let input = cx.new(|cx| {
            ComposerInput::with_context(
                "Theme file, package.json, or extension folder",
                "PaletteSearch",
                cx,
            )
        });
        let events = cx.subscribe(&input, |this: &mut Self, _, event, cx| match event {
            ComposerInputEvent::Edited => {
                let source = this
                    .import_dialog
                    .as_ref()
                    .map(|dialog| PathBuf::from(dialog.input.read(cx).text().trim()));
                if let Some(dialog) = this.import_dialog.as_mut()
                    && dialog
                        .compilation
                        .as_ref()
                        .zip(source.as_ref())
                        .is_some_and(|(compilation, source)| compilation.path != *source)
                {
                    dialog.compilation = None;
                    dialog.selected.clear();
                    dialog.review_variant = None;
                    dialog.error = None;
                    cx.notify();
                }
            }
            ComposerInputEvent::Submitted => {
                if this
                    .import_dialog
                    .as_ref()
                    .is_some_and(|dialog| dialog.compilation.is_some())
                {
                    this.finish_import(cx);
                } else {
                    this.compile_import(cx);
                }
            }
            _ => {}
        });
        self.import_dialog = Some(ImportDialog {
            input,
            _events: events,
            focus: cx.focus_handle(),
            focus_pending: true,
            mode: InstallMode::Snapshot,
            compilation: None,
            selected: HashSet::new(),
            review_variant: None,
            error: None,
        });
        cx.notify();
    }

    fn compile_import(&mut self, cx: &mut Context<Self>) {
        let Some(dialog) = self.import_dialog.as_mut() else {
            return;
        };
        let source = dialog.input.read(cx).text().trim().to_owned();
        if source.is_empty() {
            dialog.error = Some("Choose a local theme file or extension folder.".into());
            cx.notify();
            return;
        }
        let path = PathBuf::from(&source);
        let family_name = source_name(&path);
        let family_id = format!("custom-{}", slug(&family_name));
        match theme_library::compile(&path, &family_id, &family_name) {
            Ok(compilation) => {
                dialog.selected = compilation
                    .family
                    .variants
                    .iter()
                    .map(|variant| variant.id.clone())
                    .collect();
                dialog.review_variant = compilation
                    .family
                    .variants
                    .first()
                    .map(|variant| variant.id.clone());
                dialog.compilation = Some(compilation);
                dialog.error = None;
            }
            Err(error) => dialog.error = Some(error.to_string().into()),
        }
        cx.notify();
    }

    fn choose_import_source(&mut self, cx: &mut Context<Self>) {
        let receiver = cx.prompt_for_paths(gpui::PathPromptOptions {
            files: true,
            directories: true,
            multiple: false,
            prompt: Some("Choose Theme Source".into()),
        });
        cx.spawn(async move |this, cx| {
            let path = match receiver.await {
                Ok(Ok(Some(mut paths))) => paths.pop(),
                _ => None,
            };
            let Some(path) = path else {
                return;
            };
            let _ = this.update(cx, |page, cx| {
                if let Some(dialog) = page.import_dialog.as_mut() {
                    dialog.input.update(cx, |input, cx| {
                        input.set_text(path.display().to_string(), cx)
                    });
                }
                page.compile_import(cx);
            });
        })
        .detach();
    }

    fn finish_import(&mut self, cx: &mut Context<Self>) {
        let Some(dialog) = self.import_dialog.as_mut() else {
            return;
        };
        if dialog.selected.is_empty() {
            dialog.error = Some("Select at least one variant to import.".into());
            cx.notify();
            return;
        }
        let Some(compilation) = dialog.compilation.take() else {
            return;
        };
        let selected = dialog.selected.iter().cloned().collect::<Vec<_>>();
        match theme_library::install(compilation.clone(), &selected, dialog.mode, cx) {
            Ok(_) => self.import_dialog = None,
            Err(error) => {
                dialog.compilation = Some(compilation);
                dialog.error = Some(error.to_string().into());
            }
        }
        cx.notify();
    }
}

fn source_name(path: &Path) -> String {
    let path = if path.file_name().and_then(|name| name.to_str()) == Some("package.json") {
        path.parent().unwrap_or(path)
    } else {
        path
    };
    path.file_stem()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("Custom theme")
        .to_owned()
}

fn slug(value: &str) -> String {
    let mut result = String::new();
    let mut separator = false;
    for character in value.chars().flat_map(char::to_lowercase) {
        if character.is_ascii_alphanumeric() {
            if separator && !result.is_empty() {
                result.push('-');
            }
            result.push(character);
            separator = false;
        } else {
            separator = true;
        }
    }
    if result.is_empty() {
        "theme".into()
    } else {
        result
    }
}

fn bar(fraction: f32, tone: Hsla) -> gpui::Div {
    div()
        .h(px(5.0))
        .w(gpui::relative(fraction))
        .rounded(px(3.0))
        .bg(tone)
}

fn accent_helper(accent: AccentSelection) -> String {
    match accent {
        AccentSelection::ThemeDefault => {
            "Theme default · Uses the palette's intended color.".into()
        }
        AccentSelection::Preset(preset) => format!(
            "{} · Controls, glyphs, selections, code, and activity.",
            preset.label()
        ),
    }
}

fn surface_label(surface: SurfacePreference) -> &'static str {
    match surface {
        SurfacePreference::ThemeDefault => "Theme default",
        SurfacePreference::Frosted => "Frosted",
        SurfacePreference::Opaque => "Opaque",
    }
}

fn surface_helper(surface: SurfacePreference, resolved: SurfaceTreatment) -> String {
    match surface {
        SurfacePreference::ThemeDefault => format!(
            "Uses this theme's {} default.",
            match resolved {
                SurfaceTreatment::Frosted => "frosted",
                SurfaceTreatment::Opaque => "opaque",
            }
        ),
        SurfacePreference::Frosted => "Theme-colored glass where supported.".into(),
        SurfacePreference::Opaque => "Solid surfaces for every theme.".into(),
    }
}

fn surface_choice(
    theme: &Theme,
    surface: SurfacePreference,
    selected: bool,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(SharedString::from(format!(
            "appearance-surface-{}",
            surface_label(surface).to_lowercase().replace(' ', "-")
        )))
        .h(px(30.0))
        .px(px(10.0))
        .rounded(px(7.0))
        .border_1()
        .border_color(if selected { theme.accent } else { theme.border })
        .bg(if selected {
            theme.accent_wash
        } else {
            theme.surface_raised.opacity(0.28)
        })
        .text_size(px(11.5))
        .font_weight(if selected {
            gpui::FontWeight::MEDIUM
        } else {
            gpui::FontWeight::NORMAL
        })
        .text_color(if selected {
            theme.accent
        } else {
            theme.text_muted
        })
        .flex()
        .items_center()
        .cursor_pointer()
        .when(!selected, |control| {
            control.hover(|style| style.bg(theme.surface_raised_hover))
        })
        .child(surface_label(surface))
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Corners {
    All,
    Left,
    Right,
}

fn miniature(theme: &Theme, corners: Corners) -> AnyElement {
    let line = theme.text.opacity(0.22);
    let strong = theme.text.opacity(0.34);
    let r = px(widgets::OPTION_CARD_RADIUS);
    let root = div().size_full().flex().flex_row().bg(theme.surface);
    let root = match corners {
        Corners::All => root.rounded(r),
        Corners::Left => root.rounded_tl(r).rounded_bl(r),
        Corners::Right => root.rounded_tr(r).rounded_br(r),
    };
    root.child(
        div()
            .w(px(44.0))
            .h_full()
            .flex_none()
            .overflow_hidden()
            .flex()
            .flex_col()
            .gap(px(7.0))
            .px(px(8.0))
            .pt(px(14.0))
            .child(bar(0.70, strong))
            .child(bar(1.0, line))
            .child(bar(0.85, line))
            .child(bar(1.0, line)),
    )
    .child(
        div()
            .flex_1()
            .min_w_0()
            .my(px(8.0))
            .mr(px(8.0))
            .rounded(px(6.0))
            .border_1()
            .border_color(theme.border)
            .bg(theme.bg)
            .overflow_hidden()
            .flex()
            .flex_col()
            .gap(px(7.0))
            .p(px(10.0))
            .child(bar(0.62, strong))
            .child(bar(0.88, line))
            .child(bar(0.76, line))
            .child(bar(0.52, line)),
    )
    .into_any_element()
}

fn miniature_split(
    themes: &ThemeSelection,
    accent: AccentSelection,
    surface: SurfacePreference,
) -> AnyElement {
    let light = Theme::for_selection(Appearance::Light, &themes.light, accent, surface);
    let dark = Theme::for_selection(Appearance::Dark, &themes.dark, accent, surface);
    div()
        .size_full()
        .flex()
        .flex_row()
        .child(
            div()
                .w_1_2()
                .h_full()
                .overflow_hidden()
                .child(miniature(&light, Corners::Left)),
        )
        .child(
            div()
                .w_1_2()
                .h_full()
                .overflow_hidden()
                .child(miniature(&dark, Corners::Right)),
        )
        .into_any_element()
}

fn preview(
    mode: AppearanceMode,
    themes: &ThemeSelection,
    accent: AccentSelection,
    surface: SurfacePreference,
) -> AnyElement {
    match mode {
        AppearanceMode::System => miniature_split(themes, accent, surface),
        AppearanceMode::Light => miniature(
            &Theme::for_selection(Appearance::Light, &themes.light, accent, surface),
            Corners::All,
        ),
        AppearanceMode::Dark => miniature(
            &Theme::for_selection(Appearance::Dark, &themes.dark, accent, surface),
            Corners::All,
        ),
    }
}

fn model_appearance(appearance: Appearance) -> zeron_theme::Appearance {
    match appearance {
        Appearance::Dark => zeron_theme::Appearance::Dark,
        Appearance::Light => zeron_theme::Appearance::Light,
    }
}

fn palette_preview(theme: &Theme) -> gpui::Div {
    div()
        .flex_none()
        .w(px(30.0))
        .h(px(18.0))
        .rounded(px(5.0))
        .overflow_hidden()
        .border_1()
        .border_color(theme.border)
        .flex()
        .child(div().w_1_3().h_full().bg(theme.surface))
        .child(div().w_1_3().h_full().bg(theme.bg))
        .child(div().w_1_3().h_full().bg(theme.accent))
}

fn compact_action(
    theme: &Theme,
    label: &str,
    id: impl Into<SharedString>,
) -> gpui::Stateful<gpui::Div> {
    let id = id.into();
    popover::btn_ghost(theme, label, id.clone()).id(id)
}

fn import_scene_preview(variant: &zeron_theme::ThemeVariant) -> AnyElement {
    let theme = Theme::from_variant(
        variant,
        AccentSelection::ThemeDefault,
        SurfacePreference::ThemeDefault,
    );
    div()
        .w_full()
        .h(px(86.0))
        .flex()
        .gap(px(8.0))
        .child(
            div()
                .w(px(152.0))
                .h_full()
                .overflow_hidden()
                .rounded(px(8.0))
                .border_1()
                .border_color(theme.border)
                .child(miniature(&theme, Corners::All)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .h_full()
                .rounded(px(8.0))
                .border_1()
                .border_color(theme.border)
                .bg(theme.bg)
                .p(px(9.0))
                .flex()
                .flex_col()
                .gap(px(6.0))
                .child(
                    div()
                        .text_size(px(10.0))
                        .font_family(theme.font_mono.clone())
                        .child(
                            div()
                                .text_color(theme.syntax.keyword)
                                .child("fn ")
                                .child(div().text_color(theme.syntax.function).child("preview"))
                                .child(div().text_color(theme.syntax.punctuation).child("() {")),
                        ),
                )
                .child(
                    div()
                        .text_size(px(10.0))
                        .font_family(theme.font_mono.clone())
                        .text_color(theme.syntax.string)
                        .child("  \"Theme mapping\""),
                )
                .child(
                    div()
                        .mt_auto()
                        .h(px(12.0))
                        .flex()
                        .rounded(px(3.0))
                        .overflow_hidden()
                        .children(
                            theme
                                .terminal
                                .ansi
                                .iter()
                                .take(8)
                                .map(|color| div().flex_1().h_full().bg(*color)),
                        ),
                ),
        )
        .child(
            div()
                .w(px(84.0))
                .h_full()
                .rounded(px(8.0))
                .border_1()
                .border_color(theme.border)
                .bg(theme.surface)
                .p(px(8.0))
                .flex()
                .flex_col()
                .gap(px(6.0))
                .child(
                    div()
                        .h(px(12.0))
                        .rounded(px(3.0))
                        .bg(theme.diff_add.opacity(0.35)),
                )
                .child(
                    div()
                        .h(px(12.0))
                        .rounded(px(3.0))
                        .bg(theme.diff_del.opacity(0.35)),
                )
                .child(div().h(px(12.0)).rounded(px(3.0)).bg(theme.accent_wash)),
        )
        .into_any_element()
}

fn report_panel(theme: &Theme, report: &ImportReport) -> gpui::Stateful<gpui::Div> {
    let summary = format!(
        "{} mapped · {} adjusted · {} inferred/fallback · {} unsupported · {} warnings · {} validation",
        report.mappings.len(),
        report.adjustments.len(),
        report.fallbacks.len(),
        report.dropped.len(),
        report.warnings.len(),
        report.validation.len(),
    );
    div()
        .id(SharedString::from(format!(
            "theme-report-{}",
            report.source_hash
        )))
        .mt(px(8.0))
        .w_full()
        .max_h(px(168.0))
        .overflow_y_scroll()
        .rounded(px(8.0))
        .border_1()
        .border_color(theme.border)
        .bg(theme.surface_raised.opacity(0.35))
        .p(px(10.0))
        .text_size(px(11.0))
        .line_height(px(16.0))
        .text_color(theme.text_muted)
        .child(div().text_color(theme.text).child(summary))
        .children(report.adjustments.iter().map(|adjustment| {
            div().mt(px(4.0)).child(SharedString::from(format!(
                "Adjusted · {} {} → {} · {}",
                adjustment.zeron_role, adjustment.original, adjustment.resolved, adjustment.reason
            )))
        }))
        .children(report.fallbacks.iter().map(|message| {
            div()
                .mt(px(4.0))
                .child(SharedString::from(format!("Fallback · {message}")))
        }))
        .children(report.warnings.iter().map(|message| {
            div()
                .mt(px(4.0))
                .child(SharedString::from(format!("Warning · {message}")))
        }))
        .children(report.validation.iter().map(|issue| {
            div().mt(px(4.0)).child(SharedString::from(format!(
                "Validation {:?} {:?} · {}",
                issue.category, issue.severity, issue.message
            )))
        }))
        .children(report.dropped.iter().map(|message| {
            div()
                .mt(px(4.0))
                .child(SharedString::from(format!("Unsupported · {message}")))
        }))
        .children(report.mappings.iter().map(|mapping| {
            div().mt(px(4.0)).child(SharedString::from(format!(
                "{} ← {}",
                mapping.zeron_role, mapping.vscode_key
            )))
        }))
}

fn accent_swatch(
    page_theme: &Theme,
    selection: AccentSelection,
    selected: bool,
) -> gpui::Stateful<gpui::Div> {
    let swatch_theme = Theme::for_selection(
        page_theme.appearance,
        page_theme.variant_id.as_ref(),
        selection,
        page_theme.surface_preference,
    );
    let sample = match selection {
        AccentSelection::ThemeDefault => div()
            .size_full()
            .rounded(px(6.0))
            .bg(swatch_theme.accent_wash)
            .flex()
            .items_center()
            .justify_center()
            .gap(px(2.0))
            .child(
                div()
                    .w(px(4.0))
                    .h(px(13.0))
                    .rounded(px(2.0))
                    .bg(swatch_theme.glyph.light),
            )
            .child(
                div()
                    .w(px(4.0))
                    .h(px(16.0))
                    .rounded(px(2.0))
                    .bg(swatch_theme.glyph.mid),
            )
            .child(
                div()
                    .w(px(4.0))
                    .h(px(11.0))
                    .rounded(px(2.0))
                    .bg(swatch_theme.glyph.deep),
            ),
        AccentSelection::Preset(_) => div().size_full().rounded(px(6.0)).bg(swatch_theme.accent),
    };
    div()
        .id(SharedString::from(format!("accent-{}", selection.label())))
        .flex_none()
        .w(px(30.0))
        .h(px(34.0))
        .pb(px(4.0))
        .border_b_2()
        .border_color(if selected {
            swatch_theme.accent
        } else {
            gpui::transparent_black()
        })
        .cursor_pointer()
        .child(
            div()
                .size(px(30.0))
                .p(px(2.0))
                .rounded(px(8.0))
                .border_1()
                .border_color(if selected {
                    page_theme.border_strong
                } else {
                    page_theme.border
                })
                .bg(page_theme.surface_raised.opacity(0.42))
                .child(sample),
        )
}

impl AppearancePage {
    fn theme_menu(&self, appearance: Appearance) -> &Popup<()> {
        match appearance {
            Appearance::Light => &self.light_theme_menu,
            Appearance::Dark => &self.dark_theme_menu,
        }
    }

    fn theme_menu_mut(&mut self, appearance: Appearance) -> &mut Popup<()> {
        match appearance {
            Appearance::Light => &mut self.light_theme_menu,
            Appearance::Dark => &mut self.dark_theme_menu,
        }
    }

    fn close_theme_menu(&mut self, appearance: Appearance, cx: &mut Context<Self>) {
        if !self.theme_menu_mut(appearance).begin_close() {
            return;
        }
        match appearance {
            Appearance::Light => popover::reap_popup(cx, |page| &mut page.light_theme_menu),
            Appearance::Dark => popover::reap_popup(cx, |page| &mut page.dark_theme_menu),
        }
    }

    fn render_theme_selector(
        &mut self,
        appearance_kind: Appearance,
        selections: &ThemeSelection,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let registry = ThemeRegistry::active();
        let selected_id = selections
            .variant_id(model_appearance(appearance_kind))
            .to_owned();
        let selected_variant = registry
            .variant(&selected_id)
            .or_else(|| {
                registry
                    .variants_for(model_appearance(appearance_kind))
                    .next()
            })
            .expect("the built-in registry has both appearances");
        let selected_theme = Theme::for_selection(
            appearance_kind,
            &selected_variant.id,
            AccentSelection::ThemeDefault,
            theme.surface_preference,
        );
        let open = self.theme_menu(appearance_kind).is_open();

        let mut trigger = div()
            .id(SharedString::from(format!(
                "{}-theme-selector",
                if appearance_kind.is_light() {
                    "light"
                } else {
                    "dark"
                }
            )))
            .relative()
            .flex_none()
            .w(px(218.0))
            .h(px(34.0))
            .px(px(10.0))
            .rounded(px(8.0))
            .border_1()
            .border_color(if open {
                theme.border_strong
            } else {
                theme.border
            })
            .bg(theme.surface_raised.opacity(if open { 0.75 } else { 0.42 }))
            .flex()
            .items_center()
            .gap(px(8.0))
            .cursor_pointer()
            .when(!open, |el| {
                el.hover(|style| style.bg(theme.surface_raised_hover))
            })
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(move |this, _, _, _| {
                    this.theme_menu_mut(appearance_kind).note_trigger_press();
                }),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                if this.theme_menu_mut(appearance_kind).take_press_was_open() {
                    this.close_theme_menu(appearance_kind, cx);
                } else {
                    let other = if appearance_kind.is_light() {
                        Appearance::Dark
                    } else {
                        Appearance::Light
                    };
                    this.close_theme_menu(other, cx);
                    this.theme_menu_mut(appearance_kind).open(());
                }
                cx.notify();
            }))
            .child(palette_preview(&selected_theme))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(px(12.5))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(theme.text)
                    .child(SharedString::from(selected_variant.name.clone())),
            )
            .child(
                icons::icon(icons::SORT_VERTICAL)
                    .size(px(14.0))
                    .text_color(theme.text_muted.opacity(if open { 0.9 } else { 0.45 })),
            );

        if self.theme_menu(appearance_kind).get().is_some() {
            let closing = self.theme_menu(appearance_kind).closing_since();
            let heading = if appearance_kind.is_light() {
                "Light themes"
            } else {
                "Dark themes"
            };
            let menu = popover::popover_card(theme)
                .w(px(260.0))
                .on_mouse_down_out(cx.listener(move |this, _, _, cx| {
                    this.close_theme_menu(appearance_kind, cx);
                    cx.notify();
                }))
                .flex()
                .flex_col()
                .gap(px(2.0))
                .child(popover::menu_heading(theme, heading))
                .children(
                    registry
                        .variants_for(model_appearance(appearance_kind))
                        .enumerate()
                        .map(|(index, variant)| {
                            let id = variant.id.clone();
                            let name = variant.name.clone();
                            let active = id == selected_id;
                            let sample = Theme::for_selection(
                                appearance_kind,
                                &id,
                                AccentSelection::ThemeDefault,
                                theme.surface_preference,
                            );
                            popover::menu_row(
                                theme,
                                active,
                                SharedString::from(format!(
                                    "appearance-theme-menu-{appearance_kind:?}-{index}"
                                )),
                            )
                            .id(SharedString::from(format!(
                                "appearance-theme-row-{appearance_kind:?}-{index}"
                            )))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                appearance::set_theme(appearance_kind, id.clone(), cx);
                                this.close_theme_menu(appearance_kind, cx);
                                cx.notify();
                            }))
                            .child(palette_preview(&sample))
                            .child(div().flex_1().min_w_0().truncate().child(name))
                            .when(active, |row| {
                                row.child(
                                    icons::icon(icons::CHECK)
                                        .size(px(14.0))
                                        .text_color(theme.accent),
                                )
                            })
                        }),
                )
                .into_any_element();
            trigger = trigger.child(popover::anchored_menu_below(
                SharedString::from(format!(
                    "appearance-{}-theme-menu",
                    if appearance_kind.is_light() {
                        "light"
                    } else {
                        "dark"
                    }
                )),
                menu,
                closing,
            ));
        }

        trigger.into_any_element()
    }

    fn render_import_dialog(
        &mut self,
        viewport: gpui::Size<gpui::Pixels>,
        theme: &Theme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        {
            let dialog = self.import_dialog.as_mut()?;
            if std::mem::take(&mut dialog.focus_pending) {
                let input_focus = dialog.input.focus_handle(cx);
                window.focus(&input_focus, cx);
            }
        }
        let dialog = self.import_dialog.as_ref()?;
        let input = dialog.input.clone();
        let focus = dialog.focus.clone();
        let mode = dialog.mode;
        let compilation = dialog.compilation.clone();
        let selected = dialog.selected.clone();
        let review_variant = dialog.review_variant.clone();
        let error = dialog.error.clone();
        let ready = compilation.is_some() && !selected.is_empty();
        let card_radius = 14.0;
        let hairline = crate::theme::hairline(0.06);
        let band = popover::band();

        let mode_control = |label: &'static str, description: &'static str, value: InstallMode| {
            let active = mode == value;
            popover::menu_row(
                theme,
                active,
                SharedString::from(format!("theme-import-mode-hover-{}", slug(label))),
            )
            .id(SharedString::from(format!(
                "theme-import-mode-{}",
                slug(label)
            )))
            .on_click(cx.listener(move |this, _, _, cx| {
                if let Some(dialog) = this.import_dialog.as_mut() {
                    dialog.mode = value;
                }
                cx.notify();
            }))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(if active { theme.text } else { theme.text_muted })
                            .child(label),
                    )
                    .child(
                        div()
                            .mt(px(1.0))
                            .text_size(px(10.5))
                            .text_color(theme.text_muted.opacity(0.55))
                            .child(description),
                    ),
            )
            .when(active, |row| {
                row.child(
                    icons::icon(icons::CHECK)
                        .size(px(13.0))
                        .flex_none()
                        .text_color(theme.accent),
                )
            })
        };

        let action_label = if compilation.is_some() {
            "Import selected"
        } else {
            "Analyze"
        };
        let action = popover::btn_primary(theme, "")
            .id("theme-import-action")
            .h(px(24.0))
            .px(px(8.0))
            .py(px(0.0))
            .rounded(px(5.0))
            .flex_none()
            .flex()
            .items_center()
            .gap(px(5.0))
            .text_size(px(12.0))
            .when(compilation.is_some() && !ready, |button| {
                button.opacity(0.45)
            })
            .when(compilation.is_none() || ready, |button| {
                button.on_click(cx.listener(move |this, _, _, cx| {
                    if this
                        .import_dialog
                        .as_ref()
                        .is_some_and(|dialog| dialog.compilation.is_some())
                    {
                        this.finish_import(cx);
                    } else {
                        this.compile_import(cx);
                    }
                }))
            })
            .child(
                icons::icon(icons::RETURN)
                    .size(px(11.0))
                    .text_color(theme.on_solid.opacity(0.8)),
            )
            .child(action_label);

        let header = div()
            .h(px(48.0))
            .flex_none()
            .rounded_t(px(card_radius))
            .pl(px(12.0))
            .pr(px(10.0))
            .flex()
            .items_center()
            .gap(px(10.0))
            .bg(band)
            .border_b_1()
            .border_color(hairline)
            .child(
                popover::key_cap(theme).child(
                    icons::icon(icons::DOCUMENT_ADD)
                        .size(px(13.0))
                        .text_color(theme.text_muted.opacity(0.75)),
                ),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .text_size(px(14.0))
                    .child(input.into_any_element()),
            )
            .child(
                popover::btn_ghost(theme, "Browse", "theme-import-browse")
                    .id("theme-import-browse")
                    .h(px(24.0))
                    .px(px(8.0))
                    .py(px(0.0))
                    .rounded(px(5.0))
                    .flex_none()
                    .on_click(cx.listener(|this, _, _, cx| this.choose_import_source(cx))),
            )
            .child(action)
            .child(
                popover::key_cap(theme)
                    .id("theme-import-esc")
                    .cursor_pointer()
                    .hover(|style| style.bg(crate::theme::ink(0.09)))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.import_dialog = None;
                        cx.notify();
                    }))
                    .text_size(px(11.0))
                    .font_family(theme.font_mono.clone())
                    .text_color(theme.text_muted.opacity(0.7))
                    .child("esc"),
            );

        let mut main = div()
            .id("theme-import-main")
            .flex_1()
            .min_w_0()
            .h_full()
            .overflow_y_scroll()
            .px(px(8.0))
            .py(px(8.0))
            .flex()
            .flex_col()
            .gap(px(3.0));

        if let Some(ref compilation) = compilation {
            main = main
                .child(popover::menu_heading(theme, "Detected variants"))
                .child(
                    div()
                        .px(px(8.0))
                        .pb(px(5.0))
                        .text_size(px(11.0))
                        .text_color(theme.text_muted.opacity(0.6))
                        .child(SharedString::from(format!(
                            "{} · Select the variants to keep",
                            compilation.family.name
                        ))),
                );
            for variant in &compilation.family.variants {
                let variant_id = variant.id.clone();
                let selected_now = selected.contains(&variant_id);
                let review_open = review_variant.as_deref() == Some(variant_id.as_str());
                let appearance = if variant.appearance.is_dark() {
                    "Dark"
                } else {
                    "Light"
                };
                let report = compilation.reports.get(&variant.id);
                let sample = Theme::from_variant(
                    variant,
                    AccentSelection::ThemeDefault,
                    SurfacePreference::ThemeDefault,
                );
                main = main.child(
                    popover::menu_row(
                        theme,
                        selected_now,
                        SharedString::from(format!("theme-import-row-hover-{variant_id}")),
                    )
                    .id(SharedString::from(format!("theme-import-row-{variant_id}")))
                    .flex_col()
                    .items_stretch()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(9.0))
                            .child(
                                div()
                                    .id(SharedString::from(format!(
                                        "theme-import-select-{variant_id}"
                                    )))
                                    .size(px(18.0))
                                    .rounded(px(5.0))
                                    .border_1()
                                    .border_color(if selected_now {
                                        theme.accent
                                    } else {
                                        theme.border_strong
                                    })
                                    .bg(if selected_now { theme.accent } else { theme.bg })
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .cursor_pointer()
                                    .when(selected_now, |item| {
                                        item.child(
                                            icons::icon(icons::CHECK)
                                                .size(px(12.0))
                                                .text_color(theme.on_accent),
                                        )
                                    })
                                    .on_click(cx.listener({
                                        let variant_id = variant_id.clone();
                                        move |this, _, _, cx| {
                                            if let Some(dialog) = this.import_dialog.as_mut() {
                                                if !dialog.selected.remove(&variant_id) {
                                                    dialog.selected.insert(variant_id.clone());
                                                }
                                            }
                                            cx.notify();
                                        }
                                    })),
                            )
                            .child(palette_preview(&sample))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .child(
                                        div()
                                            .text_size(px(12.5))
                                            .font_weight(gpui::FontWeight::MEDIUM)
                                            .text_color(theme.text)
                                            .child(SharedString::from(variant.name.clone())),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(11.0))
                                            .text_color(theme.text_muted.opacity(0.65))
                                            .child(appearance),
                                    ),
                            )
                            .child(
                                compact_action(
                                    theme,
                                    if review_open {
                                        "Hide mapping"
                                    } else {
                                        "Review mapping"
                                    },
                                    format!("theme-import-review-{variant_id}"),
                                )
                                .on_click(cx.listener({
                                    let variant_id = variant_id.clone();
                                    move |this, _, _, cx| {
                                        if let Some(dialog) = this.import_dialog.as_mut() {
                                            dialog.review_variant =
                                                if dialog.review_variant.as_deref()
                                                    == Some(variant_id.as_str())
                                                {
                                                    None
                                                } else {
                                                    Some(variant_id.clone())
                                                };
                                        }
                                        cx.notify();
                                    }
                                })),
                            ),
                    )
                    .when(review_open, |row| {
                        row.child(
                            div()
                                .mt(px(8.0))
                                .pt(px(8.0))
                                .border_t_1()
                                .border_color(hairline)
                                .child(import_scene_preview(variant)),
                        )
                        .when_some(report, |row, report| row.child(report_panel(theme, report)))
                    }),
                );
            }
            for failure in &compilation.failures {
                main = main.child(
                    div()
                        .px(px(8.0))
                        .py(px(5.0))
                        .text_size(px(11.0))
                        .text_color(theme.warning)
                        .child(SharedString::from(format!(
                            "{} could not be compiled · {}",
                            failure.name, failure.message
                        ))),
                );
            }
        } else {
            main = main
                .child(popover::menu_heading(theme, "Add a theme"))
                .child(
                    popover::menu_row(theme, false, "theme-import-local-source-hover")
                        .id("theme-import-local-source")
                        .on_click(cx.listener(|this, _, _, cx| this.choose_import_source(cx)))
                        .child(
                            icons::icon(icons::FOLDER_WITH_FILES)
                                .size(px(15.0))
                                .flex_none()
                                .text_color(theme.text_muted.opacity(0.8)),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .child(
                                    div()
                                        .text_size(px(12.5))
                                        .text_color(theme.text)
                                        .child("Choose a local source"),
                                )
                                .child(
                                    div()
                                        .mt(px(1.0))
                                        .text_size(px(10.5))
                                        .text_color(theme.text_muted.opacity(0.55))
                                        .child("Theme file, package.json, or extension folder"),
                                ),
                        )
                        .child(popover::kbd_hint(theme, "Browse")),
                )
                .child(
                    div()
                        .mx(px(8.0))
                        .mt(px(7.0))
                        .pt(px(10.0))
                        .border_t_1()
                        .border_color(hairline)
                        .text_size(px(11.0))
                        .line_height(px(16.0))
                        .text_color(theme.text_muted.opacity(0.55))
                        .child(
                            "Zeron detects light and dark variants, maps the palette, and validates contrast before import.",
                        ),
                );
        }

        let rail = div()
            .w(px(196.0))
            .flex_none()
            .h_full()
            .border_l_1()
            .border_color(hairline)
            .px(px(8.0))
            .py(px(8.0))
            .flex()
            .flex_col()
            .gap(px(3.0))
            .child(popover::menu_heading(theme, "Import mode"))
            .child(mode_control(
                "Import snapshot",
                "Keep a self-contained copy",
                InstallMode::Snapshot,
            ))
            .child(mode_control(
                "Link source",
                "Reload changes from disk",
                InstallMode::Link,
            ))
            .child(div().h(px(1.0)).mx(px(2.0)).my(px(7.0)).bg(hairline))
            .child(
                div()
                    .px(px(8.0))
                    .flex()
                    .items_start()
                    .gap(px(6.0))
                    .text_size(px(10.5))
                    .line_height(px(15.0))
                    .text_color(theme.text_muted.opacity(0.5))
                    .child(
                        icons::icon(icons::INFO_CIRCLE)
                            .size(px(12.0))
                            .flex_none()
                            .mt(px(1.0)),
                    )
                    .child("Theme tokens are compiled into Zeron roles."),
            );

        let body = div()
            .h(px(if compilation.is_some() { 460.0 } else { 250.0 }))
            .flex()
            .items_stretch()
            .child(main)
            .child(rail);

        let footer = div()
            .flex_none()
            .rounded_b(px(card_radius))
            .bg(band)
            .border_t_1()
            .border_color(hairline)
            .px(px(12.0))
            .py(px(8.0))
            .flex()
            .items_center()
            .gap(px(12.0))
            .child(popover::key_hint(
                theme,
                icons::RETURN,
                if compilation.is_some() {
                    "Import selected"
                } else {
                    "Analyze"
                },
            ))
            .child(popover::key_hint_text(theme, "esc", "Close"))
            .when_some(error, |footer, error| {
                footer.child(
                    div()
                        .ml_auto()
                        .min_w_0()
                        .truncate()
                        .text_size(px(11.0))
                        .text_color(theme.danger)
                        .child(error),
                )
            });

        let card = popover::palette_card(theme, px(680.0), card_radius)
            .id("theme-import-card")
            .track_focus(&focus)
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                match popover::classify_key(
                    event.keystroke.key.as_str(),
                    event.keystroke.modifiers.platform,
                    event.keystroke.modifiers.control,
                ) {
                    popover::MenuKey::Escape => {
                        this.import_dialog = None;
                        cx.notify();
                    }
                    popover::MenuKey::Enter | popover::MenuKey::ModEnter => {
                        if this
                            .import_dialog
                            .as_ref()
                            .is_some_and(|dialog| dialog.compilation.is_some())
                        {
                            this.finish_import(cx);
                        } else {
                            this.compile_import(cx);
                        }
                    }
                    _ => {}
                }
            }))
            .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                this.import_dialog = None;
                cx.notify();
            }))
            .child(header)
            .child(body)
            .child(footer)
            .into_any_element();

        Some(popover::modal_glass(
            "theme-import-dialog",
            viewport,
            card,
            card_radius,
        ))
    }

    fn render_review_dialog(
        &mut self,
        viewport: gpui::Size<gpui::Pixels>,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let entry_id = self.review_entry.as_ref()?;
        let entry = theme_library::entries(cx)
            .into_iter()
            .find(|entry| &entry.id == entry_id)?;
        let mut card = popover::dialog_card(theme)
            .id("theme-review-card")
            .w(px(660.0))
            .max_h(px(720.0))
            .overflow_y_scroll()
            .child(popover::dialog_title(theme, "Theme mapping"))
            .child(
                popover::dialog_body(theme, format!("{} · {}", entry.name, entry.source.label()))
                    .mt(px(6.0)),
            );
        for variant in &entry.family.variants {
            card = card
                .child(
                    div()
                        .mt(px(14.0))
                        .text_size(px(12.5))
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .child(SharedString::from(variant.name.clone())),
                )
                .child(import_scene_preview(variant));
            if let Some(report) = entry.reports.get(&variant.id) {
                card = card.child(report_panel(theme, report));
            }
        }
        card = card.child(
            div().mt(px(16.0)).flex().justify_end().child(
                popover::btn_primary(theme, "Done")
                    .id("theme-review-close")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.review_entry = None;
                        cx.notify();
                    })),
            ),
        );
        Some(popover::modal(
            "theme-review-dialog",
            viewport,
            card.into_any_element(),
        ))
    }

    fn render_library_entry(
        &mut self,
        entry: CustomThemeEntry,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = entry.id.clone();
        let linked = entry.source.is_linked();
        let source = entry
            .source
            .path()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|| "Self-contained snapshot".into());
        let status = match &entry.status {
            CustomThemeStatus::Ready => format!(
                "{} · {} variant{} · {}",
                entry.source.label(),
                entry.family.variants.len(),
                if entry.family.variants.len() == 1 {
                    ""
                } else {
                    "s"
                },
                source
            ),
            CustomThemeStatus::Warning { message } => {
                format!("Using last known good · {message}")
            }
        };
        widgets::card_row(theme, false)
            .child(widgets::row_tile(
                theme,
                if linked {
                    icons::GLOBAL
                } else {
                    icons::DOCUMENT
                },
            ))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(widgets::row_title(theme, &entry.name))
                    .child(
                        div()
                            .truncate()
                            .text_size(px(11.0))
                            .text_color(
                                if matches!(entry.status, CustomThemeStatus::Warning { .. }) {
                                    theme.warning
                                } else {
                                    theme.text_muted
                                },
                            )
                            .child(SharedString::from(status)),
                    ),
            )
            .child(
                div()
                    .flex_none()
                    .flex()
                    .items_center()
                    .gap(px(2.0))
                    .when(linked, |actions| {
                        actions.child(
                            compact_action(theme, "Reload", format!("theme-reload-{id}")).on_click(
                                cx.listener({
                                    let id = id.clone();
                                    move |_, _, _, cx| {
                                        let _ = theme_library::reload(&id, cx);
                                        cx.notify();
                                    }
                                }),
                            ),
                        )
                    })
                    .child(
                        compact_action(theme, "Reveal", format!("theme-reveal-{id}")).on_click(
                            cx.listener({
                                let id = id.clone();
                                move |this, _, _, cx| {
                                    if let Err(error) = theme_library::reveal(&id, cx) {
                                        this.library_error = Some(error.to_string().into());
                                    }
                                    cx.notify();
                                }
                            }),
                        ),
                    )
                    .child(
                        compact_action(theme, "Review", format!("theme-review-{id}")).on_click(
                            cx.listener({
                                let id = id.clone();
                                move |this, _, _, cx| {
                                    this.review_entry = Some(id.clone());
                                    cx.notify();
                                }
                            }),
                        ),
                    )
                    .child(
                        compact_action(
                            theme,
                            "Duplicate as editable",
                            format!("theme-duplicate-{id}"),
                        )
                        .on_click(cx.listener({
                            let id = id.clone();
                            move |this, _, _, cx| {
                                if let Err(error) = theme_library::duplicate_as_editable(&id, cx) {
                                    this.library_error = Some(error.to_string().into());
                                }
                                cx.notify();
                            }
                        })),
                    )
                    .when(linked, |actions| {
                        actions.child(
                            compact_action(theme, "Unlink", format!("theme-unlink-{id}")).on_click(
                                cx.listener({
                                    let id = id.clone();
                                    move |this, _, _, cx| {
                                        if let Err(error) = theme_library::unlink(&id, cx) {
                                            this.library_error = Some(error.to_string().into());
                                        }
                                        cx.notify();
                                    }
                                }),
                            ),
                        )
                    })
                    .child(
                        compact_action(theme, "Remove", format!("theme-remove-{id}"))
                            .text_color(theme.danger)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Err(error) = theme_library::remove(&id, cx) {
                                    this.library_error = Some(error.to_string().into());
                                }
                                cx.notify();
                            })),
                    ),
            )
            .into_any_element()
    }

    fn render_theme_library_rows(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let entries = theme_library::entries(cx);
        let (linked, imported): (Vec<_>, Vec<_>) = entries
            .into_iter()
            .partition(|entry| entry.source.is_linked());
        let mut rows = vec![
            widgets::card_row(theme, false)
                .child(widgets::row_tile(theme, icons::FOLDER_WITH_FILES))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .child(widgets::row_title(theme, "Theme library"))
                        .child(widgets::meta_line(
                            theme,
                            vec![
                                div()
                                    .child("Import or link custom themes.")
                                    .into_any_element(),
                            ],
                        )),
                )
                .child(
                    popover::btn_primary(theme, "Add theme")
                        .id("theme-library-add")
                        .on_click(cx.listener(|this, _, _, cx| this.open_import(cx))),
                )
                .into_any_element(),
        ];
        if !imported.is_empty() {
            rows.push(
                div()
                    .px(px(16.0))
                    .pt(px(12.0))
                    .pb(px(4.0))
                    .border_t_1()
                    .border_color(theme.border)
                    .text_size(px(10.5))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(theme.text_faint)
                    .child("IMPORTED")
                    .into_any_element(),
            );
            rows.extend(
                imported
                    .into_iter()
                    .map(|entry| self.render_library_entry(entry, theme, cx)),
            );
        }
        if !linked.is_empty() {
            rows.push(
                div()
                    .px(px(16.0))
                    .pt(px(12.0))
                    .pb(px(4.0))
                    .border_t_1()
                    .border_color(theme.border)
                    .text_size(px(10.5))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(theme.text_faint)
                    .child("LINKED")
                    .into_any_element(),
            );
            rows.extend(
                linked
                    .into_iter()
                    .map(|entry| self.render_library_entry(entry, theme, cx)),
            );
        }
        rows
    }
}

impl Render for AppearancePage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let current_mode = appearance::mode(cx);
        let current_themes = appearance::themes(cx);
        let current_accent = appearance::accent(cx);
        let current_surface = appearance::surface(cx);
        let cards = AppearanceMode::ALL
            .into_iter()
            .map(|mode| {
                widgets::option_card(
                    &theme,
                    mode.label(),
                    mode == current_mode,
                    preview(mode, &current_themes, current_accent, current_surface),
                )
                .id(SharedString::from(format!("appearance-{}", mode.label())))
                .on_click(cx.listener(move |_, _, _, cx| {
                    appearance::set_mode(mode, cx);
                    cx.notify();
                }))
            })
            .collect::<Vec<_>>();

        let mut theme_rows = Vec::new();
        for (index, appearance_kind) in [Appearance::Light, Appearance::Dark]
            .into_iter()
            .enumerate()
        {
            let label = if appearance_kind.is_light() {
                "Light theme"
            } else {
                "Dark theme"
            };
            let selector = self.render_theme_selector(appearance_kind, &current_themes, &theme, cx);
            theme_rows.push(
                widgets::card_row(&theme, index == 0)
                    .child(widgets::row_tile(&theme, icons::TUNING))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(widgets::row_title(&theme, label))
                            .child(widgets::meta_line(
                                &theme,
                                vec![
                                    div()
                                        .child(SharedString::from(
                                            "Used whenever this appearance is active.",
                                        ))
                                        .into_any_element(),
                                ],
                            )),
                    )
                    .child(selector)
                    .into_any_element(),
            );
        }

        let mut accent_choices = vec![AccentSelection::ThemeDefault];
        accent_choices.extend(AccentPreset::ALL.map(AccentSelection::Preset));
        let accent_controls = accent_choices
            .into_iter()
            .map(|selection| {
                let selected = selection == current_accent;
                accent_swatch(&theme, selection, selected).on_click(cx.listener(
                    move |_, _, _, cx| {
                        appearance::set_accent(selection, cx);
                        cx.notify();
                    },
                ))
            })
            .collect::<Vec<_>>();
        let surface_controls = SurfacePreference::ALL
            .into_iter()
            .map(|surface| {
                surface_choice(&theme, surface, surface == current_surface).on_click(cx.listener(
                    move |_, _, _, cx| {
                        appearance::set_surface(surface, cx);
                        cx.notify();
                    },
                ))
            })
            .collect::<Vec<_>>();
        let mut settings_rows = theme_rows;
        settings_rows.push(
            widgets::card_row(&theme, false)
                .child(widgets::row_tile(&theme, icons::TUNING))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .child(widgets::row_title(&theme, "Accent color"))
                        .child(widgets::meta_line(
                            &theme,
                            vec![
                                div()
                                    .child(SharedString::from(accent_helper(current_accent)))
                                    .into_any_element(),
                            ],
                        )),
                )
                .child(
                    div()
                        .flex_none()
                        .ml(px(10.0))
                        .flex()
                        .items_center()
                        .gap(px(6.0))
                        .children(accent_controls),
                )
                .into_any_element(),
        );
        settings_rows.push(
            widgets::card_row(&theme, false)
                .child(widgets::row_tile(&theme, icons::WIDGET))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .child(widgets::row_title(&theme, "Glass"))
                        .child(widgets::meta_line(
                            &theme,
                            vec![
                                div()
                                    .child(SharedString::from(surface_helper(
                                        current_surface,
                                        theme.surface_treatment,
                                    )))
                                    .into_any_element(),
                            ],
                        )),
                )
                .child(
                    div()
                        .flex_none()
                        .ml(px(10.0))
                        .flex()
                        .items_center()
                        .gap(px(6.0))
                        .children(surface_controls),
                )
                .into_any_element(),
        );
        settings_rows.extend(self.render_theme_library_rows(&theme, cx));
        let library_warning = self
            .library_error
            .clone()
            .or_else(|| theme_library::load_warning(cx).map(SharedString::from));
        let modal = self
            .render_import_dialog(window.viewport_size(), &theme, window, cx)
            .or_else(|| self.render_review_dialog(window.viewport_size(), &theme, cx));

        div()
            .id("appearance-page")
            .size_full()
            .overflow_y_scroll()
            .child(
                widgets::page_column()
                    .child(widgets::page_header(&theme, "Appearance", None))
                    .child(
                        widgets::page_subtitle(
                            &theme,
                            "Choose how Zeron looks. These settings stay on this device.",
                        )
                        .max_w(px(512.0))
                        .line_height(px(20.0)),
                    )
                    .child(
                        div()
                            .mt(px(32.0))
                            .flex()
                            .flex_col()
                            .gap(px(12.0))
                            .child(widgets::field_label(&theme, "Appearance"))
                            .child(widgets::option_card_row().children(cards)),
                    )
                    .child(widgets::section_card(&theme).children(settings_rows))
                    .when_some(library_warning, |page, warning| {
                        page.child(
                            div()
                                .mt(px(8.0))
                                .text_size(px(11.5))
                                .text_color(theme.warning)
                                .child(warning),
                        )
                    }),
            )
            .children(modal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_mode_gets_a_card() {
        assert_eq!(AppearanceMode::ALL.len(), 3);
        for mode in AppearanceMode::ALL {
            assert!(!mode.label().is_empty());
        }
    }

    #[test]
    fn registry_offers_both_appearances_and_keeps_single_dark_families_valid() {
        let registry = ThemeRegistry::builtin();
        assert_eq!(
            registry
                .variants_for(zeron_theme::Appearance::Light)
                .count(),
            10
        );
        assert_eq!(
            registry.variants_for(zeron_theme::Appearance::Dark).count(),
            20
        );
    }

    #[test]
    fn accent_helper_explains_default_and_override_scope() {
        assert!(accent_helper(AccentSelection::ThemeDefault).contains("intended"));
        let copy = accent_helper(AccentSelection::Preset(AccentPreset::Pink));
        assert!(copy.starts_with("Pink ·"));
        assert!(copy.contains("glyphs"));
    }

    #[test]
    fn surface_helper_explains_theme_default_and_global_overrides() {
        let default = surface_helper(SurfacePreference::ThemeDefault, SurfaceTreatment::Opaque);
        assert!(default.contains("opaque default"));
        assert!(
            surface_helper(SurfacePreference::Frosted, SurfaceTreatment::Opaque)
                .contains("where supported")
        );
        assert!(
            surface_helper(SurfacePreference::Opaque, SurfaceTreatment::Frosted)
                .contains("every theme")
        );
    }
}
