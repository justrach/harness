//! ACP form elicitation (`elicitation/create`, mode `form`): an agent asks the
//! user to fill a small flat schema mid-turn. Graff 0.0.302.6 sends ask_user
//! this way to clients that advertise `clientCapabilities.elicitation.form`,
//! and answers at once ("assume and continue") for clients that don't.
//!
//! Each supported property becomes one question on the engine's input bridge:
//! strings (free text, or picks when the schema has an `enum`), booleans
//! (Yes / No), and numbers. A schema with a required property we can't show
//! is declined so the agent never waits on a form nobody can fill.

use harness_proto::{UserInputAnswer, UserInputQuestion};
use serde_json::{Map, Value, json};

/// The capability advertised at `initialize`.
pub(super) fn capability() -> Value {
    json!({ "form": {} })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Text,
    Bool,
    Integer,
    Number,
}

#[derive(Debug, Clone)]
struct Field {
    key: String,
    kind: Kind,
    question: UserInputQuestion,
}

/// A form the user can answer, with the questions to show.
#[derive(Debug, Clone)]
pub(super) struct Form {
    fields: Vec<Field>,
}

impl Form {
    pub(super) fn questions(&self) -> Vec<UserInputQuestion> {
        self.fields
            .iter()
            .map(|field| field.question.clone())
            .collect()
    }

    /// The `elicitation/create` result for these answers. No answers at all
    /// (the resolver was dropped or the turn ended) cancels; an answered form
    /// missing a value, or holding one that doesn't parse, declines.
    pub(super) fn response(&self, answers: &[UserInputAnswer]) -> Value {
        if answers.is_empty() {
            return cancel();
        }
        let mut content = Map::new();
        for field in &self.fields {
            let Some(label) = answers
                .iter()
                .find(|answer| answer.question_id == field.question.id)
                .and_then(|answer| answer.labels.first())
                .map(|label| label.trim())
                .filter(|label| !label.is_empty())
            else {
                return json!({ "action": "decline" });
            };
            let Some(value) = field.kind.parse(label) else {
                return json!({ "action": "decline" });
            };
            content.insert(field.key.clone(), value);
        }
        json!({ "action": "accept", "content": content })
    }
}

impl Kind {
    fn parse(self, label: &str) -> Option<Value> {
        match self {
            Kind::Text => Some(Value::String(label.to_owned())),
            Kind::Bool => match label.to_ascii_lowercase().as_str() {
                "yes" | "true" => Some(Value::Bool(true)),
                "no" | "false" => Some(Value::Bool(false)),
                _ => None,
            },
            Kind::Integer => label.parse::<i64>().ok().map(Value::from),
            Kind::Number => label
                .parse::<f64>()
                .ok()
                .and_then(|n| serde_json::Number::from_f64(n).map(Value::Number)),
        }
    }
}

/// The response for a request we won't show (wrong session, unsupported form).
pub(super) fn cancel() -> Value {
    json!({ "action": "cancel" })
}

/// Parse `elicitation/create` params into a form, or None when it can't be
/// shown: URL mode, a nested or empty schema, or a required property of a
/// type we don't render. Optional properties we can't render are left out.
pub(super) fn form(params: &Value, new_id: impl Fn() -> String) -> Option<Form> {
    if params.get("mode").and_then(Value::as_str).unwrap_or("form") != "form" {
        return None;
    }
    let message = params
        .get("message")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|message| !message.is_empty())
        .unwrap_or("The agent needs your input.");
    let schema = params.get("requestedSchema")?;
    let properties = schema.get("properties")?.as_object()?;
    let required: Vec<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|keys| keys.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let single = properties.len() == 1;
    let mut fields = Vec::new();
    for (key, property) in properties {
        let Some((kind, options)) = kind_of(property) else {
            if required.contains(&key.as_str()) {
                return None;
            }
            continue;
        };
        let title = property
            .get("title")
            .or_else(|| property.get("description"))
            .and_then(Value::as_str)
            .unwrap_or(key);
        let question = if single {
            message.to_owned()
        } else {
            format!("{message}\n\n{title}")
        };
        fields.push(Field {
            key: key.clone(),
            kind,
            question: UserInputQuestion {
                id: new_id(),
                header: "Agent question".into(),
                question,
                options,
                multi_select: false,
            },
        });
    }
    (!fields.is_empty()).then_some(Form { fields })
}

fn kind_of(property: &Value) -> Option<(Kind, Vec<String>)> {
    match property.get("type").and_then(Value::as_str)? {
        "string" => {
            let options = property
                .get("enum")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            Some((Kind::Text, options))
        }
        "boolean" => Some((Kind::Bool, vec!["Yes".into(), "No".into()])),
        "integer" => Some((Kind::Integer, Vec::new())),
        "number" => Some((Kind::Number, Vec::new())),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids() -> impl Fn() -> String {
        let next = std::cell::Cell::new(0);
        move || {
            next.set(next.get() + 1);
            format!("q{}", next.get())
        }
    }

    fn answer(id: &str, label: &str) -> UserInputAnswer {
        UserInputAnswer {
            question_id: id.into(),
            labels: vec![label.into()],
        }
    }

    /// The exact shape graff 0.0.302.6 sends for ask_user with choices.
    fn graff_ask(choices: Option<&[&str]>) -> Value {
        let mut answer = json!({ "type": "string", "title": "Answer" });
        if let Some(choices) = choices {
            answer["enum"] = json!(choices);
        }
        json!({
            "sessionId": "s1",
            "mode": "form",
            "message": "Which database should I use?",
            "requestedSchema": {
                "type": "object",
                "properties": { "answer": answer },
                "required": ["answer"],
            },
        })
    }

    #[test]
    fn graff_ask_user_becomes_one_question_and_answers_accept() {
        let form = form(&graff_ask(Some(&["Postgres", "SQLite"])), ids()).unwrap();
        let questions = form.questions();
        assert_eq!(questions.len(), 1);
        assert_eq!(questions[0].question, "Which database should I use?");
        assert_eq!(questions[0].options, ["Postgres", "SQLite"]);
        assert_eq!(
            form.response(&[answer("q1", "SQLite")]),
            json!({ "action": "accept", "content": { "answer": "SQLite" } })
        );
    }

    #[test]
    fn free_text_questions_take_typed_answers() {
        let form = form(&graff_ask(None), ids()).unwrap();
        assert!(form.questions()[0].options.is_empty());
        assert_eq!(
            form.response(&[answer("q1", "  the one in docker  ")]),
            json!({ "action": "accept", "content": { "answer": "the one in docker" } })
        );
    }

    #[test]
    fn a_dropped_or_blank_answer_never_accepts() {
        let form = form(&graff_ask(None), ids()).unwrap();
        assert_eq!(form.response(&[]), json!({ "action": "cancel" }));
        assert_eq!(
            form.response(&[answer("q1", "   ")]),
            json!({ "action": "decline" })
        );
    }

    #[test]
    fn typed_fields_parse_or_decline() {
        let params = json!({
            "message": "Settings",
            "requestedSchema": {
                "type": "object",
                "properties": {
                    "confirm": { "type": "boolean", "title": "Proceed?" },
                    "count": { "type": "integer" },
                },
                "required": ["confirm", "count"],
            },
        });
        let form = form(&params, ids()).unwrap();
        let questions = form.questions();
        assert_eq!(questions[0].options, ["Yes", "No"]);
        assert_eq!(questions[0].question, "Settings\n\nProceed?");
        assert_eq!(
            form.response(&[answer("q1", "Yes"), answer("q2", "3")]),
            json!({ "action": "accept", "content": { "confirm": true, "count": 3 } })
        );
        assert_eq!(
            form.response(&[answer("q1", "Yes"), answer("q2", "three")]),
            json!({ "action": "decline" })
        );
    }

    #[test]
    fn unshowable_forms_are_refused() {
        let url = json!({ "mode": "url", "url": "https://example.com", "message": "Sign in" });
        assert!(form(&url, ids()).is_none());
        let nested = json!({
            "message": "x",
            "requestedSchema": {
                "type": "object",
                "properties": { "items": { "type": "array" } },
                "required": ["items"],
            },
        });
        assert!(form(&nested, ids()).is_none());
    }
}
