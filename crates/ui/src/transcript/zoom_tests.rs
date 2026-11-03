use super::*;

#[gpui::test]
fn thinking_text_matches_output_at_every_zoom_size(cx: &mut gpui::TestAppContext) {
    let _selection = crate::markdown::selection::test_state_lock();
    struct Thinking;
    impl Render for Thinking {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let theme = Theme::of(cx).clone();
            let tool = thought_item("thought", &parse_full("Synthetic thinking text"), false);
            let text: SharedString = "Synthetic thinking text".into();
            let probe = |key: &str| {
                render::selectable_text_element(
                    key.to_owned().into(),
                    text.clone(),
                    vec![TextRun {
                        len: text.len(),
                        font: gpui::font(theme.font_sans_fixed.clone()),
                        color: theme.text,
                        background_color: None,
                        underline: None,
                        strikethrough: None,
                    }],
                    theme.selection,
                )
            };
            div()
                .w(px(800.0))
                .font_family(theme.font_sans_fixed.clone())
                .flex()
                .flex_col()
                .child(render::selection_frame_reset())
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(render::MD_TEXT_SIZE))
                        .child(probe("zoom-reference")),
                )
                .child(
                    chip_header_row(
                        &tool,
                        None,
                        None,
                        PreviewPathAnchors::default(),
                        &theme,
                        cx.entity_id(),
                        cx,
                    )
                    .child(probe("zoom-header")),
                )
                .child(
                    div()
                        .debug_selector(|| "zoom-thought-body".into())
                        .child(detail_body(
                            tool.detail.as_deref().unwrap(),
                            None,
                            "zoom-thought",
                            None,
                            &theme,
                        )),
                )
        }
    }
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
    });
    let (_, cx) = cx.add_window_view(|_, _| Thinking);
    for size in crate::typography::UiFontSize::ALL {
        cx.update(|window, cx| {
            window.set_rem_size(px(size.pixels()));
            window.refresh();
            let _ = window.draw(cx);
        });
        let text_width = |key| {
            let (text, layout, _) = render::selection_test_snapshot(key);
            render::range_rects(&layout, &(0..text.len()), 0.0, 0.0)[0]
                .size
                .width
        };
        let reference = text_width("zoom-reference");
        for key in ["zoom-header", "zoom-thought:0"] {
            let actual = text_width(key);
            assert!(
                f32::from(actual - reference).abs() < 0.01,
                "{key} must match assistant output at {} px: {actual} != {reference}",
                size.pixels()
            );
        }
        let expected_height = OUTPUT_BODY_PAD + OUTPUT_LINE_HEIGHT * size.pixels() / 16.0;
        let actual_height = f32::from(cx.debug_bounds("zoom-thought-body").unwrap().size.height);
        // Layout snaps rem heights to the display's pixel grid.
        assert!(
            (actual_height - expected_height).abs() <= 0.5,
            "thinking rows must grow with the text: {actual_height} != {expected_height}"
        );
    }
}

#[test]
fn thinking_fold_height_scales_without_resizing_code_output() {
    let lines = thought_lines(&parse_full("First paragraph\n\nSecond paragraph"));
    let rows = lines.len() + 1; // The counted tail is a text row too.
    let thought = ToolDetail::Thought {
        lines,
        truncated_by: 3,
    };
    let output = ToolDetail::Output {
        lines: vec!["Synthetic command output".into()],
        truncated_by: 0,
    };
    for size in crate::typography::UiFontSize::ALL {
        let expected = DETAIL_SEPARATOR
            + OUTPUT_BODY_PAD
            + rows as f32 * OUTPUT_LINE_HEIGHT * size.pixels() / 16.0;
        assert_eq!(
            detail_height_with_ui_size(&thought, size.pixels()),
            expected
        );
        assert_eq!(
            detail_height_with_ui_size(&output, size.pixels()),
            detail_height(&output),
            "code output keeps its independent pixel size"
        );
    }
}
