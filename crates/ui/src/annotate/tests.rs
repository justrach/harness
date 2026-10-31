use super::*;

fn png(width: u32, height: u32, rgba: [u8; 4]) -> Vec<u8> {
    let img = image::RgbaImage::from_pixel(width, height, image::Rgba(rgba));
    let mut out = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut out, image::ImageFormat::Png)
        .unwrap();
    out.into_inner()
}

fn decode_png(bytes: &[u8]) -> image::RgbaImage {
    image::load_from_memory(bytes).unwrap().to_rgba8()
}

fn rect(x: f32, y: f32, w: f32, h: f32) -> ImageRect {
    ImageRect { x, y, w, h }
}

fn close(a: image::Rgba<u8>, rgb: u32, tolerance: i32) -> bool {
    let want = [(rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8];
    (0..3).all(|c| (a[c] as i32 - want[c] as i32).abs() <= tolerance)
}

#[test]
fn a_drag_normalizes_in_any_direction_and_clamps_to_the_image() {
    let size = (200.0, 100.0);
    assert_eq!(
        ImageRect::from_drag((150.0, 80.0), (50.0, 20.0), size),
        rect(50.0, 20.0, 100.0, 60.0)
    );
    assert_eq!(
        ImageRect::from_drag((-30.0, 50.0), (250.0, 140.0), size),
        rect(0.0, 50.0, 200.0, 50.0)
    );
}

#[test]
fn a_click_is_not_a_box() {
    let mut doc = Annotations::default();
    assert_eq!(
        doc.add_rect(rect(10.0, 10.0, 3.0, 40.0), MarkColor::Red),
        None
    );
    assert_eq!(
        doc.add_rect(rect(10.0, 10.0, 40.0, 0.0), MarkColor::Red),
        None
    );
    assert!(doc.is_empty());
    assert!(!doc.can_undo(), "a rejected box leaves no undo step");
    assert!(
        doc.add_rect(rect(10.0, 10.0, 4.0, 4.0), MarkColor::Red)
            .is_some()
    );
}

#[test]
fn pins_number_boxes_in_drawing_order_and_skip_text() {
    let mut doc = Annotations::default();
    let a = doc
        .add_rect(rect(0.0, 0.0, 10.0, 10.0), MarkColor::Red)
        .unwrap();
    let t = doc.add_text((5.0, 5.0), 13.0, MarkColor::Blue);
    doc.commit_text(t, "hello");
    let b = doc
        .add_rect(rect(20.0, 0.0, 10.0, 10.0), MarkColor::Green)
        .unwrap();
    assert_eq!(doc.number(a), Some(1));
    assert_eq!(doc.number(t), None);
    assert_eq!(doc.number(b), Some(2));
    doc.remove(a);
    assert_eq!(doc.number(b), Some(1), "numbers close up after a delete");
}

#[test]
fn a_new_box_is_selected_and_remove_selected_deletes_it() {
    let mut doc = Annotations::default();
    let a = doc
        .add_rect(rect(0.0, 0.0, 10.0, 10.0), MarkColor::Red)
        .unwrap();
    let b = doc
        .add_rect(rect(20.0, 0.0, 10.0, 10.0), MarkColor::Red)
        .unwrap();
    assert_eq!(doc.selected(), Some(b));
    assert!(doc.remove_selected());
    assert_eq!(doc.selected(), None);
    assert!(!doc.remove_selected());
    assert_eq!(doc.items().len(), 1);
    assert_eq!(doc.items()[0].id, a);
}

#[test]
fn undo_steps_back_through_adds_notes_recolors_and_removes() {
    let mut doc = Annotations::default();
    let a = doc
        .add_rect(rect(0.0, 0.0, 10.0, 10.0), MarkColor::Red)
        .unwrap();
    assert!(doc.commit_text(a, "  tighten this  "));
    assert_eq!(doc.get(a).unwrap().text, "tighten this");
    assert!(
        !doc.commit_text(a, "tighten this"),
        "an unchanged note is no step"
    );
    assert!(doc.recolor(a, MarkColor::Blue));
    assert!(!doc.recolor(a, MarkColor::Blue));
    assert!(doc.remove(a));

    assert!(doc.undo());
    assert_eq!(doc.get(a).unwrap().color, MarkColor::Blue);
    assert!(doc.undo());
    assert_eq!(doc.get(a).unwrap().color, MarkColor::Red);
    assert!(doc.undo());
    assert_eq!(doc.get(a).unwrap().text, "");
    assert!(doc.undo());
    assert!(doc.is_empty());
    assert!(!doc.undo());
}

#[test]
fn empty_text_marks_vanish_without_an_undo_step() {
    let mut doc = Annotations::default();
    let a = doc
        .add_rect(rect(0.0, 0.0, 10.0, 10.0), MarkColor::Red)
        .unwrap();
    let t = doc.add_text((1.0, 1.0), 13.0, MarkColor::Red);
    assert!(doc.commit_text(t, "   "));
    assert!(doc.get(t).is_none());
    // The next undo removes the box, not a phantom text placement.
    assert!(doc.undo());
    assert!(doc.get(a).is_none());
}

#[test]
fn the_prompt_block_lists_numbered_boxes_then_text() {
    let mut doc = Annotations::default();
    assert_eq!(prompt_block("shot.png", &doc), None);
    let a = doc
        .add_rect(rect(120.4, 80.0, 299.6, 140.0), MarkColor::Red)
        .unwrap();
    doc.commit_text(a, "tighten\nthis");
    doc.add_rect(rect(40.0, 400.0, 200.0, 60.0), MarkColor::Blue);
    let t = doc.add_text((500.0, 30.0), 13.0, MarkColor::Green);
    doc.commit_text(t, "ship \"it\"");
    assert_eq!(
        prompt_block("shot-annotated.png", &doc).unwrap(),
        "Annotations on shot-annotated.png (boxes are x,y,w,h in image pixels):\n\
         1. [box 120,80,300,140] tighten this\n\
         2. [box 40,400,200,60] (no note)\n\
         Text on the image:\n\
         - [text 500,30] \"ship 'it'\""
    );
}

#[test]
fn with_annotations_goes_after_the_words() {
    assert_eq!(with_annotations("fix it", &[]), "fix it");
    assert_eq!(with_annotations("fix it\n", &["A", " "]), "fix it\n\nA");
    assert_eq!(with_annotations("", &["A", "B"]), "A\n\nB");
}

#[test]
fn annotated_names_are_png_and_do_not_stack() {
    assert_eq!(annotated_name("shot.jpg"), "shot-annotated.png");
    assert_eq!(annotated_name("shot-annotated.png"), "shot-annotated.png");
    assert_eq!(annotated_name("1a2b3c4d-mock.png"), "mock-annotated.png");
    assert_eq!(annotated_name("image"), "image-annotated.png");
}

#[test]
fn the_prompt_format_matches_the_parity_vectors() {
    let v: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../apps/parity/vectors/annotations.json"
    ))
    .unwrap();
    for case in v["cases"].as_array().unwrap() {
        let mut doc = Annotations::default();
        for mark in case["marks"].as_array().unwrap() {
            let f = |k: &str| mark[k].as_f64().unwrap() as f32;
            let text = mark["text"].as_str().unwrap_or("");
            match mark["kind"].as_str().unwrap() {
                "box" => {
                    let id = doc
                        .add_rect(rect(f("x"), f("y"), f("w"), f("h")), MarkColor::Red)
                        .unwrap();
                    doc.commit_text(id, text);
                }
                "text" => {
                    let id = doc.add_text((f("x"), f("y")), 13.0, MarkColor::Red);
                    doc.commit_text(id, text);
                }
                other => panic!("unknown mark kind {other}"),
            }
        }
        assert_eq!(
            prompt_block(case["name"].as_str().unwrap(), &doc).as_deref(),
            case["prompt"].as_str(),
            "{}",
            case["case"]
        );
    }
}

#[test]
fn flatten_keeps_the_size_and_paints_only_the_marks() {
    let source = png(200, 120, [255, 255, 255, 255]);
    let mut doc = Annotations::default();
    doc.add_rect(rect(60.0, 40.0, 100.0, 60.0), MarkColor::Blue);
    let out = decode_png(&flatten(&source, &doc, 1.0).unwrap());
    assert_eq!(out.dimensions(), (200, 120));
    // The stroke is 2px inside the box: the right edge column is blue.
    assert!(close(*out.get_pixel(159, 70), MarkColor::Blue.rgb(), 8));
    assert!(close(*out.get_pixel(110, 99), MarkColor::Blue.rgb(), 8));
    // Inside the box and outside it the picture is untouched.
    assert_eq!(*out.get_pixel(110, 70), image::Rgba([255, 255, 255, 255]));
    assert_eq!(*out.get_pixel(10, 110), image::Rgba([255, 255, 255, 255]));
    assert_eq!(*out.get_pixel(170, 70), image::Rgba([255, 255, 255, 255]));
}

#[test]
fn flatten_draws_a_numbered_pin_on_the_corner() {
    let source = png(200, 120, [255, 255, 255, 255]);
    let mut doc = Annotations::default();
    doc.add_rect(rect(60.0, 40.0, 100.0, 60.0), MarkColor::Red);
    let out = decode_png(&flatten(&source, &doc, 1.0).unwrap());
    // Pin: a 20px red disc centered on (60, 40), with white digits in it.
    assert!(close(*out.get_pixel(60 - 8, 40), MarkColor::Red.rgb(), 8));
    assert!(close(*out.get_pixel(60, 40 - 8), MarkColor::Red.rgb(), 8));
    let white_in_pin = (52..68)
        .flat_map(|x| (32..48).map(move |y| (x, y)))
        .filter(|&(x, y)| {
            let p = out.get_pixel(x, y);
            p[0] > 230 && p[1] > 200 && p[2] > 200
        })
        .count();
    assert!(
        white_in_pin >= 6,
        "the digit 1 is drawn ({white_in_pin} light px)"
    );
}

#[test]
fn flatten_scales_marks_to_what_was_seen_on_screen() {
    // Shown at half size, a 2px screen stroke is 4 image px.
    let source = png(400, 240, [255, 255, 255, 255]);
    let mut doc = Annotations::default();
    doc.add_rect(rect(100.0, 100.0, 200.0, 100.0), MarkColor::Green);
    let out = decode_png(&flatten(&source, &doc, 2.0).unwrap());
    for x in 296..300 {
        assert!(
            close(*out.get_pixel(x, 150), MarkColor::Green.rgb(), 8),
            "x={x}"
        );
    }
    assert_eq!(*out.get_pixel(294, 150), image::Rgba([255, 255, 255, 255]));
}

#[test]
fn flatten_renders_text_marks_on_a_chip() {
    let source = png(300, 100, [0, 0, 0, 255]);
    let mut doc = Annotations::default();
    let t = doc.add_text((20.0, 20.0), 13.0, MarkColor::Yellow);
    doc.commit_text(t, "Hello");
    let out = decode_png(&flatten(&source, &doc, 1.0).unwrap());
    assert!(close(*out.get_pixel(22, 22), MarkColor::Yellow.rgb(), 8));
    // Dark glyph pixels inside the chip.
    let ink = (28..70)
        .flat_map(|x| (24..42).map(move |y| (x, y)))
        .filter(|&(x, y)| out.get_pixel(x, y)[0] < 90)
        .count();
    assert!(ink > 20, "text glyphs are drawn ({ink} dark px)");
    // Past the chip the picture is untouched.
    assert_eq!(*out.get_pixel(250, 80), image::Rgba([0, 0, 0, 255]));
}

#[test]
fn flatten_keeps_transparency_outside_the_marks() {
    let source = png(100, 100, [10, 20, 30, 0]);
    let mut doc = Annotations::default();
    doc.add_rect(rect(10.0, 10.0, 50.0, 50.0), MarkColor::Red);
    let out = decode_png(&flatten(&source, &doc, 1.0).unwrap());
    assert_eq!(out.get_pixel(90, 90)[3], 0);
    assert_eq!(out.get_pixel(59, 30)[3], 255);
}

#[test]
fn flatten_reads_svg_sources() {
    let svg = br##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="#ffffff"/></svg>"##;
    assert_eq!(image_size(svg), Some((120.0, 80.0)));
    let mut doc = Annotations::default();
    doc.add_rect(rect(30.0, 20.0, 60.0, 40.0), MarkColor::Red);
    let out = decode_png(&flatten(svg, &doc, 1.0).unwrap());
    assert_eq!(out.dimensions(), (120, 80));
    assert!(close(*out.get_pixel(89, 40), MarkColor::Red.rgb(), 8));
}

#[test]
fn text_in_marks_is_escaped_for_the_overlay() {
    let mut doc = Annotations::default();
    let t = doc.add_text((0.0, 0.0), 13.0, MarkColor::Red);
    doc.commit_text(t, "<b>&\"'");
    let svg = overlay_svg(100.0, 100.0, &doc, 1.0);
    assert!(svg.contains("&lt;b&gt;&amp;&quot;&apos;"));
    assert!(usvg::Tree::from_str(&svg, &crate::image_media::svg_options()).is_ok());
}

#[test]
fn into_staged_carries_the_notes() {
    let staged = Annotated {
        name: "a-annotated.png".into(),
        png: png(4, 4, [0, 0, 0, 255]),
        notes: Some("Annotations".into()),
    }
    .into_staged();
    assert_eq!(staged.name, "a-annotated.png");
    assert_eq!(staged.annotations.as_deref(), Some("Annotations"));
    assert!(staged.image.is_some());
}

#[cfg(target_os = "linux")]
#[test]
fn the_lightbox_annotates_end_to_end() {
    use gpui::{
        AppContext as _, Bounds, Context, IntoElement, KeyDownEvent, Keystroke, MouseButton,
        MouseDownEvent, MouseMoveEvent, MouseUpEvent, ParentElement as _, PlatformInput, Point,
        Render, Styled as _, Window, div, point, px, size,
    };
    use std::cell::RefCell;
    use std::rc::Rc;

    struct Harness {
        preview: Option<crate::attachments::PreviewImage>,
        focus: gpui::FocusHandle,
    }
    impl Render for Harness {
        fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let Some(preview) = self.preview.clone() else {
                return div().into_any_element();
            };
            let weak = cx.weak_entity();
            div()
                .size_full()
                .child(crate::attachments::lightbox(
                    window,
                    &preview,
                    &self.focus,
                    move |_, cx| {
                        weak.update(cx, |view, cx| {
                            view.preview = None;
                            cx.notify();
                        })
                        .ok();
                    },
                    cx,
                ))
                .into_any_element()
        }
    }

    gpui_platform::headless().run(|cx| {
        cx.set_global(crate::theme::Theme::dark());
        let result: Rc<RefCell<Option<Annotated>>> = Rc::default();
        let sink = result.clone();
        let window = cx
            .open_window(
                gpui::WindowOptions {
                    window_bounds: Some(gpui::WindowBounds::Windowed(Bounds::new(
                        Point::default(),
                        size(px(800.0), px(600.0)),
                    ))),
                    ..Default::default()
                },
                |window, cx| {
                    cx.new(|cx| {
                        let focus = cx.focus_handle();
                        window.focus(&focus, cx);
                        let image = std::sync::Arc::new(gpui::Image::from_bytes(
                            gpui::ImageFormat::Png,
                            png(400, 200, [255, 255, 255, 255]),
                        ));
                        let preview = crate::attachments::PreviewImage::new("shot.png", image)
                            .annotatable(move |annotated, _, _| {
                                *sink.borrow_mut() = Some(annotated);
                            });
                        Harness {
                            preview: Some(preview),
                            focus,
                        }
                    })
                },
            )
            .unwrap();
        let harness = window.entity(cx).unwrap();
        let draw = |cx: &mut gpui::App| {
            cx.update_window(window.into(), |_, window, cx| {
                window.refresh();
                let _ = window.draw(cx);
            })
            .unwrap();
        };
        let send = |cx: &mut gpui::App, events: Vec<PlatformInput>| {
            cx.update_window(window.into(), |_, window, cx| {
                for event in events {
                    window.dispatch_event(event, cx);
                }
                window.refresh();
                let _ = window.draw(cx);
            })
            .unwrap();
        };
        let click = |at: Point<gpui::Pixels>| {
            vec![
                PlatformInput::MouseMove(MouseMoveEvent {
                    position: at,
                    ..Default::default()
                }),
                PlatformInput::MouseDown(MouseDownEvent {
                    position: at,
                    button: MouseButton::Left,
                    click_count: 1,
                    ..Default::default()
                }),
                PlatformInput::MouseUp(MouseUpEvent {
                    position: at,
                    button: MouseButton::Left,
                    click_count: 1,
                    ..Default::default()
                }),
            ]
        };
        let key = |k: &str| {
            PlatformInput::KeyDown(KeyDownEvent {
                keystroke: Keystroke::parse(k).unwrap(),
                is_held: false,
                prefer_character_input: false,
            })
        };
        for _ in 0..3 {
            draw(cx);
        }

        // The Annotate button sits 24px in from the bottom-right corner.
        send(
            cx,
            click(point(px(800.0 - 24.0 - 20.0), px(600.0 - 24.0 - 16.0))),
        );
        let preview = harness.read(cx).preview.clone().expect("still open");
        let editor = preview.annotate_editor().expect("annotate mode is on");
        draw(cx);
        draw(cx);

        // Drag a box: image pixels (50,40) to (250,140). The image is shown
        // at 1:1 inside the editor's frame.
        let frame = editor.read(cx).frame.get();
        let w = f32::from(frame.size.width);
        let h = f32::from(frame.size.height);
        let origin = point(
            frame.origin.x + px((w - 400.0) / 2.0),
            frame.origin.y + px((h - 200.0) / 2.0),
        );
        let at = |x: f32, y: f32| origin + point(px(x), px(y));
        send(
            cx,
            vec![
                PlatformInput::MouseMove(MouseMoveEvent {
                    position: at(50.0, 40.0),
                    ..Default::default()
                }),
                PlatformInput::MouseDown(MouseDownEvent {
                    position: at(50.0, 40.0),
                    button: MouseButton::Left,
                    click_count: 1,
                    ..Default::default()
                }),
                PlatformInput::MouseMove(MouseMoveEvent {
                    position: at(250.0, 140.0),
                    pressed_button: Some(MouseButton::Left),
                    ..Default::default()
                }),
                PlatformInput::MouseUp(MouseUpEvent {
                    position: at(250.0, 140.0),
                    button: MouseButton::Left,
                    click_count: 1,
                    ..Default::default()
                }),
            ],
        );
        let id = {
            let e = editor.read(cx);
            assert_eq!(e.doc.items().len(), 1);
            assert_eq!(
                e.doc.items()[0].shape,
                Shape::Rect(ImageRect {
                    x: 50.0,
                    y: 40.0,
                    w: 200.0,
                    h: 100.0
                })
            );
            assert_eq!(e.editing, Some(e.doc.items()[0].id), "the note opens");
            e.doc.items()[0].id
        };
        editor.update(cx, |e, cx| e.type_note("tighten this", cx));
        // Escape while a note is open commits it and keeps annotate mode.
        send(cx, vec![key("escape")]);
        assert_eq!(editor.read(cx).editing, None);
        assert_eq!(editor.read(cx).doc.get(id).unwrap().text, "tighten this");
        assert!(preview.annotating());

        // Backspace deletes the selected box; Cmd/Ctrl+Z brings it back.
        editor.update(cx, |e, _| e.doc.select(Some(id)));
        send(cx, vec![key("backspace")]);
        assert!(editor.read(cx).doc.is_empty());
        let undo = if cfg!(target_os = "macos") {
            "cmd-z"
        } else {
            "ctrl-z"
        };
        send(cx, vec![key(undo)]);
        assert_eq!(editor.read(cx).doc.items().len(), 1);

        // Done hands back the flattened file and the notes.
        cx.update_window(window.into(), |_, window, cx| {
            editor.update(cx, |e, cx| e.press_done(window, cx));
        })
        .unwrap();
        let annotated = result.borrow_mut().take().expect("Done delivered");
        assert_eq!(annotated.name, "shot-annotated.png");
        assert_eq!(
            annotated.notes.as_deref(),
            Some(
                "Annotations on shot-annotated.png (boxes are x,y,w,h in image pixels):\n\
                 1. [box 50,40,200,100] tighten this"
            )
        );
        let out = decode_png(&annotated.png);
        assert_eq!(out.dimensions(), (400, 200));
        assert!(close(*out.get_pixel(249, 90), MarkColor::Red.rgb(), 8));
        assert!(!preview.annotating(), "Done leaves annotate mode");

        // Escape with nothing open cancels annotate mode, not the preview.
        draw(cx);
        send(
            cx,
            click(point(px(800.0 - 24.0 - 20.0), px(600.0 - 24.0 - 16.0))),
        );
        assert!(preview.annotating());
        send(cx, vec![key("escape")]);
        assert!(!preview.annotating());
        assert!(harness.read(cx).preview.is_some(), "the preview stays open");
        cx.spawn(async move |cx| {
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
}
