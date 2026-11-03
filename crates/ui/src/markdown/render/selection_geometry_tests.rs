use super::*;

fn fractional_visible_bands() -> [Bounds<gpui::Pixels>; 4] {
    [
        Bounds::new(point(px(12.375), px(43.625)), size(px(287.75), px(66.5))),
        Bounds::new(point(px(-31.125), px(-19.75)), size(px(153.5), px(22.25))),
        Bounds::new(point(px(0.1), px(107.3)), size(px(420.2), px(13.7))),
        // A sliver left by clipping is still selectable, not a zero-area bound.
        Bounds::new(point(px(8.625), px(511.125)), size(px(99.75), px(0.25))),
    ]
}

fn assert_visible_position(position: gpui::Point<gpui::Pixels>, bounds: Bounds<gpui::Pixels>) {
    assert!(f32::from(position.x).is_finite(), "{position:?}");
    assert!(f32::from(position.y).is_finite(), "{position:?}");
    assert!(
        position.y > bounds.top() && position.y < bounds.bottom(),
        "{position:?} must be strictly within the visible vertical band {bounds:?}"
    );
}

#[test]
fn visible_selection_preserves_in_band_coordinates_including_horizontal_gutters() {
    for bounds in fractional_visible_bands() {
        let xs = [
            bounds.left() - px(81.375),
            bounds.left(),
            bounds.left() + bounds.size.width / 2.0,
            bounds.right(),
            bounds.right() + px(97.625),
        ];
        for x in xs {
            for fraction in [0.125, 0.5, 0.875] {
                let position = point(x, bounds.top() + bounds.size.height * fraction);
                let actual = visible_selection_position(position, bounds);
                assert_eq!(actual, position, "in-band pointers must not move");
                assert_visible_position(actual, bounds);
            }
        }
    }
}

#[test]
fn visible_selection_top_is_inclusive_and_preserves_gutter_x() {
    for bounds in fractional_visible_bands() {
        for x in [bounds.left() - px(19.75), bounds.right() + px(23.125)] {
            let actual = visible_selection_position(point(x, bounds.top()), bounds);
            assert_eq!(actual.x, x, "the exact top belongs to the visible band");
            assert_visible_position(actual, bounds);
            assert!(actual.y - bounds.top() < px(0.001));
        }
    }
}

#[test]
fn visible_selection_bottom_is_exclusive_and_selects_visible_end() {
    for bounds in fractional_visible_bands() {
        for x in [bounds.left() - px(19.75), bounds.right() + px(23.125)] {
            let actual = visible_selection_position(point(x, bounds.bottom()), bounds);
            assert_eq!(actual.x, bounds.right(), "the exact bottom is outside");
            assert_visible_position(actual, bounds);
            assert!(bounds.bottom() - actual.y < px(0.001));
        }
    }
}

#[test]
fn visible_selection_outside_vertical_band_maps_to_visible_start_or_end() {
    for bounds in fractional_visible_bands() {
        for x in [
            bounds.left() - px(10_000.25),
            bounds.left() + bounds.size.width / 2.0,
            bounds.right() + px(10_000.75),
        ] {
            for distance in [0.0625, 0.5, 22.0, 10_000.0] {
                let above =
                    visible_selection_position(point(x, bounds.top() - px(distance)), bounds);
                assert_eq!(above.x, bounds.left(), "above selects visible start");
                assert_visible_position(above, bounds);
                assert!(above.y - bounds.top() < px(0.001));

                let below =
                    visible_selection_position(point(x, bounds.bottom() + px(distance)), bounds);
                assert_eq!(below.x, bounds.right(), "below selects visible end");
                assert_visible_position(below, bounds);
                assert!(bounds.bottom() - below.y < px(0.001));
            }
        }
    }
}
