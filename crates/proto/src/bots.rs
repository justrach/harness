//! graff Bots as the engine reports them (`graff bot --user state --json`):
//! standing roles the user messages from any project, each with one job, its
//! own memory and work log, and routines it starts by itself (codegraff ADR
//! 0333, 0334). graff prints snake_case; clients read camelCase.

use serde::{Deserialize, Serialize};

/// Work a bot starts by itself: once after a delay, or every so often.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct BotRoutine {
    pub id: String,
    pub instruction: String,
    /// graff's words for the schedule, in UTC.
    #[serde(default)]
    pub when: String,
    /// The next slot, in Unix milliseconds.
    #[serde(default)]
    pub at_ms: i64,
    /// Zero for a routine that runs once.
    #[serde(default)]
    pub interval_ms: i64,
    #[serde(default)]
    pub paused: bool,
    /// A one-shot routine that is spent.
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub runs: u32,
    #[serde(default)]
    pub last_run_ms: i64,
    /// The first slot that came due while nothing was checking, and how many
    /// have since. Zero: nothing was missed, or the user dealt with it.
    #[serde(default)]
    pub missed_at_ms: i64,
    #[serde(default)]
    pub missed_open: u32,
    /// A check right now would start it.
    #[serde(default)]
    pub due: bool,
    /// The turn that runs it now. For the engine; clients don't need it.
    #[serde(default, skip_serializing)]
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct BotRow {
    pub name: String,
    pub job: String,
    /// A graff model name; empty for graff's default.
    #[serde(default)]
    pub model: String,
    /// Its headless `graff bot` runs skip approvals. A run in a chat follows
    /// that chat's own settings.
    #[serde(default)]
    pub yolo: bool,
    /// The folder its runs work in; empty when it has none.
    #[serde(default)]
    pub project: String,
    /// The user's default point of contact. One bot at most.
    #[serde(default)]
    pub primary: bool,
    /// Its standing conversation; empty until its first run.
    #[serde(default)]
    pub chat: String,
    #[serde(default)]
    pub created_ms: i64,
    #[serde(default)]
    pub routines: Vec<BotRoutine>,
}

/// Everything the Bots list and the catch-up draw.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all(serialize = "camelCase", deserialize = "snake_case"))]
pub struct BotsState {
    #[serde(default)]
    pub now_ms: i64,
    /// When routines were last checked; zero for never.
    #[serde(default)]
    pub last_check_ms: i64,
    /// The latest stretch in which nothing checked them.
    #[serde(default)]
    pub gap_from_ms: i64,
    #[serde(default)]
    pub gap_to_ms: i64,
    /// A few facts about the user that every bot is shown.
    #[serde(default)]
    pub about: String,
    #[serde(default)]
    pub bots: Vec<BotRow>,
}

/// What a bot remembers and what it did last (`graff bot show`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BotDetail {
    #[serde(default)]
    pub memory: String,
    #[serde(default)]
    pub log: String,
}

/// A routine graff handed over to be run now (`graff bot due --claim`).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct BotDue {
    pub bot: String,
    pub id: String,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub chat: String,
    /// The bot's standing text, then the turn.
    pub system: String,
    pub message: String,
}

/// What `BotAction` changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BotVerb {
    Create,
    Remove,
    SetJob,
    SetModel,
    SetProject,
    SetPrimary,
    RoutineAdd,
    RoutinePause,
    RoutineResume,
    RoutineRemove,
    /// The user ran or dismissed a routine that came due and did not run.
    MissedClear,
    Remember,
    Forget,
    /// What every bot knows about the user. Takes no bot.
    About,
}

/// A bot's name: a directory name and a word on a command line.
pub fn valid_bot_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 32
        && !name.starts_with(['-', '_'])
        && name
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-' || c == b'_')
}

/// A routine id: `r` and a number.
pub fn valid_routine_id(id: &str) -> bool {
    (2..=12).contains(&id.len())
        && id.starts_with('r')
        && id[1..].bytes().all(|c| c.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn graffs_snake_case_state_reaches_clients_in_camel_case() {
        let state: BotsState = serde_json::from_str(
            r#"{"scope":"user","now_ms":9,"last_check_ms":7,"gap_from_ms":3,"gap_to_ms":7,"about":"Alex.",
                "bots":[{"name":"notes","job":"Draft release notes","model":"","yolo":false,"project":"/repo/comet",
                         "primary":false,"chat":"c1","created_ms":1,
                         "routines":[{"bot":"notes","id":"r1","instruction":"draft","when":"every 6h, next …",
                                      "at_ms":5,"interval_ms":21600000,"paused":false,"done":false,"runs":11,
                                      "last_run_ms":4,"missed_at_ms":2,"missed_open":1,"due":false,
                                      "message":"[routine r1] draft"}]}]}"#,
        )
        .unwrap();
        assert_eq!(state.bots[0].routines[0].message, "[routine r1] draft");
        let wire = serde_json::to_value(&state).unwrap();
        assert_eq!(wire["lastCheckMs"], 7);
        assert_eq!(wire["gapFromMs"], 3);
        let routine = &wire["bots"][0]["routines"][0];
        assert_eq!(routine["missedOpen"], 1);
        assert_eq!(routine["intervalMs"], 21_600_000);
        assert!(
            routine.get("message").is_none(),
            "the turn stays in the engine"
        );
        assert_eq!(wire["bots"][0]["project"], "/repo/comet");
    }

    #[test]
    fn names_and_routine_ids_are_safe_command_words() {
        for ok in ["triage", "release-notes", "bot_2", "9lives"] {
            assert!(valid_bot_name(ok), "{ok}");
        }
        let long = "x".repeat(33);
        for bad in [
            "",
            "Triage",
            "a b",
            "../x",
            "-lead",
            "_lead",
            "--yolo",
            long.as_str(),
        ] {
            assert!(!valid_bot_name(bad), "{bad}");
        }
        for ok in ["r1", "r42"] {
            assert!(valid_routine_id(ok), "{ok}");
        }
        for bad in ["", "r", "1", "r1x", "--json", "r-1"] {
            assert!(!valid_routine_id(bad), "{bad}");
        }
    }
}
