//! macOS generated-image gallery support. Saving reads the original encoded
//! file; transcript-cache images are bounded PNG previews and are never exports.
use super::{
    BASE64, MAX_ATTACHMENT_BYTES, MAX_READ_CHUNKS, PreviewImage, READ_CHUNK_TIMEOUT,
    call_with_timeout, with_target,
};
use base64::Engine as _;
use gpui::{AnyElement, BackgroundExecutor, SharedString, div, prelude::*, px};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub(crate) struct GallerySaveSource {
    pub id: String,
    pub path: String,
    pub name: String,
    pub mime_type: String,
    pub device_ids: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct GallerySavedFile {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    digest: [u8; 32],
}

#[derive(Clone, Debug)]
pub(crate) struct GallerySaveFailure {
    pub id: String,
    pub name: String,
    pub message: String,
}

#[derive(Clone, Debug)]
pub(crate) struct GallerySaveReport {
    pub directory: PathBuf,
    pub total: usize,
    pub saved: Vec<GallerySavedFile>,
    pub failures: Vec<GallerySaveFailure>,
}

impl GallerySaveReport {
    pub fn complete(&self) -> bool {
        self.total > 0 && self.saved.len() == self.total && self.failures.is_empty()
    }

    /// Synthetic capture state only; this does not read or create files.
    #[cfg(feature = "appshots-fixture")]
    pub(crate) fn fixture_partial(saved: usize, total: usize) -> Self {
        let directory = PathBuf::from("/synthetic/gallery-export");
        let saved = saved.min(total);
        Self {
            directory: directory.clone(),
            total,
            saved: (0..saved)
                .map(|index| GallerySavedFile {
                    id: format!("fixture-{index}"),
                    name: format!("concept-{}.png", index + 1),
                    path: directory.join(format!("concept-{}.png", index + 1)),
                    digest: [0; 32],
                })
                .collect(),
            failures: (saved..total)
                .map(|index| GallerySaveFailure {
                    id: format!("fixture-{index}"),
                    name: format!("concept-{}.png", index + 1),
                    message: "The destination is unavailable. Reconnect it, then retry.".into(),
                })
                .collect(),
        }
    }
}

/// Save a snapshot of a gallery. A retry carries its prior report: unchanged
/// successful files are retained, failed/missing/modified files alone are tried
/// again. Existing files are never overwritten. Network work uses the existing
/// attachment RPC; verification and disk writes run on the background executor.
pub(crate) async fn save_gallery_images(
    engine: &crate::state::EngineHandle,
    executor: &BackgroundExecutor,
    local_device_id: Option<&str>,
    sources: Vec<GallerySaveSource>,
    directory: PathBuf,
    previous: Option<GallerySaveReport>,
) -> GallerySaveReport {
    let ids: HashSet<String> = sources.iter().map(|source| source.id.clone()).collect();
    let target = directory.clone();
    let saved = executor
        .spawn(async move { retained_saves(&target, &ids, previous) })
        .await;
    let mut report = GallerySaveReport {
        directory,
        total: sources.len(),
        saved,
        failures: Vec::new(),
    };
    for source in sources {
        if report.saved.iter().any(|saved| saved.id == source.id) {
            continue;
        }
        let mut devices = HashSet::new();
        let mut original =
            Err("The image's computer is unavailable. Reconnect and retry.".to_string());
        for device in &source.device_ids {
            if !devices.insert(device) {
                continue;
            }
            let target = (local_device_id != Some(device.as_str())).then_some(device.as_str());
            original = read_original_image(engine, executor, target, &source).await;
            if original.is_ok() {
                break;
            }
        }
        let result = match original {
            Ok(bytes) => {
                let directory = report.directory.clone();
                let item = source.clone();
                executor
                    .spawn(async move { save_original_file(&directory, &item, &bytes) })
                    .await
            }
            Err(error) => Err(error),
        };
        match result {
            Ok(saved) => report.saved.push(saved),
            Err(message) => report.failures.push(GallerySaveFailure {
                id: source.id,
                name: source.name,
                message,
            }),
        }
    }
    report
}

async fn read_original_image(
    engine: &crate::state::EngineHandle,
    executor: &BackgroundExecutor,
    target_device_id: Option<&str>,
    source: &GallerySaveSource,
) -> Result<Vec<u8>, String> {
    image_extension(&source.mime_type)?;
    let mut bytes = Vec::new();
    let mut offset = 0u64;
    for _ in 0..MAX_READ_CHUNKS {
        let chunk = call_with_timeout(
            engine,
            executor,
            harness_rpc::methods::READ_ATTACHMENT_CHUNK,
            with_target(
                serde_json::json!({ "path": source.path, "offset": offset }),
                target_device_id,
            ),
            READ_CHUNK_TIMEOUT,
        )
        .await
        .map_err(|error| format!("Could not read the original image: {error}"))?;
        if chunk.get("mimeType").and_then(|value| value.as_str()) != Some(source.mime_type.as_str())
        {
            return Err(
                "The original image format changed. Refresh the conversation and retry.".into(),
            );
        }
        let data = chunk
            .get("data")
            .and_then(|value| value.as_str())
            .ok_or("The image read returned no data.")?;
        if data.len() > (MAX_ATTACHMENT_BYTES as usize).div_ceil(3) * 4 {
            return Err("The original image exceeds the 24 MB download limit.".into());
        }
        let decoded = BASE64
            .decode(data.as_bytes())
            .map_err(|_| "The image read returned invalid data.")?;
        if bytes.len().saturating_add(decoded.len()) > MAX_ATTACHMENT_BYTES as usize {
            return Err("The original image exceeds the 24 MB download limit.".into());
        }
        let next = chunk
            .get("nextOffset")
            .and_then(|value| value.as_u64())
            .ok_or("The image read stopped before completion.")?;
        if next != offset + decoded.len() as u64 {
            return Err(
                "The image read returned an incomplete byte range. Retry the download.".into(),
            );
        }
        bytes.extend_from_slice(&decoded);
        match chunk.get("done").and_then(|value| value.as_bool()) {
            Some(true) => {
                validate_original(&bytes, &source.mime_type)?;
                return Ok(bytes);
            }
            Some(false) => {
                if next <= offset {
                    return Err(
                        "The image read stopped before completion. Retry the download.".into(),
                    );
                }
                offset = next;
            }
            None => return Err("The image read returned an invalid completion status.".into()),
        }
    }
    Err("The image read did not finish. Retry the download.".into())
}

/// A small gallery-only rail image, separate from the full-preview cache.
pub(crate) async fn read_gallery_thumbnail(
    engine: &crate::state::EngineHandle,
    executor: &BackgroundExecutor,
    target_device_id: Option<&str>,
    path: &str,
    expected_mime: &str,
) -> Option<super::LoadedAttachmentImage> {
    let source = GallerySaveSource {
        id: path.into(),
        path: path.into(),
        name: super::name_from_path(path),
        mime_type: expected_mime.into(),
        device_ids: Vec::new(),
    };
    let bytes = read_original_image(engine, executor, target_device_id, &source)
        .await
        .ok()?;
    let image = executor
        .spawn(async move { decode_gallery_thumbnail(bytes) })
        .await?;
    Some(super::LoadedAttachmentImage {
        name: source.name,
        image,
    })
}

pub(crate) fn decode_gallery_thumbnail(bytes: Vec<u8>) -> Option<std::sync::Arc<gpui::Image>> {
    let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .ok()?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    let image = reader.decode().ok()?.thumbnail(128, 128).to_rgba8();
    let mut bytes = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(image)
        .write_to(&mut bytes, image::ImageFormat::Png)
        .ok()?;
    Some(std::sync::Arc::new(gpui::Image::from_bytes(
        gpui::ImageFormat::Png,
        bytes.into_inner(),
    )))
}

fn retained_saves(
    directory: &Path,
    source_ids: &HashSet<String>,
    previous: Option<GallerySaveReport>,
) -> Vec<GallerySavedFile> {
    let Some(previous) = previous.filter(|previous| previous.directory == directory) else {
        return Vec::new();
    };
    let mut retained = Vec::new();
    let mut ids = HashSet::new();
    for saved in previous.saved {
        if !source_ids.contains(&saved.id)
            || !ids.insert(saved.id.clone())
            || saved.path.parent() != Some(directory)
        {
            continue;
        }
        // The user may have deleted, replaced or edited a saved file since the
        // failure. Never silently count it as this operation's successful copy.
        let matches = std::fs::symlink_metadata(&saved.path)
            .is_ok_and(|metadata| metadata.is_file() && metadata.len() <= MAX_ATTACHMENT_BYTES)
            && std::fs::read(&saved.path)
                .is_ok_and(|bytes| <[u8; 32]>::from(Sha256::digest(&bytes)) == saved.digest);
        if matches {
            retained.push(saved);
        }
    }
    retained
}

fn image_extension(mime: &str) -> Result<&'static str, String> {
    match mime {
        "image/png" => Ok("png"),
        "image/jpeg" => Ok("jpg"),
        "image/webp" => Ok("webp"),
        "image/gif" => Ok("gif"),
        _ => Err("This generated-image format cannot be saved.".into()),
    }
}

fn validate_original(bytes: &[u8], mime: &str) -> Result<(), String> {
    image_extension(mime)?;
    if bytes.is_empty() || bytes.len() > MAX_ATTACHMENT_BYTES as usize {
        return Err("The original image is empty or exceeds the 24 MB download limit.".into());
    }
    let actual = image::guess_format(bytes).map_err(|_| "The original image data is invalid.")?;
    if Some(actual) != image::ImageFormat::from_mime_type(mime) {
        return Err("The original image does not match its reported format.".into());
    }
    Ok(())
}

fn safe_image_stem(name: &str) -> String {
    let name = name.rsplit(['/', '\\']).next().unwrap_or_default();
    let stem = Path::new(name)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or_default();
    let cleaned: String = stem
        .chars()
        .map(|character| {
            if character.is_control() || matches!(character, '/' | '\\' | ':' | '\0') {
                '_'
            } else {
                character
            }
        })
        .collect();
    let cleaned =
        cleaned.trim_matches(|character: char| character == '.' || character.is_whitespace());
    let mut result = String::new();
    for character in cleaned.chars() {
        if result.len() + character.len_utf8() > 180 {
            break;
        }
        result.push(character);
    }
    if result.is_empty() {
        "image".into()
    } else {
        result
    }
}

fn save_original_file(
    directory: &Path,
    source: &GallerySaveSource,
    bytes: &[u8],
) -> Result<GallerySavedFile, String> {
    validate_original(bytes, &source.mime_type)?;
    let extension = image_extension(&source.mime_type)?;
    let stem = safe_image_stem(&source.name);
    // The temporary file remains in the destination filesystem. Publishing uses
    // macOS exclusive rename, refusing existing files and symlinks.
    let temporary = directory.join(format!(".harness-image-{}.tmp", uuid::Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|error| format!("Could not create an image in the chosen folder: {error}"))?;
    let written = file.write_all(bytes).and_then(|_| file.sync_all());
    drop(file);
    if let Err(error) = written {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("Could not finish saving the image: {error}"));
    }
    let mut result =
        Err("Too many files share this image's name. Choose another folder.".to_string());
    for suffix in 0..10_000 {
        let name = if suffix == 0 {
            format!("{stem}.{extension}")
        } else {
            format!("{stem} ({}).{extension}", suffix + 1)
        };
        let path = directory.join(&name);
        match publish_exclusive(&temporary, &path, bytes) {
            Ok(()) => {
                result = Ok(GallerySavedFile {
                    id: source.id.clone(),
                    name,
                    path,
                    digest: Sha256::digest(bytes).into(),
                });
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                result = Err(format!(
                    "Could not save the image in the chosen folder: {error}"
                ));
                break;
            }
        }
    }
    let _ = std::fs::remove_file(&temporary);
    result
}

// The same native exclusive-rename operation used by tempfile on macOS.
// A filesystem without it falls back to create_new, never overwrite-capable
// rename/copy. That fallback removes its own partial file after a write failure.
fn publish_exclusive(temporary: &Path, destination: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let from = std::ffi::CString::new(temporary.as_os_str().as_bytes())?;
    let to = std::ffi::CString::new(destination.as_os_str().as_bytes())?;
    // SAFETY: both CString values remain alive through the call, and the
    // RENAME_EXCL flag requires that the destination does not exist.
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if matches!(
        error.raw_os_error(),
        Some(libc::ENOTSUP | libc::EINVAL | libc::ENOSYS)
    ) {
        write_exclusive_fallback(destination, bytes)
    } else {
        Err(error)
    }
}

fn write_exclusive_fallback(destination: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)?;
    let identity = file
        .metadata()
        .ok()
        .map(|metadata| (metadata.dev(), metadata.ino()));
    let result = file.write_all(bytes).and_then(|_| file.sync_all());
    drop(file);
    if result.is_err()
        && identity.is_some_and(|identity| {
            std::fs::symlink_metadata(destination)
                .is_ok_and(|metadata| (metadata.dev(), metadata.ino()) == identity)
        })
    {
        let _ = std::fs::remove_file(destination);
    }
    result
}

/// One lazily loaded gallery page. Missing pages remain in the sequence and
/// show loading or retry UI, rather than silently disappearing from the count.
pub(crate) fn gallery_lightbox(
    window: &mut gpui::Window,
    preview: Option<&PreviewImage>,
    index: usize,
    total: usize,
    error: bool,
    focus: &gpui::FocusHandle,
    on_change: impl Fn(usize, &mut gpui::Window, &mut gpui::App) + 'static,
    on_retry: impl Fn(&mut gpui::Window, &mut gpui::App) + 'static,
    on_close: impl Fn(&mut gpui::Window, &mut gpui::App) + 'static,
    cx: &mut gpui::App,
) -> AnyElement {
    if total == 0 {
        return div().into_any_element();
    }
    let index = index.min(total - 1);
    if let Some(preview) = preview.filter(|preview| preview.annotate_editor().is_some()) {
        return super::lightbox(window, preview, focus, on_close, cx);
    }
    let annotate_button = preview.and_then(|preview| {
        super::preview::annotation_actions("gallery-lightbox", preview, focus, window, cx)
    });
    let viewport = window.viewport_size();
    let layout = super::image_preview_layout(viewport);
    let theme = crate::theme::Theme::of(cx).clone();
    let natural_size = preview
        .and_then(|preview| preview.image.clone().use_render_image(window, cx))
        .map(|image| {
            let dimensions = image.size(0);
            gpui::size(
                px(dimensions.width.0 as f32),
                px(dimensions.height.0 as f32),
            )
        });
    let content = match (preview, natural_size) {
        (Some(preview), Some(natural)) => {
            preview
                .viewer
                .render(preview.image.clone(), natural, None, window, cx)
        }
        _ => div()
            .size_full()
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap(px(12.0))
            .text_color(theme.text)
            .child(if error {
                "This image is unavailable"
            } else {
                "Loading image…"
            })
            .when(error, |body| {
                body.child(
                    div()
                        .id("gallery-lightbox-retry")
                        .h(px(36.0))
                        .px(px(14.0))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(8.0))
                        .border_1()
                        .bg(theme.surface_overlay.alpha(1.0))
                        .border_color(theme.border)
                        .role(gpui::Role::Button)
                        .aria_label("Retry loading image")
                        .tab_index(0)
                        .cursor_pointer()
                        .on_click(move |_, window, cx| {
                            cx.stop_propagation();
                            on_retry(window, cx);
                        })
                        .child("Retry"),
                )
            })
            .into_any_element(),
    };
    let on_close = std::rc::Rc::new(on_close);
    let close_on_key = on_close.clone();
    let close_on_background = on_close.clone();
    let press_state = preview.map(|preview| preview.viewer.clone());
    let click_state = press_state.clone();
    let step = std::rc::Rc::new(on_change);
    let key_step = step.clone();
    let trap_focus = focus.clone();
    let nav = |id: &'static str, label: &'static str, next: Option<usize>| {
        let step = step.clone();
        div()
            .id(id)
            .debug_selector(move || id.to_owned())
            .h(px(36.0))
            .px(px(14.0))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(8.0))
            .border_1()
            .border_color(gpui::rgba(0xffffff00))
            .text_size(crate::typography::ui_rems(12.0))
            .text_color(theme.text)
            .opacity(if next.is_some() { 1.0 } else { 0.4 })
            .role(gpui::Role::Button)
            .aria_label(label)
            .when(next.is_some(), |button| {
                button
                    .tab_index(0)
                    .cursor_pointer()
                    .focus_visible(|style| style.border_color(theme.accent))
                    .hover(|style| style.bg(theme.element_hover))
            })
            .on_click(move |_, window, cx| {
                cx.stop_propagation();
                if let Some(next) = next {
                    step(next, window, cx);
                }
            })
            .child(label)
    };
    gpui::deferred(
        gpui::anchored()
            .position(gpui::point(px(0.0), px(0.0)))
            .child(
                div()
                    .id("gallery-lightbox")
                    .debug_selector(|| "gallery-lightbox".into())
                    .occlude()
                    .track_focus(focus)
                    .w(viewport.width)
                    .h(viewport.height)
                    .relative()
                    .bg(crate::popover::scrim_alpha(0.7))
                    .on_key_down(move |event: &gpui::KeyDownEvent, window, cx| {
                        let modifiers = event.keystroke.modifiers;
                        if event.keystroke.key == "tab"
                            && !modifiers.control
                            && !modifiers.alt
                            && !modifiers.platform
                        {
                            cx.stop_propagation();
                            cycle_gallery_focus(&trap_focus, modifiers.shift, window, cx);
                        } else if event.keystroke.key == "escape" {
                            cx.stop_propagation();
                            close_on_key(window, cx);
                        } else if let Some(next) =
                            gallery_key_index(&event.keystroke.key, index, total)
                        {
                            cx.stop_propagation();
                            if next != index {
                                key_step(next, window, cx);
                            }
                        }
                    })
                    .capture_any_mouse_down(move |event, _, _| {
                        if event.button == gpui::MouseButton::Left {
                            if let Some(press_state) = &press_state {
                                press_state.begin_click();
                            }
                        }
                    })
                    .on_click(move |_, window, cx| {
                        cx.stop_propagation();
                        if !click_state.as_ref().is_some_and(|state| state.dragged()) {
                            close_on_background(window, cx);
                        }
                    })
                    .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
                    .child(
                        div()
                            .absolute()
                            .left(layout.frame.origin.x)
                            .top(layout.frame.origin.y)
                            .w(layout.frame.size.width)
                            .h(layout.frame.size.height)
                            .child(content),
                    )
                    .child(
                        div()
                            .absolute()
                            .top(layout.footer_top)
                            .left(layout.gutter)
                            .right(layout.gutter)
                            .flex()
                            .flex_col()
                            .items_center()
                            .gap(px(8.0))
                            .child(
                                div()
                                    .max_w(layout.frame.size.width)
                                    .h(px(18.0))
                                    .px(px(8.0))
                                    .rounded(px(4.0))
                                    .bg(theme.surface_overlay.alpha(1.0))
                                    .overflow_hidden()
                                    .text_ellipsis()
                                    .whitespace_nowrap()
                                    .text_size(crate::typography::ui_rems(11.0))
                                    .line_height(px(18.0))
                                    .text_color(theme.text)
                                    .child(
                                        preview
                                            .map(|preview| preview.name.clone())
                                            .unwrap_or_default(),
                                    ),
                            )
                            .child(
                                div()
                                    .h(px(40.0))
                                    .px(px(4.0))
                                    .flex()
                                    .items_center()
                                    .gap(px(4.0))
                                    .rounded(px(12.0))
                                    .bg(theme.surface_overlay.alpha(1.0))
                                    .border_1()
                                    .border_color(theme.border)
                                    .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| {
                                        cx.stop_propagation()
                                    })
                                    .child(nav("gallery-prev", "Previous", index.checked_sub(1)))
                                    .child(
                                        div()
                                            .id("gallery-count")
                                            .debug_selector(|| "gallery-count".into())
                                            .rounded_full()
                                            .bg(theme.element_hover)
                                            .px(px(12.0))
                                            .py(px(6.0))
                                            .text_size(crate::typography::ui_rems(12.0))
                                            .text_color(theme.text)
                                            .child(SharedString::from(format!(
                                                "{} of {total}",
                                                index + 1
                                            ))),
                                    )
                                    .child(nav(
                                        "gallery-next",
                                        "Next",
                                        (index + 1 < total).then_some(index + 1),
                                    ))
                                    .child(
                                        div()
                                            .id("gallery-close")
                                            .h(px(36.0))
                                            .px(px(12.0))
                                            .flex()
                                            .items_center()
                                            .rounded(px(8.0))
                                            .text_size(crate::typography::ui_rems(12.0))
                                            .text_color(theme.text)
                                            .role(gpui::Role::Button)
                                            .aria_label("Close image viewer")
                                            .tab_index(0)
                                            .cursor_pointer()
                                            .border_1()
                                            .border_color(gpui::rgba(0xffffff00))
                                            .focus_visible(|style| style.border_color(theme.accent))
                                            .hover(|style| style.bg(theme.element_hover))
                                            .on_click(move |_, window, cx| {
                                                cx.stop_propagation();
                                                on_close(window, cx);
                                            })
                                            .child("Close"),
                                    ),
                            )
                            .children(annotate_button),
                    ),
            ),
    )
    .priority(3)
    .into_any_element()
}

fn cycle_gallery_focus(
    root: &gpui::FocusHandle,
    reverse: bool,
    window: &mut gpui::Window,
    cx: &mut gpui::App,
) {
    let mut first = None;
    // Global Tab order also contains the composer behind this modal. Skip
    // outside stops without dispatching input, then wrap within this root.
    for _ in 0..4096 {
        if reverse {
            window.focus_prev(cx);
        } else {
            window.focus_next(cx);
        }
        if root.contains_focused(window, cx) {
            return;
        }
        let Some(current) = window.focused(cx) else {
            break;
        };
        if first.as_ref() == Some(&current) {
            break;
        }
        if first.is_none() {
            first = Some(current);
        }
    }
    window.focus(root, cx);
}

fn gallery_key_index(key: &str, index: usize, count: usize) -> Option<usize> {
    if count == 0 {
        return None;
    }
    match key {
        "left" | "arrowleft" => Some(index.saturating_sub(1)),
        "right" | "arrowright" => Some((index + 1).min(count - 1)),
        "home" => Some(0),
        "end" => Some(count - 1),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(id: &str, name: &str) -> GallerySaveSource {
        GallerySaveSource {
            id: id.into(),
            path: format!("/generated/{id}"),
            name: name.into(),
            mime_type: "image/png".into(),
            device_ids: vec!["local".into()],
        }
    }

    fn png() -> Vec<u8> {
        let mut bytes = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgba8(2, 2)
            .write_to(&mut bytes, image::ImageFormat::Png)
            .unwrap();
        bytes.into_inner()
    }

    #[test]
    fn gallery_export_preserves_original_bytes_corrects_extension_and_never_overwrites() {
        let directory = tempfile::tempdir().unwrap();
        let bytes = png();
        std::fs::write(directory.path().join("poster.png"), b"existing user file").unwrap();
        let saved = save_original_file(directory.path(), &source("1", "../../poster.jpeg"), &bytes)
            .unwrap();
        assert_eq!(saved.name, "poster (2).png");
        assert_eq!(std::fs::read(&saved.path).unwrap(), bytes);
        assert_eq!(
            std::fs::read(directory.path().join("poster.png")).unwrap(),
            b"existing user file"
        );
        assert_eq!(
            std::fs::read_dir(directory.path()).unwrap().count(),
            2,
            "temporary file removed"
        );
    }

    #[test]
    fn gallery_export_retry_retains_successes_and_retries_only_failed_or_changed_files() {
        let directory = tempfile::tempdir().unwrap();
        let bytes = png();
        let first = source("first", "first.png");
        let second = source("second", "second.png");
        let saved = save_original_file(directory.path(), &first, &bytes).unwrap();
        let failure =
            save_original_file(directory.path(), &second, b"incomplete bytes").unwrap_err();
        let previous = GallerySaveReport {
            directory: directory.path().into(),
            total: 2,
            saved: vec![saved.clone()],
            failures: vec![GallerySaveFailure {
                id: second.id.clone(),
                name: second.name.clone(),
                message: failure,
            }],
        };
        assert!(!previous.complete());
        let ids = HashSet::from([first.id.clone(), second.id.clone()]);
        let mut kept = retained_saves(directory.path(), &ids, Some(previous.clone()));
        assert_eq!(kept.len(), 1);
        kept.push(save_original_file(directory.path(), &second, &bytes).unwrap());
        assert!(
            GallerySaveReport {
                directory: directory.path().into(),
                total: 2,
                saved: kept,
                failures: Vec::new()
            }
            .complete()
        );
        assert_eq!(
            std::fs::read_dir(directory.path()).unwrap().count(),
            2,
            "retry didn't duplicate successful file"
        );
        std::fs::write(&saved.path, b"user edited this saved file").unwrap();
        assert!(retained_saves(directory.path(), &ids, Some(previous)).is_empty());
        let retried = save_original_file(directory.path(), &first, &bytes).unwrap();
        assert_ne!(retried.path, saved.path);
        assert_eq!(
            std::fs::read(saved.path).unwrap(),
            b"user edited this saved file"
        );
    }

    #[test]
    fn gallery_export_reports_bad_destination_and_mime_without_creating_partial_files() {
        let directory = tempfile::tempdir().unwrap();
        let item = source("1", "image.png");
        assert!(
            save_original_file(&directory.path().join("missing"), &item, &png())
                .unwrap_err()
                .contains("chosen folder")
        );
        let mut wrong = item.clone();
        wrong.mime_type = "image/jpeg".into();
        assert!(
            save_original_file(directory.path(), &wrong, &png())
                .unwrap_err()
                .contains("reported format")
        );
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
        assert_eq!(safe_image_stem("../../..."), "image");
        assert!(safe_image_stem(&"界".repeat(200)).len() <= 180);
        assert!(
            !GallerySaveReport {
                directory: directory.path().into(),
                total: 0,
                saved: Vec::new(),
                failures: Vec::new()
            }
            .complete()
        );
    }

    #[test]
    fn gallery_export_fallback_and_symlink_collisions_never_overwrite() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("saved.png");
        let bytes = png();
        write_exclusive_fallback(&path, &bytes).unwrap();
        assert_eq!(
            write_exclusive_fallback(&path, b"replacement")
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::AlreadyExists
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        std::os::unix::fs::symlink(&path, directory.path().join("linked.png")).unwrap();
        let saved =
            save_original_file(directory.path(), &source("linked", "linked.png"), &bytes).unwrap();
        assert_eq!(saved.name, "linked (2).png");
        assert!(
            std::fs::symlink_metadata(directory.path().join("linked.png"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }

    #[test]
    fn gallery_viewer_navigation_stays_in_bounds_even_for_missing_pages() {
        assert_eq!(gallery_key_index("left", 0, 3), Some(0));
        assert_eq!(gallery_key_index("right", 2, 3), Some(2));
        assert_eq!(gallery_key_index("home", 2, 3), Some(0));
        assert_eq!(gallery_key_index("end", 0, 3), Some(2));
        assert_eq!(gallery_key_index("end", 0, 0), None);
    }

    #[test]
    fn gallery_thumbnails_have_a_bounded_retained_size() {
        let mut bytes = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgba8(2048, 2048)
            .write_to(&mut bytes, image::ImageFormat::Png)
            .unwrap();
        let thumbnail = decode_gallery_thumbnail(bytes.into_inner()).unwrap();
        let decoded = image::load_from_memory(thumbnail.bytes()).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (128, 128));
        assert!(thumbnail.bytes().len() + 128 * 128 * 8 < 150_000);
        assert!(decode_gallery_thumbnail(b"invalid bytes".to_vec()).is_none());
    }

    #[gpui::test]
    fn gallery_modal_tab_wraps_without_focusing_the_composer_behind_it(
        cx: &mut gpui::TestAppContext,
    ) {
        use gpui::{AppContext, Context, Render};
        let directory = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(crate::theme::Theme::dark());
            crate::settings::init(crate::settings::UiSettings::default(), directory.path(), cx);
        });
        struct Fixture {
            preview: PreviewImage,
            focus: gpui::FocusHandle,
            behind: gpui::FocusHandle,
            index: usize,
            closed: bool,
        }
        impl Render for Fixture {
            fn render(
                &mut self,
                window: &mut gpui::Window,
                cx: &mut Context<Self>,
            ) -> impl IntoElement {
                let change = cx.weak_entity();
                let close = change.clone();
                let mut root = div()
                    .id("gallery-focus-fixture")
                    .size_full()
                    .on_key_down(|event: &gpui::KeyDownEvent, window, cx| {
                        // Match Shell's fallback: without the modal trap this
                        // traverses the composer along with the viewer controls.
                        if event.keystroke.key == "tab" {
                            if event.keystroke.modifiers.shift {
                                window.focus_prev(cx);
                            } else {
                                window.focus_next(cx);
                            }
                        }
                    })
                    .child(
                        div()
                            .id("composer-behind-gallery")
                            .track_focus(&self.behind)
                            .tab_index(0)
                            .child("Composer behind the gallery"),
                    );
                if !self.closed {
                    root = root.child(gallery_lightbox(
                        window,
                        Some(&self.preview),
                        self.index,
                        2,
                        false,
                        &self.focus,
                        move |index, _, cx| {
                            change
                                .update(cx, |fixture, cx| {
                                    fixture.index = index;
                                    cx.notify();
                                })
                                .unwrap();
                        },
                        |_, _| {},
                        move |window, cx| {
                            close
                                .update(cx, |fixture, cx| {
                                    fixture.closed = true;
                                    window.focus(&fixture.behind, cx);
                                    cx.notify();
                                })
                                .unwrap();
                        },
                        cx,
                    ));
                }
                root
            }
        }
        let (view, cx) = cx.add_window_view(|window, cx| {
            let focus = cx.focus_handle();
            window.focus(&focus, cx);
            Fixture {
                preview: PreviewImage::new(
                    "test.png",
                    std::sync::Arc::new(gpui::Image::from_bytes(gpui::ImageFormat::Png, png())),
                ),
                focus,
                behind: cx.focus_handle(),
                index: 0,
                closed: false,
            }
        });
        cx.run_until_parked();
        cx.update(|window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        });
        let mut visited = Vec::new();
        for key in [
            "tab",
            "tab",
            "tab",
            "tab",
            "shift-tab",
            "shift-tab",
            "shift-tab",
            "shift-tab",
        ] {
            cx.simulate_keystrokes(key);
            cx.run_until_parked();
            cx.update(|window, cx| {
                let fixture = view.read(cx);
                assert!(
                    fixture.focus.contains_focused(window, cx),
                    "Tab must remain within the gallery"
                );
                assert!(!fixture.behind.is_focused(window));
                let current = window.focused(cx).unwrap();
                if !visited.contains(&current) {
                    visited.push(current);
                }
            });
        }
        assert!(
            visited.len() >= 2,
            "Tab must visit controls, not merely pin focus to the modal root"
        );
        cx.simulate_keystrokes("escape");
        cx.run_until_parked();
        cx.update(|window, cx| {
            let fixture = view.read(cx);
            assert!(fixture.closed);
            assert!(
                fixture.behind.is_focused(window),
                "Escape restores the caller's focus"
            );
        });
    }

    struct ExportRpc {
        calls: std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
        files: std::collections::HashMap<String, (String, Vec<u8>)>,
        fail_second: std::sync::Arc<std::sync::atomic::AtomicBool>,
    }

    #[async_trait::async_trait]
    impl harness_rpc::RpcService for ExportRpc {
        async fn handle(
            &self,
            method: &str,
            params: serde_json::Value,
        ) -> Result<harness_rpc::RpcReply, harness_rpc::RpcError> {
            assert_eq!(method, harness_rpc::methods::READ_ATTACHMENT_CHUNK);
            self.calls.lock().unwrap().push(params.clone());
            let path = params["path"].as_str().unwrap();
            if path == "/generated/second"
                && self.fail_second.load(std::sync::atomic::Ordering::SeqCst)
            {
                return Err(harness_rpc::RpcError::Failed(
                    "Image computer disconnected".into(),
                ));
            }
            let (mime, bytes) = &self.files[path];
            let offset = params["offset"].as_u64().unwrap() as usize;
            // Deliberately not divisible by three: each RPC chunk is its own
            // base64 value, including padding, and must decode independently.
            let end = (offset + 17).min(bytes.len());
            let done = if path == "/generated/malformed" {
                serde_json::json!("invalid status")
            } else {
                serde_json::json!(end == bytes.len())
            };
            harness_rpc::RpcReply::value(&serde_json::json!({
                "name": "original", "mimeType": mime,
                "data": BASE64.encode(&bytes[offset..end]),
                "nextOffset": end, "done": done,
            }))
        }
    }

    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn gallery_export_reads_original_chunks_routes_owner_and_retries_failed_files_only() {
        let _native = crate::NATIVE_PLATFORM_TEST_LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let executor = gpui_platform::background_executor();
        let directory = tempfile::tempdir().unwrap();
        let mut animation = Vec::new();
        {
            let mut encoder = image::codecs::gif::GifEncoder::new(&mut animation);
            for color in [[255, 0, 0, 255], [0, 0, 255, 255]] {
                encoder
                    .encode_frame(image::Frame::new(image::RgbaImage::from_pixel(
                        8,
                        8,
                        image::Rgba(color),
                    )))
                    .unwrap();
            }
        }
        let calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let failing = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        let engine = crate::state::EngineHandle::from_test_client(harness_rpc::memory_client(
            std::sync::Arc::new(ExportRpc {
                calls: calls.clone(),
                fail_second: failing.clone(),
                files: std::collections::HashMap::from([
                    (
                        "/generated/first".into(),
                        ("image/gif".into(), animation.clone()),
                    ),
                    ("/generated/second".into(), ("image/png".into(), png())),
                    ("/generated/malformed".into(), ("image/png".into(), png())),
                ]),
            }),
        ));
        let mut first = source("first", "animation.png");
        first.mime_type = "image/gif".into();
        first.device_ids = vec!["remote-owner".into()];
        let mut second = source("second", "second.png");
        second.device_ids = vec!["remote-owner".into()];
        let sources = vec![first, second];
        let failed = save_gallery_images(
            &engine,
            &executor,
            Some("local-device"),
            sources.clone(),
            directory.path().into(),
            None,
        )
        .await;
        assert_eq!(failed.saved.len(), 1);
        assert_eq!(failed.failures.len(), 1);
        assert!(!failed.complete());
        assert_eq!(failed.saved[0].name, "animation.gif");
        assert_eq!(
            std::fs::read(&failed.saved[0].path).unwrap(),
            animation,
            "animated original is preserved, not a PNG preview"
        );
        let first_requests = calls
            .lock()
            .unwrap()
            .iter()
            .filter(|call| call["path"] == "/generated/first")
            .count();
        assert!(first_requests > 1, "read includes chunk continuation");
        assert!(
            calls
                .lock()
                .unwrap()
                .iter()
                .all(|call| call["targetDeviceId"] == "remote-owner")
        );
        failing.store(false, std::sync::atomic::Ordering::SeqCst);
        let recovered = save_gallery_images(
            &engine,
            &executor,
            Some("local-device"),
            sources,
            directory.path().into(),
            Some(failed),
        )
        .await;
        assert!(recovered.complete());
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 2);
        assert_eq!(
            calls
                .lock()
                .unwrap()
                .iter()
                .filter(|call| call["path"] == "/generated/first")
                .count(),
            first_requests,
            "successful file is neither fetched nor saved again"
        );
        assert_eq!(
            std::fs::read(directory.path().join("second.png")).unwrap(),
            png()
        );
        let mut malformed = source("malformed", "malformed.png");
        malformed.device_ids = vec!["local-device".into()];
        let bad = save_gallery_images(
            &engine,
            &executor,
            Some("local-device"),
            vec![malformed],
            directory.path().into(),
            None,
        )
        .await;
        assert!(bad.saved.is_empty());
        assert_eq!(bad.failures.len(), 1);
        assert!(bad.failures[0].message.contains("completion status"));
        assert!(!bad.complete());
        assert!(
            calls
                .lock()
                .unwrap()
                .last()
                .unwrap()
                .get("targetDeviceId")
                .is_none(),
            "local device is not relay-forwarded"
        );
        assert_eq!(
            std::fs::read_dir(directory.path()).unwrap().count(),
            2,
            "malformed download creates no partial export"
        );
    }

    #[test]
    fn gallery_explicit_retry_never_duplicates_a_pending_or_loaded_read() {
        let key = super::super::AttachmentKey::new(
            "gallery-retry-test",
            "/gallery-retry.png",
            Some("image/png"),
        );
        assert!(super::super::begin_load_for(&key));
        assert!(!super::super::retry_attachment_for(&key));
        super::super::store_error_for(&key);
        assert!(super::super::retry_attachment_for(&key));
        assert!(super::super::begin_load_for(&key));
        super::super::store_loaded_for(
            &key,
            "image.png".into(),
            std::sync::Arc::new(gpui::Image::from_bytes(gpui::ImageFormat::Png, png())),
        );
        assert!(!super::super::retry_attachment_for(&key));
        assert!(matches!(
            super::super::attachment_snapshot_for(&key),
            super::super::AttachmentSnapshot::Loaded(_)
        ));
    }
}
