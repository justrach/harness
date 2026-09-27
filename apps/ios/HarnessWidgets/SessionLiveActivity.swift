// The session Live Activity: status, title and project on the lock screen,
// the status and elapsed time in the Dynamic Island. Tapping opens the chat.

import ActivityKit
import SwiftUI
import WidgetKit

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            SessionActivityCard(attributes: context.attributes, state: context.state)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusGlyph(phase: state.phase)
                        .font(.title3)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusLabel(state: state)
                        .font(.callout.weight(.medium))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(attributes.location)
                            .font(.caption)
                            .foregroundStyle(projectColor(attributes.projectTint))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                StatusGlyph(phase: state.phase)
            } compactTrailing: {
                StatusLabel(state: state, compact: true)
                    .font(.caption.weight(.semibold))
            } minimal: {
                StatusGlyph(phase: state.phase)
            }
            .widgetURL(attributes.url)
            .keylineTint(phaseColor(state.phase))
        }
    }
}

private struct SessionActivityCard: View {
    let attributes: SessionActivityAttributes
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusGlyph(phase: state.phase)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(attributes.location)
                    .font(.subheadline)
                    .foregroundStyle(projectColor(attributes.projectTint))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusLabel(state: state)
                .font(.subheadline.weight(.medium))
        }
        .padding(16)
    }
}

private struct StatusGlyph: View {
    let phase: SessionActivityAttributes.ContentState.Phase

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(phaseColor(phase))
    }

    private var symbol: String {
        switch phase {
        case .working: return "sparkle"
        case .waiting: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// Working: a live elapsed timer. Otherwise the state in words.
private struct StatusLabel: View {
    let state: SessionActivityAttributes.ContentState
    var compact = false

    var body: some View {
        switch state.phase {
        case .working:
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: compact ? 44 : 64, alignment: .trailing)
                .foregroundStyle(phaseColor(.working))
        case .waiting:
            Text(compact ? "Input" : "Waiting for you").foregroundStyle(phaseColor(.waiting))
        case .done:
            Text("Done").foregroundStyle(phaseColor(.done))
        case .failed:
            Text("Failed").foregroundStyle(phaseColor(.failed))
        }
    }
}

/// The app's status colors (pink working, indigo waiting, emerald done, red
/// failed), as system colors that adapt to the lock screen.
private func phaseColor(_ phase: SessionActivityAttributes.ContentState.Phase) -> Color {
    switch phase {
    case .working: return .pink
    case .waiting: return .indigo
    case .done: return .green
    case .failed: return .red
    }
}

/// The app's eight project tints (coral, amber, green, teal, sky, indigo,
/// violet, pink), in the same order as `Theme.projectTint`.
private func projectColor(_ index: Int?) -> Color {
    guard let index else { return .secondary }
    let hues: [Double] = [0.02, 0.10, 0.36, 0.48, 0.56, 0.66, 0.76, 0.92]
    return Color(hue: hues[index % hues.count], saturation: 0.55, brightness: 0.85)
}
