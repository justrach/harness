//! The core's `tracing` output, handed to the app (Android writes it to logcat). Sync must never fail silently: a
//! rejected sign-in, a refused write or a wedged room shows up here.

use std::sync::{Arc, OnceLock};

use tracing::field::{Field, Visit};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::{Layer, Registry};

#[uniffi::export(with_foreign)]
pub trait LogSink: Send + Sync {
    /// `level` is "error", "warn", "info" or "debug".
    fn log(&self, level: String, target: String, message: String);
}

struct SinkLayer(Arc<dyn LogSink>);

#[derive(Default)]
struct Line(String);

impl Visit for Line {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.0.insert_str(0, &format!("{value:?}"));
        } else {
            self.0.push_str(&format!(" {}={value:?}", field.name()));
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.0.insert_str(0, value);
        } else {
            self.0.push_str(&format!(" {}={value}", field.name()));
        }
    }
}

impl<S: Subscriber> Layer<S> for SinkLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let level = match *event.metadata().level() {
            Level::ERROR => "error",
            Level::WARN => "warn",
            // Our own info lines (joins, repairs); dependencies' info lines are internal diagnostics.
            Level::INFO if event.metadata().target().starts_with("harness") => "info",
            _ => return,
        };
        let mut line = Line::default();
        event.record(&mut line);
        self.0
            .log(level.into(), event.metadata().target().into(), line.0);
    }
}

static INSTALLED: OnceLock<()> = OnceLock::new();

/// Send the core's log lines (warnings and errors, plus Harness's own info lines) to `sink`. Only the first call in a process takes effect.
#[uniffi::export]
pub fn install_log_sink(sink: Arc<dyn LogSink>) {
    INSTALLED.get_or_init(|| {
        let subscriber = Registry::default().with(SinkLayer(sink));
        let _ = tracing::subscriber::set_global_default(subscriber);
    });
}
