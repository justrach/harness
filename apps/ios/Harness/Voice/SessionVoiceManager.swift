// Hands-free Session Voice Mode: live speech recognition (`SFSpeechRecognizer` +
// `AVAudioEngine`), silence endpointing into `SessionStore.sendRun`, optional
// `AVSpeechSynthesizer` spoken assistant replies, and Live Activity voice state.

import AVFoundation
import Foundation
import Observation
import Speech

enum SessionVoiceRules {
    enum Phase: Equatable, Sendable {
        case idle
        case requestingPermission
        case listening(transcript: String)
        case processing(prompt: String)
        case speaking(reply: String)
        case muted
        case error(String)
    }

    static let defaultSilenceThresholdMs: Int64 = 1_400

    static func liveActivityState(
        for phase: Phase,
        runLive: Bool
    ) -> SessionActivityAttributes.ContentState.VoiceState? {
        switch phase {
        case .idle, .requestingPermission, .error:
            return nil
        case .muted:
            return .muted
        case .speaking:
            return .speaking
        case .processing:
            return .processing
        case .listening:
            return runLive ? .processing : .listening
        }
    }

    static func shouldAutoSend(
        transcript: String,
        silenceElapsedMs: Int64,
        thresholdMs: Int64 = defaultSilenceThresholdMs
    ) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return silenceElapsedMs >= thresholdMs
    }

    /// Convert settled assistant markdown into clean spoken prose for `AVSpeechSynthesizer`,
    /// replacing fenced code blocks with a brief spoken cue.
    static func cleanForSpeech(_ markdown: String) -> String {
        var result = ""
        var inFence = false
        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !inFence {
                    result += " Code block omitted. "
                }
                inFence.toggle()
                continue
            }
            if inFence { continue }
            var line = trimmed
            while line.hasPrefix("#") { line.removeFirst() }
            line = line
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                if !result.isEmpty && !result.hasSuffix(" ") { result += " " }
                result += line
            }
        }
        let collapsed = result
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > 900 ? String(collapsed.prefix(899)) + "…" : collapsed
    }

    /// Find the newest settled assistant reply strictly after `afterEntryId` (or the latest settled
    /// assistant reply if `afterEntryId` is nil and `allowInitial` is true).
    static func extractSpeakableReply(
        from entries: [MessageEntry],
        afterEntryId: String?
    ) -> (entryId: String, text: String)? {
        let slice: ArraySlice<MessageEntry>
        if let afterEntryId {
            guard let ix = entries.lastIndex(where: { $0.id == afterEntryId }) else { return nil }
            let nextIx = entries.index(after: ix)
            guard nextIx < entries.endIndex else { return nil }
            slice = entries[nextIx...]
        } else {
            return nil
        }
        for entry in slice.reversed() where entry.role == .assistant && entry.status == .complete {
            let joined = entry.parts.compactMap { part -> String? in
                if case .text(_, let text) = part, !text.isEmpty { return text }
                return nil
            }.joined(separator: "\n")
            let spoken = cleanForSpeech(joined)
            if !spoken.isEmpty {
                return (entry.id, spoken)
            }
        }
        return nil
    }
}

@MainActor
@Observable
final class SessionVoiceRegistry {
    static let shared = SessionVoiceRegistry()

    private(set) var states: [String: SessionActivityAttributes.ContentState.VoiceState] = [:]
    private(set) var details: [String: String] = [:]

    func update(
        chatId: String,
        state: SessionActivityAttributes.ContentState.VoiceState?,
        detail: String?
    ) {
        if let state {
            states[chatId] = state
            if let detail, !detail.isEmpty {
                details[chatId] = detail
            } else {
                details.removeValue(forKey: chatId)
            }
        } else {
            states.removeValue(forKey: chatId)
            details.removeValue(forKey: chatId)
        }
    }

    func activeVoiceState(for chatId: String) -> SessionActivityAttributes.ContentState.VoiceState? {
        states[chatId]
    }

    func detailOverride(for chatId: String) -> String? {
        details[chatId]
    }
}

@MainActor
@Observable
final class SessionVoiceManager: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var phase: SessionVoiceRules.Phase = .idle
    private(set) var audioLevel: Double = 0
    var autoSpeakReplies: Bool = true
    private(set) var lastSpokenEntryId: String?

    private let chatId: String
    private let demoMode: Bool
    private var onSendPrompt: ((String) -> Void)?
    private var runLive = false

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var speechRecognizer = SFSpeechRecognizer()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var lastTranscriptUpdateMs: Int64 = 0

    init(chatId: String, demoMode: Bool = false) {
        self.chatId = chatId
        self.demoMode = demoMode
        super.init()
        synthesizer.delegate = self
    }

    func start(
        entries: [MessageEntry],
        runLive: Bool,
        onSendPrompt: @escaping (String) -> Void
    ) async {
        self.onSendPrompt = onSendPrompt
        self.runLive = runLive
        self.lastSpokenEntryId = entries.last?.id

        if demoMode {
            let sample = "Summarize the latest diff in TranscriptView and run the unit tests."
            phase = .listening(transcript: sample)
            audioLevel = 0.64
            syncRegistry(detail: sample)
            return
        }

        phase = .requestingPermission
        let authorized = await requestPermissions()
        guard authorized else {
            phase = .error("Microphone and Speech Recognition access are required for Voice Mode.")
            syncRegistry(detail: nil)
            return
        }
        beginListening()
    }

    func observeSession(entries: [MessageEntry], runLive: Bool) {
        self.runLive = runLive
        if case .processing = phase, !runLive {
            if autoSpeakReplies,
               let reply = SessionVoiceRules.extractSpeakableReply(
                   from: entries,
                   afterEntryId: lastSpokenEntryId
               ) {
                lastSpokenEntryId = reply.entryId
                speak(reply.text)
                return
            }
            lastSpokenEntryId = entries.last?.id
            if !demoMode {
                beginListening()
            } else {
                phase = .listening(transcript: "")
                syncRegistry(detail: nil)
            }
            return
        }
        syncRegistry(detail: currentTranscript)
    }

    var currentTranscript: String? {
        switch phase {
        case .listening(let text) where !text.isEmpty: return text
        case .processing(let prompt): return prompt
        case .speaking(let reply): return reply
        default: return nil
        }
    }

    func toggleMute() {
        switch phase {
        case .muted:
            if demoMode {
                phase = .listening(transcript: "")
                audioLevel = 0.45
                syncRegistry(detail: nil)
            } else {
                beginListening()
            }
        default:
            teardownCapture()
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
            audioLevel = 0
            phase = .muted
            syncRegistry(detail: "Voice muted")
        }
    }

    func sendCurrentTranscriptNow() {
        guard case .listening(let text) = phase else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        teardownCapture()
        audioLevel = 0
        phase = .processing(prompt: trimmed)
        syncRegistry(detail: trimmed)
        onSendPrompt?(trimmed)
    }

    func interruptSpeech() {
        guard synthesizer.isSpeaking || ({ if case .speaking = phase { return true }; return false }()) else {
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        if demoMode {
            phase = .listening(transcript: "")
            syncRegistry(detail: nil)
        } else {
            beginListening()
        }
    }

    func stop() {
        teardownCapture()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioLevel = 0
        phase = .idle
        SessionVoiceRegistry.shared.update(chatId: chatId, state: nil, detail: nil)
    }

    // MARK: - Private Audio / Speech Pipeline

    private func syncRegistry(detail: String?) {
        let mapped = SessionVoiceRules.liveActivityState(for: phase, runLive: runLive)
        SessionVoiceRegistry.shared.update(chatId: chatId, state: mapped, detail: detail)
    }

    private func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func beginListening() {
        teardownCapture()
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            phase = .error("Speech recognition is currently unavailable on this device.")
            syncRegistry(detail: nil)
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let level = Self.normalizedRMS(buffer: buffer)
                Task { @MainActor [weak self] in
                    self?.audioLevel = level
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            phase = .listening(transcript: "")
            syncRegistry(detail: "Listening…")

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if case .listening = self.phase {
                            self.phase = .listening(transcript: text)
                            self.lastTranscriptUpdateMs = Int64(Date().timeIntervalSince1970 * 1000)
                            self.syncRegistry(detail: text)
                            self.armSilenceTimer()
                        }
                        if result.isFinal {
                            self.sendCurrentTranscriptNow()
                        }
                    } else if error != nil, case .listening(let partial) = self.phase, !partial.isEmpty {
                        self.sendCurrentTranscriptNow()
                    }
                }
            }
        } catch {
            phase = .error("Could not start microphone capture: \(error.localizedDescription)")
            syncRegistry(detail: nil)
        }
    }

    private func armSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SessionVoiceRules.defaultSilenceThresholdMs) * 1_000_000)
            guard let self, !Task.isCancelled, case .listening(let text) = self.phase else { return }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if SessionVoiceRules.shouldAutoSend(
                transcript: text,
                silenceElapsedMs: now - self.lastTranscriptUpdateMs
            ) {
                self.sendCurrentTranscriptNow()
            }
        }
    }

    private func speak(_ text: String) {
        phase = .speaking(reply: text)
        audioLevel = 0.52
        syncRegistry(detail: text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .speaking = self.phase {
                if self.demoMode {
                    self.phase = .listening(transcript: "")
                    self.syncRegistry(detail: nil)
                } else {
                    self.beginListening()
                }
            }
        }
    }

    private func teardownCapture() {
        silenceTask?.cancel()
        silenceTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    nonisolated private static func normalizedRMS(buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 0.000_01))
        return Double(min(max((db + 50) / 45, 0), 1))
    }
}
