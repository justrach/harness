//! Computer use as nanocua reports it (`nanocua ctl <command> --json`): what the
//! MCP servers settings page shows and what its buttons do.
//!
//! nanocua is its own app, which graff and Harness's graff chats both connect
//! to. Reading and turning things off happen at once. Turning something on only
//! asks: the question appears in nanocua's window and a person's click there
//! answers it, because agents have shells and can run the same command.

use serde::{Deserialize, Serialize};

/// nanocua's state on one device. Its field names are nanocua's wire format.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUseStatus {
    /// This device's system has computer use at all. Set by the engine.
    pub supported: bool,
    pub installed: bool,
    pub running: bool,
    /// Every agent's calls are refused.
    pub stopped: bool,
    pub input: bool,
    pub whole_screen: bool,
    /// What macOS has granted the app.
    pub accessibility: bool,
    pub screen_recording: bool,
    pub agents: usize,
    pub calls: u64,
    /// What's waiting for an answer in nanocua's window.
    pub pending: Option<String>,
    /// How the last action went (see [`ComputerUseStatus::outcome_text`]).
    pub outcome: Option<String>,
}

impl ComputerUseStatus {
    /// The state in a few words.
    pub fn summary(&self) -> &'static str {
        if !self.installed {
            "Not installed"
        } else if !self.running {
            "Not running"
        } else if self.stopped {
            "Stopped"
        } else if self.input {
            "Acting"
        } else {
            "Looking only"
        }
    }

    /// What the last action came to, for a person.
    pub fn outcome_text(&self) -> Option<&'static str> {
        Some(match self.outcome.as_deref()? {
            "allowed" => "Allowed.",
            "denied" => "Denied in nanocua's window.",
            "expired" => "Nobody answered in nanocua's window.",
            "busy" => "nanocua's window is already waiting for an answer.",
            "quiet" => "Just denied: try again in a few seconds.",
            "unreachable" => "Couldn't reach nanocua.",
            "opened" => "macOS's prompt or its settings should be open: turn nanocua on there.",
            _ => return None,
        })
    }

    /// The buttons for this state, most urgent first. The ones that end in an
    /// ellipsis ask in nanocua's window; the others happen at once.
    pub fn controls(&self) -> Vec<(&'static str, ComputerUseAction)> {
        use ComputerUseAction as A;
        if !self.installed {
            return Vec::new();
        }
        if !self.running {
            return vec![("Open nanocua", A::Open)];
        }
        let mut out = Vec::new();
        out.push(if self.stopped {
            ("Resume…", A::Resume)
        } else {
            ("Stop", A::Stop)
        });
        out.push(if self.input {
            ("Turn input off", A::TurnOffInput)
        } else {
            ("Allow input…", A::AllowInput)
        });
        out.push(if self.whole_screen {
            ("Turn whole screen off", A::TurnOffWholeScreen)
        } else {
            ("Allow whole screen…", A::AllowWholeScreen)
        });
        if !self.accessibility {
            out.push(("Grant Accessibility…", A::GrantAccessibility));
        }
        if !self.screen_recording {
            out.push(("Grant Screen Recording…", A::GrantScreen));
        }
        out.push(("Open nanocua", A::Open));
        out
    }
}

/// A closed set, so a request can never become an arbitrary command line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComputerUseAction {
    Stop,
    TurnOffInput,
    TurnOffWholeScreen,
    AllowInput,
    AllowWholeScreen,
    Resume,
    GrantAccessibility,
    GrantScreen,
    Open,
}

impl ComputerUseAction {
    /// What goes after `nanocua ctl`.
    pub fn ctl_args(self) -> &'static [&'static str] {
        match self {
            Self::Stop => &["stop"],
            Self::TurnOffInput => &["off", "input"],
            Self::TurnOffWholeScreen => &["off", "whole_screen"],
            Self::AllowInput => &["allow", "input"],
            Self::AllowWholeScreen => &["allow", "whole_screen"],
            Self::Resume => &["allow", "resume"],
            Self::GrantAccessibility => &["grant", "accessibility"],
            Self::GrantScreen => &["grant", "screen"],
            Self::Open => &["open"],
        }
    }

    /// Whether this waits for someone to answer in nanocua's window.
    pub fn asks(self) -> bool {
        matches!(
            self,
            Self::AllowInput | Self::AllowWholeScreen | Self::Resume
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nanocuas_reply_parses_and_ignores_what_it_adds_later() {
        let json = r#"{"installed":true,"running":true,"stopped":false,"input":true,
            "wholeScreen":false,"accessibility":true,"screenRecording":false,"agents":2,
            "calls":7,"stopKey":true,"pending":"whole_screen","outcome":"allowed","later":1}"#;
        let status: ComputerUseStatus = serde_json::from_str(json).unwrap();
        assert!(status.input && status.accessibility && !status.screen_recording);
        assert_eq!(status.agents, 2);
        assert_eq!(status.pending.as_deref(), Some("whole_screen"));
        assert_eq!(status.summary(), "Acting");
        assert_eq!(status.outcome_text(), Some("Allowed."));
    }

    #[test]
    fn turning_on_asks_and_turning_off_never_does() {
        for action in [
            ComputerUseAction::AllowInput,
            ComputerUseAction::AllowWholeScreen,
            ComputerUseAction::Resume,
        ] {
            assert!(action.asks());
            assert_eq!(action.ctl_args()[0], "allow");
        }
        for action in [
            ComputerUseAction::Stop,
            ComputerUseAction::TurnOffInput,
            ComputerUseAction::TurnOffWholeScreen,
            ComputerUseAction::GrantScreen,
            ComputerUseAction::Open,
        ] {
            assert!(!action.asks());
            assert_ne!(action.ctl_args()[0], "allow");
        }
    }

    #[test]
    fn the_buttons_follow_the_state() {
        let labels = |status: &ComputerUseStatus| -> Vec<&'static str> {
            status.controls().into_iter().map(|c| c.0).collect()
        };
        assert!(labels(&ComputerUseStatus::default()).is_empty());
        let mut status = ComputerUseStatus {
            installed: true,
            ..Default::default()
        };
        assert_eq!(labels(&status), ["Open nanocua"]);

        status.running = true;
        assert_eq!(
            labels(&status),
            [
                "Stop",
                "Allow input…",
                "Allow whole screen…",
                "Grant Accessibility…",
                "Grant Screen Recording…",
                "Open nanocua",
            ]
        );

        status.stopped = true;
        status.input = true;
        status.whole_screen = true;
        status.accessibility = true;
        status.screen_recording = true;
        assert_eq!(
            labels(&status),
            [
                "Resume…",
                "Turn input off",
                "Turn whole screen off",
                "Open nanocua",
            ]
        );
    }

    #[test]
    fn the_summary_names_the_most_important_state() {
        let mut status = ComputerUseStatus::default();
        assert_eq!(status.summary(), "Not installed");
        status.installed = true;
        assert_eq!(status.summary(), "Not running");
        status.running = true;
        assert_eq!(status.summary(), "Looking only");
        status.input = true;
        assert_eq!(status.summary(), "Acting");
        status.stopped = true;
        assert_eq!(status.summary(), "Stopped");
    }
}
