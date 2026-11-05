//! Section-aware virtual rows for the session icon picker. Choice indices stay
//! separate from row indices so headings never become selectable items.
use super::session_icon_catalog::{IconChoice, IconPickerTab, emoji_categories};

pub(super) const COLUMNS: usize = 8;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum IconPickerRow {
    Heading {
        category: Option<String>,
        label: String,
    },
    Choices {
        start: usize,
        len: usize,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct IconPickerGrid {
    pub(super) rows: Vec<IconPickerRow>,
    choice_rows: Vec<usize>,
}

impl IconPickerGrid {
    pub(super) fn new(choices: &[IconChoice], tab: IconPickerTab, searching: bool) -> Self {
        let mut grid = Self {
            rows: Vec::new(),
            choice_rows: Vec::with_capacity(choices.len()),
        };
        if choices.is_empty() {
            return grid;
        }

        if tab == IconPickerTab::Icons {
            grid.push_choices(0, choices.len());
        } else if searching {
            grid.rows.push(IconPickerRow::Heading {
                category: None,
                label: "Search results".into(),
            });
            grid.push_choices(0, choices.len());
        } else {
            let mut start = 0;
            while start < choices.len() {
                let category = choices[start].category.clone();
                let end = (start + 1..choices.len())
                    .find(|&index| choices[index].category != category)
                    .unwrap_or(choices.len());
                let label = emoji_categories()
                    .iter()
                    .find(|(id, _)| category.as_deref() == Some(*id))
                    .map_or("Emoji", |(_, label)| *label);
                grid.rows.push(IconPickerRow::Heading {
                    category,
                    label: label.into(),
                });
                grid.push_choices(start, end);
                start = end;
            }
        }

        grid
    }

    fn push_choices(&mut self, start: usize, end: usize) {
        for start in (start..end).step_by(COLUMNS) {
            let len = (end - start).min(COLUMNS);
            let row = self.rows.len();
            self.rows.push(IconPickerRow::Choices { start, len });
            self.choice_rows.extend(std::iter::repeat_n(row, len));
        }
    }

    pub(super) fn row_for_choice(&self, index: usize) -> Option<usize> {
        self.choice_rows.get(index).copied()
    }

    pub(super) fn first_choice_row(&self) -> Option<usize> {
        self.choice_rows.first().copied()
    }

    /// Move to the adjacent selectable row, preserving the column where it
    /// exists. A short last row clamps to its last cell; headings are skipped.
    pub(super) fn vertical_neighbor(&self, selected: usize, forward: bool) -> usize {
        let Some(row_index) = self.row_for_choice(selected) else {
            return selected;
        };
        let IconPickerRow::Choices { start, .. } = self.rows[row_index] else {
            return selected;
        };
        let column = selected - start;
        let choice_range = |row: &IconPickerRow| match row {
            IconPickerRow::Choices { start, len } => Some((*start, *len)),
            IconPickerRow::Heading { .. } => None,
        };
        let neighbor = if forward {
            self.rows[row_index + 1..].iter().find_map(choice_range)
        } else {
            self.rows[..row_index].iter().rev().find_map(choice_range)
        };
        neighbor.map_or(selected, |(start, len)| start + column.min(len - 1))
    }
}

#[cfg(test)]
mod tests {
    use super::super::session_icon::SessionIcon;
    use super::super::session_icon_catalog::choices;
    use super::*;

    fn sample_choices(categories: &[(&str, usize)]) -> Vec<IconChoice> {
        categories
            .iter()
            .flat_map(|(category, count)| {
                (0..*count).map(move |index| IconChoice {
                    key: format!("{category}-{index}"),
                    label: format!("Choice {index}"),
                    icon: SessionIcon::Emoji("😀".into()),
                    category: Some((*category).into()),
                })
            })
            .collect()
    }

    #[test]
    fn session_icon_grid_sections_cover_every_choice_once_without_mixing_categories() {
        let choices = choices(IconPickerTab::Emoji, "");
        let grid = IconPickerGrid::new(&choices, IconPickerTab::Emoji, false);
        let mut visited = Vec::new();
        let mut headings = Vec::new();
        let mut section = None;
        for (row_index, row) in grid.rows.iter().enumerate() {
            match row {
                IconPickerRow::Heading { category, label } => {
                    section = category.as_deref();
                    headings.push((section.unwrap(), label.as_str()));
                }
                IconPickerRow::Choices { start, len } => {
                    assert!((1..=COLUMNS).contains(len));
                    for index in *start..start + len {
                        assert_eq!(choices[index].category.as_deref(), section);
                        assert_eq!(grid.row_for_choice(index), Some(row_index));
                        visited.push(index);
                    }
                }
            }
        }
        assert_eq!(visited, (0..choices.len()).collect::<Vec<_>>());
        assert_eq!(headings, emoji_categories());
        assert_eq!(grid.first_choice_row(), Some(1));
        assert_eq!(grid.row_for_choice(choices.len()), None);
    }

    #[test]
    fn session_icon_grid_vertical_navigation_skips_headings_and_handles_partial_rows() {
        let choices = sample_choices(&[("animals_nature", 10), ("food_drink", 11)]);
        let grid = IconPickerGrid::new(&choices, IconPickerTab::Emoji, false);
        assert_eq!(grid.row_for_choice(0), Some(1));
        assert_eq!(grid.row_for_choice(8), Some(2));
        assert_eq!(grid.row_for_choice(10), Some(4));
        assert_eq!(grid.row_for_choice(18), Some(5));
        // Moving down a short row clamps the column, then crosses its heading.
        assert_eq!(grid.vertical_neighbor(7, true), 9);
        assert_eq!(grid.vertical_neighbor(9, true), 11);
        assert_eq!(grid.vertical_neighbor(11, false), 9);
        assert_eq!(grid.vertical_neighbor(17, false), 9);
        assert_eq!(grid.vertical_neighbor(17, true), 20);
        assert_eq!(grid.vertical_neighbor(20, false), 12);
        assert_eq!(grid.vertical_neighbor(0, false), 0);
        assert_eq!(grid.vertical_neighbor(20, true), 20);
        assert_eq!(grid.vertical_neighbor(100, true), 100);
    }

    #[test]
    fn session_icon_grid_search_has_one_nonselectable_heading_and_no_category_breaks() {
        let choices = sample_choices(&[("animals_nature", 3), ("food_drink", 7)]);
        let grid = IconPickerGrid::new(&choices, IconPickerTab::Emoji, true);
        assert_eq!(
            grid.rows,
            vec![
                IconPickerRow::Heading {
                    category: None,
                    label: "Search results".into(),
                },
                IconPickerRow::Choices { start: 0, len: 8 },
                IconPickerRow::Choices { start: 8, len: 2 },
            ]
        );
        assert_eq!(grid.first_choice_row(), Some(1));
        assert_eq!(grid.vertical_neighbor(7, true), 9);
        assert_eq!(grid.vertical_neighbor(8, false), 0);
    }

    #[test]
    fn session_icon_grid_stock_icons_and_empty_results_have_no_browse_headings() {
        let choices = choices(IconPickerTab::Icons, "");
        for searching in [false, true] {
            let grid = IconPickerGrid::new(&choices, IconPickerTab::Icons, searching);
            assert_eq!(grid.first_choice_row(), Some(0));
            assert!(
                grid.rows
                    .iter()
                    .all(|row| matches!(row, IconPickerRow::Choices { .. }))
            );
            let empty = IconPickerGrid::new(&[], IconPickerTab::Emoji, searching);
            assert!(empty.rows.is_empty());
            assert_eq!(empty.first_choice_row(), None);
            assert_eq!(empty.row_for_choice(0), None);
            assert_eq!(empty.vertical_neighbor(0, true), 0);
        }
    }
}
