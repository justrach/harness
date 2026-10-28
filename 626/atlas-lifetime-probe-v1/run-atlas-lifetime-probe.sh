#!/bin/sh
# Run from a Harness checkout containing tag v0.2.146, on macOS with Metal.
# Component diagnostic only, not a complete desktop/cache reproduction.
# The atlas implementation is copied unchanged from that tag. Small GPUI
# value/interface shims avoid compiling the application; Metal is real.
set -eu
root="$(git rev-parse --show-toplevel)"
probe="$(mktemp -d "${TMPDIR:-/tmp}/harness-atlas-probe.XXXXXX")"
mkdir -p "$probe/src"
cat > "$probe/Cargo.toml" <<'CARGO_EOF'
[package]
name = "atlas-lifetime-probe"
version = "0.1.0"
edition = "2024"
publish = false

[workspace]

[dependencies]
anyhow = "1"
derive_more = { version = "2.1.1", features = ["deref", "deref_mut"] }
etagere = "0.2.15"
log = "0.4"
metal = "0.33"
parking_lot = "0.12"
CARGO_EOF
cat > "$probe/src/main.rs" <<'RUST_EOF'
// Diagnostic only: compile the unmodified v0.2.146 metal_atlas.rs with real
// Metal/etagere. These minimal GPUI value/interface shims avoid building the
// whole application. No real Window, Scene, image cache, or user data is used.
extern crate self as gpui;
extern crate self as collections;

use std::{borrow::Cow, panic::{AssertUnwindSafe, catch_unwind}};
pub type FxHashMap<K, V> = std::collections::HashMap<K, V>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct DevicePixels(pub i32);
impl DevicePixels {
    pub fn to_bytes(self, bpp: u8) -> usize { self.0 as usize * bpp as usize }
}
impl From<i32> for DevicePixels { fn from(v: i32) -> Self { Self(v) } }
impl From<DevicePixels> for i32 { fn from(v: DevicePixels) -> Self { v.0 } }
impl From<DevicePixels> for u64 { fn from(v: DevicePixels) -> Self { v.0 as u64 } }

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Size<T> { pub width: T, pub height: T }
impl Size<DevicePixels> {
    pub fn min(self, rhs: &Self) -> Self {
        Self { width: self.width.min(rhs.width), height: self.height.min(rhs.height) }
    }
    pub fn max(self, rhs: &Self) -> Self {
        Self { width: self.width.max(rhs.width), height: self.height.max(rhs.height) }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Point<T> { pub x: T, pub y: T }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bounds<T> { pub origin: Point<T>, pub size: Size<T> }
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AtlasTextureKind { Monochrome, Polychrome, Subpixel }
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AtlasTextureId { pub index: u32, pub kind: AtlasTextureKind }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TileId(pub u32);
impl From<etagere::AllocId> for TileId {
    fn from(id: etagere::AllocId) -> Self { Self(id.serialize()) }
}
impl From<TileId> for etagere::AllocId {
    fn from(id: TileId) -> Self { Self::deserialize(id.0) }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AtlasTile {
    pub texture_id: AtlasTextureId,
    pub tile_id: TileId,
    pub bounds: Bounds<DevicePixels>,
    pub padding: u32,
}
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct AtlasKey(pub usize);
impl AtlasKey {
    fn texture_kind(&self) -> AtlasTextureKind { AtlasTextureKind::Polychrome }
}
pub struct AtlasTextureList<T> { pub textures: Vec<Option<T>>, pub free_list: Vec<usize> }
impl<T> Default for AtlasTextureList<T> {
    fn default() -> Self { Self { textures: Vec::new(), free_list: Vec::new() } }
}
impl<T> AtlasTextureList<T> {
    pub fn iter_mut(&mut self) -> impl DoubleEndedIterator<Item=&mut T> {
        self.textures.iter_mut().flatten()
    }
}
impl<T> std::ops::Index<usize> for AtlasTextureList<T> {
    type Output = Option<T>;
    fn index(&self, index: usize) -> &Self::Output { &self.textures[index] }
}
pub trait PlatformAtlas {
    fn get_or_insert_with<'a>(
        &self, key: &AtlasKey,
        build: &mut dyn FnMut() -> anyhow::Result<Option<(Size<DevicePixels>, Cow<'a, [u8]>)>>,
    ) -> anyhow::Result<Option<AtlasTile>>;
    fn remove(&self, key: &AtlasKey);
}

mod metal_atlas;

fn insert(atlas: &metal_atlas::MetalAtlas, key: &AtlasKey, pixel: [u8; 4]) -> AtlasTile {
    atlas.get_or_insert_with(key, &mut || Ok(Some((
        Size { width: DevicePixels(1024), height: DevicePixels(1024) },
        Cow::Owned(pixel.repeat(1024 * 1024)),
    )))).unwrap().unwrap()
}

fn read_pixel(atlas: &metal_atlas::MetalAtlas, tile: AtlasTile) -> [u8; 4] {
    let texture = atlas.metal_texture(tile.texture_id);
    let mut pixel = [0u8; 4];
    texture.get_bytes(
        pixel.as_mut_ptr().cast(), 4,
        metal::MTLRegion::new_2d(tile.bounds.origin.x.0 as u64,
                              tile.bounds.origin.y.0 as u64, 1, 1), 0,
    );
    pixel
}

fn main() {
    let device = metal::Device::system_default().expect("native Metal device required");
    let atlas = metal_atlas::MetalAtlas::new(device, true);
    let a = AtlasKey(1);
    let b = AtlasKey(2);
    let original = [12, 34, 56, 255];
    let replacement = [80, 100, 120, 255];
    let retained_tile = insert(&atlas, &a, original);
    assert_eq!(read_pixel(&atlas, retained_tile), original);
    println!("CONTROL: live tile returns original synthetic pixels");

    atlas.remove(&a);
    let old_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let stale_lookup = catch_unwind(AssertUnwindSafe(|| atlas.metal_texture(retained_tile.texture_id)));
    std::panic::set_hook(old_hook);
    assert!(stale_lookup.is_err());
    println!("REPRODUCED: retained texture ID panics after last-key removal");

    let replacement_tile = insert(&atlas, &b, replacement);
    assert_eq!(retained_tile.texture_id, replacement_tile.texture_id);
    assert_eq!(retained_tile.bounds, replacement_tile.bounds);
    assert_eq!(read_pixel(&atlas, retained_tile), replacement);
    println!("REPRODUCED: reused slot makes old tile read replacement-image pixels");

    let fresh_tile = insert(&atlas, &a, original);
    assert_eq!(read_pixel(&atlas, fresh_tile), original);
    println!("CONTROL: fresh get_or_insert_with restores original-image pixels");
    println!("LIMIT: atlas component probe; not a full UI/cache or incident reproduction");
}
RUST_EOF
git -C "$root" show 'v0.2.146:vendor/zui/crates/gpui_macos/src/metal_atlas.rs' > "$probe/src/metal_atlas.rs"
CARGO_TARGET_DIR="$probe/target" "$root/scripts/heavy-build.sh" cargo run --manifest-path "$probe/Cargo.toml"
# The temporary diagnostic directory is intentionally retained for inspection.
