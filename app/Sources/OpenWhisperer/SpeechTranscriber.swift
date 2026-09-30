import Foundation
import OpenWhispererKit
import WhisperKit

/// In-process Whisper speech-to-text via WhisperKit (CoreML / ANE).
///
/// Ported from the former HTTP round-trip to the Python `mlx_whisper` server (now deleted). Actor-isolated
/// so concurrent `transcribe` calls serialize on the compute unit, and so the one-time
/// model load can't race.
actor SpeechTranscriber {
    enum TranscriberError: LocalizedError {
        case loadFailed(String)
        var errorDescription: String? {
            switch self {
            case .loadFailed(let why): return "Speech model failed to load: \(why)"
            }
        }
    }

    /// The checkpoint the `stt_translate` pref currently selects — turbo for plain dictation,
    /// a non-turbo build when "Translate to English" is on (turbo cannot translate; see
    /// `STTModelChoice`). Read fresh on every access: the user can flip the pref between
    /// dictations, and a `static let` would pin the first answer for the life of the process
    /// — the same caching trap AGENTS.md records for `OWColor`.
    static var activeChoice: STTModelChoice {
        STTModelChoice.forTranslate(FileManager.default.fileExists(atPath: Paths.sttTranslate.path))
    }

    /// WhisperKit variant id of the active checkpoint. Was a `static let` pinned to turbo.
    static var modelName: String { activeChoice.modelName }

    /// Prompt-token budget for the vocabulary glossary. WhisperKit hard-trims
    /// prompts to 111 tokens (maxTokenContext/2 - 1) with keep-LAST semantics;
    /// capping at 96 keep-FIRST ourselves leaves slack for BPE boundary drift
    /// between per-term and joined encodings.
    private static let promptTokenBudget = 96

    /// Encode the user's vocabulary glossary (Paths.sttVocabulary) as prompt
    /// tokens, keeping leading terms within the budget. Every failure path
    /// (missing file, no tokenizer, empty list, zero fitting terms) degrades
    /// to nil — dictation must never break on account of its own glossary.
    /// Counts and returns TEXT tokens only: `encode(text:)` wraps its result
    /// in special tokens (SOT/notimestamps/EOT), which would inflate the
    /// budget math ~3 tokens per encode; WhisperKit filters specials from
    /// promptTokens anyway, so stripping them here keeps the budget honest.
    private static func glossaryPromptTokens(tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer,
              let text = try? String(contentsOf: Paths.sttVocabulary, encoding: .utf8) else { return nil }
        let terms = VocabularyPrompt.terms(from: text)
        guard !terms.isEmpty else { return nil }
        let sentinel = tokenizer.specialTokens.specialTokenBegin
        func textTokens(_ s: String) -> [Int] {
            tokenizer.encode(text: s).filter { $0 < sentinel }
        }
        let counts = terms.map { textTokens($0).count }
        let separatorCount = textTokens(", ").count
        let kept = VocabularyPrompt.fittingPrefixCount(
            tokenCounts: counts, separatorCount: separatorCount, budget: promptTokenBudget)
        guard kept > 0 else {
            NSLog("SpeechTranscriber: vocabulary dropped entirely — first term alone exceeds the \(promptTokenBudget)-token budget")
            return nil
        }
        if kept < terms.count {
            NSLog("SpeechTranscriber: vocabulary trimmed to first \(kept) of \(terms.count) terms")
        }
        guard let prompt = VocabularyPrompt.promptText(Array(terms.prefix(kept))) else { return nil }
        // Leading space: the OpenAI reference and WhisperKit's CLI both encode
        // prompts as " " + text so the first word tokenizes in its in-transcript form.
        return textTokens(" " + prompt)
    }

    /// WhisperKit download base — the app's Application Support space (not the user's
    /// iCloud-synced ~/Documents). `ModelStorage.migrateWhisperHubIfNeeded()` moves an
    /// existing legacy cache here on launch, before this is first read.
    private static var hubBase: URL { Paths.whisperHubBase }

    /// On-disk cache folder for a given CoreML model.
    private static func cachedModelFolder(for choice: STTModelChoice) -> URL {
        hubBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(choice.modelName)")
    }

    /// On-disk cache folder for the active model.
    private static var cachedModelFolder: URL { cachedModelFolder(for: activeChoice) }

    private var whisperKit: WhisperKit?
    /// Which checkpoint `whisperKit` actually is, so flipping the pref triggers a swap
    /// instead of silently reusing a model that cannot do what was asked.
    private var loadedChoice: STTModelChoice?
    private var loadTask: Task<WhisperKit, Error>?
    /// Which checkpoint `loadTask` is loading. A concurrent caller wanting a *different*
    /// model must start its own load rather than be handed this one.
    private var loadingChoice: STTModelChoice?
    /// Bumped per load so a superseded load cannot install itself over a newer one.
    private var loadGeneration = 0
    /// The checkpoint most recently asked for by a *supersedable* caller (a pre-warm or a
    /// Settings-driven reload). A waiter that no longer matches has been overtaken — the user
    /// flipped the toggle back while it was waiting — and must abandon rather than drop the
    /// resident model to compile something nobody wants any more.
    private var newestSupersedableRequest: STTModelChoice?
    /// Called with 0…1 while the ~1.5 GB model archive downloads on first run.
    /// Set before `prepare()`; never called when the model is already cached.
    private var downloadProgressHandler: (@Sendable (Double) -> Void)?

    var isReady: Bool { whisperKit != nil && loadedChoice == Self.activeChoice }

    func setDownloadProgressHandler(_ handler: (@Sendable (Double) -> Void)?) {
        downloadProgressHandler = handler
    }

    /// True when a checkpoint is already downloaded on disk. The first load of each also pays a
    /// one-time Neural-Engine compile (~2 min, measured). Used to choose the right "this is
    /// taking a while because…" message, and to decide whether enabling translation needs to
    /// ask the user for a download first. Sizes differ per checkpoint — see
    /// `STTModelChoice.approximateDownloadDescription`.
    static func isModelCached(_ choice: STTModelChoice) -> Bool {
        FileManager.default.fileExists(atPath: cachedModelFolder(for: choice).path)
    }

    static var isModelCached: Bool { isModelCached(activeChoice) }

    /// Download (first run) + load the model. Idempotent: concurrent callers await the
    /// same in-flight load rather than starting a second one.
    @discardableResult
    /// `supersedable`: true for speculative loads (launch prepare, pre-warm, a Settings
    /// toggle) — these may be abandoned if the user changes their mind while they wait.
    /// A transcription's own load is NOT supersedable: it has audio to turn into text.
    func prepare(_ choice: STTModelChoice? = nil,
                 supersedable: Bool = false) async throws -> WhisperKit {
        let want = choice ?? Self.activeChoice
        if supersedable { newestSupersedableRequest = want }
        if let whisperKit, loadedChoice == want { return whisperKit }
        if let loadTask, loadingChoice == want { return try await loadTask.value }

        // Never compile two checkpoints at once. Measured 2026-09-29: parallel ANE compiles
        // starved each other for >10 minutes and left ~1.2 GB of orphaned `.tmp` bundles per
        // attempt in the e5 cache. Toggling translation twice quickly is how you get there,
        // so wait out the load that was in flight when we arrived.
        //
        // Deliberately awaited ONCE, on a captured task — not looped on `loadTask` being
        // non-nil. Actors are reentrant: when the awaited task finishes, this continuation
        // can be resumed *before* the originating `prepare` clears `loadTask`/`loadingChoice`,
        // so a loop would see the same stale state and spin on an already-completed task,
        // starving the very continuation that would clear it.
        if let inFlight = loadTask, loadingChoice != want {
            _ = try? await inFlight.value
            // Re-check after the suspension: the world may have moved on, including someone
            // else having loaded exactly what we want.
            if let whisperKit, loadedChoice == want { return whisperKit }
            if let loadTask, loadingChoice == want { return try await loadTask.value }
            // Overtaken while waiting. Falling through here would drop the model another
            // caller just installed and start compiling a checkpoint the user has already
            // cancelled — leaving the flags reading "ready" while nothing is resident, and
            // every dictation blocking behind a load nobody asked for until the 35 s
            // watchdog kills it.
            if supersedable, let newest = newestSupersedableRequest, newest != want {
                throw CancellationError()
            }
        }

        // Swapping checkpoints: drop our reference instead of calling `unloadModels()`.
        // Actors are **reentrant**, so another transcription may be suspended mid-`await`
        // holding its own strong reference to this instance; unloading the models underneath
        // it would break that in-flight call. Releasing ours lets ARC free the CoreML models
        // once the last user is finished — draining for free.
        //
        // A load already running for the *other* checkpoint is deliberately NOT cancelled:
        // an interrupted ANE compile leaves a full-size orphan bundle in the e5 cache and
        // never resumes it (measured — ~1.2 GB per interrupted attempt). Letting it finish
        // and discarding the result is cheaper than cancelling it.
        whisperKit = nil
        loadedChoice = nil

        loadGeneration += 1
        let generation = loadGeneration
        let progressHandler = downloadProgressHandler
        let task = Task<WhisperKit, Error> {
            try await Self.loadWhisperKit(choice: want, progress: progressHandler)
        }
        loadTask = task
        loadingChoice = want
        do {
            let wk = try await task.value
            // Only install if a newer prepare() hasn't superseded us — the user can flip the
            // pref mid-load, and the two loads can complete in either order. The caller still
            // gets the model it asked for either way.
            if generation == loadGeneration {
                whisperKit = wk
                loadedChoice = want
                loadTask = nil
                loadingChoice = nil
            }
            return wk
        } catch {
            if generation == loadGeneration {
                loadTask = nil
                loadingChoice = nil
            }
            throw TranscriberError.loadFailed(error.localizedDescription)
        }
    }

    /// Loads WhisperKit, preferring the on-disk cache so a blocked/slow Hub or Xet CDN
    /// can't break an already-downloaded model: when the model folder exists we load
    /// `download: false` with explicit `modelFolder`/`tokenizerFolder`, which avoids the
    /// network round-trip entirely. Falls back to a normal download when the model isn't
    /// cached yet (or the cache is incomplete/unloadable).
    private static func loadWhisperKit(choice: STTModelChoice,
                                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> WhisperKit {
        let modelName = choice.modelName
        let cachedModelFolder = cachedModelFolder(for: choice)
        if FileManager.default.fileExists(atPath: cachedModelFolder.path) {
            do {
                let config = WhisperKitConfig(
                    model: modelName,
                    downloadBase: hubBase,
                    modelFolder: cachedModelFolder.path,
                    tokenizerFolder: hubBase.appendingPathComponent("models/openai/whisper-large-v3"),
                    download: false
                )
                return try await WhisperKit(config)
            } catch {
                NSLog("SpeechTranscriber: offline load failed (\(error)); retrying with download")
            }
        } else if let progress {
            // Pre-download explicitly so the UI can show real percent progress (the
            // load-time download below reports nothing). Only the model archive —
            // the tokenizer still comes from the normal load, so on failure we just
            // fall through and let the load-time download surface its own error.
            do {
                _ = try await WhisperKit.download(
                    variant: modelName,
                    downloadBase: hubBase,
                    progressCallback: { progress($0.fractionCompleted) }
                )
            } catch {
                NSLog("SpeechTranscriber: pre-download failed (\(error)); falling back to load-time download")
            }
        }
        let config = WhisperKitConfig(model: modelName, downloadBase: hubBase)
        return try await WhisperKit(config)
    }

    /// Transcribe 16 kHz mono normalized Float PCM ([-1, 1)). `language` nil/"auto"
    /// means autodetect. Loads the model on first use if `prepare()` hasn't run yet.
    ///
    /// `translate` switches the decoder to Whisper's translate task, which is
    /// X->English **only** — the model has no target-language parameter, so this is a
    /// flag rather than a picker. `language` keeps meaning the *source*.
    func transcribe(samples: [Float], language: String?, translate: Bool = false) async throws -> String {
        // Route to the checkpoint that can actually do what was asked. `prepare` returns
        // immediately when that model is already loaded, and swaps when it isn't.
        let wk = try await prepare(STTModelChoice.forTranslate(translate))

        // Pad very short audio with silence to ensure WhisperKit's feature extractor
        // and decoding options can process it reliably (prevents empty transcripts).
        var processedSamples = samples
        let minSamples = 24000 // 1.5 seconds at 16kHz
        if processedSamples.count < minSamples {
            let paddingCount = minSamples - processedSamples.count
            processedSamples.append(contentsOf: [Float](repeating: 0.0, count: paddingCount))
        }

        let lang = (language?.isEmpty == false && language != "auto") ? language : nil
        // detectLanguage: WhisperKit's default (false while usePrefillPrompt is on)
        // prefills <|en|> for a nil language — "Auto-detect" would force English.
        // withoutTimestamps: dictation needs no timestamps. suppressBlank: matches
        // the OpenAI reference decoder (WhisperKit defaults it off). .vad: better
        // window seams on >30 s dictations; no effect on short clips.
        let options = DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: lang,
            detectLanguage: lang == nil,
            withoutTimestamps: true,
            promptTokens: Self.glossaryPromptTokens(tokenizer: wk.tokenizer),
            suppressBlank: true,
            chunkingStrategy: .vad
        )
        let results = try await wk.transcribe(audioArray: processedSamples, decodeOptions: options)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
