// "Now" strip — the top of Home. What's running or waiting on you, as a row of
// swipeable cards you can act on at a glance, so the list below can stay a plain
// newest-first history. Cards keep the order you last called each session, and
// opening one pages through the same set (see SessionPager).

import SwiftUI

struct NowStrip: View {
    @Environment(AppModel.self) private var model
    let chats: [Chat]
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Now")
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(summary)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(chats) { chat in
                        NowCard(chat: chat, indicator: model.indicator(for: chat)) { open(chat.id) }
                            .containerRelativeFrame(.horizontal) { width, _ in
                                max(220, min(width * 0.78, 320))
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("now-strip")
    }

    private var summary: String {
        let needsYou = chats.filter { HomeStatusFilter.attention.matches(model.indicator(for: $0)) }.count
        let running = chats.filter { HomeStatusFilter.running.matches(model.indicator(for: $0)) }.count
        var parts: [String] = []
        if needsYou > 0 { parts.append("\(needsYou) need you") }
        if running > 0 { parts.append("\(running) running") }
        return parts.joined(separator: " · ")
    }

    /// The sessions the strip shows: running or waiting, in call order.
    @MainActor
    static func active(in chats: [Chat], model: AppModel) -> [Chat] {
        Array(sortActive(chats).filter {
            let indicator = model.indicator(for: $0)
            return HomeStatusFilter.attention.matches(indicator) || HomeStatusFilter.running.matches(indicator)
        }.prefix(8))
    }
}

private struct NowCard: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let indicator: ChatIndicator
    let onTap: () -> Void

    private var waiting: Bool { HomeStatusFilter.attention.matches(indicator) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if waiting {
                        Circle().fill(Theme.warning).frame(width: 8, height: 8)
                        Text(indicator == .errored ? "Run failed" : "Needs you")
                            .foregroundStyle(Theme.warning)
                    } else {
                        MiniSpinner()
                        Text("Running")
                            .foregroundStyle(Theme.statusWorking)
                    }
                    Spacer(minLength: 4)
                    Text(relativeTime(chat.calledAt))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                }
                .font(Theme.sans(12, weight: .medium))

                Text(chat.displayTitle)
                    .font(Theme.sans(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(preview)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)

                HStack(spacing: 5) {
                    if let harness = chat.config?.harness {
                        HarnessBadge(harness: harness, size: 12, neutral: Theme.textMuted)
                    }
                    Text(location)
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(waiting ? Theme.warning.opacity(0.10) : ink(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(waiting ? Theme.warning.opacity(0.45) : Theme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("now-card-\(chat.id)")
    }

    private var preview: String {
        let text = chat.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? (waiting ? "Waiting for your answer" : "Working…") : text
    }

    private var location: String {
        let space = chat.spaceId.flatMap { id in model.spaces.first { $0.id == id }?.displayName }
            ?? chat.cwd.map { ($0 as NSString).lastPathComponent }
        let device = model.deviceName(chat.deviceId)
        return [space, device].compactMap { $0 }.joined(separator: " @ ")
    }
}
