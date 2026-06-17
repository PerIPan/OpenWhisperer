import Foundation
import WhisperKit

/// In-process Whisper speech-to-text via WhisperKit (CoreML / ANE).
///
/// Replaces the old HTTP round-trip to the Python `mlx_whisper` server. Actor-isolated
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

    private var whisperKit: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    var isReady: Bool { whisperKit != nil }

    /// Download (first run) + load the model. Idempotent: concurrent callers await the
    /// same in-flight load rather than starting a second one.
    @discardableResult
    func prepare() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        if let loadTask { return try await loadTask.value }

        let task = Task<WhisperKit, Error> {
            let config = WhisperKitConfig(model: Self.modelName)
            return try await WhisperKit(config)
        }
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

    /// Transcribe 16 kHz mono normalized Float PCM ([-1, 1)). `language` nil/"auto"
    /// means autodetect. Loads the model on first use if `prepare()` hasn't run yet.
    func transcribe(samples: [Float], language: String?) async throws -> String {
        let wk: WhisperKit
        if let whisperKit {
            wk = whisperKit
        } else {
            wk = try await prepare()
        }
        let lang = (language?.isEmpty == false && language != "auto") ? language : nil
        let options = DecodingOptions(language: lang)
        let results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
