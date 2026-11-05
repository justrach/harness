// Records what's said on the Watch, as compact speech audio for the iPhone
// to write out (watchOS has no speech recognizer an app can call).

import AVFoundation
import Observation

@MainActor
@Observable
final class Recorder {
    enum State: Equatable {
        case idle
        case recording(started: Date)
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// 0…1, for the level bar.
    private(set) var level: Double = 0
    /// The recording stopped itself at `maxSeconds`.
    private(set) var reachedLimit = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meter: Task<Void, Never>?

    /// The longest recording: a thought, not a meeting.
    static let maxSeconds: TimeInterval = 60

    func start(id: String) async {
        if WatchStore.screen == "recording" {
            // Screenshot rig: the simulator has no microphone, so the level is made up.
            state = .recording(started: Date().addingTimeInterval(-7))
            meter = Task { @MainActor [weak self] in
                var t = 0.0
                while !Task.isCancelled, let self {
                    t += 0.35
                    self.level = 0.25 + 0.55 * abs(sin(t)) * (0.6 + 0.4 * abs(sin(t * 2.7)))
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .denied
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)
            let url = Self.file(id)
            try? FileManager.default.removeItem(at: url)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.maxSeconds) else {
                state = .failed("Couldn't start recording.")
                return
            }
            self.recorder = recorder
            reachedLimit = false
            state = .recording(started: Date())
            meter = Task { @MainActor [weak self] in
                while !Task.isCancelled, let self, let recorder = self.recorder {
                    recorder.updateMeters()
                    // -50 dB and below reads as silence.
                    self.level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
                    if !recorder.isRecording {
                        self.reachedLimit = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        } catch {
            state = .failed("Couldn't start recording.")
        }
    }

    /// Stops and returns the recording, if anything was captured.
    func stop() -> URL? {
        meter?.cancel()
        meter = nil
        guard let recorder else { return nil }
        // A tap that started and stopped at once has nothing in it. One that
        // ran to the limit has stopped already, and its time reads 0.
        let captured = recorder.isRecording ? recorder.currentTime > 0.3 : true
        recorder.stop()
        self.recorder = nil
        level = 0
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false)
        return captured && FileManager.default.fileExists(atPath: recorder.url.path) ? recorder.url : nil
    }

    func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
    }

    func reset() { state = .idle }

    static func file(_ id: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(id).m4a")
    }
}
