import Foundation
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
    func play(text: String, voice: String) {
        generation += 1
        let gen = generation
        synthDone = false
        playTask?.cancel()
        engine.stop()

        let sentences = SentenceSplitter.split(text)
        guard !sentences.isEmpty else { removeLock(); return }
        let volume = Self.readVolume()
        writeLock()

        engine.onDrained = { [weak self] in
            Task { await self?.handleDrain(gen: gen) }
        }

        playTask = Task {
            for sentence in sentences {
                if Task.isCancelled { break }
                do {
                    let (samples, _) = try await self.tts.synthesizeSamples(sentence, voice: voice)
                    if Task.isCancelled { break }
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

    // MARK: - Lock file + volume

    private var lockURL: URL { Paths.appSupport.appendingPathComponent("tts_playing.lock") }
    private func writeLock() { try? Data().write(to: lockURL) }
    private func removeLock() { try? FileManager.default.removeItem(at: lockURL) }

    private static func readVolume() -> Float {
        let url = Paths.appSupport.appendingPathComponent("tts_volume")
        guard let raw = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let v = Float(raw) else { return 1 }
        return v
    }
}
