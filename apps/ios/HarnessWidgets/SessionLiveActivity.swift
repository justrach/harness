// The session Live Activity. Dynamic Island: the agent's mark and a status
// dot with the elapsed time (compact), plus title, latest line and project
// when expanded. Lock screen: the same, laid out as a card. Tapping either
// opens the session.

import ActivityKit
import SwiftUI
import WidgetKit

private typealias Phase = SessionActivityAttributes.ContentState.Phase

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenCard(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MarkTile(harness: attributes.harness, size: 40)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        StatusPill(phase: state.phase)
                        if state.phase == .working {
                            ElapsedTimer(startedAt: state.startedAt)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(.trailing, 6)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(attributes.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        WorkLine(state: state)
                        PlaceLine(attributes: attributes)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                BrandGlyph(harness: attributes.harness, size: 17)
                    .padding(.leading, 2)
            } compactTrailing: {
                CompactStatus(state: state)
            } minimal: {
                ZStack {
                    Circle().strokeBorder(phaseColor(state.phase), lineWidth: 2)
                    BrandGlyph(harness: attributes.harness, size: 11)
                }
            }
            .widgetURL(attributes.url)
            .keylineTint(phaseColor(state.phase))
        }
    }
}

// MARK: - Lock screen

private struct LockScreenCard: View {
    let attributes: SessionActivityAttributes
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MarkTile(harness: attributes.harness, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(attributes.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    StatusPill(phase: state.phase)
                }
                WorkLine(state: state)
                HStack(spacing: 8) {
                    PlaceLine(attributes: attributes)
                    Spacer(minLength: 4)
                    if state.phase == .working {
                        ElapsedTimer(startedAt: state.startedAt)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .font(.caption)
            }
        }
        .padding(16)
    }
}

// MARK: - Pieces

/// The agent's brand mark (Claude keeps its orange, others are white).
private struct BrandGlyph: View {
    let harness: String
    let size: CGFloat

    var body: some View {
        let mark = BrandMark.forHarness(harness)
        BrandMarkShape(mark: mark)
            .fill(BrandMark.tint(for: harness), style: FillStyle(eoFill: mark.evenOddFill))
            .frame(width: size, height: size)
    }
}

/// The mark on a soft rounded tile, for the expanded island and the card.
private struct MarkTile: View {
    let harness: String
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(.white.opacity(0.10))
            .overlay(BrandGlyph(harness: harness, size: size * 0.5))
            .frame(width: size, height: size)
    }
}

/// "Working" / "Waiting for you" / "Done" / "Failed" on a tinted capsule.
private struct StatusPill: View {
    let phase: Phase

    var body: some View {
        HStack(spacing: 5) {
            if phase == .working {
                Circle().fill(phaseColor(phase)).frame(width: 6, height: 6)
            } else {
                Image(systemName: phaseSymbol(phase)).font(.system(size: 10, weight: .bold))
            }
            Text(phaseLabel(phase))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(phaseColor(phase))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(phaseColor(phase).opacity(0.18), in: Capsule())
        .fixedSize()
    }
}

/// Compact trailing: a status dot and the running time, or the state's icon.
private struct CompactStatus: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .working:
            HStack(spacing: 5) {
                Circle().fill(phaseColor(.working)).frame(width: 6, height: 6)
                // With a task list, progress says more than the clock.
                if state.hasTasks, let total = state.tasksTotal {
                    Text("\(state.tasksDone ?? 0)/\(total)")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                } else {
                    ElapsedTimer(startedAt: state.startedAt)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 40)
                }
            }
        case .waiting, .done, .failed:
            Image(systemName: phaseSymbol(state.phase))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(phaseColor(state.phase))
        }
    }
}

/// What the agent is on: the current task and progress through its task
/// list when it keeps one, otherwise its latest line.
private struct WorkLine: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        if state.hasTasks, let total = state.tasksTotal {
            let done = state.tasksDone ?? 0
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: state.task == nil ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(phaseColor(state.phase))
                    Text(state.task ?? "All \(total) tasks done")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text("\(done) of \(total)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize()
                }
                ProgressView(value: Double(done), total: Double(total))
                    .tint(phaseColor(state.phase))
            }
        } else if let detail = state.detail {
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
        }
    }
}

/// Counts up from the run's start by itself (no updates needed).
private struct ElapsedTimer: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/// "● project · device", the dot and name in the project's tint.
private struct PlaceLine: View {
    let attributes: SessionActivityAttributes

    var body: some View {
        HStack(spacing: 5) {
            if let project = attributes.project {
                Circle().fill(projectColor(attributes.projectTint)).frame(width: 6, height: 6)
                Text(project)
                    .foregroundStyle(projectColor(attributes.projectTint))
                    .fontWeight(.medium)
                Text("· \(attributes.device)").foregroundStyle(.white.opacity(0.55))
            } else {
                Text(attributes.device).foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Palette

private func phaseLabel(_ phase: Phase) -> String {
    switch phase {
    case .working: return "Working"
    case .waiting: return "Waiting for you"
    case .done: return "Done"
    case .failed: return "Failed"
    }
}

private func phaseSymbol(_ phase: Phase) -> String {
    switch phase {
    case .working: return "circle.fill"
    case .waiting: return "hand.raised.fill"
    case .done: return "checkmark"
    case .failed: return "exclamationmark"
    }
}

/// The app's status colors: pink working, indigo waiting, emerald done, red failed.
private func phaseColor(_ phase: Phase) -> Color {
    switch phase {
    case .working: return Color(red: 0.96, green: 0.45, blue: 0.71)
    case .waiting: return Color(red: 0.51, green: 0.55, blue: 0.97)
    case .done: return Color(red: 0.20, green: 0.83, blue: 0.60)
    case .failed: return Color(red: 0.97, green: 0.44, blue: 0.44)
    }
}

/// The app's eight project tints (coral, amber, green, teal, sky, indigo,
/// violet, pink), in the same order as `Theme.projectTint`.
private func projectColor(_ index: Int?) -> Color {
    guard let index else { return .white.opacity(0.55) }
    let hues: [Double] = [0.02, 0.10, 0.36, 0.48, 0.56, 0.66, 0.76, 0.92]
    return Color(hue: hues[index % hues.count], saturation: 0.5, brightness: 0.95)
}
