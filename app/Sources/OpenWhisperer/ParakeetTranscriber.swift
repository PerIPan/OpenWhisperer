import FluidAudio
import Foundation

/// In-process Parakeet TDT v3 speech-to-text via FluidAudio (CoreML / ANE).
///
/// Mirrors `SpeechTranscriber`'s surface so `DictationManager` can dispatch on the
/// `stt_engine` pref (2026-07-13 feel-test; see the engine-configurability spec
/// addendum). Actor-isolated for the same reasons as the Whisper path: serialize
/// work on the compute unit and dedup the one-time model load.
///
/// Differences from the Whisper path, by design:
/// - No `stt_vocabulary` glossary: `promptTokens` is a Whisper mechanism. FluidAudio
///   has its own vocabulary-boosting system (CTC keyword spotter + rescorer), but it
///   needs an extra model download — evaluate separately if Parakeet wins the feel-test.
/// - `stt_language` maps to a script-filter hint (v3 top-K token filtering), not a
///   decode prompt; unknown codes and "auto" mean no hint (the model auto-detects).
actor ParakeetTranscriber {
    enum TranscriberError: LocalizedError {
        case loadFailed(String)
        var errorDescription: String? {
            switch self {
            case .loadFailed(let why): return "Parakeet model failed to load: \(why)"
            }
        }
    }

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    /// Called with 0…1 while the ~460 MB model set downloads on first run.
    private var downloadProgressHandler: (@Sendable (Double) -> Void)?

    var isReady: Bool { manager != nil }

    func setDownloadProgressHandler(_ handler: (@Sendable (Double) -> Void)?) {
        downloadProgressHandler = handler
    }

    /// True when the Parakeet v3 CoreML bundles are already on disk
    /// (`~/Library/Application Support/FluidAudio/Models/…`).
    static var isModelCached: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
    }

    /// Download (first run) + load the models. Idempotent: concurrent callers await
    /// the same in-flight load rather than starting a second one.
    @discardableResult
    func prepare() async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let progress = downloadProgressHandler
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: progress.map { handler in
                    { handler($0.fractionCompleted) }
                }
            )
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            return mgr
        }
        loadTask = task
        do {
            let mgr = try await task.value
            manager = mgr
            loadTask = nil
            return mgr
        } catch {
            loadTask = nil
            throw TranscriberError.loadFailed(error.localizedDescription)
        }
    }

    /// Transcribe 16 kHz mono normalized Float PCM ([-1, 1)). `language` nil/"auto"
    /// means no script-filter hint. Loads the model on first use if `prepare()`
    /// hasn't run yet.
    func transcribe(samples: [Float], language: String?) async throws -> String {
        let mgr = try await prepare()

        // Pad very short clips with silence, same rationale as the Whisper path:
        // sub-second dictations otherwise sit at the edge of the mel/window math.
        var processedSamples = samples
        let minSamples = 24000 // 1.5 s at 16 kHz
        if processedSamples.count < minSamples {
            processedSamples.append(
                contentsOf: [Float](repeating: 0.0, count: minSamples - processedSamples.count))
        }

        var state = try TdtDecoderState()
        let result = try await mgr.transcribe(
            processedSamples, decoderState: &state, language: Self.languageHint(language))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribe an audio file (any format/rate AVAudioFile reads; FluidAudio
    /// resamples). Used by the `--diag-parakeet` headless probe.
    func transcribe(url: URL, language: String?) async throws -> String {
        let mgr = try await prepare()
        var state = try TdtDecoderState()
        let result = try await mgr.transcribe(
            url, decoderState: &state, language: Self.languageHint(language))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Map the app's `stt_language` pref (ISO code or "auto") to FluidAudio's
    /// script-filter `Language`. Unknown codes degrade to nil (auto), never throw.
    private static func languageHint(_ language: String?) -> Language? {
        guard let language, !language.isEmpty, language != "auto" else { return nil }
        return Language(rawValue: language)
    }
}
