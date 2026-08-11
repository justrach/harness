//! Device-local interface typography: bundled font registration, the persisted
//! catalog choice, and the effective family installed into [`crate::theme::Theme`].

use std::borrow::Cow;
use std::path::{Path, PathBuf};

use gpui::{App, Global, SharedString};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::settings::UiSettings;

/// Stable, device-local interface font choices.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum UiFontFamily {
    #[default]
    Geist,
    GeistMono,
    System,
    Inter,
    AtkinsonHyperlegibleNext,
}

impl UiFontFamily {
    pub const ALL: [Self; 5] = [
        Self::Geist,
        Self::GeistMono,
        Self::System,
        Self::Inter,
        Self::AtkinsonHyperlegibleNext,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Geist => "Geist",
            Self::GeistMono => "Geist Mono",
            Self::System => "System UI",
            Self::Inter => "Inter",
            Self::AtkinsonHyperlegibleNext => "Atkinson Hyperlegible Next",
        }
    }

    pub fn family_name(self) -> &'static str {
        match self {
            Self::Geist => "Geist",
            Self::GeistMono => "Geist Mono",
            Self::System => ".SystemUIFont",
            Self::Inter => "Inter",
            Self::AtkinsonHyperlegibleNext => "Atkinson Hyperlegible Next",
        }
    }

    fn wire_name(self) -> &'static str {
        match self {
            Self::Geist => "geist",
            Self::GeistMono => "geistMono",
            Self::System => "system",
            Self::Inter => "inter",
            Self::AtkinsonHyperlegibleNext => "atkinsonHyperlegibleNext",
        }
    }

    fn from_wire_name(value: &str) -> Self {
        match value {
            "geist" => Self::Geist,
            "geistMono" => Self::GeistMono,
            "system" => Self::System,
            "inter" => Self::Inter,
            "atkinsonHyperlegibleNext" => Self::AtkinsonHyperlegibleNext,
            _ => Self::Geist,
        }
    }
}

impl Serialize for UiFontFamily {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.wire_name())
    }
}

impl<'de> Deserialize<'de> for UiFontFamily {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(Self::from_wire_name(&value))
    }
}

/// Which catalog families successfully registered during this process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FontAvailability {
    geist: bool,
    geist_mono: bool,
    inter: bool,
    atkinson: bool,
}

impl FontAvailability {
    pub fn all() -> Self {
        Self {
            geist: true,
            geist_mono: true,
            inter: true,
            atkinson: true,
        }
    }

    pub fn is_available(self, family: UiFontFamily) -> bool {
        match family {
            UiFontFamily::Geist => self.geist,
            UiFontFamily::GeistMono => self.geist_mono,
            UiFontFamily::System => true,
            UiFontFamily::Inter => self.inter,
            UiFontFamily::AtkinsonHyperlegibleNext => self.atkinson,
        }
    }

    fn fallback(self) -> UiFontFamily {
        if self.geist {
            UiFontFamily::Geist
        } else {
            UiFontFamily::System
        }
    }

    #[cfg(test)]
    pub(crate) fn without(mut self, family: UiFontFamily) -> Self {
        match family {
            UiFontFamily::Geist => self.geist = false,
            UiFontFamily::GeistMono => self.geist_mono = false,
            UiFontFamily::System => {}
            UiFontFamily::Inter => self.inter = false,
            UiFontFamily::AtkinsonHyperlegibleNext => self.atkinson = false,
        }
        self
    }
}

impl Default for FontAvailability {
    fn default() -> Self {
        Self::all()
    }
}

/// Requested and effective typography for the process.
pub struct TypographyState {
    pub requested: UiFontFamily,
    pub effective: UiFontFamily,
    pub availability: FontAvailability,
    data_dir: PathBuf,
}

impl Global for TypographyState {}

const GEIST: [&[u8]; 8] = [
    include_bytes!("../assets/fonts/Geist.ttf"),
    include_bytes!("../assets/fonts/Geist-Italic.ttf"),
    include_bytes!("../assets/fonts/Geist-Medium.ttf"),
    include_bytes!("../assets/fonts/Geist-MediumItalic.ttf"),
    include_bytes!("../assets/fonts/Geist-SemiBold.ttf"),
    include_bytes!("../assets/fonts/Geist-SemiBoldItalic.ttf"),
    include_bytes!("../assets/fonts/Geist-Bold.ttf"),
    include_bytes!("../assets/fonts/Geist-BoldItalic.ttf"),
];

const GEIST_MONO: [&[u8]; 8] = [
    include_bytes!("../assets/fonts/GeistMono.ttf"),
    include_bytes!("../assets/fonts/GeistMono-Italic.ttf"),
    include_bytes!("../assets/fonts/GeistMono-Medium.ttf"),
    include_bytes!("../assets/fonts/GeistMono-MediumItalic.ttf"),
    include_bytes!("../assets/fonts/GeistMono-SemiBold.ttf"),
    include_bytes!("../assets/fonts/GeistMono-SemiBoldItalic.ttf"),
    include_bytes!("../assets/fonts/GeistMono-Bold.ttf"),
    include_bytes!("../assets/fonts/GeistMono-BoldItalic.ttf"),
];

const INTER: [&[u8]; 8] = [
    include_bytes!("../assets/fonts/Inter-Regular.ttf"),
    include_bytes!("../assets/fonts/Inter-Italic.ttf"),
    include_bytes!("../assets/fonts/Inter-Medium.ttf"),
    include_bytes!("../assets/fonts/Inter-MediumItalic.ttf"),
    include_bytes!("../assets/fonts/Inter-SemiBold.ttf"),
    include_bytes!("../assets/fonts/Inter-SemiBoldItalic.ttf"),
    include_bytes!("../assets/fonts/Inter-Bold.ttf"),
    include_bytes!("../assets/fonts/Inter-BoldItalic.ttf"),
];

const ATKINSON: [&[u8]; 8] = [
    include_bytes!("../assets/fonts/AtkinsonHyperlegibleNext-Regular.ttf"),
    include_bytes!("../assets/fonts/AtkinsonHyperlegibleNext-Italic.ttf"),
    include_bytes!("../assets/fonts/AtkinsonHyperlegibleNext-Medium.ttf"),
    include_bytes!("../assets/fonts/AtkinsonHyperlegibleNext-MediumItalic.ttf"),
    include_bytes!("../assets/fonts/AtkinsonHyperlegibleNext-SemiBold.ttf"),
    include_bytes!("../assets/fonts/AtkinsonHyperlegibleNext-SemiBoldItalic.ttf"),
    include_bytes!("../assets/fonts/AtkinsonHyperlegibleNext-Bold.ttf"),
    include_bytes!("../assets/fonts/AtkinsonHyperlegibleNext-BoldItalic.ttf"),
];

fn register_family(cx: &App, family: UiFontFamily, faces: &'static [&'static [u8]]) -> bool {
    let fonts = faces.iter().map(|face| Cow::Borrowed(*face)).collect();
    match cx.text_system().add_fonts(fonts) {
        Ok(()) => true,
        Err(err) => {
            tracing::warn!(font_family = family.label(), error = %err, "failed to register bundled font family");
            false
        }
    }
}

/// Register each family independently so one bad optional asset cannot hide
/// the rest of the catalog.
pub fn register_fonts(cx: &App) -> FontAvailability {
    FontAvailability {
        geist: register_family(cx, UiFontFamily::Geist, &GEIST),
        geist_mono: register_family(cx, UiFontFamily::GeistMono, &GEIST_MONO),
        inter: register_family(cx, UiFontFamily::Inter, &INTER),
        atkinson: register_family(cx, UiFontFamily::AtkinsonHyperlegibleNext, &ATKINSON),
    }
}

fn resolve_effective(requested: UiFontFamily, availability: FontAvailability) -> UiFontFamily {
    if availability.is_available(requested) {
        requested
    } else {
        availability.fallback()
    }
}

/// Install typography state before appearance builds the first [`crate::theme::Theme`].
pub fn init(
    requested: UiFontFamily,
    availability: FontAvailability,
    data_dir: impl Into<PathBuf>,
    cx: &mut App,
) {
    let effective = resolve_effective(requested, availability);
    cx.set_global(TypographyState {
        requested,
        effective,
        availability,
        data_dir: data_dir.into(),
    });
}

pub fn requested(cx: &App) -> UiFontFamily {
    cx.try_global::<TypographyState>()
        .map(|state| state.requested)
        .unwrap_or_default()
}

pub fn effective(cx: &App) -> UiFontFamily {
    cx.try_global::<TypographyState>()
        .map(|state| state.effective)
        .unwrap_or_default()
}

pub fn effective_family_name(cx: &App) -> SharedString {
    effective(cx).family_name().into()
}

pub fn availability(cx: &App) -> FontAvailability {
    cx.try_global::<TypographyState>()
        .map(|state| state.availability)
        .unwrap_or_default()
}

pub fn is_available(family: UiFontFamily, cx: &App) -> bool {
    availability(cx).is_available(family)
}

/// Validate, apply, repaint, and persist one confirmed choice. Returns whether
/// the effective family changed (re-selecting the current family is a no-op).
pub fn set_family(family: UiFontFamily, cx: &mut App) -> bool {
    let Some(state) = cx.try_global::<TypographyState>() else {
        return false;
    };
    if !state.availability.is_available(family) {
        return false;
    }
    let effective = resolve_effective(family, state.availability);
    if state.requested == family && state.effective == effective {
        return false;
    }

    let data_dir = state.data_dir.clone();
    let effective_changed = state.effective != effective;
    let state = cx.global_mut::<TypographyState>();
    state.requested = family;
    state.effective = effective;

    if effective_changed {
        crate::theme::bump_style_generation();
        let appearance = crate::theme::current_appearance();
        crate::theme::Theme::install(appearance, cx);
        cx.refresh_windows();
    }
    persist(family, &data_dir);
    effective_changed
}

fn persist(family: UiFontFamily, data_dir: &Path) {
    let mut settings = UiSettings::load(data_dir);
    settings.ui_font_family = family;
    if let Err(err) = settings.save(data_dir) {
        tracing::warn!(error = %err, "could not persist interface font");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_values_round_trip_and_unknown_falls_back() {
        for family in UiFontFamily::ALL {
            let json = serde_json::to_string(&family).unwrap();
            assert_eq!(serde_json::from_str::<UiFontFamily>(&json).unwrap(), family);
        }
        assert_eq!(
            serde_json::from_str::<UiFontFamily>(r#""futureFont""#).unwrap(),
            UiFontFamily::Geist
        );
    }

    #[test]
    fn unavailable_family_resolves_to_geist() {
        let availability = FontAvailability::all().without(UiFontFamily::Inter);
        assert_eq!(
            resolve_effective(UiFontFamily::Inter, availability),
            UiFontFamily::Geist
        );
        assert!(availability.is_available(UiFontFamily::System));
    }

    #[test]
    fn catalog_order_is_stable() {
        assert_eq!(
            UiFontFamily::ALL.map(UiFontFamily::label),
            [
                "Geist",
                "Geist Mono",
                "System UI",
                "Inter",
                "Atkinson Hyperlegible Next"
            ]
        );
    }

    #[test]
    fn bundled_families_have_required_static_faces() {
        for (expected_family, faces) in [
            ("Geist", GEIST.as_slice()),
            ("Geist Mono", GEIST_MONO.as_slice()),
            ("Inter", INTER.as_slice()),
            ("Atkinson Hyperlegible Next", ATKINSON.as_slice()),
        ] {
            let mut found = Vec::new();
            for bytes in faces {
                let face = ttf_parser::Face::parse(bytes, 0).unwrap();
                found.push((face.weight().to_number(), face.is_italic()));
                let has_family = face.names().into_iter().any(|name| {
                    name.name_id == ttf_parser::name_id::TYPOGRAPHIC_FAMILY
                        && name.to_string().as_deref() == Some(expected_family)
                }) || face.names().into_iter().any(|name| {
                    name.name_id == ttf_parser::name_id::FAMILY
                        && name.to_string().as_deref() == Some(expected_family)
                });
                assert!(has_family, "wrong family metadata for {expected_family}");
            }
            found.sort_unstable();
            assert_eq!(
                found,
                vec![
                    (400, false),
                    (400, true),
                    (500, false),
                    (500, true),
                    (600, false),
                    (600, true),
                    (700, false),
                    (700, true),
                ],
                "missing static faces for {expected_family}"
            );
        }
    }
}
