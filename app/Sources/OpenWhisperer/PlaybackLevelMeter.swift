import Foundation
import OpenWhispererKit

/// Live output-band snapshot for TTS playback — the speaking counterpart to
/// AudioRecorder.spectrumBands. Written by AudioPlaybackEngine's output tap
/// (audio thread → main queue), read by the overlay's segmented spectrum display.
final class PlaybackLevelMeter: ObservableObject {
    static let shared = PlaybackLevelMeter()

    /// Normalized (0…1) per-band energy of the latest playback buffer's channel-0
    /// samples — same shape as the recorder's, see `SpectrumBands`.
    @Published private(set) var spectrumBands: [Float] = []

    func push(bands: [Float]) {
        DispatchQueue.main.async {
            self.spectrumBands = bands
        }
    }

    func reset() {
        DispatchQueue.main.async {
            self.spectrumBands = []
        }
    }
}
