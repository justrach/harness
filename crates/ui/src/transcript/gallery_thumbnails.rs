//! Small, bounded thumbnails do not compete with full-size attachment previews.
use super::*;
use crate::attachments::{
    AttachmentKey, AttachmentSnapshot, CachedAttachmentImage, attachment_snapshot_for,
};

type Key = (Vec<String>, String, String);
const MAX_THUMBNAILS: usize = 64;
const MAX_LOADS: usize = 2;
struct Thumbnail {
    snapshot: AttachmentSnapshot,
    touched: u64,
    task: Option<Task<()>>,
}
#[derive(Default)]
pub(super) struct GalleryThumbnails {
    entries: HashMap<Key, Thumbnail>,
    clock: u64,
}
impl GalleryThumbnails {
    pub(super) fn clear(&mut self, cx: &mut gpui::App) {
        for (_, thumbnail) in self.entries.drain() {
            release(thumbnail.snapshot, cx);
        }
    }
    pub(super) fn retry(
        &mut self,
        devices: &[String],
        image: &GeneratedImageRef,
        cx: &mut gpui::App,
    ) {
        let key = (
            devices.to_vec(),
            image.path.clone(),
            image.mime_type.clone(),
        );
        if self
            .entries
            .get(&key)
            .is_some_and(|thumb| matches!(thumb.snapshot, AttachmentSnapshot::Error { .. }))
        {
            if let Some(thumb) = self.entries.remove(&key) {
                release(thumb.snapshot, cx);
            }
        }
    }
}
fn release(snapshot: AttachmentSnapshot, cx: &mut gpui::App) {
    if let AttachmentSnapshot::Loaded(loaded) = snapshot {
        cx.defer(move |cx| gpui::ImageSource::Image(loaded.image).evict(None, cx));
    }
}
impl Transcript {
    pub(super) fn gallery_thumbnail_state(
        &mut self,
        devices: &[String],
        image: &GeneratedImageRef,
        load: bool,
        cx: &mut Context<Self>,
    ) -> AttachmentSnapshot {
        let key = (
            devices.to_vec(),
            image.path.clone(),
            image.mime_type.clone(),
        );
        self.gallery_thumbnails.clock += 1;
        let touched = self.gallery_thumbnails.clock;
        if let Some(thumbnail) = self.gallery_thumbnails.entries.get_mut(&key) {
            thumbnail.touched = touched;
            return thumbnail.snapshot.clone();
        }
        if !load
            || self
                .gallery_thumbnails
                .entries
                .values()
                .filter(|thumb| thumb.task.is_some())
                .count()
                >= MAX_LOADS
        {
            return AttachmentSnapshot::Loading;
        }
        let cached = devices.iter().find_map(|device| {
            match attachment_snapshot_for(&AttachmentKey::new(
                device,
                &image.path,
                Some(&image.mime_type),
            )) {
                AttachmentSnapshot::Loaded(loaded) => Some(loaded),
                _ => None,
            }
        });
        let engine = self.state.read(cx).engine().cloned();
        let local = self.state.read(cx).local_device_id.clone();
        while self.gallery_thumbnails.entries.len() >= MAX_THUMBNAILS {
            let oldest = self
                .gallery_thumbnails
                .entries
                .iter()
                .filter(|(_, thumb)| thumb.task.is_none())
                .min_by_key(|(_, thumb)| thumb.touched)
                .map(|(key, _)| key.clone());
            let Some(oldest) = oldest else {
                return AttachmentSnapshot::Loading;
            };
            if let Some(removed) = self.gallery_thumbnails.entries.remove(&oldest) {
                release(removed.snapshot, cx);
            }
        }
        if let Some(cached) = &cached {
            if crate::appshots::png_dimensions(&cached.image.bytes)
                .is_some_and(|(w, h)| w <= 128 && h <= 128)
            {
                let snapshot = AttachmentSnapshot::Loaded(cached.clone());
                self.gallery_thumbnails.entries.insert(
                    key,
                    Thumbnail {
                        snapshot: snapshot.clone(),
                        touched,
                        task: None,
                    },
                );
                return snapshot;
            }
        }
        if cached.is_none() && engine.is_none() {
            let snapshot = AttachmentSnapshot::Error {
                retry_in: Duration::MAX,
            };
            self.gallery_thumbnails.entries.insert(
                key,
                Thumbnail {
                    snapshot: snapshot.clone(),
                    touched,
                    task: None,
                },
            );
            return snapshot;
        }
        let source = image.clone();
        let candidates = devices.to_vec();
        let task_key = key.clone();
        let task = cx.spawn(async move |this, cx| {
            let loaded = if let Some(cached) = cached {
                let bytes = cached.image.bytes().to_vec();
                let thumb = cx
                    .background_executor()
                    .spawn(async move { crate::attachments::decode_gallery_thumbnail(bytes) })
                    .await;
                thumb.map(|image| CachedAttachmentImage {
                    name: source.name.clone().into(),
                    image,
                })
            } else if let Some(engine) = engine {
                let mut loaded = None;
                for device in &candidates {
                    let target =
                        (local.as_deref() != Some(device.as_str())).then_some(device.as_str());
                    if let Some(thumb) = crate::attachments::read_gallery_thumbnail(
                        &engine,
                        cx.background_executor(),
                        target,
                        &source.path,
                        &source.mime_type,
                    )
                    .await
                    {
                        loaded = Some(CachedAttachmentImage {
                            name: source.name.clone().into(),
                            image: thumb.image,
                        });
                        break;
                    }
                }
                loaded
            } else {
                None
            };
            let _ = this.update(cx, |this, cx| {
                if let Some(entry) = this.gallery_thumbnails.entries.get_mut(&task_key) {
                    entry.task = None;
                    entry.snapshot = loaded.map(AttachmentSnapshot::Loaded).unwrap_or(
                        AttachmentSnapshot::Error {
                            retry_in: Duration::MAX,
                        },
                    );
                    cx.notify();
                }
            });
        });
        self.gallery_thumbnails.entries.insert(
            key,
            Thumbnail {
                snapshot: AttachmentSnapshot::Loading,
                touched,
                task: Some(task),
            },
        );
        AttachmentSnapshot::Loading
    }
}
