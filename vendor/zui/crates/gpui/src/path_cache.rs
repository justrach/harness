// Adapted from gpui-fast (https://github.com/longbridge/gpui-fast, Apache-2.0),
// `crates/gpui/src/fast/path_cache.rs` and `crates/gpui/src/fast/tests/path_cache.rs`
// at f0572b0. Changed for Harness: moved from gpui-fast's `fast` module to
// `crate::path_cache`, and its build tests moved into this file (`build_tests`).
// See vendor/zui/NOTICE.

//! Tessellated paths kept from one build to the next.
//!
//! A path is tessellated into triangles every time it is built, which for a
//! sparkline in every row of a table, a chart's moving averages or a donut is
//! a large part of what painting them costs, though most of them are the same
//! shape as the frame before, or the same shape moved, as a table scrolls.
//!
//! [`build`] tessellates a path relative to its first point and keeps the
//! triangles, keyed by that relative path and by how it is stroked or filled;
//! a path of the same shape built again anywhere reuses them, moved to its
//! first point. Every path is tessellated that way, kept or not, so a path
//! drawn from kept triangles is exactly the path tessellating it again gives.

use std::{cell::RefCell, rc::Rc};

use anyhow::Error;
use collections::FxHashMap;
use lyon::path::PathEvent;

use crate::{Bounds, Path, PathBuilder, PathStyle, PathVertex, Pixels, Point, point, px};

/// How many shapes are kept before the least recently drawn is let go.
const KEPT: usize = 2048;

/// How many bytes of keys and triangles (their weight: the memory they own,
/// not what surrounds them) the kept shapes weigh before the least recently
/// drawn is let go. A window-sized path is hundreds of kilobytes, a sparkline
/// about ten.
const KEPT_BYTES: usize = 16 * 1024 * 1024;

/// A link to no slot.
const NONE: usize = usize::MAX;

thread_local! {
    static KEPT_PATHS: RefCell<KeptPaths> = RefCell::new(KeptPaths::new(KEPT_BYTES, KEPT));
}

/// Tessellated shapes, the least recently drawn let go first once more than
/// `shapes` are kept or they weigh more than `limit`.
///
/// A shape stays kept until `shapes` other shapes, or other shapes weighing
/// `limit` less its own weight, have been drawn since it last was. One
/// exception: a shape heavier than `limit` is kept alone in a slot of its
/// own, outside the rest, until the next such shape takes it. One drawn every
/// frame lets go of none of the rest, but two drawn in turn each take the
/// slot from the other and are tessellated every time. A thread keeps at most
/// `limit` plus the one shape in its slot.
struct KeptPaths {
    /// Slots linked from the newest shape drawn to the oldest.
    slots: Vec<Option<Slot>>,
    /// The slots no shape is in.
    vacant: Vec<usize>,
    index: FxHashMap<Rc<[u32]>, usize>,
    newest: usize,
    oldest: usize,
    /// The weight of the shapes in `slots`.
    bytes: usize,
    heavy: Option<(Rc<[u32]>, Rc<Path<Pixels>>)>,
    limit: usize,
    shapes: usize,
    #[cfg(test)]
    stats: PathCacheStats,
}

struct Slot {
    key: Rc<[u32]>,
    path: Rc<Path<Pixels>>,
    bytes: usize,
    newer: usize,
    older: usize,
}

/// What a thread's kept shapes did since it began, and hold now, for
/// benchmarks and tests. Counts are per thread.
#[cfg(test)]
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PathCacheStats {
    /// Paths built from kept triangles.
    pub hits: u64,
    /// Paths tessellated, and then kept.
    pub misses: u64,
    /// Shapes let go, to keep to the count or the weight.
    pub evictions: u64,
    /// The weight, in bytes, of the shapes tessellated, kept or since let go.
    pub built_bytes: u64,
    /// The weight, in bytes, of the shapes kept now.
    pub held_bytes: usize,
    /// How many shapes are kept now.
    pub held_shapes: usize,
}

/// What keeping `path` under `key` weighs: the memory its key (exactly its
/// length) and its triangles (their capacity) own, not the memory around them.
fn weight(key: &[u32], path: &Path<Pixels>) -> usize {
    std::mem::size_of_val(key)
        + path.vertices.capacity() * std::mem::size_of::<PathVertex<Pixels>>()
}

impl KeptPaths {
    fn new(limit: usize, shapes: usize) -> Self {
        Self {
            slots: Vec::new(),
            vacant: Vec::new(),
            index: FxHashMap::default(),
            newest: NONE,
            oldest: NONE,
            bytes: 0,
            heavy: None,
            limit,
            shapes,
            #[cfg(test)]
            stats: PathCacheStats::default(),
        }
    }

    fn slot(&self, at: usize) -> &Slot {
        self.slots[at].as_ref().expect("a linked slot is occupied")
    }

    fn slot_mut(&mut self, at: usize) -> &mut Slot {
        self.slots[at].as_mut().expect("a linked slot is occupied")
    }

    fn get(&mut self, key: &[u32]) -> Option<Rc<Path<Pixels>>> {
        let found = match self.index.get(key) {
            Some(&at) => {
                if self.newest != at {
                    self.unlink(at);
                    self.link_newest(at);
                }
                Some(self.slot(at).path.clone())
            }
            None => match &self.heavy {
                Some((heavy, path)) if **heavy == *key => Some(path.clone()),
                _ => None,
            },
        };
        #[cfg(test)]
        if found.is_some() {
            self.stats.hits += 1;
        }
        found
    }

    /// Keeps a shape just tessellated, letting go of the least recently drawn
    /// until it fits.
    fn insert(&mut self, key: Vec<u32>, path: Rc<Path<Pixels>>) {
        let key: Rc<[u32]> = key.into();
        let bytes = weight(&key, &path);
        #[cfg(test)]
        {
            self.stats.misses += 1;
            self.stats.built_bytes += bytes as u64;
        }
        if bytes > self.limit {
            #[cfg(test)]
            if self.heavy.is_some() {
                self.stats.evictions += 1;
            }
            self.heavy = Some((key, path));
            return;
        }
        while self.bytes + bytes > self.limit || self.index.len() >= self.shapes {
            self.let_go_of_oldest();
        }
        let slot = Slot {
            key: key.clone(),
            path,
            bytes,
            newer: NONE,
            older: NONE,
        };
        let at = match self.vacant.pop() {
            Some(at) => {
                self.slots[at] = Some(slot);
                at
            }
            None => {
                self.slots.push(Some(slot));
                self.slots.len() - 1
            }
        };
        self.index.insert(key, at);
        self.link_newest(at);
        self.bytes += bytes;
    }

    fn let_go_of_oldest(&mut self) {
        let at = self.oldest;
        self.unlink(at);
        let slot = self.slots[at].take().expect("a linked slot is occupied");
        self.index.remove(&slot.key);
        self.bytes -= slot.bytes;
        self.vacant.push(at);
        #[cfg(test)]
        {
            self.stats.evictions += 1;
        }
    }

    fn unlink(&mut self, at: usize) {
        let Slot { newer, older, .. } = *self.slot(at);
        match newer {
            NONE => self.newest = older,
            newer => self.slot_mut(newer).older = older,
        }
        match older {
            NONE => self.oldest = newer,
            older => self.slot_mut(older).newer = newer,
        }
    }

    fn link_newest(&mut self, at: usize) {
        let before = self.newest;
        let slot = self.slot_mut(at);
        slot.newer = NONE;
        slot.older = before;
        match before {
            NONE => self.oldest = at,
            before => self.slot_mut(before).newer = at,
        }
        self.newest = at;
    }
}

/// What this thread's kept shapes did and hold.
#[cfg(test)]
pub(crate) fn path_cache_stats() -> PathCacheStats {
    KEPT_PATHS.with_borrow(|kept| {
        let heavy = kept.heavy.as_ref();
        PathCacheStats {
            held_bytes: kept.bytes + heavy.map_or(0, |(key, path)| weight(key, path)),
            held_shapes: kept.index.len() + heavy.is_some() as usize,
            ..kept.stats
        }
    })
}

/// Builds `builder` as [`PathBuilder::build`] does, from triangles kept from
/// an earlier path of the same shape where there is one.
#[inline]
pub(crate) fn build(builder: PathBuilder) -> Result<Path<Pixels>, Error> {
    let path = match builder.transform {
        Some(transform) => builder.raw.build().transformed(&transform),
        None => builder.raw.build(),
    };
    let Some(origin) = path.iter().find_map(|event| match event {
        PathEvent::Begin { at } => Some(at),
        _ => None,
    }) else {
        return tessellate(&builder.style, builder.dash_array, &path);
    };
    let relative = path.transformed(&lyon::math::Transform::translation(-origin.x, -origin.y));
    let offset = point(px(origin.x), px(origin.y));

    let key = shape_key(&relative, &builder.style, builder.dash_array.as_deref());
    if let Some(kept) = KEPT_PATHS.with_borrow_mut(|kept| kept.get(&key)) {
        return Ok(moved(&kept, offset));
    }
    let tessellated = tessellate(&builder.style, builder.dash_array, &relative)?;
    let tessellated = Rc::new(tessellated);
    KEPT_PATHS.with_borrow_mut(|kept| kept.insert(key, tessellated.clone()));
    Ok(moved(&tessellated, offset))
}

fn tessellate(
    style: &PathStyle,
    dash_array: Option<Vec<Pixels>>,
    path: &lyon::path::Path,
) -> Result<Path<Pixels>, Error> {
    match style {
        PathStyle::Stroke(options) => PathBuilder::tessellate_stroke(dash_array, path, options),
        PathStyle::Fill(options) => PathBuilder::tessellate_fill(path, options),
    }
}

/// `path`, tessellated at the origin, moved by `offset`, as tessellating it
/// with `build_path` there gives it: starting at its first vertex.
fn moved(path: &Path<Pixels>, offset: Point<Pixels>) -> Path<Pixels> {
    let start = path
        .vertices
        .first()
        .map_or(offset, |vertex| vertex.xy_position + offset);
    let mut moved = Path::new(start);
    moved.vertices = path
        .vertices
        .iter()
        .map(|vertex| {
            let mut vertex = vertex.clone();
            vertex.xy_position = vertex.xy_position + offset;
            vertex
        })
        .collect();
    moved.bounds = Bounds {
        origin: path.bounds.origin + offset,
        size: path.bounds.size,
    };
    moved
}

/// The key a shape is kept by: its events at the origin, and how it is
/// stroked or filled, as bits, so that only the same shape matches.
fn shape_key(
    path: &lyon::path::Path,
    style: &PathStyle,
    dash_array: Option<&[Pixels]>,
) -> Vec<u32> {
    let mut key = Vec::with_capacity(64);
    let mut point = |key: &mut Vec<u32>, point: lyon::math::Point| {
        key.push(point.x.to_bits());
        key.push(point.y.to_bits());
    };
    for event in path.iter() {
        match event {
            PathEvent::Begin { at } => {
                key.push(0);
                point(&mut key, at);
            }
            PathEvent::Line { to, .. } => {
                key.push(1);
                point(&mut key, to);
            }
            PathEvent::Quadratic { ctrl, to, .. } => {
                key.push(2);
                point(&mut key, ctrl);
                point(&mut key, to);
            }
            PathEvent::Cubic {
                ctrl1, ctrl2, to, ..
            } => {
                key.push(3);
                point(&mut key, ctrl1);
                point(&mut key, ctrl2);
                point(&mut key, to);
            }
            PathEvent::End { close, .. } => key.push(4 + close as u32),
        }
    }
    // The options are small and seldom vary; their debug form covers every
    // field without listing them.
    let options = match style {
        PathStyle::Stroke(options) => format!("s{options:?}"),
        PathStyle::Fill(options) => format!("f{options:?}"),
    };
    key.push(u32::MAX);
    key.extend(options.bytes().map(u32::from));
    if let Some(dash_array) = dash_array {
        key.push(u32::MAX - 1);
        key.extend(dash_array.iter().map(|dash| dash.0.to_bits()));
    }
    key
}

/// The most this thread's kept shapes weigh when none is heavier than the limit.
#[cfg(test)]
pub(crate) const MOST_HELD_BYTES: usize = KEPT_BYTES;

#[cfg(test)]
mod tests {
    use rand::{Rng as _, SeedableRng as _, rngs::StdRng};

    use super::{KEPT, KeptPaths, NONE, Path, PathVertex, Pixels, Rc, point, px, weight};

    /// A shape of `vertices` vertices, under a key of one word.
    fn shape(id: u32, vertices: usize) -> (Vec<u32>, Rc<Path<Pixels>>) {
        let mut path = Path::new(point(px(0.), px(0.)));
        path.vertices = vec![
            PathVertex {
                xy_position: point(px(1.), px(2.)),
                st_position: point(0., 1.),
                content_mask: Default::default(),
            };
            vertices
        ];
        (vec![id], Rc::new(path))
    }

    /// What a shape of `vertices` vertices weighs.
    fn weighs(vertices: usize) -> usize {
        let (key, path) = shape(0, vertices);
        weight(&key, &path)
    }

    /// Draws a shape as `build` does: kept triangles if there are, else a
    /// shape tessellated and kept. Whether it was kept.
    fn draw(kept: &mut KeptPaths, id: u32, vertices: usize) -> bool {
        let (key, path) = shape(id, vertices);
        if kept.get(&key).is_some() {
            return true;
        }
        kept.insert(key, path);
        false
    }

    /// The links, the index and the weights agree, and the limits hold.
    fn consistent(kept: &KeptPaths) {
        let mut at = kept.newest;
        let (mut linked, mut bytes, mut before) = (0, 0, NONE);
        while at != NONE {
            let slot = kept.slot(at);
            assert_eq!(slot.newer, before);
            assert_eq!(kept.index[&slot.key], at);
            assert_eq!(slot.bytes, weight(&slot.key, &slot.path));
            (linked, bytes, before, at) = (linked + 1, bytes + slot.bytes, at, slot.older);
        }
        assert_eq!(before, kept.oldest);
        assert_eq!(linked, kept.index.len());
        assert_eq!(bytes, kept.bytes);
        assert!(kept.bytes <= kept.limit);
        assert!(kept.index.len() <= kept.shapes);
        assert_eq!(kept.slots.iter().flatten().count(), linked);
    }

    #[test]
    fn unique_shapes_never_weigh_more_than_the_limit() {
        let mut kept = KeptPaths::new(20 * weighs(100), usize::MAX);
        let mut built = 0;
        for id in 0..500 {
            assert!(!draw(&mut kept, id, 100));
            built += weighs(100);
            consistent(&kept);
        }
        assert!(built > 10 * kept.limit);
        assert!(
            kept.bytes > kept.limit - weighs(100),
            "the newest stay kept"
        );
    }

    #[test]
    fn unique_shapes_never_outnumber_the_count() {
        let mut kept = KeptPaths::new(usize::MAX, 30);
        for id in 0..500 {
            assert!(!draw(&mut kept, id, 1));
            consistent(&kept);
        }
        assert_eq!(kept.index.len(), 30);
    }

    #[test]
    fn a_shape_drawn_again_stays_kept_among_unique_large_ones() {
        let mut kept = KeptPaths::new(20 * weighs(100), usize::MAX);
        assert!(!draw(&mut kept, u32::MAX, 10));
        for id in 0..500 {
            assert!(
                draw(&mut kept, u32::MAX, 10),
                "drawn again after {id} others"
            );
            draw(&mut kept, id, 100);
            consistent(&kept);
        }
    }

    /// A set drawn every frame, heavier than half the limit and lighter than
    /// the limit, is kept.
    #[test]
    fn a_set_drawn_every_frame_between_half_the_limit_and_the_limit_is_kept() {
        let mut kept = KeptPaths::new(100 * weighs(100), 2048);
        for frame in 0..10 {
            for id in 0..75 {
                let hit = draw(&mut kept, id, 100);
                assert_eq!(hit, frame > 0, "shape {id} in frame {frame}");
            }
            consistent(&kept);
        }
    }

    #[test]
    fn a_set_drawn_every_frame_is_kept_among_unique_shapes() {
        let mut kept = KeptPaths::new(100 * weighs(100), 2048);
        for frame in 0..300 {
            for id in 0..75 {
                assert_eq!(
                    draw(&mut kept, id, 100),
                    frame > 0,
                    "shape {id}, frame {frame}"
                );
            }
            draw(&mut kept, 1000 + frame, 100);
            consistent(&kept);
        }
    }

    #[test]
    fn a_shape_over_the_limit_is_kept_alone_while_it_is_drawn_again() {
        let mut kept = KeptPaths::new(weighs(300) / 2, usize::MAX);
        draw(&mut kept, u32::MAX, 300);
        for id in 0..500 {
            assert!(
                draw(&mut kept, u32::MAX, 300),
                "drawn again after {id} others"
            );
            draw(&mut kept, id, 10);
            consistent(&kept);
        }
        assert_eq!(kept.stats.hits, 500);
    }

    /// Two shapes over the limit drawn in turn share the one slot, so each is
    /// tessellated every time.
    #[test]
    fn two_shapes_over_the_limit_drawn_in_turn_are_tessellated_every_time() {
        let mut kept = KeptPaths::new(weighs(300) / 2, usize::MAX);
        for turn in 0..20 {
            assert!(!draw(&mut kept, turn % 2, 300), "draw {turn}");
        }
        assert_eq!(kept.stats.hits, 0);
        assert_eq!(kept.stats.evictions, 19);
    }

    #[test]
    fn a_frame_with_a_shape_over_the_limit_keeps_the_set_drawn_every_frame() {
        let mut kept = KeptPaths::new(100 * weighs(100), 2048);
        for frame in 0..50 {
            for id in 0..75 {
                assert_eq!(
                    draw(&mut kept, id, 100),
                    frame > 0,
                    "shape {id}, frame {frame}"
                );
                if id % 25 == 0 {
                    // Alternating, so that it is let go of and built again.
                    draw(&mut kept, u32::MAX - frame % 2, 20_000);
                }
            }
            consistent(&kept);
        }
        // The set once, and the shape over the limit once a frame.
        assert_eq!(kept.stats.misses, 75 + 50);
    }

    #[test]
    fn unique_shapes_over_the_limit_are_held_one_at_a_time() {
        let mut kept = KeptPaths::new(weighs(300) / 2, usize::MAX);
        for id in 0..50 {
            assert!(!draw(&mut kept, id, 300));
            consistent(&kept);
        }
        assert_eq!(kept.index.len(), 0);
        assert!(kept.get(&[49]).is_some());
        assert!(kept.get(&[48]).is_none());
        assert_eq!(kept.stats.evictions, 49);
    }

    #[test]
    fn the_links_and_weights_follow_every_insert_hit_and_let_go() {
        let mut rng = StdRng::seed_from_u64(5);
        let mut kept = KeptPaths::new(50 * weighs(40), 30);
        for _ in 0..5000 {
            let id = rng.random_range(0..400);
            draw(&mut kept, id, rng.random_range(1..80));
            consistent(&kept);
        }
    }

    /// The count rule's reference: two generations of `size` shapes, the
    /// older dropped whenever the recent fills, a shape drawn from the older
    /// moved to the recent.
    #[derive(Default)]
    struct Generations {
        size: usize,
        recent: std::collections::HashSet<u32>,
        older: std::collections::HashSet<u32>,
    }

    impl Generations {
        fn draw(&mut self, id: u32) -> bool {
            let hit = self.recent.contains(&id) || self.older.remove(&id);
            if !self.recent.contains(&id) {
                if self.recent.len() >= self.size {
                    self.older = std::mem::take(&mut self.recent);
                }
                self.recent.insert(id);
            }
            hit
        }
    }

    /// Draws `ids` through the reference of `size` shapes a generation and a
    /// cache of twice that, and counts the draws the reference hits and the
    /// cache does not.
    fn lost(size: usize, ids: impl Iterator<Item = u32>) -> usize {
        let mut reference = Generations {
            size,
            ..Default::default()
        };
        let mut kept = KeptPaths::new(usize::MAX, 2 * size);
        let mut lost = 0;
        for id in ids {
            let (reference, ours) = (reference.draw(id), draw(&mut kept, id, 1));
            lost += (reference && !ours) as usize;
        }
        lost
    }

    /// A reused set of `reused` shapes drawn every frame, and per frame
    /// `churn` new shapes, of which each is drawn again `gap` frames later.
    fn reuse_and_churn(reused: u32, churn: u32, gap: u32, frames: u32) -> Vec<u32> {
        let mut ids = Vec::new();
        for frame in 0..frames {
            ids.extend(0..reused);
            for n in 0..churn {
                ids.push(1_000_000 + frame * churn + n);
                if frame >= gap {
                    ids.push(1_000_000 + (frame - gap) * churn + n);
                }
            }
        }
        ids
    }

    /// The cache hits every draw the reference hits, at small sizes on random
    /// sequences and at `KEPT / 2` on a reused set among churn.
    #[test]
    fn every_shape_two_generations_keep_is_kept() {
        let mut rng = StdRng::seed_from_u64(7);
        for size in [1, 2, 3, 4, 8] {
            for _ in 0..1000 {
                let span = rng.random_range(2..6 * size as u32);
                let ids: Vec<u32> = (0..60).map(|_| rng.random_range(0..span)).collect();
                assert_eq!(lost(size, ids.iter().copied()), 0, "size {size}: {ids:?}");
            }
        }
        for reused in [700, 1500] {
            for churn in [1, 10] {
                let ids = reuse_and_churn(reused, churn, 100, 250);
                let n = lost(KEPT / 2, ids.into_iter());
                assert_eq!(n, 0, "{reused} reused, {churn} new a frame");
            }
        }
    }
}

/// Paths drawn from kept triangles, built through [`PathBuilder::build`].
#[cfg(test)]
mod build_tests {
    use super::{MOST_HELD_BYTES, path_cache_stats};
    use crate::{PathBuilder, Pixels, point, px};

    fn sparkline(at: (f32, f32)) -> PathBuilder {
        let mut builder = PathBuilder::stroke(px(1.5));
        builder.move_to(point(px(at.0), px(at.1)));
        for step in 1..20 {
            let x = at.0 + step as f32 * 3.;
            let y = at.1 + ((step * 7) % 11) as f32;
            builder.line_to(point(px(x), px(y)));
        }
        builder
    }

    fn positions(path: &crate::Path<Pixels>) -> Vec<(f32, f32)> {
        path.vertices
            .iter()
            .map(|vertex| (vertex.xy_position.x.0, vertex.xy_position.y.0))
            .collect()
    }

    /// A shape built again gives the same triangles, whether they were kept or
    /// not.
    #[test]
    fn a_path_built_again_is_the_same() {
        let first = sparkline((10., 20.)).build().unwrap();
        let again = sparkline((10., 20.)).build().unwrap();
        assert_eq!(positions(&first), positions(&again));
        assert_eq!(first.bounds, again.bounds);
        assert!(!first.vertices.is_empty());
    }

    /// The same shape built somewhere else is the same triangles moved there.
    #[test]
    fn a_path_of_the_same_shape_elsewhere_is_moved() {
        let here = sparkline((0., 0.)).build().unwrap();
        let there = sparkline((100., 250.)).build().unwrap();
        let moved: Vec<(f32, f32)> = positions(&here)
            .into_iter()
            .map(|(x, y)| (x + 100., y + 250.))
            .collect();
        assert_eq!(positions(&there), moved);
        assert_eq!(
            there.bounds.origin,
            here.bounds.origin + point(px(100.), px(250.))
        );
        assert_eq!(there.bounds.size, here.bounds.size);
    }

    /// A different shape, or the same shape stroked differently, is not taken
    /// for a kept one.
    #[test]
    fn a_different_shape_or_stroke_is_tessellated_again() {
        let thin = sparkline((0., 0.)).build().unwrap();
        let mut wide_builder = PathBuilder::stroke(px(4.));
        wide_builder.move_to(point(px(0.), px(0.)));
        for step in 1..20 {
            wide_builder.line_to(point(px(step as f32 * 3.), px(((step * 7) % 11) as f32)));
        }
        let wide = wide_builder.build().unwrap();
        assert_ne!(positions(&thin), positions(&wide));
        assert!(wide.bounds.size.height > thin.bounds.size.height);
    }

    /// A window-sized ground with `holes` square holes, which move with `frame`
    /// so that no two frames are the same shape.
    fn ground(frame: usize, holes: usize) -> PathBuilder {
        let mut builder = PathBuilder::fill();
        builder.move_to(point(px(0.), px(0.)));
        builder.line_to(point(px(2056.), px(0.)));
        builder.line_to(point(px(2056.), px(1290.)));
        builder.line_to(point(px(0.), px(1290.)));
        builder.close();
        for hole in 0..holes {
            let x = 10. + (hole % 40) as f32 * 50. + frame as f32 * 0.37;
            let y = 10. + (hole / 40) as f32 * 50.;
            builder.move_to(point(px(x), px(y)));
            builder.line_to(point(px(x), px(y + 30.)));
            builder.line_to(point(px(x + 30.), px(y + 30.)));
            builder.line_to(point(px(x + 30.), px(y)));
            builder.close();
        }
        builder
    }

    /// Window-sized paths in a new shape every frame fill the kept shapes, but
    /// not past the bytes they may hold.
    #[test]
    fn unique_window_sized_paths_are_kept_within_a_bounded_number_of_bytes() {
        for frame in 0..400 {
            ground(frame, 200).build().unwrap();
            assert!(path_cache_stats().held_bytes <= MOST_HELD_BYTES);
        }
        let stats = path_cache_stats();
        assert_eq!(stats.misses, 400);
        assert!(
            stats.built_bytes > 2 * MOST_HELD_BYTES as u64,
            "{} bytes built is not enough to need a bound",
            stats.built_bytes
        );
        assert!(
            stats.held_bytes > MOST_HELD_BYTES / 4,
            "{} held",
            stats.held_bytes
        );
    }

    /// A shape let go of and built again is tessellated again, to the same
    /// triangles.
    #[test]
    fn shapes_built_again_after_being_let_go_are_tessellated_again_the_same() {
        let first = ground(0, 200).build().unwrap();
        for frame in 1..400 {
            ground(frame, 200).build().unwrap();
        }
        let before = path_cache_stats();
        assert!(before.evictions > 0, "nothing was let go of");
        let again = ground(0, 200).build().unwrap();
        let after = path_cache_stats();
        assert_eq!(
            after.misses,
            before.misses + 1,
            "built again from kept ones"
        );
        assert_eq!(after.hits, before.hits);
        assert_eq!(positions(&again), positions(&first));
        assert_eq!(again.bounds, first.bounds);
    }

    /// Window-sized paths of a set drawn again every frame, weighing more than
    /// half of what may be kept and less than all of it, are never tessellated
    /// again after the first frame, though more than one generation of the
    /// kept shapes this replaced.
    #[test]
    fn a_set_of_window_sized_paths_between_half_and_all_the_bytes_is_drawn_from_kept_ones() {
        let most = MOST_HELD_BYTES as u64;
        for frame in 0..5 {
            for shape in 0..100 {
                ground(shape, 200).build().unwrap();
            }
            let stats = path_cache_stats();
            assert_eq!(stats.misses, 100, "after frame {frame}");
            assert_eq!(stats.hits, 100 * frame);
            assert!(stats.built_bytes > most / 2 && stats.built_bytes < most);
        }
    }
}
