//! What a viewer may do to a page, and the DevTools commands each becomes.
//! Coordinates are the page's CSS pixels within the visible viewport, the
//! same space the frames' `width` and `height` describe.

use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use super::url_rule;

/// The most text one input may insert.
pub const MAX_TEXT_CHARS: usize = 2000;
/// The largest single scroll step, in CSS pixels.
const MAX_SCROLL: f64 = 20_000.0;

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PageInput {
    Tap {
        x: f64,
        y: f64,
    },
    Scroll {
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
    },
    Text {
        text: String,
    },
    Key {
        name: String,
    },
    Navigate {
        url: String,
    },
    Back,
    Forward,
    Reload,
    Resize {
        width: f64,
        height: f64,
        #[serde(default)]
        scale: Option<f64>,
    },
}

/// The page's emulated screen: a phone's size in CSS pixels and its scale.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Viewport {
    pub width: u32,
    pub height: u32,
    pub scale: f64,
}

impl Default for Viewport {
    fn default() -> Self {
        Self {
            width: 390,
            height: 844,
            scale: 2.0,
        }
    }
}

impl Viewport {
    /// A viewer's size, kept to something a phone or tablet could be.
    pub fn clamped(width: f64, height: f64, scale: Option<f64>) -> Result<Self, String> {
        let scale = scale.unwrap_or(2.0);
        if !(width.is_finite() && height.is_finite() && scale.is_finite()) {
            return Err("not a screen size".into());
        }
        Ok(Self {
            width: width.round().clamp(240.0, 1600.0) as u32,
            height: height.round().clamp(240.0, 2400.0) as u32,
            // Screencasts render at the browser's real 2x at most.
            scale: scale.clamp(1.0, 2.0),
        })
    }

    pub fn metrics_override(&self) -> Value {
        json!({
            "width": self.width,
            "height": self.height,
            "deviceScaleFactor": self.scale,
            "mobile": true,
            "screenWidth": self.width,
            "screenHeight": self.height,
        })
    }

    pub fn screencast(&self, quality: u32) -> Value {
        json!({
            "format": "jpeg",
            "quality": quality,
            "maxWidth": (f64::from(self.width) * self.scale).round() as u32,
            "maxHeight": (f64::from(self.height) * self.scale).round() as u32,
            "everyNthFrame": 1,
        })
    }
}

/// JPEG quality a viewer may ask for (default 70).
pub fn quality(asked: Option<u32>) -> u32 {
    asked.unwrap_or(70).clamp(30, 90)
}

/// Frames a second a viewer may ask for (default 15).
pub fn fps(asked: Option<u32>) -> u32 {
    asked.unwrap_or(15).clamp(1, 30)
}

/// How long to hold a frame's ack: the browser sends nothing new until it
/// is acked, so this paces it to the fastest viewer's rate.
pub fn ack_delay(since_frame: Duration, fps: u32) -> Duration {
    (Duration::from_secs(1) / fps.max(1)).saturating_sub(since_frame)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Command {
    pub method: &'static str,
    pub params: Value,
}

fn command(method: &'static str, params: Value) -> Command {
    Command { method, params }
}

/// What carrying out an input takes.
#[derive(Debug, Clone, PartialEq)]
pub enum Plan {
    /// Send these, in order.
    Send(Vec<Command>),
    /// Open this (already checked) loopback page.
    Navigate(String),
    /// Move through history: -1 back, +1 forward.
    History(i32),
    Resize(Viewport),
}

/// A named key's DOM `key`, `code`, Windows key code, and the text it types.
fn named_key(name: &str) -> Option<(&'static str, &'static str, u32, Option<&'static str>)> {
    Some(match name.to_ascii_lowercase().as_str() {
        "enter" | "return" => ("Enter", "Enter", 13, Some("\r")),
        "backspace" => ("Backspace", "Backspace", 8, None),
        "tab" => ("Tab", "Tab", 9, None),
        "escape" => ("Escape", "Escape", 27, None),
        "arrowleft" | "left" => ("ArrowLeft", "ArrowLeft", 37, None),
        "arrowup" | "up" => ("ArrowUp", "ArrowUp", 38, None),
        "arrowright" | "right" => ("ArrowRight", "ArrowRight", 39, None),
        "arrowdown" | "down" => ("ArrowDown", "ArrowDown", 40, None),
        "delete" => ("Delete", "Delete", 46, None),
        _ => return None,
    })
}

fn point(x: f64, y: f64, viewport: &Viewport) -> Result<(f64, f64), String> {
    if !x.is_finite() || !y.is_finite() {
        return Err("touch outside the page".into());
    }
    Ok((
        x.clamp(0.0, f64::from(viewport.width)),
        y.clamp(0.0, f64::from(viewport.height)),
    ))
}

pub fn plan(input: &PageInput, viewport: &Viewport) -> Result<Plan, String> {
    Ok(match input {
        PageInput::Tap { x, y } => {
            let (x, y) = point(*x, *y, viewport)?;
            // A touch, not a click: the page runs with touch emulation, so it
            // sees what a phone's tap would send (and the click that follows).
            Plan::Send(vec![
                command(
                    "Input.dispatchTouchEvent",
                    json!({ "type": "touchStart", "touchPoints": [{ "x": x, "y": y }] }),
                ),
                command(
                    "Input.dispatchTouchEvent",
                    json!({ "type": "touchEnd", "touchPoints": [] }),
                ),
            ])
        }
        PageInput::Scroll { x, y, dx, dy } => {
            let (x, y) = point(*x, *y, viewport)?;
            if !dx.is_finite() || !dy.is_finite() {
                return Err("not a scroll".into());
            }
            Plan::Send(vec![command(
                "Input.dispatchMouseEvent",
                json!({
                    "type": "mouseWheel",
                    "x": x,
                    "y": y,
                    "deltaX": dx.clamp(-MAX_SCROLL, MAX_SCROLL),
                    "deltaY": dy.clamp(-MAX_SCROLL, MAX_SCROLL),
                }),
            )])
        }
        PageInput::Text { text } => {
            if text.chars().count() > MAX_TEXT_CHARS {
                return Err(format!(
                    "send at most {MAX_TEXT_CHARS} characters at a time"
                ));
            }
            if text.is_empty() {
                return Ok(Plan::Send(Vec::new()));
            }
            Plan::Send(vec![command("Input.insertText", json!({ "text": text }))])
        }
        PageInput::Key { name } => {
            let (key, code, vk, text) =
                named_key(name).ok_or_else(|| format!("unknown key {name:?}"))?;
            let mut down = json!({
                "type": if text.is_some() { "keyDown" } else { "rawKeyDown" },
                "key": key,
                "code": code,
                "windowsVirtualKeyCode": vk,
                "nativeVirtualKeyCode": vk,
            });
            if let Some(text) = text {
                down["text"] = json!(text);
                down["unmodifiedText"] = json!(text);
            }
            Plan::Send(vec![
                command("Input.dispatchKeyEvent", down),
                command(
                    "Input.dispatchKeyEvent",
                    json!({
                        "type": "keyUp",
                        "key": key,
                        "code": code,
                        "windowsVirtualKeyCode": vk,
                        "nativeVirtualKeyCode": vk,
                    }),
                ),
            ])
        }
        PageInput::Navigate { url } => Plan::Navigate(url_rule::loopback_url(url)?.to_string()),
        PageInput::Back => Plan::History(-1),
        PageInput::Forward => Plan::History(1),
        PageInput::Reload => Plan::Send(vec![command("Page.reload", json!({}))]),
        PageInput::Resize {
            width,
            height,
            scale,
        } => Plan::Resize(Viewport::clamped(*width, *height, *scale)?),
    })
}

/// The history entry `delta` steps from the current one, if it exists and
/// stays on loopback. `history` is `Page.getNavigationHistory`'s reply.
pub fn history_target(history: &Value, delta: i32) -> Result<Option<i64>, String> {
    let current = history["currentIndex"].as_i64().unwrap_or(0);
    let entries = history["entries"].as_array().cloned().unwrap_or_default();
    let target = current + i64::from(delta);
    let Some(entry) = usize::try_from(target).ok().and_then(|i| entries.get(i)) else {
        return Ok(None);
    };
    let url = entry["url"].as_str().unwrap_or_default();
    if !url_rule::allowed_navigation(url) {
        return Err("That page isn't on this computer, so it doesn't open here.".into());
    }
    Ok(entry["id"].as_i64())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sent(input: PageInput) -> Vec<(&'static str, Value)> {
        match plan(&input, &Viewport::default()).unwrap() {
            Plan::Send(commands) => commands.into_iter().map(|c| (c.method, c.params)).collect(),
            other => panic!("expected commands, got {other:?}"),
        }
    }

    #[test]
    fn a_tap_is_a_touch_start_and_end_inside_the_viewport() {
        assert_eq!(
            sent(PageInput::Tap { x: 120.5, y: 900.0 }),
            vec![
                (
                    "Input.dispatchTouchEvent",
                    json!({ "type": "touchStart", "touchPoints": [{ "x": 120.5, "y": 844.0 }] })
                ),
                (
                    "Input.dispatchTouchEvent",
                    json!({ "type": "touchEnd", "touchPoints": [] })
                ),
            ]
        );
        assert!(
            plan(
                &PageInput::Tap {
                    x: f64::NAN,
                    y: 1.0
                },
                &Viewport::default()
            )
            .is_err()
        );
    }

    #[test]
    fn a_scroll_is_a_mouse_wheel_at_the_finger() {
        assert_eq!(
            sent(PageInput::Scroll {
                x: 100.0,
                y: 200.0,
                dx: 0.0,
                dy: 1e9
            }),
            vec![(
                "Input.dispatchMouseEvent",
                json!({ "type": "mouseWheel", "x": 100.0, "y": 200.0, "deltaX": 0.0, "deltaY": 20000.0 })
            )]
        );
        assert!(
            plan(
                &PageInput::Scroll {
                    x: 0.0,
                    y: 0.0,
                    dx: f64::INFINITY,
                    dy: 0.0
                },
                &Viewport::default()
            )
            .is_err()
        );
    }

    #[test]
    fn text_is_inserted_and_named_keys_press_and_release() {
        assert_eq!(
            sent(PageInput::Text {
                text: "Tomatoes 🍅".into()
            }),
            vec![("Input.insertText", json!({ "text": "Tomatoes 🍅" }))]
        );
        assert_eq!(sent(PageInput::Text { text: "".into() }), vec![]);
        let long = "a".repeat(MAX_TEXT_CHARS + 1);
        assert!(plan(&PageInput::Text { text: long }, &Viewport::default()).is_err());

        let enter = sent(PageInput::Key {
            name: "Enter".into(),
        });
        assert_eq!(enter[0].1["type"], "keyDown");
        assert_eq!(enter[0].1["text"], "\r");
        assert_eq!(enter[0].1["windowsVirtualKeyCode"], 13);
        assert_eq!(enter[1].1["type"], "keyUp");
        let backspace = sent(PageInput::Key {
            name: "backspace".into(),
        });
        assert_eq!(
            backspace[0].1,
            json!({ "type": "rawKeyDown", "key": "Backspace", "code": "Backspace",
                    "windowsVirtualKeyCode": 8, "nativeVirtualKeyCode": 8 })
        );
        for name in [
            "Tab",
            "Escape",
            "ArrowLeft",
            "ArrowUp",
            "ArrowRight",
            "ArrowDown",
        ] {
            let keys = sent(PageInput::Key { name: name.into() });
            assert_eq!(keys[0].1["key"], name);
        }
        assert!(plan(&PageInput::Key { name: "F13".into() }, &Viewport::default()).is_err());
    }

    #[test]
    fn navigation_reload_history_and_resize() {
        assert_eq!(
            plan(
                &PageInput::Navigate {
                    url: "0.0.0.0:3000/plots".into()
                },
                &Viewport::default()
            ),
            Ok(Plan::Navigate("http://localhost:3000/plots".into()))
        );
        assert!(
            plan(
                &PageInput::Navigate {
                    url: "https://example.com".into()
                },
                &Viewport::default()
            )
            .is_err()
        );
        assert_eq!(sent(PageInput::Reload), vec![("Page.reload", json!({}))]);
        assert_eq!(
            plan(&PageInput::Back, &Viewport::default()),
            Ok(Plan::History(-1))
        );
        assert_eq!(
            plan(&PageInput::Forward, &Viewport::default()),
            Ok(Plan::History(1))
        );
        assert_eq!(
            plan(
                &PageInput::Resize {
                    width: 10.0,
                    height: 5000.0,
                    scale: Some(3.0)
                },
                &Viewport::default()
            ),
            Ok(Plan::Resize(Viewport {
                width: 240,
                height: 2400,
                scale: 2.0
            }))
        );
    }

    #[test]
    fn input_parses_from_the_wire_shape_and_nothing_else() {
        let tap: PageInput = serde_json::from_str(r#"{"kind":"tap","x":10,"y":20}"#).unwrap();
        assert_eq!(tap, PageInput::Tap { x: 10.0, y: 20.0 });
        let back: PageInput = serde_json::from_str(r#"{"kind":"back"}"#).unwrap();
        assert_eq!(back, PageInput::Back);
        let resize: PageInput =
            serde_json::from_str(r#"{"kind":"resize","width":390,"height":700}"#).unwrap();
        assert_eq!(
            resize,
            PageInput::Resize {
                width: 390.0,
                height: 700.0,
                scale: None
            }
        );
        assert!(serde_json::from_str::<PageInput>(r#"{"kind":"evaluate","js":"1"}"#).is_err());
    }

    #[test]
    fn history_moves_only_to_entries_that_exist_and_stay_on_loopback() {
        let history = json!({
            "currentIndex": 1,
            "entries": [
                { "id": 10, "url": "https://example.com/" },
                { "id": 11, "url": "http://localhost:3000/" },
                { "id": 12, "url": "http://localhost:3000/plots" },
            ]
        });
        assert_eq!(history_target(&history, 1), Ok(Some(12)));
        assert!(history_target(&history, -1).is_err());
        assert_eq!(history_target(&history, 2), Ok(None));
        assert_eq!(history_target(&json!({}), -1), Ok(None));
    }

    #[test]
    fn the_screencast_is_capped_to_the_viewers_size_and_acks_pace_it() {
        let viewport = Viewport::clamped(390.0, 700.0, Some(2.0)).unwrap();
        assert_eq!(
            viewport.screencast(70),
            json!({ "format": "jpeg", "quality": 70, "maxWidth": 780, "maxHeight": 1400, "everyNthFrame": 1 })
        );
        assert_eq!(viewport.metrics_override()["mobile"], true);
        assert_eq!(quality(None), 70);
        assert_eq!(quality(Some(5)), 30);
        assert_eq!(fps(Some(500)), 30);
        assert_eq!(
            ack_delay(Duration::from_millis(10), 10),
            Duration::from_millis(90)
        );
        assert_eq!(
            ack_delay(Duration::from_millis(300), 10),
            Duration::ZERO,
            "a late frame is acked at once"
        );
        assert!(Viewport::clamped(f64::NAN, 1.0, None).is_err());
    }
}
