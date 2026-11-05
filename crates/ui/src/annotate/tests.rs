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

#[cfg(target_os = "macos")]
#[test]
fn annotation_note_card_stays_inside_the_canvas_at_window_edges() {
    use gpui::{Bounds, point, px, size};

    for viewport in [size(px(1200.0), px(760.0)), size(px(480.0), px(640.0))] {
        let layout = crate::attachments::image_preview_layout(viewport);
        let image_origin = layout.frame.origin + point(px(60.0), px(40.0));
        for preferred in [(-300.0, -300.0), (2000.0, 2000.0)] {
            let relative = super::editor::note_popover_bounds(
                preferred,
                image_origin,
                layout.frame,
                viewport,
                layout.gutter,
            );
            let card = Bounds::new(image_origin + relative.origin, relative.size);
            assert!(card.left() >= layout.gutter);
            assert!(card.right() <= viewport.width - layout.gutter);
            assert!(card.top() >= layout.gutter);
            assert!(card.bottom() <= layout.frame.bottom());
            assert!(card.bottom() < layout.footer_top);
        }
    }
}

#[cfg(target_os = "macos")]
#[test]
fn comment_editor_keeps_its_pin_visible_near_each_window_edge() {
    use gpui::{Bounds, point, px, size};

    for viewport in [size(px(1200.0), px(800.0)), size(px(420.0), px(700.0))] {
        let layout = crate::attachments::image_preview_layout(viewport);
        let origin = layout.frame.origin;
        let diameter = 24.0;
        let radius = diameter / 2.0;
        let width = f32::from(layout.frame.size.width);
        let height = f32::from(layout.frame.size.height);
        for pin in [
            (radius, radius),
            (width - radius, radius),
            (radius, height - radius),
            (width - radius, height - radius),
            (width * 0.7, height * 0.8),
        ] {
            let relative = super::editor::comment_popover_bounds(
                pin,
                diameter,
                origin,
                layout.frame,
                viewport,
                layout.gutter,
            );
            let card = Bounds::new(origin + relative.origin, relative.size);
            let pin = Bounds::new(
                origin + point(px(pin.0 - radius), px(pin.1 - radius)),
                size(px(diameter), px(diameter)),
            );
            assert!(
                card.right() <= pin.left()
                    || card.left() >= pin.right()
                    || card.bottom() <= pin.top()
                    || card.top() >= pin.bottom(),
                "the comment field must not cover its numbered anchor"
            );
            assert!(card.left() >= layout.gutter);
            assert!(card.right() <= viewport.width - layout.gutter);
            assert!(card.top() >= layout.gutter);
            assert!(card.bottom() <= layout.frame.bottom());
        }
    }
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
        #[cfg(target_os = "macos")]
        editable: None,
    }
    .into_staged();
    assert_eq!(staged.name, "a-annotated.png");
    assert_eq!(staged.annotations.as_deref(), Some("Annotations"));
    assert!(staged.image.is_some());
}

#[test]
fn freehand_export_keeps_width_in_image_pixels_and_preserves_the_source() {
    let source = png(100, 80, [255, 255, 255, 255]);
    let original = source.clone();
    let mut doc = Annotations::default();
    doc.add_stroke(vec![(20.0, 20.0), (80.0, 20.0)], 8.0, MarkColor::Blue)
        .unwrap();
    let normal = flatten(&source, &doc, 1.0).unwrap();
    let resized = flatten(&source, &doc, 3.0).unwrap();
    assert_eq!(
        normal, resized,
        "stored stroke width does not change with the viewport"
    );
    let out = decode_png(&normal);
    assert!(close(*out.get_pixel(50, 17), MarkColor::Blue.rgb(), 8));
    assert_eq!(*out.get_pixel(50, 25), image::Rgba([255; 4]));
    assert_eq!(source, original, "flatten always draws into a copy");
    assert!(prompt_block("drawing.png", &doc).is_none());

    let dot = doc
        .add_stroke(vec![(50.0, 50.0)], 10.0, MarkColor::Red)
        .unwrap();
    assert_eq!(doc.number(dot), None);
    let out = decode_png(&flatten(&source, &doc, 1.0).unwrap());
    assert!(close(*out.get_pixel(50, 50), MarkColor::Red.rgb(), 8));
    assert_eq!(*out.get_pixel(50, 57), image::Rgba([255; 4]));
}

#[test]
fn point_comments_number_with_legacy_regions_but_keep_bodies_outside_pixels() {
    let mut doc = Annotations::default();
    let region = doc
        .add_rect(rect(20.0, 20.0, 40.0, 40.0), MarkColor::Red)
        .unwrap();
    doc.commit_text(region, "Legacy region");
    let markup = doc
        .add_markup_rect(rect(80.0, 20.0, 30.0, 30.0), 6.0, MarkColor::Blue)
        .unwrap();
    let comment = doc.add_comment((120.0, 50.0), MarkColor::Green).unwrap();
    doc.commit_text(comment, "Move this label\nKeep <this> text separate");
    assert_eq!(doc.number(region), Some(1));
    assert_eq!(doc.number(markup), None);
    assert_eq!(doc.number(comment), Some(2));
    let svg = overlay_svg(180.0, 100.0, &doc, 1.0);
    assert!(!svg.contains("Move this"));
    assert!(!svg.contains("Legacy region"));
    assert!(!svg.contains("Keep &lt;this&gt;"));
    assert_eq!(svg.matches("text-anchor=\"middle\"").count(), 2);
    let notes = prompt_block("review.png", &doc).unwrap();
    assert!(notes.contains("1. [box 20,20,40,40] Legacy region"));
    assert!(notes.contains("2. [point 120,50] Move this label\n   Keep <this> text separate"));
    let out = decode_png(&flatten(&png(180, 100, [255; 4]), &doc, 1.0).unwrap());
    assert!(close(*out.get_pixel(81, 35), MarkColor::Blue.rgb(), 8));
    assert_eq!(*out.get_pixel(95, 35), image::Rgba([255; 4]));
}

#[test]
fn an_erase_gesture_sweeps_fast_movement_and_undo_restores_every_hit() {
    let mut doc = Annotations::default();
    let a = doc
        .add_stroke(vec![(25.0, 10.0), (25.0, 90.0)], 4.0, MarkColor::Red)
        .unwrap();
    let b = doc
        .add_stroke(vec![(75.0, 10.0), (75.0, 90.0)], 4.0, MarkColor::Blue)
        .unwrap();
    let comment = doc.add_comment((50.0, 50.0), MarkColor::Green).unwrap();
    doc.commit_text(comment, "Keep this comment");
    let legacy = doc
        .add_rect(rect(10.0, 10.0, 80.0, 80.0), MarkColor::Red)
        .unwrap();
    let before = doc.items().to_vec();
    doc.begin_erase();
    assert!(doc.erase_segment((0.0, 50.0), (50.0, 50.0), 1.0));
    assert!(doc.erase_segment((50.0, 50.0), (100.0, 50.0), 1.0));
    assert!(doc.end_erase());
    assert!(doc.get(a).is_none() && doc.get(b).is_none());
    assert!(doc.get(comment).is_some() && doc.get(legacy).is_some());
    let erased = doc.items().to_vec();
    assert!(doc.undo());
    assert_eq!(doc.items(), before);
    assert!(doc.redo());
    assert_eq!(doc.items(), erased);
    assert!(!doc.redo());
}

#[test]
fn eraser_hits_drawn_edges_not_empty_box_interiors_and_can_erase_text() {
    let mut doc = Annotations::default();
    let outline = doc
        .add_markup_rect(rect(10.0, 10.0, 80.0, 80.0), 4.0, MarkColor::Red)
        .unwrap();
    doc.begin_erase();
    assert!(!doc.erase_segment((40.0, 50.0), (60.0, 50.0), 2.0));
    assert!(!doc.end_erase());
    assert!(doc.get(outline).is_some());
    doc.begin_erase();
    assert!(doc.erase_segment((8.0, 50.0), (8.0, 50.0), 3.0));
    assert!(doc.end_erase());
    assert!(doc.undo());
    assert!(doc.can_redo());
    doc.begin_erase();
    assert!(!doc.erase_segment((200.0, 200.0), (300.0, 300.0), 1.0));
    assert!(!doc.end_erase());
    assert!(doc.can_redo(), "a no-op gesture leaves redo intact");

    let text = doc.add_text((120.0, 20.0), 13.0, MarkColor::Blue);
    doc.commit_text(text, "Erase this");
    assert!(!doc.can_redo(), "a new edit starts a new history branch");
    doc.begin_erase();
    assert!(doc.erase_segment((122.0, 24.0), (122.0, 24.0), 1.0));
    assert!(doc.end_erase());
    assert!(doc.get(text).is_none());
    assert!(doc.undo());
    assert_eq!(doc.get(text).unwrap().text, "Erase this");
}

#[test]
fn comment_text_edits_delete_and_redo_remain_reversible() {
    let mut doc = Annotations::default();
    let empty = doc.add_comment((10.0, 10.0), MarkColor::Red).unwrap();
    doc.commit_text(empty, "  ");
    assert!(doc.is_empty() && !doc.can_undo());
    let id = doc.add_comment((30.0, 40.0), MarkColor::Blue).unwrap();
    doc.commit_text(id, "Original");
    doc.commit_text(id, "Updated");
    assert!(doc.undo());
    assert_eq!(doc.get(id).unwrap().text, "Original");
    assert!(doc.redo());
    assert_eq!(doc.get(id).unwrap().text, "Updated");
    doc.commit_text(id, "");
    assert!(doc.get(id).is_none());
    assert!(doc.undo());
    assert_eq!(doc.get(id).unwrap().text, "Updated");
    assert!(doc.redo());
    assert!(doc.get(id).is_none());
}

#[test]
fn editable_document_round_trip_validates_geometry_and_keeps_ids_distinct() {
    let mut doc = Annotations::default();
    doc.add_stroke(vec![(10.0, 10.0), (90.0, 40.0)], 5.0, MarkColor::Blue)
        .unwrap();
    let comment = doc.add_comment((70.0, 50.0), MarkColor::Red).unwrap();
    doc.commit_text(comment, "Outside the pixels");
    assert!(doc.is_valid_for_image((100.0, 100.0)));
    let json = serde_json::to_value(&doc).unwrap();
    for field in ["selected", "undo", "redo", "erase_origin"] {
        assert!(json.get(field).is_none());
    }
    let mut loaded: Annotations = serde_json::from_value(json.clone()).unwrap();
    assert_eq!(loaded, doc);
    assert!(!loaded.can_undo() && !loaded.can_redo());
    assert!(loaded.is_valid_for_image((100.0, 100.0)));
    let mut stale_id = json.clone();
    stale_id["next_id"] = serde_json::json!(0);
    loaded = serde_json::from_value(stale_id).unwrap();
    let next = loaded.add_comment((20.0, 20.0), MarkColor::Green).unwrap();
    assert!(next > comment);

    let mut invalid = json.clone();
    invalid["items"][0]["shape"]["Stroke"]["width"] = serde_json::json!(-1);
    assert!(
        !serde_json::from_value::<Annotations>(invalid)
            .unwrap()
            .is_valid_for_image((100.0, 100.0))
    );
    let mut invalid = json;
    invalid["items"][1]["id"] = invalid["items"][0]["id"].clone();
    assert!(
        !serde_json::from_value::<Annotations>(invalid)
            .unwrap()
            .is_valid_for_image((100.0, 100.0))
    );
    assert!(!doc.is_valid_for_image((50.0, 50.0)));
}

#[test]
fn malformed_or_unbounded_new_marks_are_rejected_without_history_changes() {
    let mut doc = Annotations::default();
    assert!(doc.add_stroke(vec![], 2.0, MarkColor::Red).is_none());
    assert!(
        doc.add_stroke(vec![(0.0, 0.0); MAX_STROKE_POINTS + 1], 2.0, MarkColor::Red)
            .is_none()
    );
    assert!(
        doc.add_stroke(vec![(f32::NAN, 0.0)], 2.0, MarkColor::Red)
            .is_none()
    );
    assert!(
        doc.add_stroke(vec![(0.0, 0.0)], 0.0, MarkColor::Red)
            .is_none()
    );
    assert!(
        doc.add_markup_rect(rect(0.0, 0.0, 20.0, 20.0), f32::INFINITY, MarkColor::Red)
            .is_none()
    );
    assert!(
        doc.add_comment((f32::INFINITY, 0.0), MarkColor::Red)
            .is_none()
    );
    assert!(doc.is_empty() && !doc.can_undo() && !doc.can_redo());
    assert!(!doc.erase_segment((0.0, 0.0), (1.0, 1.0), 1.0));
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

#[cfg(target_os = "macos")]
#[test]
fn first_comment_body_undo_removes_pin_and_redo_restores_words() {
    let mut doc = Annotations::default();
    let stroke = doc
        .add_stroke(vec![(1.0, 1.0), (50.0, 50.0)], 4.0, MarkColor::Red)
        .unwrap();
    let pin = doc.add_comment((20.0, 20.0), MarkColor::Blue).unwrap();
    doc.commit_text(pin, "Move this action");
    assert!(doc.undo());
    assert!(doc.get(pin).is_none());
    assert!(doc.get(stroke).is_some());
    assert!(doc.redo());
    assert_eq!(doc.get(pin).unwrap().text, "Move this action");
    doc.commit_text(pin, "Updated comment");
    assert!(doc.undo());
    assert_eq!(doc.get(pin).unwrap().text, "Move this action");
    assert!(doc.redo());
    assert_eq!(doc.get(pin).unwrap().text, "Updated comment");
}
