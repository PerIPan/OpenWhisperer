import Foundation

/// Live output-sample snapshot for TTS playback — the speaking counterpart to
/// AudioRecorder.scopeSamples. Written by AudioPlaybackEngine's output tap
/// (audio thread → main queue), read by the overlay's oscilloscope waveform.
final class PlaybackLevelMeter: ObservableObject {
    static let shared = PlaybackLevelMeter()

    /// Downsampled signed snapshot (~96 points) of the latest playback buffer's
    /// channel-0 samples — same shape as the recorder's.
    @Published private(set) var scopeSamples: [Float] = []

    func push(samples: [Float]) {
        DispatchQueue.main.async {
            self.scopeSamples = samples
        }
    }

    func reset() {
        DispatchQueue.main.async {
            self.scopeSamples = []
        }
    }
}
