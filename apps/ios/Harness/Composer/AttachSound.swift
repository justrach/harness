// The desktop's attach cue (crates/ui/src/sound.rs `play_attach`): a soft
// thump and two rising notes when an image lands in the composer. Off until
// switched on in Settings → Notifications, like the desktop's "Attaching
// files". Ambient audio: it mixes with whatever is playing and stays quiet
// with the ring switch on silent.

import AVFoundation

@MainActor
enum AttachSound {
    static let storageKey = "attachSound.enabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    private static var player: AVAudioPlayer?

    /// Plays the cue once for a batch that staged `added` images.
    static func play(added: Int) {
        guard added > 0, enabled else { return }
        if player == nil {
            guard let url = Bundle.main.url(forResource: "attach", withExtension: "wav") else { return }
            try? AVAudioSession.sharedInstance().setCategory(.ambient)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        }
        player?.currentTime = 0
        player?.play()
    }
}
