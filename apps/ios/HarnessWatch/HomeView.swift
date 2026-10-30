// The Watch's one screen: where the next message goes, the Speak button, and
// how the last few messages went.

import SwiftUI

struct HomeView: View {
    @Environment(WatchStore.self) private var store
    @Environment(Recorder.self) private var recorder
    let dictateRequest: Int

    @State private var flow: Flow?
    @State private var showPicker = false

    /// What's on top of the home screen while a message is being made.
    enum Flow: Identifiable, Equatable {
        case recording(id: String)
        case review(text: String)
        case transcribing(id: String, file: URL)
        /// The iPhone isn't reachable: the recording can wait for it.
        case away(id: String, file: URL)

        var id: String {
            switch self {
            case .recording(let id), .transcribing(let id, _), .away(let id, _): id
            case .review(let text): "review-\(text.hashValue)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    targetCard
                    speakButton
                    TextFieldLink(prompt: Text("Type or dictate")) {
                        Label("Type instead", systemImage: "keyboard")
                            .font(WatchTheme.sans(14, .medium))
                            .foregroundStyle(WatchTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    } onSubmit: { typed in
                        if let text = WatchLink.cleaned(typed) { flow = .review(text: text) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("watch-type")
                    if let fresh { SentCard(sent: fresh) }
                    if let notice { NoticeCard(text: notice) }
                    if !earlier.isEmpty { earlierList }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 8)
            }
            .background(WatchTheme.bg.ignoresSafeArea())
            .toolbar {
                // The brand sits in the clock's row, leaving the screen to Speak.
                ToolbarItem(placement: .topBarLeading) { header }
            }
            .navigationDestination(isPresented: $showPicker) { ChatPickerView() }
        }
        .tint(WatchTheme.accent)
        .fullScreenCover(item: $flow) { flow in
            FlowView(flow: flow, finish: { next in self.flow = next })
                .environment(store)
                .environment(recorder)
        }
        .onChange(of: dictateRequest) { _, _ in speak() }
        .task {
            store.refresh()
            switch WatchStore.screen {
            case "picker": showPicker = true
            case "review": flow = .review(text: "Also check the retry path when the upload times out, and add a test for it.")
            case "recording": flow = .recording(id: WatchStore.newId())
            default: break
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            HarnessMarkShape()
                .fill(WatchTheme.accent)
                .frame(width: 18, height: 18)
            Text("Harness")
                .font(WatchTheme.sans(15, .semibold, relativeTo: .headline))
                .foregroundStyle(WatchTheme.text)
        }
        .accessibilityElement(children: .combine)
    }

    private var targetCard: some View {
        Button { showPicker = true } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SEND TO")
                        .font(WatchTheme.eyebrow())
                        .tracking(0.8)
                        .foregroundStyle(WatchTheme.muted)
                    Text(store.targetTitle)
                        .font(WatchTheme.sans(15, .medium))
                        .foregroundStyle(WatchTheme.text)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    if let status = store.targetChat?.status {
                        StatusLabel(status: status)
                    } else {
                        Text("Auto models")
                            .font(WatchTheme.sans(12))
                            .foregroundStyle(WatchTheme.muted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WatchTheme.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-target")
    }

    private var speakButton: some View {
        Button(action: speak) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(WatchTheme.accentWash, lineWidth: 5)
                        .frame(width: 70, height: 70)
                    Circle()
                        .fill(WatchTheme.accent)
                        .frame(width: 58, height: 58)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(WatchTheme.onAccent)
                }
                Text("Speak")
                    .font(WatchTheme.sans(18, .semibold, relativeTo: .title3))
                    .foregroundStyle(WatchTheme.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speak")
        .accessibilityIdentifier("watch-speak")
    }

    private var earlierList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EARLIER")
                .font(WatchTheme.eyebrow())
                .tracking(0.8)
                .foregroundStyle(WatchTheme.muted)
                .padding(.leading, 6)
            ForEach(earlier) { SentCard(sent: $0, compact: true) }
        }
        .padding(.top, 4)
    }

    /// The latest message, for two minutes after it was sent.
    private var fresh: WatchLink.Sent? {
        store.sent.first.flatMap { WatchStore.nowMs() - $0.createdAt < 120_000 ? $0 : nil }
    }

    private var earlier: [WatchLink.Sent] {
        Array(store.sent.filter { $0.id != fresh?.id }.prefix(5))
    }

    private var notice: String? {
        guard let context = store.context else { return "Open Harness on your iPhone to see your chats here." }
        return context.signedIn ? nil : "Sign in to Harness on your iPhone."
    }

    private func speak() {
        guard flow == nil else { return }
        flow = .recording(id: WatchStore.newId())
    }
}

/// A sent message and how it went.
private struct SentCard: View {
    let sent: WatchLink.Sent
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(sent.text)
                    .font(WatchTheme.sans(compact ? 13 : 14, .medium))
                    .foregroundStyle(WatchTheme.text)
                    .lineLimit(compact ? 2 : 3)
                Text(caption)
                    .font(WatchTheme.sans(12))
                    .foregroundStyle(captionColor)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: compact ? WatchTheme.card : WatchTheme.raised)
    }

    private var icon: String {
        switch sent.state {
        case .waiting: "clock"
        case .delivered: "checkmark"
        case .failed: "exclamationmark"
        }
    }

    private var tint: Color {
        switch sent.state {
        case .waiting: WatchTheme.muted
        case .delivered: WatchTheme.success
        case .failed: WatchTheme.danger
        }
    }

    private var caption: String {
        switch sent.state {
        case .waiting: "Waiting for iPhone · \(sent.chatTitle)"
        case .delivered: "Sent · \(sent.chatTitle)"
        case .failed(let why): why
        }
    }

    private var captionColor: Color {
        if case .failed = sent.state { return WatchTheme.danger }
        return WatchTheme.muted
    }
}

private struct NoticeCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "iphone")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WatchTheme.warning)
            Text(text)
                .font(WatchTheme.sans(13))
                .foregroundStyle(WatchTheme.text)
            Spacer(minLength: 0)
        }
        .padding(12)
        .card(stroke: WatchTheme.warning.opacity(0.35))
    }
}
