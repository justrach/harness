//! Mermaid diagrams for the Markdown surfaces that draw them: the file
//! preview and the chat transcript.
//!
//! - [`render_media`] renders and decodes one diagram. It runs the native
//!   renderer, so call it only on a background executor.
//! - [`DiagramCache`] keeps finished diagrams per (source, theme palette), so a
//!   re-render, the streamed → settled handoff of a reply, or a theme switched
//!   back never renders the same diagram twice. It runs one job at a time.
//! - [`fitted_media`] is the clickable image both surfaces show: it scales
//!   down to the pane's width and opens the full-size viewer on click.
//! - [`fence_is_closed`] says when a streamed fence's bytes are final, so a
//!   reply still streaming its diagram isn't rendered on every token.

use std::collections::{HashMap, HashSet, VecDeque};

use gpui::{
    AnyElement, InteractiveElement, IntoElement, ParentElement, SharedString,
    StatefulInteractiveElement, Styled, Task, Window, div, px,
};

use super::mermaid::Palette;
use crate::image_media::MediaImage;

/// Tallest a diagram draws inline; taller ones scale down (the full-size
/// viewer shows them at their natural size).
pub(crate) const MAX_INLINE_HEIGHT: f32 = 480.0;
/// Finished diagrams a cache keeps, and the memory they may hold.
const MAX_DIAGRAMS: usize = 32;
const MAX_RETAINED_BYTES: usize = 96 * 1024 * 1024;

/// Render `source` and decode it for display. Background executor only.
pub(crate) fn render_media(source: &str, palette: &Palette) -> Result<MediaImage, String> {
    let svg = super::mermaid::render(source, palette)?;
    crate::image_media::decode_image("image/svg+xml", svg.into_bytes())
}

/// The image as it sits in a Markdown column: as wide as the column allows up
/// to its natural width, at most [`MAX_INLINE_HEIGHT`] tall, aspect kept.
/// A click calls `on_open` (the owner's full-size viewer).
pub(crate) fn fitted_media(
    loaded: &MediaImage,
    id: SharedString,
    aria_label: SharedString,
    on_open: impl Fn(&mut Window, &mut gpui::App) + 'static,
) -> AnyElement {
    use gpui::StyledImage as _;
    div()
        .id(id)
        .w_full()
        .max_w(px(loaded.width))
        .mx_auto()
        .max_h(px(MAX_INLINE_HEIGHT))
        .aspect_ratio(loaded.width / loaded.height)
        .cursor_pointer()
        .role(gpui::Role::Button)
        .aria_label(aria_label)
        .on_click(move |_, window, cx| {
            cx.stop_propagation();
            on_open(window, cx);
        })
        .child(
            gpui::img(loaded.image.clone())
                .size_full()
                .object_fit(gpui::ObjectFit::Contain),
        )
        .into_any_element()
}

/// Whether a top-level fenced code block's source ends with its closing
/// fence. A closed fence can't grow (what streams next starts a new block),
/// so its diagram can render while the rest of the reply still streams.
/// Anything that isn't a fenced block answers `false`.
pub(crate) fn fence_is_closed(block_source: &str) -> bool {
    let mut lines = block_source.trim_end().lines();
    let Some(opener) = lines.next().map(str::trim_start) else {
        return false;
    };
    let Some(fence) = opener.chars().next().filter(|c| matches!(c, '`' | '~')) else {
        return false;
    };
    let width = opener.chars().take_while(|c| *c == fence).count();
    if width < 3 {
        return false;
    }
    lines.next_back().is_some_and(|closer| {
        let closer = closer.trim();
        closer.chars().count() >= width && closer.chars().all(|c| c == fence)
    })
}

/// A diagram's source rendered in one theme palette.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct DiagramKey {
    pub palette: Palette,
    pub source: String,
}

#[derive(Clone)]
pub(crate) enum DiagramState {
    /// Queued or rendering on the background executor. `stand_in` is the same
    /// source already rendered in another palette (a theme switch), to show
    /// until this one lands instead of flashing the source.
    Rendering {
        stand_in: Option<MediaImage>,
    },
    Ready(MediaImage),
    /// The renderer rejected it; the message is the renderer's own.
    Failed(SharedString),
}

/// Finished diagrams by (source, palette), with a queue that renders one at a
/// time. The owner starts the job [`DiagramCache::next_job`] names and calls
/// [`DiagramCache::finish`] with its result.
#[derive(Default)]
pub(crate) struct DiagramCache {
    done: HashMap<DiagramKey, Result<MediaImage, SharedString>>,
    recency: VecDeque<DiagramKey>,
    retained_bytes: usize,
    queue: VecDeque<DiagramKey>,
    /// Rows showing each queued or running diagram, to re-measure when it lands.
    waiters: HashMap<DiagramKey, HashSet<SharedString>>,
    running: Option<(DiagramKey, Task<()>)>,
    started: u64,
}

impl DiagramCache {
    /// The state of `key` for `row`; a miss queues a render.
    pub fn request(&mut self, key: &DiagramKey, row: &SharedString) -> DiagramState {
        if let Some(result) = self.done.get(key) {
            let state = match result {
                Ok(media) => DiagramState::Ready(media.clone()),
                Err(error) => DiagramState::Failed(error.clone()),
            };
            self.touch(key);
            return state;
        }
        match self.waiters.get_mut(key) {
            Some(rows) => {
                rows.insert(row.clone());
            }
            None => {
                self.waiters
                    .insert(key.clone(), HashSet::from([row.clone()]));
                self.queue.push_back(key.clone());
            }
        }
        let stand_in = self.done.iter().find_map(|(done, result)| {
            (done.source == key.source)
                .then(|| result.as_ref().ok().cloned())
                .flatten()
        });
        DiagramState::Rendering { stand_in }
    }

    /// The next diagram to render, or `None` while one is rendering. Queued
    /// diagrams of a palette that is no longer current are dropped.
    pub fn next_job(&mut self, palette: &Palette) -> Option<DiagramKey> {
        if self.running.is_some() {
            return None;
        }
        while let Some(key) = self.queue.pop_front() {
            if &key.palette == palette {
                return Some(key);
            }
            self.waiters.remove(&key);
        }
        None
    }

    pub fn start(&mut self, key: DiagramKey, task: Task<()>) {
        self.started += 1;
        self.running = Some((key, task));
    }

    /// Store a finished render. Returns the rows that showed it while it
    /// rendered, and media evicted to stay within the cache's bounds (the
    /// owner releases it from the GPU).
    pub fn finish(
        &mut self,
        key: DiagramKey,
        result: Result<MediaImage, String>,
    ) -> (Vec<SharedString>, Vec<MediaImage>) {
        if self
            .running
            .as_ref()
            .is_some_and(|(running, _)| *running == key)
        {
            self.running = None;
        }
        let rows = self
            .waiters
            .remove(&key)
            .map(|rows| rows.into_iter().collect())
            .unwrap_or_default();
        let mut evicted = Vec::new();
        let result = result.map_err(SharedString::from);
        if let Ok(media) = &result {
            self.retained_bytes = self.retained_bytes.saturating_add(media.bytes);
        }
        if let Some(Ok(previous)) = self.done.insert(key.clone(), result) {
            self.retained_bytes = self.retained_bytes.saturating_sub(previous.bytes);
            evicted.push(previous);
        }
        self.touch(&key);
        while self.done.len() > MAX_DIAGRAMS || self.retained_bytes > MAX_RETAINED_BYTES {
            let Some(oldest) = self.recency.pop_front() else {
                break;
            };
            if oldest == key && self.done.len() == 1 {
                // A single diagram over the budget still shows.
                self.recency.push_back(oldest);
                break;
            }
            if let Some(Ok(media)) = self.done.remove(&oldest) {
                self.retained_bytes = self.retained_bytes.saturating_sub(media.bytes);
                evicted.push(media);
            }
        }
        (rows, evicted)
    }

    /// Render jobs started so far.
    pub fn started(&self) -> u64 {
        self.started
    }

    /// Drop everything, returning the media to release.
    pub fn clear(&mut self) -> Vec<MediaImage> {
        self.queue.clear();
        self.waiters.clear();
        self.running = None;
        self.recency.clear();
        self.retained_bytes = 0;
        self.done
            .drain()
            .filter_map(|(_, result)| result.ok())
            .collect()
    }

    fn touch(&mut self, key: &DiagramKey) {
        if self.recency.back() != Some(key) {
            self.recency.retain(|candidate| candidate != key);
            self.recency.push_back(key.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::theme::Theme;

    #[test]
    fn a_fence_is_closed_only_by_a_matching_closer() {
        assert!(fence_is_closed("```mermaid\nflowchart LR\n  A --> B\n```"));
        assert!(fence_is_closed("```mermaid\nA\n```\n"));
        assert!(fence_is_closed("~~~mermaid\r\nA\r\n~~~~\r\n"));
        assert!(fence_is_closed("````mermaid\nA\n`````"));
        // Still streaming: no closer, a partial closer, or a shorter one.
        assert!(!fence_is_closed("```mermaid"));
        assert!(!fence_is_closed("```mermaid\nflowchart LR\n  A --> B"));
        assert!(!fence_is_closed("```mermaid\nA\n``"));
        assert!(!fence_is_closed("````mermaid\nA\n```"));
        assert!(!fence_is_closed("```mermaid\nA\n~~~"));
        assert!(!fence_is_closed("```mermaid\nA\n```x"));
        // Not a fence at all.
        assert!(!fence_is_closed("plain paragraph"));
        assert!(!fence_is_closed(""));
    }

    fn media(bytes: usize) -> MediaImage {
        let mut media = crate::image_media::decode_image(
            "image/svg+xml",
            br#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"/>"#.to_vec(),
        )
        .unwrap();
        media.bytes = bytes;
        media
    }

    #[test]
    fn cache_queues_each_diagram_once_and_keys_by_palette() {
        let dark = Palette::from_theme(&Theme::dark());
        let light = Palette::from_theme(&Theme::light());
        let row: SharedString = "row".into();
        let key = |palette: &Palette, source: &str| DiagramKey {
            palette: palette.clone(),
            source: source.into(),
        };
        let mut cache = DiagramCache::default();
        assert!(matches!(
            cache.request(&key(&dark, "A"), &row),
            DiagramState::Rendering { stand_in: None }
        ));
        // Asking again (another frame, another row) doesn't queue it twice.
        cache.request(&key(&dark, "A"), &"other".into());
        assert_eq!(cache.next_job(&dark), Some(key(&dark, "A")));
        assert_eq!(cache.next_job(&dark), None);
        let (mut rows, evicted) = cache.finish(key(&dark, "A"), Ok(media(10)));
        rows.sort();
        assert_eq!(rows, ["other", "row"]);
        assert!(evicted.is_empty());
        assert!(matches!(
            cache.request(&key(&dark, "A"), &row),
            DiagramState::Ready(_)
        ));
        // The same source in the other palette is its own diagram.
        assert!(matches!(
            cache.request(&key(&light, "A"), &row),
            DiagramState::Rendering { stand_in: Some(_) }
        ));
        // A queued job of a palette no longer in use is dropped.
        assert_eq!(cache.next_job(&dark), None);
        cache.finish(key(&dark, "B"), Err("Syntax error".into()));
        assert!(matches!(
            cache.request(&key(&dark, "B"), &row),
            DiagramState::Failed(message) if message == "Syntax error"
        ));
    }

    #[test]
    fn cache_evicts_the_least_recent_diagram_past_its_bounds() {
        let palette = Palette::from_theme(&Theme::dark());
        let key = |n: usize| DiagramKey {
            palette: palette.clone(),
            source: format!("graph {n}"),
        };
        let mut cache = DiagramCache::default();
        for n in 0..MAX_DIAGRAMS {
            assert!(cache.finish(key(n), Ok(media(1))).1.is_empty());
        }
        // Use the oldest, so the next insert evicts the second oldest.
        cache.request(&key(0), &"row".into());
        let (_, evicted) = cache.finish(key(MAX_DIAGRAMS), Ok(media(1)));
        assert_eq!(evicted.len(), 1);
        assert!(matches!(
            cache.request(&key(0), &"row".into()),
            DiagramState::Ready(_)
        ));
        assert!(matches!(
            cache.request(&key(1), &"row".into()),
            DiagramState::Rendering { stand_in: None }
        ));
        // Memory is bounded too; one diagram over the budget still shows.
        let mut cache = DiagramCache::default();
        cache.finish(key(0), Ok(media(MAX_RETAINED_BYTES / 2 + 1)));
        let (_, evicted) = cache.finish(key(1), Ok(media(MAX_RETAINED_BYTES / 2 + 1)));
        assert_eq!(evicted.len(), 1);
        let (_, evicted) = cache.finish(key(2), Ok(media(MAX_RETAINED_BYTES + 1)));
        assert_eq!(evicted.len(), 1);
        assert!(matches!(
            cache.request(&key(2), &"row".into()),
            DiagramState::Ready(_)
        ));
    }
}
