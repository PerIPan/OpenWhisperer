import Foundation
import FluidAudio
import OpenWhispererKit

/// In-process Kokoro text-to-speech via FluidAudio (CoreML / ANE).
///
/// Replaces the out-of-process Python `mlx_audio` server. Actor-isolated so the one-time
/// model load can't race and synthesis calls serialize on the compute unit. Mirrors the
/// `SpeechTranscriber` pattern (in-flight load dedup, error wrapping). FluidAudio caches
/// its CoreML chain under `~/.cache/fluidaudio` and loads from cache when present, so an
/// already-downloaded model survives a blocked/slow Hub (offline-first by construction).
actor KokoroTTS {
    enum KokoroTTSError: LocalizedError {
        case loadFailed(String)
        var errorDescription: String? {
            switch self {
            case .loadFailed(let why): return "TTS model failed to load: \(why)"
            }
        }
    }

    /// US-English female voice — the same default the Python Kokoro path used.
    static let defaultVoice = "af_heart"

    private let manager = KokoroAneManager(variant: .english)
    private var loaded = false
    private var loadTask: Task<Void, Error>?

    var isReady: Bool { loaded }

    /// Download (first run) + load the 7-stage Kokoro CoreML chain. Idempotent:
    /// concurrent callers await the same in-flight load.
    func prepare() async throws {
        if loaded { return }
        if let loadTask { try await loadTask.value; return }

        let task = Task<Void, Error> { try await manager.initialize() }
        loadTask = task
        do {
            try await task.value
            loaded = true
            loadTask = nil
        } catch {
            loadTask = nil
            throw KokoroTTSError.loadFailed(error.localizedDescription)
        }
    }

    /// Synthesize `text` → 24 kHz mono WAV `Data`. Expands numerics to spoken words first
    /// (the engine mishandles raw `$5.99`/`15%`), then runs FluidAudio's Kokoro. Loads the
    /// model on first use if `prepare()` hasn't run.
    func synthesize(_ text: String, voice: String = "af_heart") async throws -> Data {
        if !loaded { try await prepare() }
        let spoken = NumberNormalizer.normalize(text)
        return try await manager.synthesize(text: spoken, voice: voice)
    }
}
