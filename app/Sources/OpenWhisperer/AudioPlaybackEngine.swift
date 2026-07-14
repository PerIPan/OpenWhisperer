import AVFoundation
import Foundation

/// In-process gapless PCM player built on one `AVAudioEngine` + `AVAudioPlayerNode`. Sentences
/// are scheduled as they synthesize; queued buffers play back-to-back with no gap. macOS plays to
/// the default output device, so no `AVAudioSession` is needed.
///
/// Owned and serialized by `TTSPlaybackController` (an actor), so `schedule`/`stop` are never
/// called concurrently. The `scheduleBuffer` completion handler runs on an AVAudioEngine thread
/// and only touches `pending` under `lock`.
final class AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var pending = 0
    /// Smoothed (EMA) output level fed to `PlaybackLevelMeter`, mutated only from the
    /// mixer tap's audio-render thread — mirrors AudioRecorder's `audioLevel` smoothing.
    private var meterLevel: Float = 0
    private let meterSmoothing: Float = 0.25

    /// Invoked when the last queued buffer finishes playing (queue drained).
    var onDrained: (@Sendable () -> Void)?
    /// Invoked when the engine fails to start (e.g. the output device disappeared), so the
    /// controller can clear the "Speaking…" lock instead of hanging.
    var onPlaybackError: (@Sendable () -> Void)?

    init(sampleRate: Double = 24_000) {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            fatalError("AudioPlaybackEngine: unsupported PCM format at \(sampleRate) Hz")
        }
        format = fmt
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Output-level tap for the overlay's "Speaking…" waveform. Installed once here
        // (not per-utterance) so it lives for the engine's whole lifetime. Runs on an
        // AVAudioEngine render thread; PlaybackLevelMeter.push hops to the main queue.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = Self.computeRMS(buffer: buffer)
            // Playback samples are already normalized to [-1, 1] (unlike the quiet raw
            // mic signal AudioRecorder scales by 120x), so a much smaller gain avoids
            // permanently clipping at 1.0.
            let level = min(1, rms * 8)
            self.meterLevel = self.meterLevel * (1 - self.meterSmoothing) + level * self.meterSmoothing
            PlaybackLevelMeter.shared.push(self.meterLevel)
        }
    }

    /// RMS of the buffer's first channel. Mirrors `AudioRecorder.computeRMS`'s shape
    /// (sans the mic-specific display gain, applied by the caller instead).
    private static func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let data = UnsafeBufferPointer(start: channelData[0], count: count)
        let sumSq = data.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSq / Float(count))
    }

    /// True when nothing is queued or playing.
    var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending == 0
    }

    /// Schedule one chunk of 24 kHz mono samples for gapless playback, applying `volume` gain.
    /// Starts the engine + node on the first chunk.
    func schedule(_ samples: [Float], volume: Float) {
        guard !samples.isEmpty,
              let buffer = Self.makeBuffer(samples, format: format, volume: volume) else { return }

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            NSLog("AudioPlaybackEngine: engine.start failed: \(error)")
            onPlaybackError?()
            return
        }

        lock.lock(); pending += 1; lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.pending -= 1; let drained = self.pending == 0; self.lock.unlock()
            if drained { self.onDrained?() }
        }
        if !player.isPlaying { player.play() }
    }

    /// Stop playback immediately and discard everything queued (barge-in / supersede).
    func stop() {
        player.stop()
        engine.stop()
        lock.lock(); pending = 0; lock.unlock()
    }

    /// Build a mono float buffer from `samples`, applying `volume` gain clamped to [-1, 1].
    static func makeBuffer(_ samples: [Float], format: AVAudioFormat, volume: Float) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let gain = max(0, volume)
        for i in samples.indices {
            let v = samples[i] * gain
            channel[i] = v > 1 ? 1 : (v < -1 ? -1 : v)
        }
        return buffer
    }
}
