import Foundation
import AppKit
import OpenWhispererKit

/// Orchestrates in-process TTS playback: splits text into sentences, synthesizes each via
/// `KokoroTTS`, and schedules them onto a gapless `AudioPlaybackEngine` so the first sentence plays
/// while later ones synthesize. Owns the `tts_playing.lock` file the app polls for the "Speaking…"
/// state (overlay waveform + hands-free mic-muting). Barge-in cancels pending synthesis — freeing
/// the ANE for STT — and stops audio instantly.
actor TTSPlaybackController {
    private let tts: KokoroTTS
    private let engine = AudioPlaybackEngine()
    private var playTask: Task<Void, Never>?

    /// Bumped on every `play`/`bargeIn` so stale drain/synth callbacks are ignored.
    private var generation = 0
    private var synthDone = false

    init(tts: KokoroTTS) {
        self.tts = tts
    }

    /// Speak `text`, superseding any current playback.
    func play(text: String, voice: String, speed: Float) {
        generation += 1
        let gen = generation
        synthDone = false
        playTask?.cancel()
        engine.stop()

        let sentences = SentenceSplitter.split(text)
        guard !sentences.isEmpty else { removeLock(); return }
        let volume = Self.readVolume()

        engine.onDrained = { [weak self] in
            Task { await self?.handleDrain(gen: gen) }
        }
        engine.onPlaybackError = { [weak self] in
            Task { await self?.handlePlaybackError(gen: gen) }
        }

        playTask = Task {
            // Hold off playing if the user is currently speaking/recording.
            while await self.isUserRecording() {
                if Task.isCancelled || gen != generation { return }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            if Task.isCancelled || gen != generation { return }
            self.writeLock()

            for sentence in sentences {
                if Task.isCancelled || gen != generation { break }
                do {
                    let (samples, _) = try await self.tts.synthesizeSamples(sentence, voice: voice, speed: speed)
                    // Generation guard in addition to Task.isCancelled: immune to a synthesize
                    // call that returns after a barge-in/supersede already bumped the generation
                    // (e.g. if cooperative cancellation is swallowed by the CoreML pipeline).
                    if Task.isCancelled || gen != generation { break }
                    self.engine.schedule(samples, volume: volume)
                } catch {
                    NSLog("TTSPlaybackController: synthesis failed: \(error)")
                    break
                }
            }
            self.synthFinished(gen: gen)
        }
    }

    /// Stop playback and cancel pending synthesis immediately (barge-in / supersede).
    func bargeIn() {
        generation += 1
        playTask?.cancel()
        playTask = nil
        engine.stop()
        removeLock()
    }

    // MARK: - Completion coordination

    /// The audio queue drained. Finish only if synthesis is also done — otherwise more sentences
    /// are still on the way and will re-fill the queue.
    private func handleDrain(gen: Int) {
        guard gen == generation, synthDone else { return }
        removeLock()
    }

    /// The synthesis loop ended. Finish now if the queue is already empty; otherwise the final
    /// drain callback will.
    private func synthFinished(gen: Int) {
        guard gen == generation else { return }
        synthDone = true
        if engine.isIdle { removeLock() }
    }

    /// The audio engine failed to start (e.g. the output device was removed mid-reply). Drop the
    /// lock so the UI doesn't hang in "Speaking…", and stop any further synthesis.
    private func handlePlaybackError(gen: Int) {
        guard gen == generation else { return }
        playTask?.cancel()
        removeLock()
    }

    // MARK: - Lock file + volume

    private var lockURL: URL { Paths.appSupport.appendingPathComponent("tts_playing.lock") }
    private func writeLock() { try? Data().write(to: lockURL) }
    private func removeLock() { try? FileManager.default.removeItem(at: lockURL) }

    private static func readVolume() -> Float {
        TTSVolume.parse(try? String(contentsOf: Paths.ttsVolume, encoding: .utf8))
    }

    private func isUserRecording() async -> Bool {
        await MainActor.run {
            guard let delegate = AppDelegate.shared else { return false }
            return delegate.dictationManager.recorder.state == .recording
        }
    }
}
