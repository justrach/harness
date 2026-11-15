import SwiftUI

struct VoiceSessionSheet: View {
    let store: SessionStore
    let chat: Chat
    let runLive: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var manager: SessionVoiceManager

    init(store: SessionStore, chat: Chat, runLive: Bool) {
        self.store = store
        self.chat = chat
        self.runLive = runLive
        let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
        _manager = State(initialValue: SessionVoiceManager(chatId: chat.id, demoMode: isDemo))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(chat.displayTitle)
                        .font(Theme.sans(17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(statusTitle)
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(orbTint)
                        .accessibilityIdentifier("voice-session-status")
                }
                .padding(.top, 12)

                Spacer(minLength: 8)

                VoiceOrbView(phase: manager.phase, level: manager.audioLevel, tint: orbTint)
                    .frame(width: 152, height: 152)
                    .accessibilityIdentifier("voice-session-orb")

                transcriptCard
                    .padding(.horizontal, 24)

                Spacer(minLength: 8)

                controlBar
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        manager.autoSpeakReplies.toggle()
                    } label: {
                        Image(systemName: manager.autoSpeakReplies ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundStyle(manager.autoSpeakReplies ? Theme.text : Theme.textMuted)
                    }
                    .accessibilityLabel(manager.autoSpeakReplies ? "Spoken replies on" : "Spoken replies off")
                    .accessibilityIdentifier("voice-toggle-tts")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        manager.stop()
                        dismiss()
                    }
                    .accessibilityIdentifier("voice-done")
                }
            }
        }
        .presentationDetents([.fraction(0.68), .large])
        .presentationDragIndicator(.visible)
        .task {
            await manager.start(entries: store.entries, runLive: runLive) { prompt in
                store.sendRun(prompt: prompt, chat: chat)
            }
        }
        .onChange(of: store.revision) { _, _ in
            manager.observeSession(entries: store.entries, runLive: runLive)
        }
        .onChange(of: runLive) { _, live in
            manager.observeSession(entries: store.entries, runLive: live)
        }
        .onDisappear {
            manager.stop()
        }
    }

    private var statusTitle: String {
        switch manager.phase {
        case .idle, .requestingPermission: return "Starting Voice Mode…"
        case .listening: return runLive ? "Agent working · Listening" : "Listening…"
        case .processing: return "Thinking…"
        case .speaking: return "Speaking…"
        case .muted: return "Microphone muted"
        case .error: return "Voice unavailable"
        }
    }

    private var orbTint: Color {
        switch manager.phase {
        case .listening:
            return Color(red: 0.16, green: 0.72, blue: 0.52)
        case .processing:
            return Color(red: 0.90, green: 0.38, blue: 0.64)
        case .speaking:
            return Color(red: 0.25, green: 0.56, blue: 0.94)
        case .muted, .idle, .requestingPermission:
            return Theme.textMuted
        case .error:
            return Theme.danger
        }
    }

    @ViewBuilder
    private var transcriptCard: some View {
        let content: String = {
            switch manager.phase {
            case .listening(let text):
                return text.isEmpty ? "Speak naturally — pauses send your turn automatically." : text
            case .processing(let prompt):
                return prompt
            case .speaking(let reply):
                return reply
            case .muted:
                return "Tap Unmute when you're ready to talk again."
            case .error(let message):
                return message
            case .idle, .requestingPermission:
                return "Preparing audio session…"
            }
        }()

        ScrollView {
            Text(content)
                .font(Theme.sans(15))
                .foregroundStyle(manager.currentTranscript == nil ? Theme.textMuted : Theme.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .frame(minHeight: 58, maxHeight: 110)
        .background(Theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("voice-transcript-card")
    }

    private var controlBar: some View {
        let isMuted: Bool = {
            if case .muted = manager.phase { return true }
            return false
        }()
        let canSendNow: Bool = {
            if case .listening(let text) = manager.phase {
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }()
        let isSpeaking: Bool = {
            if case .speaking = manager.phase { return true }
            return false
        }()

        return HStack(spacing: 24) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                manager.toggleMute()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isMuted ? Theme.onAccent : Theme.text)
                        .frame(width: 56, height: 56)
                        .background(isMuted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface), in: Circle())
                    Text(isMuted ? "Unmute" : "Mute")
                        .font(Theme.sans(12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice-mute-button")

            if isSpeaking {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    manager.interruptSpeech()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 56, height: 56)
                            .background(orbTint, in: Circle())
                        Text("Interrupt")
                            .font(Theme.sans(12, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voice-interrupt-button")
            } else if canSendNow {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    manager.sendCurrentTranscriptNow()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 56, height: 56)
                            .background(Theme.accent, in: Circle())
                        Text("Send now")
                            .font(Theme.sans(12, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voice-send-now")
            }

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                manager.stop()
                dismiss()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Theme.danger, in: Circle())
                    Text("End")
                        .font(Theme.sans(12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice-end-button")
        }
    }
}

private struct VoiceOrbView: View {
    let phase: SessionVoiceRules.Phase
    let level: Double
    let tint: Color

    var body: some View {
        let clamped = min(max(level, 0.08), 1.0)
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .scaleEffect(0.88 + clamped * 0.24)
            Circle()
                .strokeBorder(tint.opacity(0.28), lineWidth: 2)
                .scaleEffect(0.72 + clamped * 0.16)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.55)],
                        center: .topLeading,
                        startRadius: 8,
                        endRadius: 80
                    )
                )
                .frame(width: 90, height: 90)
                .shadow(color: tint.opacity(0.35), radius: 18, y: 6)
            Image(systemName: centerSymbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.18), value: clamped)
    }

    private var centerSymbol: String {
        switch phase {
        case .listening: return "waveform"
        case .processing: return "Sparkles".lowercased() == "sparkles" ? "ellipsis" : "waveform"
        case .speaking: return "speaker.wave.2.fill"
        case .muted: return "mic.slash.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle, .requestingPermission: return "waveform"
        }
    }
}
