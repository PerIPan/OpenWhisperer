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

    /// CoreML build of the same checkpoint the app used via MLX
    /// (`mlx-community/whisper-large-v3-turbo` → OpenAI Sept-2024 turbo).
    /// For a smaller ~632 MB 4-bit download, use
    /// `"openai_whisper-large-v3-v20240930_turbo_632MB"`.
    static let modelName = "openai_whisper-large-v3-v20240930_turbo"

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

    /// WhisperKit's default download base (`~/Documents/huggingface`).
    private static var hubBase: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("huggingface")
    }

    /// On-disk cache folder for the CoreML model.
    private static var cachedModelFolder: URL {
        hubBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelName)")
    }

    private var whisperKit: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?
    /// Called with 0…1 while the ~1.5 GB model archive downloads on first run.
    /// Set before `prepare()`; never called when the model is already cached.
    private var downloadProgressHandler: (@Sendable (Double) -> Void)?

    var isReady: Bool { whisperKit != nil }

    func setDownloadProgressHandler(_ handler: (@Sendable (Double) -> Void)?) {
        downloadProgressHandler = handler
    }

    /// True when the CoreML model is already downloaded on disk. The first run downloads ~1.5 GB;
    /// the first *load* after that also pays a one-time Neural-Engine compile. Used to choose the
    /// right "this is taking a while because…" message.
    static var isModelCached: Bool {
        FileManager.default.fileExists(atPath: cachedModelFolder.path)
    }

    /// Download (first run) + load the model. Idempotent: concurrent callers await the
    /// same in-flight load rather than starting a second one.
    @discardableResult
    func prepare() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        if let loadTask { return try await loadTask.value }

        let progressHandler = downloadProgressHandler
        let task = Task<WhisperKit, Error> { try await Self.loadWhisperKit(progress: progressHandler) }
        loadTask = task
        do {
            let wk = try await task.value
            whisperKit = wk
            loadTask = nil
            return wk
        } catch {
            loadTask = nil
            throw TranscriberError.loadFailed(error.localizedDescription)
        }
    }

    /// Loads WhisperKit, preferring the on-disk cache so a blocked/slow Hub or Xet CDN
    /// can't break an already-downloaded model: when the model folder exists we load
    /// `download: false` with explicit `modelFolder`/`tokenizerFolder`, which avoids the
    /// network round-trip entirely. Falls back to a normal download when the model isn't
    /// cached yet (or the cache is incomplete/unloadable).
    private static func loadWhisperKit(progress: (@Sendable (Double) -> Void)? = nil) async throws -> WhisperKit {
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
    func transcribe(samples: [Float], language: String?) async throws -> String {
        let wk: WhisperKit
        if let whisperKit {
            wk = whisperKit
        } else {
            wk = try await prepare()
        }

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
