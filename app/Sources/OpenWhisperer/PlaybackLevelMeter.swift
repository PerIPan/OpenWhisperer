import Foundation

/// Live output-level history for TTS playback — the speaking counterpart to
/// AudioRecorder.levelHistory. Written by AudioPlaybackEngine's output tap
/// (audio thread → main queue), read by the overlay's waveform.
final class PlaybackLevelMeter: ObservableObject {
    static let shared = PlaybackLevelMeter()

    /// Scrolling normalized levels (0…1), newest last — same shape as the recorder's.
    @Published private(set) var levelHistory: [Float] = Array(repeating: 0, count: 50)

    func push(_ level: Float) {
        DispatchQueue.main.async {
            self.levelHistory.removeFirst()
            self.levelHistory.append(min(max(level, 0), 1))
        }
    }

    func reset() {
        DispatchQueue.main.async {
            self.levelHistory = Array(repeating: 0, count: 50)
        }
    }
}
