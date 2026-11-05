// Making one message: record, get the text back from the iPhone, review it,
// then Send or Discard. A recording made while the iPhone is away can be
// sent as it is; the iPhone writes it out and sends it when they reconnect.

import SwiftUI

struct FlowView: View {
    let flow: HomeView.Flow
    let finish: (HomeView.Flow?) -> Void

    var body: some View {
        Group {
            switch flow {
            case .recording(let id): RecordingView(id: id, finish: finish)
            case .transcribing(let id, let file): TranscribingView(id: id, file: file, finish: finish)
            case .review(let text): ReviewView(text: text, finish: finish)
            case .away(let id, let file): AwayView(id: id, file: file, finish: finish)
            }
        }
        .background(WatchTheme.bg.ignoresSafeArea())
    }
}

/// "To <chat>", above each step.
private struct TargetLine: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        HStack(spacing: 5) {
            if let status = store.targetChat?.status { StatusDot(status: status, size: 6) }
            Text("To \(store.targetTitle)")
                .font(WatchTheme.sans(12, .medium, relativeTo: .caption))
                .foregroundStyle(WatchTheme.muted)
                .lineLimit(1)
        }
    }
}

private struct RecordingView: View {
    @Environment(WatchStore.self) private var store
    @Environment(Recorder.self) private var recorder
    let id: String
    let finish: (HomeView.Flow?) -> Void
    /// The last few levels, newest last, for the waveform.
    @State private var levels: [Double] = Array(repeating: 0, count: Self.bars)

    static let bars = 22

    var body: some View {
        VStack(spacing: 10) {
            switch recorder.state {
            case .denied:
                Problem(text: "Allow the microphone for Harness in the Watch's Settings.") { recorder.reset(); finish(nil) }
            case .failed(let why):
                Problem(text: why) { recorder.reset(); finish(nil) }
            case .idle, .recording:
                Waveform(levels: levels)
                    .frame(height: 46)
                    .padding(.horizontal, 4)
                    .padding(.top, 18)
                elapsed
                TargetLine()
                Button(action: stop) {
                    ZStack {
                        Circle().stroke(WatchTheme.accent, lineWidth: 4).frame(width: 58, height: 58)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(WatchTheme.accent)
                            .frame(width: 22, height: 22)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
                .accessibilityIdentifier("watch-stop")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await recorder.start(id: id)
            if case .recording = recorder.state { WatchTheme.haptic(.start) }
        }
        .onChange(of: recorder.level) { _, level in
            levels = Array((levels + [level]).suffix(Self.bars))
        }
        .onChange(of: recorder.reachedLimit) { _, reached in if reached { stop() } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Discard", systemImage: "xmark") {
                    recorder.cancel()
                    finish(nil)
                }
            }
        }
    }

    @ViewBuilder private var elapsed: some View {
        if case .recording(let started) = recorder.state {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(Duration.seconds(context.date.timeIntervalSince(started)).formatted(.time(pattern: .minuteSecond)))
                    .font(WatchTheme.mono(22))
                    .foregroundStyle(WatchTheme.text)
            }
        } else {
            Text("0:00").font(WatchTheme.mono(22)).foregroundStyle(WatchTheme.faint)
        }
    }

    private func stop() {
        WatchTheme.haptic(.stop)
        guard let file = recorder.stop() else {
            finish(nil)
            return
        }
        finish(store.reachable ? .transcribing(id: id, file: file) : .away(id: id, file: file))
    }
}

/// Amber bars, newest on the right; quiet bars keep a sliver so the line
/// never disappears.
private struct Waveform: View {
    let levels: [Double]

    var body: some View {
        GeometryReader { geo in
            let count = CGFloat(levels.count)
            let gap: CGFloat = 3
            let width = max(2, (geo.size.width - gap * (count - 1)) / count)
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(index == levels.count - 1 ? WatchTheme.accentLight : WatchTheme.accent)
                        .opacity(0.35 + 0.65 * Double(index) / Double(max(1, levels.count - 1)))
                        .frame(width: width, height: max(4, geo.size.height * level))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}

private struct TranscribingView: View {
    @Environment(WatchStore.self) private var store
    let id: String
    let file: URL
    let finish: (HomeView.Flow?) -> Void
    @State private var slow = false
    @State private var pulse = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let transcript = store.transcripts[id], transcript.text == nil {
                    Problem(text: transcript.detail ?? "Couldn't write that out.") { finish(nil) }
                } else if slow {
                    Text("Your iPhone is taking a while.")
                        .font(WatchTheme.sans(15, .medium))
                        .foregroundStyle(WatchTheme.text)
                        .multilineTextAlignment(.center)
                    Button {
                        store.sendRecording(file, id: WatchStore.newId(), deliver: true)
                        WatchTheme.haptic(.click)
                        finish(nil)
                    } label: {
                        Label("Send without reviewing", systemImage: "arrow.up")
                    }
                    .buttonStyle(AccentButtonStyle())
                    Button("Discard") { finish(nil) }
                        .buttonStyle(QuietButtonStyle(tint: WatchTheme.muted))
                } else {
                    HarnessMarkShape()
                        .fill(WatchTheme.accent)
                        .frame(width: 44, height: 44)
                        .opacity(pulse ? 1 : 0.35)
                        .scaleEffect(pulse ? 1 : 0.9)
                        .padding(.top, 18)
                    Text("Writing it out on your iPhone…")
                        .font(WatchTheme.sans(14, .medium))
                        .foregroundStyle(WatchTheme.text)
                        .multilineTextAlignment(.center)
                    TargetLine()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .task {
            store.sendRecording(file, id: id, deliver: false)
            try? await Task.sleep(for: .seconds(20))
            slow = true
        }
        .onChange(of: store.transcripts[id]) { _, transcript in
            if let text = transcript?.text {
                store.forgetTranscript(id)
                WatchTheme.haptic(.click)
                finish(.review(text: text))
            }
        }
    }
}

private struct ReviewView: View {
    @Environment(WatchStore.self) private var store
    @State private var text: String
    let finish: (HomeView.Flow?) -> Void

    init(text: String, finish: @escaping (HomeView.Flow?) -> Void) {
        _text = State(initialValue: text)
        self.finish = finish
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TargetLine()
                    .padding(.leading, 4)
                Text(text)
                    .font(WatchTheme.sans(16))
                    .foregroundStyle(WatchTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .card(fill: WatchTheme.raised)
                    .accessibilityIdentifier("watch-transcript")
                if store.targetBusy { modePicker }
            }
            // Clear of the bottom toolbar's buttons.
            .padding(.bottom, 44)
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                TextFieldLink(prompt: Text("Edit")) {
                    Image(systemName: "pencil")
                } onSubmit: { edited in
                    if let edited = WatchLink.cleaned(edited) { text = edited }
                }
                .accessibilityLabel("Edit")
                Spacer()
                Button {
                    if store.send(text) {
                        WatchTheme.haptic(.click)
                        finish(nil)
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .tint(WatchTheme.accent)
                .disabled(WatchLink.cleaned(text) == nil)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("watch-send")
            }
        }
    }

    /// Queue or steer, while the agent works.
    private var modePicker: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 6) {
            Text("WHILE IT'S WORKING")
                .font(WatchTheme.eyebrow())
                .tracking(0.8)
                .foregroundStyle(WatchTheme.muted)
                .padding(.leading, 4)
            HStack(spacing: 6) {
                ModePill(title: "Queue", selected: store.mode == .queue) { store.mode = .queue }
                ModePill(title: "Steer now", selected: store.mode == .now) { store.mode = .now }
            }
        }
    }
}

private struct ModePill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WatchTheme.sans(13, .semibold))
                .foregroundStyle(selected ? WatchTheme.onAccent : WatchTheme.text)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(selected ? WatchTheme.accent : WatchTheme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AwayView: View {
    @Environment(WatchStore.self) private var store
    let id: String
    let file: URL
    let finish: (HomeView.Flow?) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(WatchTheme.warning)
                    .padding(.top, 6)
                Text("Your iPhone isn't nearby")
                    .font(WatchTheme.sans(16, .semibold))
                    .foregroundStyle(WatchTheme.text)
                Text("Harness on your iPhone writes the recording out and sends it to \(store.targetTitle) when they reconnect.")
                    .font(WatchTheme.sans(13))
                    .foregroundStyle(WatchTheme.muted)
                    .multilineTextAlignment(.center)
                Button {
                    store.sendRecording(file, id: id, deliver: true)
                    WatchTheme.haptic(.click)
                    finish(nil)
                } label: {
                    Label("Send recording", systemImage: "arrow.up")
                }
                .buttonStyle(AccentButtonStyle())
                Button("Discard") {
                    try? FileManager.default.removeItem(at: file)
                    finish(nil)
                }
                .buttonStyle(QuietButtonStyle(tint: WatchTheme.muted))
            }
        }
    }
}

/// Something went wrong before a message existed.
private struct Problem: View {
    let text: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(WatchTheme.danger)
            Text(text)
                .font(WatchTheme.sans(14, .medium))
                .foregroundStyle(WatchTheme.text)
                .multilineTextAlignment(.center)
            Button("Close", action: close)
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 4)
        .onAppear { WatchTheme.haptic(.failure) }
    }
}
