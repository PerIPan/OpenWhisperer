import Foundation
import AppKit
import OpenWhispererKit

/// Orchestrates in-process TTS playback: splits text into sentences, synthesizes each via
/// `KokoroTTS`, and schedules them onto a gapless `AudioPlaybackEngine` so the first sentence plays
/// while later ones synthesize. Owns the `tts_playing.lock` file the app polls for the "Speaking…"
/// state (notch indicator waveform + hands-free mic-muting). Barge-in cancels pending synthesis — freeing
/// the ANE for STT — and stops audio instantly.
actor TTSPlaybackController {
    private let tts: KokoroTTS
    private let engine = AudioPlaybackEngine()
    private var playTask: Task<Void, Never>?

    private struct QueueItem {
        let text: String
        let voice: String
        let speed: Float
        let parentGeneration: Int
    }

    private var playQueue: [QueueItem] = []
    private var currentItem: QueueItem?

    /// Bumped on barge-in to invalidate the entire queue and any active playback.
    private var generation = 0
    /// Bumped on starting any item to identify the currently active item's task/callbacks.
    private var activeItemGen = 0
    private var synthDone = false

    init(tts: KokoroTTS) {
        self.tts = tts
    }

    /// Speak `text`, queueing it for sequential playback.
    func play(text: String, voice: String, speed: Float) {
        let item = QueueItem(text: text, voice: voice, speed: speed, parentGeneration: generation)
        playQueue.append(item)
        if currentItem == nil {
            startNext()
        }
    }

    private func startNext() {
        guard !playQueue.isEmpty else {
            removeLock()
            return
        }
        let item = playQueue.removeFirst()
        startItem(item)
    }

    private func startItem(_ item: QueueItem) {
        guard item.parentGeneration == generation else { return }
        activeItemGen += 1
        let itemGen = activeItemGen
        let parentGen = item.parentGeneration

        currentItem = item
        synthDone = false

        let sentences = SentenceSplitter.split(item.text)
        guard !sentences.isEmpty else {
            itemFinished(itemGen: itemGen, parentGen: parentGen)
            return
        }
        let volume = Self.readVolume()

        engine.onDrained = { [weak self] in
            Task { await self?.handleDrain(itemGen: itemGen, parentGen: parentGen) }
        }
        engine.onPlaybackError = { [weak self] in
            Task { await self?.handlePlaybackError(itemGen: itemGen, parentGen: parentGen) }
        }

        playTask = Task {
            // Hold off playing if the user is currently speaking/recording.
            while await self.isUserRecording() {
                if Task.isCancelled || parentGen != self.generation || itemGen != self.activeItemGen { return }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            if Task.isCancelled || parentGen != self.generation || itemGen != self.activeItemGen { return }
            self.writeLock()

            for sentence in sentences {
                if Task.isCancelled || parentGen != self.generation || itemGen != self.activeItemGen { break }
                do {
                    let (samples, _) = try await self.tts.synthesizeSamples(sentence, voice: item.voice, speed: item.speed)
                    if Task.isCancelled || parentGen != self.generation || itemGen != self.activeItemGen { break }
                    self.engine.schedule(samples, volume: volume)
                } catch {
                    NSLog("TTSPlaybackController: synthesis failed: \(error)")
                    break
                }
            }
            self.synthFinished(itemGen: itemGen, parentGen: parentGen)
        }
    }

    /// Stop playback and cancel pending synthesis immediately (barge-in / supersede).
    func bargeIn() {
        generation += 1
        playQueue.removeAll()
        currentItem = nil
        playTask?.cancel()
        playTask = nil
        engine.stop()
        removeLock()
    }

    // MARK: - Completion coordination

    private func itemFinished(itemGen: Int, parentGen: Int) {
        guard parentGen == generation && itemGen == activeItemGen else { return }
        currentItem = nil
        startNext()
  }

    /// The audio queue drained. Finish only if synthesis is also done — otherwise more sentences
    /// are still on the way and will re-fill the queue.
    private func handleDrain(itemGen: Int, parentGen: Int) {
        guard parentGen == generation && itemGen == activeItemGen && synthDone else { return }
        itemFinished(itemGen: itemGen, parentGen: parentGen)
    }

    /// The synthesis loop ended. Finish now if the queue is already empty; otherwise the final
    /// drain callback will.
    private func synthFinished(itemGen: Int, parentGen: Int) {
        guard parentGen == generation && itemGen == activeItemGen else { return }
        synthDone = true
        if engine.isIdle { itemFinished(itemGen: itemGen, parentGen: parentGen) }
    }

    /// The audio engine failed to start (e.g. the output device was removed mid-reply). Drop the
    /// lock so the UI doesn't hang in "Speaking…", and stop any further synthesis.
    private func handlePlaybackError(itemGen: Int, parentGen: Int) {
        guard parentGen == generation && itemGen == activeItemGen else { return }
        playTask?.cancel()
        playQueue.removeAll()
        currentItem = nil
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
