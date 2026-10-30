//! Mermaid fences in agent replies draw as diagrams: rendered off the main
//! thread, toggled to their source, opened full size, falling back to the
//! source when the renderer rejects them, and rendered once a streamed fence
//! closes rather than on every token.

use super::*;
use gpui::{Modifiers, VisualTestContext};

const FLOWCHART: &str = "flowchart LR\n  A[Plan] --> B[Build]\n  B --> C[Ship]";

fn entry(
    id: &str,
    role: MessageRole,
    status: Option<MessageStatus>,
    text: &str,
) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts: vec![MessagePart::Text {
            id: "text".into(),
            text: text.into(),
        }],
        created_at: 0,
        device_id: "dev".into(),
        status,
        continuation_of: None,
        duration_ms: None,
    }
}

fn prompt() -> SessionMessageEntry {
    entry("p", MessageRole::User, None, "Sketch the release flow.")
}

fn reply(status: MessageStatus, text: &str) -> SessionMessageEntry {
    entry("a", MessageRole::Assistant, Some(status), text)
}

struct Host(Entity<Transcript>);
impl Render for Host {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.0.clone())
    }
}

struct Fixture {
    state: Entity<AppState>,
    transcript: Entity<Transcript>,
    window: VisualTestContext,
    worker: TranscriptPreparation,
    _dir: tempfile::TempDir,
}

impl Fixture {
    fn new(cx: &mut gpui::TestAppContext) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let state = cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::dark());
            crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
            cx.new(|_| AppState::new())
        });
        state.update(cx, |state, cx| state.select_chat(Some("chat".into()), cx));
        let (host, window) =
            cx.add_window_view(|_, cx| Host(cx.new(|cx| Transcript::new(state.clone(), cx))));
        let transcript = window.read(|cx| host.read(cx).0.clone());
        Self {
            state,
            transcript,
            window: window.clone(),
            worker: TranscriptPreparation::default(),
            _dir: dir,
        }
    }

    fn deliver(&mut self, frame: harness_doc::TranscriptFrame) {
        let update = harness_doc::TranscriptUpdate {
            frame,
            context_usage: None,
            replay_baseline: None,
        };
        let prepared = self.worker.prepare(&update).unwrap();
        self.state.update(&mut self.window, |state, cx| {
            state
                .receive_opening_transcript_update(update, false, cx)
                .unwrap();
            state.prepared_transcripts.insert("chat".into(), prepared);
        });
        self.settle();
    }

    fn reset(&mut self, entries: &[SessionMessageEntry]) {
        self.deliver(harness_doc::TranscriptFrame::reset(entries));
    }

    fn append(&mut self, text: &str, len: usize, count: usize) {
        self.deliver(harness_doc::TranscriptFrame::Delta {
            upsert: Vec::new(),
            append: vec![harness_doc::TextAppend {
                entry: "a".into(),
                part: "text".into(),
                text: text.into(),
                len,
            }],
            remove: Vec::new(),
            count,
        });
    }

    /// Draw, let background work (a diagram render) finish, and draw again.
    fn settle(&mut self) {
        self.draw();
        self.window.run_until_parked();
        self.draw();
    }

    fn draw(&mut self) {
        self.window.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
    }

    fn bounds(&mut self, selector: &'static str) -> Option<Bounds<Pixels>> {
        self.window.debug_bounds(selector)
    }

    fn renders(&mut self) -> u64 {
        self.transcript
            .read_with(&self.window, |this, _| this.diagrams.started())
    }
}

#[gpui::test]
fn mermaid_reply_draws_a_diagram_that_toggles_to_source_and_opens_full_size(
    cx: &mut gpui::TestAppContext,
) {
    let mut fixture = Fixture::new(cx);
    let text = format!("Here is the flow:\n\n```mermaid\n{FLOWCHART}\n```\n\nShip it.");
    fixture.reset(&[prompt(), reply(MessageStatus::Complete, &text)]);
    let diagram = fixture
        .bounds("mermaid-diagram")
        .expect("the fence draws as a diagram");
    assert_eq!(fixture.renders(), 1);
    assert!(fixture.bounds("mermaid-note").is_none());

    // Repainting reuses the cached diagram.
    fixture.settle();
    fixture.settle();
    assert_eq!(fixture.renders(), 1);

    // "Show source" swaps in the code, and back.
    let toggle = "a#text.1-mermaid-1-source-toggle";
    let at = fixture.bounds(toggle).expect("source toggle").center();
    fixture.window.simulate_click(at, Modifiers::default());
    fixture.settle();
    assert!(fixture.bounds("mermaid-diagram").is_none());
    let at = fixture.bounds(toggle).expect("diagram toggle").center();
    fixture.window.simulate_click(at, Modifiers::default());
    fixture.settle();
    assert!(fixture.bounds("mermaid-diagram").is_some());
    assert_eq!(fixture.renders(), 1, "toggling never re-renders");

    // A click opens the shared viewer at the diagram's natural size.
    fixture
        .window
        .simulate_click(diagram.center(), Modifiers::default());
    fixture.transcript.read_with(&fixture.window, |this, _| {
        assert!(this.attachment_preview.is_some());
        assert!(this.diagram_zoom.is_some());
    });
    fixture.draw();
    fixture.window.simulate_keystrokes("escape");
    fixture.transcript.read_with(&fixture.window, |this, _| {
        assert!(this.attachment_preview.is_none());
        assert!(this.diagram_zoom.is_none());
    });

    // The palette follows the theme: light renders its own diagram once.
    fixture.window.update(|_, cx| cx.set_global(Theme::light()));
    fixture.settle();
    assert_eq!(fixture.renders(), 2);
    assert!(fixture.bounds("mermaid-diagram").is_some());
    fixture.window.update(|_, cx| cx.set_global(Theme::dark()));
    fixture.settle();
    assert_eq!(
        fixture.renders(),
        2,
        "switching back reuses the dark diagram"
    );
}

#[gpui::test]
fn mermaid_diagram_fits_a_narrow_pane(cx: &mut gpui::TestAppContext) {
    let mut fixture = Fixture::new(cx);
    // Wide enough to overflow any narrow pane at its natural size.
    let wide = "flowchart LR\n  A[First step] --> B[Second step] --> C[Third step] --> D[Fourth step] --> E[Fifth step]";
    let text = format!("```mermaid\n{wide}\n```");
    fixture.window.simulate_resize(size(px(360.0), px(700.0)));
    fixture.reset(&[prompt(), reply(MessageStatus::Complete, &text)]);
    let diagram = fixture.bounds("mermaid-diagram").expect("diagram");
    assert!(
        diagram.right() <= px(360.0) && diagram.left() >= px(0.0),
        "the diagram scales into the pane: {diagram:?}"
    );
}

#[gpui::test]
fn invalid_mermaid_falls_back_to_its_source_with_a_note(cx: &mut gpui::TestAppContext) {
    let mut fixture = Fixture::new(cx);
    let text = "```mermaid\nthis is not a diagram\n```";
    fixture.reset(&[prompt(), reply(MessageStatus::Complete, text)]);
    assert_eq!(fixture.renders(), 1);
    assert!(fixture.bounds("mermaid-diagram").is_none());
    assert!(fixture.bounds("mermaid-note").is_some());
    // No toggle to a diagram that doesn't exist; the copy button stays.
    assert!(fixture.bounds("a#text.0-mermaid-0-source-toggle").is_none());
    fixture.settle();
    assert_eq!(fixture.renders(), 1, "a failure is cached too");
}

#[gpui::test]
fn streamed_mermaid_renders_once_its_fence_closes_not_per_token(cx: &mut gpui::TestAppContext) {
    let mut fixture = Fixture::new(cx);
    let mut text = String::from("Here is the flow:\n\n```mermaid\n");
    fixture.reset(&[prompt(), reply(MessageStatus::Streaming, &text)]);
    let tokens = [
        "flowchart LR\n",
        "  A[Plan]",
        " --> ",
        "B[Build]\n",
        "  B --> C",
        "[Ship]\n",
        "``",
    ];
    for token in tokens {
        text.push_str(token);
        fixture.append(token, text.len(), 2);
        assert_eq!(fixture.renders(), 0, "an open fence isn't rendered");
        assert!(fixture.bounds("mermaid-diagram").is_none());
    }
    // The closer arrives: the diagram renders while the reply still streams.
    text.push('`');
    fixture.append("`", text.len(), 2);
    assert_eq!(fixture.renders(), 1);
    assert!(fixture.bounds("mermaid-diagram").is_some());
    for token in ["\n\nThat", " covers", " the", " release", "."] {
        text.push_str(token);
        fixture.append(token, text.len(), 2);
    }
    assert_eq!(fixture.renders(), 1, "later tokens don't re-render it");
    // Completing the reply keeps the same diagram.
    fixture.deliver(harness_doc::TranscriptFrame::Delta {
        upsert: vec![harness_doc::TranscriptUpsert {
            after: Some("p".into()),
            entry: reply(MessageStatus::Complete, &text),
        }],
        append: Vec::new(),
        remove: Vec::new(),
        count: 2,
    });
    assert_eq!(fixture.renders(), 1);
    assert!(fixture.bounds("mermaid-diagram").is_some());
}
