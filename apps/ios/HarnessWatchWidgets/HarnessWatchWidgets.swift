// The Watch complication and Smart Stack widget (#322): the Harness mark,
// one tap from recording a message for a chat.

import SwiftUI
import WidgetKit

struct DictateEntry: TimelineEntry {
    let date: Date
}

struct DictateProvider: TimelineProvider {
    func placeholder(in context: Context) -> DictateEntry { DictateEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (DictateEntry) -> Void) {
        completion(DictateEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DictateEntry>) -> Void) {
        // Nothing on it changes over time.
        completion(Timeline(entries: [DictateEntry(date: Date())], policy: .never))
    }
}

/// Codegraff Dark's amber, for faces that show full colour.
private let amber = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255)

struct DictateView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WatchLink.dictateURL)
            .containerBackground(for: .widget) {}
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 8) {
                HarnessMarkShape()
                    .fill(amber)
                    .widgetAccentable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Harness").font(.headline)
                    Label("Speak to a chat", systemImage: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label("Speak to Harness", systemImage: "mic.fill")
        case .accessoryCorner:
            HarnessMarkShape()
                .fill(amber)
                .widgetAccentable()
                .padding(4)
                .widgetLabel("Speak")
        default:
            ZStack {
                AccessoryWidgetBackground()
                HarnessMarkShape()
                    .fill(amber)
                    .widgetAccentable()
                    .padding(9)
            }
        }
    }
}

@main
struct HarnessWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "harness.dictate", provider: DictateProvider()) { _ in
            DictateView()
        }
        .configurationDisplayName("Speak to Harness")
        .description("Opens Harness ready to record a message for a chat.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
