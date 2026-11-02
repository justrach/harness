//! Local editable state for an unsent annotated image.
//!
//! The upload remains a flattened PNG. Its original and drawing document are
//! retained separately so reopening a draft never paints over already baked
//! marks. Only the compact document/reference belongs in settings JSON.

use std::path::Path;
use std::sync::Arc;

use gpui::{Image, ImageFormat};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::Annotations;

const CACHE_DIR: &str = "annotation-originals";
const VERSION: u32 = 1;

#[derive(Clone)]
pub struct EditableAnnotation {
    pub original_name: String,
    pub original: Arc<Image>,
    pub document: Annotations,
}

impl std::fmt::Debug for EditableAnnotation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EditableAnnotation")
            .field("original_name", &self.original_name)
            .field("original_format", &self.original.format)
            .field("original_bytes", &self.original.bytes.len())
            .field("document", &self.document)
            .finish()
    }
}

/// An additive, local-only draft field. The original bytes never enter JSON,
/// the outgoing prompt or the upload alongside the flattened attachment.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedEditableAnnotation {
    pub version: u32,
    pub original_name: String,
    pub original_cache_key: String,
    pub original_mime_type: String,
    pub document: Annotations,
}

pub(crate) fn content_digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// The ordinary draft cache accepts UUID keys. Deriving one from this PNG's
/// content keeps old saved snapshots intact while a stable attachment ID is
/// edited repeatedly.
pub(crate) fn flattened_cache_key(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut id = [0; 16];
    id.copy_from_slice(&digest[..16]);
    uuid::Uuid::from_bytes(id).to_string()
}

impl EditableAnnotation {
    pub fn saved_reference(&self) -> SavedEditableAnnotation {
        SavedEditableAnnotation {
            version: VERSION,
            original_name: self.original_name.clone(),
            original_cache_key: content_digest(&self.original.bytes),
            original_mime_type: self.original.format.mime_type().to_owned(),
            document: self.document.clone(),
        }
    }

    pub fn save(&self, draft_cache: &Path) -> std::io::Result<SavedEditableAnnotation> {
        use std::io::Write as _;
        use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};

        let saved = self.saved_reference();
        let folder = draft_cache.join(CACHE_DIR);
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&folder)?;
        std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o700))?;
        let path = folder.join(&saved.original_cache_key);
        if std::fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.file_type().is_file())
            && std::fs::read(&path)
                .is_ok_and(|bytes| content_digest(&bytes) == saved.original_cache_key)
        {
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
            return Ok(saved);
        }
        let temporary = folder.join(format!("{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(&self.original.bytes)?;
            std::fs::rename(&temporary, &path)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result.map(|()| saved)
    }
}

impl SavedEditableAnnotation {
    pub fn restore(&self, draft_cache: &Path) -> Result<EditableAnnotation, String> {
        if self.version != VERSION
            || self.original_cache_key.len() != 64
            || !self
                .original_cache_key
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err("The saved annotation reference is not supported.".into());
        }
        let format = ImageFormat::from_mime_type(&self.original_mime_type)
            .ok_or("The original image format is not supported.")?;
        let path = draft_cache.join(CACHE_DIR).join(&self.original_cache_key);
        let metadata =
            std::fs::symlink_metadata(&path).map_err(|_| "The original image is unavailable.")?;
        if !metadata.file_type().is_file()
            || metadata.len() == 0
            || metadata.len() > crate::attachments::MAX_ATTACHMENT_BYTES as u64
        {
            return Err("The original image cache entry is invalid.".into());
        }
        let bytes = std::fs::read(path).map_err(|_| "The original image is unavailable.")?;
        if content_digest(&bytes) != self.original_cache_key {
            return Err("The original image cache entry has changed.".into());
        }
        let size = super::image_size(&bytes).ok_or("The original image could not be decoded.")?;
        if !self.document.is_valid_for_image(size) {
            return Err("The saved annotation document is invalid.".into());
        }
        Ok(EditableAnnotation {
            original_name: self.original_name.clone(),
            original: Arc::new(Image::from_bytes(format, bytes)),
            document: self.document.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::annotate::MarkColor;

    fn editable() -> EditableAnnotation {
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(64, 64)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let mut document = Annotations::default();
        document
            .add_stroke(vec![(8.0, 8.0), (32.0, 24.0)], 4.0, MarkColor::Red)
            .unwrap();
        let comment = document.add_comment((40.0, 40.0), MarkColor::Blue).unwrap();
        document.commit_text(comment, "Move this action");
        EditableAnnotation {
            original_name: "original.png".into(),
            original: Arc::new(Image::from_bytes(ImageFormat::Png, png.into_inner())),
            document,
        }
    }

    #[test]
    fn editable_annotation_json_round_trip_restores_original_and_document() {
        let folder = tempfile::tempdir().unwrap();
        let editable = editable();
        let saved = editable.save(folder.path()).unwrap();
        let json = serde_json::to_string(&saved).unwrap();
        assert!(!json.contains("originalBytes"));
        assert!(!json.contains("undo"));
        let saved: SavedEditableAnnotation = serde_json::from_str(&json).unwrap();
        let restored = saved.restore(folder.path()).unwrap();
        assert_eq!(restored.original.bytes, editable.original.bytes);
        assert_eq!(restored.original.format, ImageFormat::Png);
        assert_eq!(restored.document, editable.document);
        assert!(!restored.document.can_undo());
        assert_eq!(
            super::super::prompt_block("original-annotated.png", &restored.document),
            super::super::prompt_block("original-annotated.png", &editable.document)
        );
    }

    #[test]
    fn editable_annotation_revisions_share_original_but_not_flattened_cache_keys() {
        let folder = tempfile::tempdir().unwrap();
        let first = editable();
        let mut next = first.clone();
        next.document.add_comment((4.0, 4.0), MarkColor::Yellow);
        let a = first.save(folder.path()).unwrap();
        let b = next.save(folder.path()).unwrap();
        assert_eq!(a.original_cache_key, b.original_cache_key);
        assert_ne!(a.document, b.document);
        assert_eq!(
            std::fs::read_dir(folder.path().join(CACHE_DIR))
                .unwrap()
                .count(),
            1
        );
        let before = super::super::flatten(&first.original.bytes, &first.document, 1.0).unwrap();
        let after = super::super::flatten(&next.original.bytes, &next.document, 1.0).unwrap();
        assert_ne!(flattened_cache_key(&before), flattened_cache_key(&after));
    }

    #[test]
    fn editable_annotation_missing_or_changed_original_never_falls_back_to_flattened() {
        let folder = tempfile::tempdir().unwrap();
        let editable = editable();
        let saved = editable.save(folder.path()).unwrap();
        let original = folder
            .path()
            .join(CACHE_DIR)
            .join(&saved.original_cache_key);
        std::fs::write(&original, b"unrelated bytes").unwrap();
        assert!(
            saved
                .restore(folder.path())
                .unwrap_err()
                .contains("changed")
        );
        std::fs::remove_file(&original).unwrap();
        assert!(
            saved
                .restore(folder.path())
                .unwrap_err()
                .contains("unavailable")
        );
        // Keeping the reference is enough to recover after its original returns.
        editable.save(folder.path()).unwrap();
        assert_eq!(
            saved.restore(folder.path()).unwrap().document,
            editable.document
        );
    }

    #[test]
    fn editable_annotation_restore_rejects_unsafe_reference_and_invalid_geometry() {
        let folder = tempfile::tempdir().unwrap();
        let mut editable = editable();
        let saved = editable.save(folder.path()).unwrap();
        let mut unsafe_reference = saved.clone();
        unsafe_reference.original_cache_key = "../../outside".into();
        assert!(unsafe_reference.restore(folder.path()).is_err());
        editable
            .document
            .add_comment((1000.0, 1000.0), MarkColor::Red);
        let invalid = editable.save(folder.path()).unwrap();
        assert!(
            invalid
                .restore(folder.path())
                .unwrap_err()
                .contains("document")
        );
        let mut future = saved;
        future.version = VERSION + 1;
        assert!(future.restore(folder.path()).is_err());
    }
}
