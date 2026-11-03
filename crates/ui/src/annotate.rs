//! Image annotation: mark up an image before it goes to the agent.
//!
//! Click an image (a composer attachment or a transcript thumbnail), choose
//! Annotate, draw numbered boxes or place text, and Done flattens the marks
//! into a new PNG that is staged in the composer. The numbered notes ride the
//! prompt as text too ([`prompt_block`]), so the agent gets the picture and
//! the words. Modeled on the Claude desktop app's annotate flow.
//!
//! This module is the model and the flattening, both pure and window-free.
//! The editor view lives in [`editor`]. Coordinates are image pixels: what
//! the agent sees in the flattened file is what the boxes say.

pub mod editor;

use std::io::Cursor;

/// The four marker colors, in toolbar order. Red is the default.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum MarkColor {
    #[default]
    Red,
    Blue,
    Green,
    Yellow,
}

impl MarkColor {
    pub const ALL: [MarkColor; 4] = [
        MarkColor::Red,
        MarkColor::Blue,
        MarkColor::Green,
        MarkColor::Yellow,
    ];

    /// sRGB as `0xRRGGBB`; the same value paints on screen and in the file.
    pub const fn rgb(self) -> u32 {
        match self {
            MarkColor::Red => 0xEF4444,
            MarkColor::Blue => 0x3B82F6,
            MarkColor::Green => 0x22C55E,
            MarkColor::Yellow => 0xEAB308,
        }
    }

    /// Text drawn on a fill of this color: white, except on yellow.
    pub const fn on_rgb(self) -> u32 {
        match self {
            MarkColor::Yellow => 0x1C1917,
            _ => 0xFFFFFF,
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            MarkColor::Red => "Red",
            MarkColor::Blue => "Blue",
            MarkColor::Green => "Green",
            MarkColor::Yellow => "Yellow",
        }
    }

    fn hex(rgb: u32) -> String {
        format!("#{rgb:06X}")
    }
}

/// The tool a drag or click uses. Rectangle is the default.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Tool {
    #[default]
    Rect,
    Text,
}

/// An axis-aligned box in image pixels, origin top-left.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ImageRect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl ImageRect {
    /// The box a drag from `a` to `b` spans, in any direction, clamped to
    /// an image of `size`.
    pub fn from_drag(a: (f32, f32), b: (f32, f32), size: (f32, f32)) -> Self {
        let clamp = |v: f32, max: f32| v.clamp(0.0, max);
        let (x0, x1) = (clamp(a.0.min(b.0), size.0), clamp(a.0.max(b.0), size.0));
        let (y0, y1) = (clamp(a.1.min(b.1), size.1), clamp(a.1.max(b.1), size.1));
        Self {
            x: x0,
            y: y0,
            w: x1 - x0,
            h: y1 - y0,
        }
    }

    pub fn right(&self) -> f32 {
        self.x + self.w
    }

    pub fn bottom(&self) -> f32 {
        self.y + self.h
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Shape {
    /// A box with a numbered pin at its top-left corner and an optional note.
    Rect(ImageRect),
    /// Free text whose top-left corner sits at `(x, y)`, `size` px tall type.
    Text { x: f32, y: f32, size: f32 },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Annotation {
    pub id: u64,
    pub shape: Shape,
    pub color: MarkColor,
    /// A box's note, or the words of a text mark.
    pub text: String,
}

impl Annotation {
    pub fn is_rect(&self) -> bool {
        matches!(self.shape, Shape::Rect(_))
    }
}

/// Smallest box a drag commits, in image pixels per side. Anything smaller
/// is a click, not a box.
pub const MIN_BOX: f32 = 4.0;
/// Undo depth. Each add, remove, recolor or note change is one step.
const UNDO_LIMIT: usize = 100;

/// Every mark on one image, with selection and undo.
#[derive(Clone, Debug, Default)]
pub struct Annotations {
    items: Vec<Annotation>,
    selected: Option<u64>,
    undo: Vec<Vec<Annotation>>,
    next_id: u64,
}

impl Annotations {
    pub fn items(&self) -> &[Annotation] {
        &self.items
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn get(&self, id: u64) -> Option<&Annotation> {
        self.items.iter().find(|a| a.id == id)
    }

    pub fn selected(&self) -> Option<u64> {
        self.selected.filter(|id| self.get(*id).is_some())
    }

    pub fn select(&mut self, id: Option<u64>) {
        self.selected = id.filter(|id| self.get(*id).is_some());
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    fn checkpoint(&mut self) {
        if self.undo.len() == UNDO_LIMIT {
            self.undo.remove(0);
        }
        self.undo.push(self.items.clone());
    }

    fn mint(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    /// Add a box. A box under [`MIN_BOX`] on either side is rejected (it
    /// was a click). The new box is selected.
    pub fn add_rect(&mut self, rect: ImageRect, color: MarkColor) -> Option<u64> {
        if !(rect.w >= MIN_BOX && rect.h >= MIN_BOX) {
            return None;
        }
        self.checkpoint();
        let id = self.mint();
        self.items.push(Annotation {
            id,
            shape: Shape::Rect(rect),
            color,
            text: String::new(),
        });
        self.selected = Some(id);
        Some(id)
    }

    /// Place text. It starts empty and selected; [`commit_text`] fills it,
    /// and an empty text mark is dropped when its editing ends.
    ///
    /// [`commit_text`]: Self::commit_text
    pub fn add_text(&mut self, at: (f32, f32), size: f32, color: MarkColor) -> u64 {
        self.checkpoint();
        let id = self.mint();
        self.items.push(Annotation {
            id,
            shape: Shape::Text {
                x: at.0,
                y: at.1,
                size,
            },
            color,
            text: String::new(),
        });
        self.selected = Some(id);
        id
    }

    /// End editing a mark's words. A box keeps its trimmed note; a text mark
    /// with no words is removed. Returns whether anything changed. An
    /// unchanged note adds no undo step.
    pub fn commit_text(&mut self, id: u64, text: &str) -> bool {
        let text = text.trim();
        let Some(index) = self.items.iter().position(|a| a.id == id) else {
            return false;
        };
        let item = &self.items[index];
        if !item.is_rect() && text.is_empty() {
            // Placing text and then typing nothing undoes the placement too.
            self.items.remove(index);
            if let Some(previous) = self.undo.last()
                && previous.iter().all(|a| a.id != id)
            {
                self.undo.pop();
            }
            if self.selected == Some(id) {
                self.selected = None;
            }
            return true;
        }
        if item.text == text {
            return false;
        }
        self.checkpoint();
        self.items[index].text = text.to_string();
        true
    }

    pub fn recolor(&mut self, id: u64, color: MarkColor) -> bool {
        match self.items.iter().position(|a| a.id == id) {
            Some(index) if self.items[index].color != color => {
                self.checkpoint();
                self.items[index].color = color;
                true
            }
            _ => false,
        }
    }

    pub fn remove(&mut self, id: u64) -> bool {
        let Some(index) = self.items.iter().position(|a| a.id == id) else {
            return false;
        };
        self.checkpoint();
        self.items.remove(index);
        if self.selected == Some(id) {
            self.selected = None;
        }
        true
    }

    pub fn remove_selected(&mut self) -> bool {
        match self.selected() {
            Some(id) => self.remove(id),
            None => false,
        }
    }

    pub fn undo(&mut self) -> bool {
        let Some(previous) = self.undo.pop() else {
            return false;
        };
        self.items = previous;
        if self.selected().is_none() {
            self.selected = None;
        }
        true
    }

    /// A box's pin number: 1, 2, 3 in drawing order, counting boxes only.
    /// Text marks carry no pin.
    pub fn number(&self, id: u64) -> Option<usize> {
        self.items
            .iter()
            .filter(|a| a.is_rect())
            .position(|a| a.id == id)
            .map(|index| index + 1)
    }
}

/// Header of the notes block, so a reader (or a later parser) can find it.
pub const PROMPT_HEADER: &str = "Annotations";

/// The notes that ride the prompt next to the flattened image, or `None`
/// when there are no marks. Boxes are numbered like their pins and carry
/// their pixel box in the flattened file as `x,y,w,h`; text marks follow.
///
/// ```text
/// Annotations on screenshot.png (boxes are x,y,w,h in image pixels):
/// 1. [box 120,80,300,140] tighten this
/// 2. [box 40,400,200,60] (no note)
/// Text on the image:
/// - [text 500,30] "ship it"
/// ```
pub fn prompt_block(name: &str, annotations: &Annotations) -> Option<String> {
    let items = annotations.items();
    if items.is_empty() {
        return None;
    }
    let round = |v: f32| v.round() as i64;
    let mut lines = vec![format!(
        "{PROMPT_HEADER} on {name} (boxes are x,y,w,h in image pixels):"
    )];
    let mut number = 0;
    for item in items {
        if let Shape::Rect(r) = &item.shape {
            number += 1;
            let note = single_line(&item.text);
            let note = if note.is_empty() {
                "(no note)".to_string()
            } else {
                note
            };
            lines.push(format!(
                "{number}. [box {},{},{},{}] {note}",
                round(r.x),
                round(r.y),
                round(r.w),
                round(r.h)
            ));
        }
    }
    let texts: Vec<String> = items
        .iter()
        .filter_map(|item| match &item.shape {
            Shape::Text { x, y, .. } if !item.text.trim().is_empty() => Some(format!(
                "- [text {},{}] \"{}\"",
                round(*x),
                round(*y),
                single_line(&item.text).replace('"', "'")
            )),
            _ => None,
        })
        .collect();
    if !texts.is_empty() {
        lines.push("Text on the image:".to_string());
        lines.extend(texts);
    }
    Some(lines.join("\n"))
}

fn single_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Fold annotation blocks into the prompt, after the user's words and
/// before the attachment refs trailer.
pub fn with_annotations(text: &str, blocks: &[&str]) -> String {
    let blocks: Vec<&str> = blocks
        .iter()
        .map(|b| b.trim())
        .filter(|b| !b.is_empty())
        .collect();
    if blocks.is_empty() {
        return text.to_string();
    }
    let body = text.trim_end();
    let notes = blocks.join("\n\n");
    if body.is_empty() {
        notes
    } else {
        format!("{body}\n\n{notes}")
    }
}

/// The flattened file's name: `shot.png` becomes `shot-annotated.png`.
pub fn annotated_name(name: &str) -> String {
    let name = crate::attachments::display_file_name(name);
    let stem = match name.rsplit_once('.') {
        Some((stem, _)) if !stem.is_empty() => stem,
        _ => name,
    };
    let stem = stem.strip_suffix("-annotated").unwrap_or(stem);
    format!("{stem}-annotated.png")
}

/// On-screen sizes that the flattened file reproduces, in screen pixels.
/// [`flatten`] divides them by the view's scale, so the file shows the marks
/// at the size they were drawn.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MarkMetrics {
    pub stroke: f32,
    pub box_radius: f32,
    pub pin_diameter: f32,
    pub pin_text: f32,
    pub chip_pad_x: f32,
    pub chip_pad_y: f32,
    pub chip_radius: f32,
}

pub const SCREEN_METRICS: MarkMetrics = MarkMetrics {
    stroke: 2.0,
    box_radius: 4.0,
    pin_diameter: 20.0,
    // typography TEXT_CAPTION.
    pin_text: 11.0,
    chip_pad_x: 8.0,
    chip_pad_y: 4.0,
    chip_radius: 6.0,
};

/// Type size of a text mark on screen (typography TEXT_TITLE).
pub const TEXT_MARK_SIZE: f32 = 13.0;

impl MarkMetrics {
    fn scaled(&self, factor: f32) -> Self {
        Self {
            stroke: self.stroke * factor,
            box_radius: self.box_radius * factor,
            pin_diameter: self.pin_diameter * factor,
            pin_text: self.pin_text * factor,
            chip_pad_x: self.chip_pad_x * factor,
            chip_pad_y: self.chip_pad_y * factor,
            chip_radius: self.chip_radius * factor,
        }
    }
}

/// The largest side [`flatten`] accepts, matching the preview decoder.
const MAX_SIDE: u32 = 8192;

fn decode(bytes: &[u8]) -> Result<image::RgbaImage, String> {
    let mut reader = image::ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| e.to_string())?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_SIDE);
    limits.max_image_height = Some(MAX_SIDE);
    limits.max_alloc = Some(512 * 1024 * 1024);
    reader.limits(limits);
    match reader.decode() {
        Ok(decoded) => Ok(decoded.to_rgba8()),
        Err(raster) => rasterize_svg(bytes).ok_or_else(|| raster.to_string()),
    }
}

fn rasterize_svg(bytes: &[u8]) -> Option<image::RgbaImage> {
    let tree = usvg::Tree::from_data(bytes, &crate::image_media::svg_options()).ok()?;
    let size = tree.size().to_int_size();
    let (w, h) = (size.width().min(MAX_SIDE), size.height().min(MAX_SIDE));
    let mut pixmap = resvg::tiny_skia::Pixmap::new(w, h)?;
    let transform = resvg::tiny_skia::Transform::from_scale(
        w as f32 / tree.size().width(),
        h as f32 / tree.size().height(),
    );
    resvg::render(&tree, transform, &mut pixmap.as_mut());
    Some(unpremultiply(
        pixmap.width(),
        pixmap.height(),
        pixmap.data(),
    ))
}

fn unpremultiply(width: u32, height: u32, data: &[u8]) -> image::RgbaImage {
    let mut out = image::RgbaImage::new(width, height);
    for (dst, src) in out.pixels_mut().zip(data.chunks_exact(4)) {
        let a = src[3] as u32;
        *dst = if a == 0 {
            image::Rgba([0, 0, 0, 0])
        } else {
            let un = |c: u8| ((c as u32 * 255 + a / 2) / a).min(255) as u8;
            image::Rgba([un(src[0]), un(src[1]), un(src[2]), src[3]])
        };
    }
    out
}

/// Pixel size of an encoded image (raster header or SVG viewport) without
/// decoding it.
pub fn image_size(bytes: &[u8]) -> Option<(f32, f32)> {
    if let Ok(reader) = image::ImageReader::new(Cursor::new(bytes)).with_guessed_format()
        && reader.format().is_some()
        && let Ok((w, h)) = reader.into_dimensions()
    {
        return Some((w as f32, h as f32));
    }
    let tree = usvg::Tree::from_data(bytes, &crate::image_media::svg_options()).ok()?;
    let size = tree.size().to_int_size();
    Some((
        size.width().min(MAX_SIDE) as f32,
        size.height().min(MAX_SIDE) as f32,
    ))
}

/// Geist faces for measuring text marks, regular then medium.
fn mark_face() -> Option<ttf_parser::Face<'static>> {
    let faces: Vec<ttf_parser::Face<'static>> = crate::typography::bundled_font_faces()
        .filter_map(|data| ttf_parser::Face::parse(data, 0).ok())
        .filter(|face| !face.is_monospaced())
        .collect();
    faces
        .iter()
        .min_by_key(|face| (face.weight().to_number() as i32 - 500).abs())
        .cloned()
}

/// Advance width and cap height of `text` at `size` px in Geist Medium.
fn measure(text: &str, size: f32) -> (f32, f32) {
    let Some(face) = mark_face() else {
        return (text.chars().count() as f32 * size * 0.56, size * 0.7);
    };
    let per_unit = size / face.units_per_em() as f32;
    let width: f32 = text
        .chars()
        .map(|c| {
            face.glyph_index(c)
                .and_then(|g| face.glyph_hor_advance(g))
                .map(|a| a as f32 * per_unit)
                .unwrap_or(size * 0.56)
        })
        .sum();
    let cap = face
        .capital_height()
        .map(|c| c as f32 * per_unit)
        .unwrap_or(size * 0.7);
    (width, cap)
}

fn escape_xml(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control())
        .map(|c| match c {
            '&' => "&amp;".to_string(),
            '<' => "&lt;".to_string(),
            '>' => "&gt;".to_string(),
            '"' => "&quot;".to_string(),
            '\'' => "&apos;".to_string(),
            c => c.to_string(),
        })
        .collect()
}

/// The marks as an SVG the size of the image. `factor` converts screen
/// pixels to image pixels (`1 / view scale`).
pub fn overlay_svg(width: f32, height: f32, annotations: &Annotations, factor: f32) -> String {
    let m = SCREEN_METRICS.scaled(factor.max(0.01));
    let mut svg = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"{height}\" viewBox=\"0 0 {width} {height}\">"
    );
    let font = "font-family=\"Geist\" font-weight=\"500\"";
    // Boxes first, then pins and text on top, so a pin is never under a box.
    for item in annotations.items() {
        if let Shape::Rect(r) = &item.shape {
            let inset = m.stroke / 2.0;
            svg.push_str(&format!(
                "<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" rx=\"{}\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"/>",
                r.x + inset,
                r.y + inset,
                (r.w - m.stroke).max(0.0),
                (r.h - m.stroke).max(0.0),
                m.box_radius,
                MarkColor::hex(item.color.rgb()),
                m.stroke
            ));
        }
    }
    for item in annotations.items() {
        match &item.shape {
            Shape::Rect(r) => {
                let number = annotations.number(item.id).unwrap_or(0).to_string();
                let radius = m.pin_diameter / 2.0;
                // The pin's center sits on the box's corner, kept on the image.
                let cx = r.x.clamp(radius, (width - radius).max(radius));
                let cy = r.y.clamp(radius, (height - radius).max(radius));
                let (_, cap) = measure(&number, m.pin_text);
                svg.push_str(&format!(
                    "<circle cx=\"{cx}\" cy=\"{cy}\" r=\"{radius}\" fill=\"{}\"/>",
                    MarkColor::hex(item.color.rgb())
                ));
                // Center the digits' cap height on the circle (optical, not
                // line box) center.
                svg.push_str(&format!(
                    "<text x=\"{cx}\" y=\"{}\" font-size=\"{}\" {font} text-anchor=\"middle\" fill=\"{}\">{number}</text>",
                    cy + cap / 2.0,
                    m.pin_text,
                    MarkColor::hex(item.color.on_rgb())
                ));
            }
            Shape::Text { x, y, size } => {
                if item.text.trim().is_empty() {
                    continue;
                }
                let text = single_line(&item.text);
                let (advance, cap) = measure(&text, *size);
                let chip_h = *size * 1.4 + 2.0 * m.chip_pad_y;
                let chip_w = advance + 2.0 * m.chip_pad_x;
                svg.push_str(&format!(
                    "<rect x=\"{x}\" y=\"{y}\" width=\"{chip_w}\" height=\"{chip_h}\" rx=\"{}\" fill=\"{}\"/>",
                    m.chip_radius,
                    MarkColor::hex(item.color.rgb())
                ));
                svg.push_str(&format!(
                    "<text x=\"{}\" y=\"{}\" font-size=\"{size}\" {font} fill=\"{}\">{}</text>",
                    x + m.chip_pad_x,
                    y + chip_h / 2.0 + cap / 2.0,
                    MarkColor::hex(item.color.on_rgb()),
                    escape_xml(&text)
                ));
            }
        }
    }
    svg.push_str("</svg>");
    svg
}

/// Paint the marks into a copy of the image and encode it as PNG. The
/// result has the source's pixel size. `factor` is image pixels per screen
/// pixel while the marks were drawn.
pub fn flatten(source: &[u8], annotations: &Annotations, factor: f32) -> Result<Vec<u8>, String> {
    let mut base = decode(source)?;
    let (width, height) = base.dimensions();
    let svg = overlay_svg(width as f32, height as f32, annotations, factor);
    let tree = usvg::Tree::from_str(&svg, &crate::image_media::svg_options())
        .map_err(|e| e.to_string())?;
    let mut pixmap = resvg::tiny_skia::Pixmap::new(width, height).ok_or("image has no pixels")?;
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::identity(),
        &mut pixmap.as_mut(),
    );
    // Source-over: the overlay is premultiplied, the base is straight alpha.
    for (dst, src) in base.pixels_mut().zip(pixmap.data().chunks_exact(4)) {
        let sa = src[3] as f32 / 255.0;
        if sa == 0.0 {
            continue;
        }
        let da = dst[3] as f32 / 255.0;
        let out_a = sa + da * (1.0 - sa);
        for c in 0..3 {
            let s = src[c] as f32 / 255.0;
            let d = dst[c] as f32 / 255.0 * da;
            let out = (s + d * (1.0 - sa)) / out_a.max(f32::EPSILON);
            dst[c] = (out * 255.0).round().clamp(0.0, 255.0) as u8;
        }
        dst[3] = (out_a * 255.0).round() as u8;
    }
    let mut png = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(base)
        .write_to(&mut png, image::ImageFormat::Png)
        .map_err(|e| e.to_string())?;
    Ok(png.into_inner())
}

/// What Done hands the image's owner: the flattened PNG to stage and the
/// notes for the prompt.
#[derive(Clone, Debug)]
pub struct Annotated {
    pub name: String,
    pub png: Vec<u8>,
    pub notes: Option<String>,
}

impl Annotated {
    /// The composer attachment for this result, carrying its notes.
    pub fn into_staged(self) -> crate::attachments::StagedAttachment {
        let mut staged = crate::attachments::stage_png_bytes(self.name, self.png);
        staged.annotations = self.notes.map(Into::into);
        staged
    }
}

#[cfg(test)]
mod tests;
