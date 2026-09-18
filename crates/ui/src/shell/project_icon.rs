//! Repository artwork is fetched once per project/connection, off the render thread.
use super::*;
use crate::files::client::{FilesRequestContext, WorkspaceFilesClient};
use crate::image_media::{MediaImage, decode_project_icon, release_media};

pub(super) const ICON_PATHS: &[&str] = &[
    "public/apple-touch-icon.png",
    "apple-touch-icon.png",
    "public/favicon.svg",
    "favicon.svg",
    "public/favicon.png",
    "public/icon.png",
    "public/logo.png",
    "favicon.png",
    "app/icon.png",
    "src/app/icon.png",
    "public/favicon.ico",
    "favicon.ico",
    "app/favicon.ico",
    "static/favicon.ico",
    "src-tauri/icons/icon.png",
    "assets/icon.png",
    "src/assets/icon.png",
];

fn load_local_icon(root: &std::path::Path) -> Option<MediaImage> {
    // A project can point at a subdirectory; match the remote workspace RPC's
    // checkout-root resolution, including linked worktrees with a .git file.
    let canonical = root.canonicalize().ok()?;
    let root = canonical
        .ancestors()
        .find(|path| path.join(".git").exists())
        .unwrap_or(&canonical);
    for path in ICON_PATHS {
        let path = root.join(path);
        if !path.is_file() {
            continue;
        }
        let bytes = std::fs::File::open(&path).ok().and_then(|file| {
            use std::io::Read;
            let mut bytes = Vec::new();
            file.take(zeron_proto::MAX_WORKSPACE_IMAGE_BYTES as u64 + 1)
                .read_to_end(&mut bytes)
                .ok()?;
            Some(bytes)
        })?;
        let mime = if path.extension().is_some_and(|e| e == "svg") {
            "image/svg+xml"
        } else {
            "image/png"
        };
        return decode_project_icon(mime, bytes).ok();
    }
    None
}

// Curated badge tones: (dark appearance, light appearance). Keep the ordering
// stable so projects retain their assigned color. These are explicit colors,
// independent of the selected theme accent; only their appearance variant changes.
const MONOGRAM_PALETTE: [(u32, u32); 8] = [
    (0x94a3b8, 0x475569), // slate
    (0x93c5fd, 0x2563eb), // blue
    (0xc4b5fd, 0x7c3aed), // violet
    (0xfda4af, 0xbe123c), // rose
    (0xfcd34d, 0xa16207), // amber
    (0x6ee7b7, 0x047857), // emerald
    (0x5eead4, 0x0f766e), // teal
    (0xfdba74, 0xc2410c), // orange
];

fn monogram(name: &str, seed: &str, theme: &Theme) -> AnyElement {
    // FNV-1a selects a stable entry from the curated palette.
    let hash = seed.bytes().fold(2166136261u32, |hash, byte| {
        (hash ^ u32::from(byte)).wrapping_mul(16777619)
    });
    let letter = name
        .trim()
        .chars()
        .next()
        .unwrap_or('?')
        .to_uppercase()
        .to_string();
    let (dark, light) = MONOGRAM_PALETTE[hash as usize % MONOGRAM_PALETTE.len()];
    let tone = gpui::Hsla::from(gpui::rgb(if theme.appearance.is_dark() {
        dark
    } else {
        light
    }));
    let tile = div()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(3.0))
        .bg(tone.opacity(0.08))
        .text_color(tone.opacity(0.85))
        .font_family(theme.font_mono.clone())
        .font_weight(gpui::FontWeight::MEDIUM)
        .child(
            div()
                .w_full()
                .text_center()
                .text_size(px(9.0))
                .line_height(px(13.0))
                .child(letter),
        );
    crate::frost::frosted(3.0, crate::frost::MENU_BLUR, tile).into_any_element()
}

pub(super) struct ProjectIcon {
    name: String,
    seed: String,
    media: Option<MediaImage>,
    refreshed: std::time::Instant,
    _task: Task<()>,
}

impl ProjectIcon {
    fn new(
        name: String,
        seed: String,
        context: FilesRequestContext,
        engine: Option<crate::state::EngineHandle>,
        cx: &mut Context<Self>,
    ) -> Self {
        cx.on_release(|this, cx| release_media(this.media.take(), cx))
            .detach();
        let task = cx.spawn(async move |this, cx| {
            let executor = cx.background_executor().clone();
            let load = async {
                if context.target_device_id.is_none() {
                    let root = std::path::PathBuf::from(context.cwd);
                    return executor.spawn(async move { load_local_icon(&root) }).await;
                }
                let client = WorkspaceFilesClient::new(engine?, context.clone());
                for path in ICON_PATHS {
                    // This also resolves the current checkout identity on the owning host.
                    let file = match client
                        .read_file(zeron_proto::ReadWorkspaceFileRequest {
                            target: context.target.clone(),
                            path: (*path).into(),
                        })
                        .await
                    {
                        Ok(file) => file,
                        Err(error) if error.retryable() => return None,
                        Err(_) => continue,
                    };
                    let (mime, bytes) = client
                        .read_image((*path).into(), file.checkout_id)
                        .await
                        .ok()?;
                    return executor
                        .spawn(async move { decode_project_icon(&mime, bytes).ok() })
                        .await;
                }
                None
            };
            let media = match futures::future::select(
                Box::pin(load),
                Box::pin(executor.timer(Duration::from_secs(30))),
            )
            .await
            {
                futures::future::Either::Left((media, _)) => {
                    media.map(|media| media.for_view((16.0, 16.0), 2.0, 4096))
                }
                _ => None,
            };
            let _ = this.update(cx, |this, cx| {
                this.media = media;
                cx.notify();
            });
        });
        Self {
            name,
            seed,
            media: None,
            refreshed: std::time::Instant::now(),
            _task: task,
        }
    }
}

impl Render for ProjectIcon {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        match &self.media {
            Some(media) => gpui::img(media.image.clone())
                .size_full()
                .object_fit(gpui::ObjectFit::Contain)
                .into_any_element(),
            None => monogram(&self.name, &self.seed, Theme::of(cx)),
        }
    }
}

impl Shell {
    pub(super) fn render_project_icon(
        &self,
        chat_id: &str,
        size: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.state.read(cx);
        let space = state
            .chats
            .iter()
            .find(|chat| chat.id == chat_id)
            .and_then(|chat| state.space_for_chat(chat));
        let name = space
            .map(|space| space.display_name().to_string())
            .unwrap_or_else(|| "Home".into());
        let seed = space
            .map(|space| space.path.clone())
            .unwrap_or_else(|| "home".into());
        let context = space.map(|space| FilesRequestContext {
            target: zeron_proto::WorkspaceTarget {
                chat_id: None,
                space_id: Some(space.id.clone()),
                checkout_path: None,
            },
            target_device_id: (state.local_device_id.as_deref() != Some(&space.device_id))
                .then(|| space.device_id.clone()),
            cwd: space.path.clone(),
            checkout_id: space.checkout_id.clone(),
        });
        let Some(context) = context else {
            return div()
                .size(px(size))
                .flex_none()
                .child(monogram(&name, &seed, Theme::of(cx)))
                .into_any_element();
        };
        let key = format!(
            "{:?}:{:?}:{}:{:?}:{}",
            self.active_sidebar_pin_profile_key(cx),
            context.target_device_id,
            context.cwd,
            context.checkout_id,
            name
        );
        let engine = state.engine().cloned();
        // Don't cache a remote miss before a connection exists.
        if context.target_device_id.is_some() && engine.is_none() {
            return div()
                .size(px(size))
                .flex_none()
                .child(monogram(&name, &seed, Theme::of(cx)))
                .into_any_element();
        }
        let mut cache = self.project_icons.borrow_mut();
        cache.retain(|_, entity| entity.read(cx).refreshed.elapsed() < Duration::from_secs(300));
        let entity = cache
            .entry(key)
            .or_insert_with(|| cx.new(|cx| ProjectIcon::new(name, seed, context, engine, cx)))
            .clone();
        div()
            .size(px(size))
            .flex_none()
            .child(entity)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn png(path: &std::path::Path, width: u32) {
        image::RgbaImage::new(width, 2).save(path).unwrap();
    }
    #[test]
    fn sidebar_project_icon_priority_and_missing_fallback() {
        let temp = tempfile::tempdir().unwrap();
        assert!(load_local_icon(temp.path()).is_none());
        png(&temp.path().join("favicon.png"), 3);
        assert_eq!(load_local_icon(temp.path()).unwrap().width, 3.0);
        std::fs::create_dir(temp.path().join("public")).unwrap();
        png(&temp.path().join("public/apple-touch-icon.png"), 7);
        assert_eq!(load_local_icon(temp.path()).unwrap().width, 7.0);
        std::fs::write(temp.path().join(".git"), "gitdir: /unused-test-checkout").unwrap();
        std::fs::create_dir_all(temp.path().join("src/nested")).unwrap();
        assert_eq!(
            load_local_icon(&temp.path().join("src/nested"))
                .unwrap()
                .width,
            7.0
        );
        // A corrupt first match uses the default rather than showing unrelated lower-priority art.
        std::fs::write(temp.path().join("public/apple-touch-icon.png"), b"invalid").unwrap();
        assert!(load_local_icon(temp.path()).is_none());
    }
    #[test]
    fn sidebar_project_icons_support_svg_and_ico() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::write(temp.path().join("favicon.svg"), br##"<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"><rect width="12" height="8" fill="#f00"/></svg>"##).unwrap();
        assert_eq!(load_local_icon(temp.path()).unwrap().width, 12.0);
        std::fs::remove_file(temp.path().join("favicon.svg")).unwrap();
        image::RgbaImage::new(16, 16)
            .save(temp.path().join("favicon.ico"))
            .unwrap();
        assert_eq!(load_local_icon(temp.path()).unwrap().width, 16.0);
    }
}
