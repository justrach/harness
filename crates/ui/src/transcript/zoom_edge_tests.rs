use super::*;

#[gpui::test]
fn thinking_body_layout_matches_fold_height_for_edge_cases(cx: &mut gpui::TestAppContext) {
    let _selection = crate::markdown::selection::test_state_lock();
    struct Body {
        detail: ToolDetail,
        width: f32,
    }
    impl Render for Body {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            div()
                .w(px(self.width))
                .flex()
                .flex_col()
                .child(render::selection_frame_reset())
                .child(
                    div()
                        .debug_selector(|| "thinking-edge-body".into())
                        .flex_none()
                        .child(detail_body(
                            &self.detail,
                            None,
                            "thinking-edge",
                            None,
                            &Theme::of(cx).clone(),
                        )),
                )
        }
    }
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
    });
    let (body, cx) = cx.add_window_view(|_, _| Body {
        detail: ToolDetail::Thought {
            lines: vec![],
            truncated_by: 0,
        },
        width: 800.0,
    });
    cx.simulate_resize(size(px(1000.0), px(1000.0)));
    let plain = |text: &str| {
        vec![InlineRun {
            text: text.to_owned(),
            style: InlineStyle::default(),
        }]
    };
    let capped: Vec<_> = (0..OUTPUT_DETAIL_MAX_LINES)
        .map(|ix| plain(&format!("Synthetic thinking line {ix}")))
        .collect();
    let cases = [
        ("empty", vec![], 0),
        ("blank rows", vec![vec![], vec![], vec![]], 0),
        (
            "styled prose",
            thought_lines(&parse_full(
                "**Bold** *italic* `code` [link](https://example.com) ~~strike~~",
            )),
            0,
        ),
        (
            "Unicode and a long unwrapped line",
            vec![plain(&"café Ελληνικά 日本語 🚀 ".repeat(30))],
            0,
        ),
        ("maximum visible rows", capped.clone(), 0),
        ("maximum rows and counted tail", capped, 1000),
        ("blank row and counted tail", vec![vec![]], 1),
        ("counted tail without visible lines", vec![], 1),
    ];
    for (name, lines, truncated_by) in cases {
        let expected_text: Vec<_> = lines
            .iter()
            .enumerate()
            .filter_map(|(ix, line)| {
                let text: String = line.iter().map(|run| run.text.as_str()).collect();
                (!text.trim().is_empty()).then_some((ix, text))
            })
            .collect();
        body.update(cx, |body, _| {
            body.detail = ToolDetail::Thought {
                lines,
                truncated_by,
            };
        });
        for width in [140.0, 800.0] {
            body.update(cx, |body, _| body.width = width);
            for font_size in crate::typography::UiFontSize::ALL {
                let line_height = cx.update(|window, cx| {
                    window.set_rem_size(px(font_size.pixels()));
                    window.refresh();
                    window.draw(cx).clear();
                    window.pixel_snap(
                        crate::typography::ui_rems(OUTPUT_LINE_HEIGHT).to_pixels(window.rem_size()),
                    )
                });
                let expected = body.read_with(cx, |body, _| {
                    detail_height_with_thought_line_height(&body.detail, f32::from(line_height))
                        - DETAIL_SEPARATOR
                });
                let actual = f32::from(cx.debug_bounds("thinking-edge-body").unwrap().size.height);
                assert!(
                    (actual - expected).abs() <= 0.5,
                    "{name}, width {width}, size {}: rendered {actual} != fold body {expected}",
                    font_size.pixels()
                );
                for (ix, expected) in &expected_text {
                    let (actual, _, _) =
                        render::selection_test_snapshot(&format!("thinking-edge:{ix}"));
                    assert_eq!(
                        actual.as_ref(),
                        expected,
                        "{name}: zoom must preserve selectable text"
                    );
                }
            }
        }
    }
}

#[test]
fn thinking_streaming_and_settled_truncation_keep_the_correct_end() {
    let source = (0..40)
        .map(|ix| format!("Synthetic paragraph {ix}"))
        .collect::<Vec<_>>()
        .join("\n\n");
    let tree = parse_full(&source);
    for live in [false, true] {
        let tool = thought_item("thinking", &tree, live);
        let ToolDetail::Thought {
            lines,
            truncated_by,
        } = tool.detail.as_deref().unwrap()
        else {
            panic!("thinking must retain its detail");
        };
        assert!(lines.len() <= OUTPUT_DETAIL_MAX_LINES);
        assert!(*truncated_by > 0);
        assert_eq!(tool.resolved, !live);
        assert!(
            !lines.first().unwrap().is_empty(),
            "no orphan leading separator"
        );
        let text = lines
            .iter()
            .map(|line| line.iter().map(|run| run.text.as_str()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n");
        if live {
            assert!(text.contains("Synthetic paragraph 39"));
            assert!(!text.contains("Synthetic paragraph 0\n"));
        } else {
            assert!(text.starts_with("Synthetic paragraph 0\n"));
            assert!(!text.contains("Synthetic paragraph 39"));
        }
    }
}
