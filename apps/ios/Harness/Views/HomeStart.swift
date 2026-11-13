// The top of Home: one question, one composer, four starters in a 2x2 grid.
// Solid cards on the Codegraff palette; no glass here (glass is for floating
// controls only). The session list below carries the history, grouped Needs
// you, Today, Earlier.

import SwiftUI

struct HomeStarter: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let prompt: String
    /// Only offered when there is a project to talk about.
    let needsProject: Bool

    static let all: [HomeStarter] = [
        HomeStarter(id: "build", title: "Build something new", symbol: "wand.and.stars",
                    prompt: "Let's build something new. Ask me what I have in mind first.",
                    needsProject: false),
        HomeStarter(id: "research", title: "Research a topic", symbol: "magnifyingglass",
                    prompt: "Research the topic below and give me a short, sourced write-up with the key takeaways first.\n\nTopic: ",
                    needsProject: false),
        HomeStarter(id: "launch", title: "Plan a launch", symbol: "globe",
                    prompt: "Help me take my product to market. Ask me about it first, then draft positioning and landing page copy.\n\nThe product: ",
                    needsProject: false),
        HomeStarter(id: "tour", title: "Tour this project", symbol: "doc.text.magnifyingglass",
                    prompt: "Give me a tour of this project: what it does, how it is laid out, and where to start.",
                    needsProject: true),
    ]

    /// Two rows of two. Without a project the tour drops out and the grid
    /// keeps three tiles rather than inventing a fourth.
    static func grid(hasProject: Bool) -> [[HomeStarter]] {
        let tiles = all.filter { hasProject || !$0.needsProject }
        return stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
    }
}

struct HomeStartHeader: View {
    let hasProject: Bool
    /// Tapping the composer: start a new session.
    let compose: () -> Void
    let start: (HomeStarter) -> Void

    static let title = "What should Graff do?"
    static let subtitle = "Ask for anything. Your chats are below."

    var body: some View {
        VStack(alignment: .center, spacing: Theme.spaceMD) {
            VStack(alignment: .center, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: 40, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                    HarnessMark()
                        .frame(width: 20, height: 20)
                }
                .padding(.bottom, 2)
                Text(Self.title)
                    .font(Theme.sans(Theme.titleSize, weight: .semibold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home-title")
                Text(Self.subtitle)
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Button(action: compose) {
                HStack(spacing: Theme.spaceSM) {
                    Text("Message Graff")
                        .font(Theme.sans(15))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.bg)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.accent))
                }
                .padding(.leading, Theme.spaceLG)
                .padding(.trailing, Theme.spaceSM)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                    .fill(Theme.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Message Graff")
            .accessibilityHint("Starts a new chat")
            .accessibilityIdentifier("home-composer")
            VStack(spacing: Theme.spaceSM) {
                ForEach(Array(HomeStarter.grid(hasProject: hasProject).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Theme.spaceSM) {
                        ForEach(row) { starter in tile(starter) }
                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
        }
    }

    private func tile(_ starter: HomeStarter) -> some View {
        Button { start(starter) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: starter.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text(starter.title)
                    .font(Theme.sans(14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(Theme.spaceMD)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressWashButtonStyle(cornerRadius: Theme.panelRadius))
        .accessibilityIdentifier("home-starter-\(starter.id)")
    }
}
