import Foundation
import FluidAudio
import OpenWhispererKit

/// In-process Kokoro text-to-speech via FluidAudio (CoreML / ANE).
///
/// Ported from the former out-of-process Python `mlx_audio` server (now deleted). Actor-isolated so the one-time
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

    /// US-English female voice — the same default the former Python Kokoro path used.
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
        await ensureVoicePack(voice)
        let spoken = NumberNormalizer.normalize(text)
        return try await manager.synthesize(text: spoken, voice: voice)
    }

    /// Synthesize `text` → raw 24 kHz mono fp32 PCM samples (no WAV wrapper), for in-process
    /// streaming playback via `AVAudioPlayerNode`. Same numeric pre-pass as `synthesize`.
    func synthesizeSamples(_ text: String, voice: String = "af_heart") async throws
        -> (samples: [Float], sampleRate: Int) {
        if !loaded { try await prepare() }
        await ensureVoicePack(voice)
        let spoken = NumberNormalizer.normalize(text)
        let result = try await manager.synthesizeDetailed(text: spoken, voice: voice)
        return (result.samples, result.sampleRate)
    }

    /// Helper to download and cache alternative voice .bin files if they are missing or corrupted on disk,
    /// because the upstream FluidInference repository only hosts af_heart.bin in its ANE folder.
    private func ensureVoicePack(_ voice: String) async {
        let sanitized = voice.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !sanitized.isEmpty && sanitized != "af_heart" else { return }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let localDir = home.appendingPathComponent(".cache/fluidaudio/Models/kokoro-82m-coreml/ANE")
        let localURL = localDir.appendingPathComponent("\(sanitized).bin")

        // If file exists and size is valid (not a tiny error page), skip downloading
        if fileManager.fileExists(atPath: localURL.path) {
            if let attrs = try? fileManager.attributesOfItem(atPath: localURL.path),
               let size = attrs[.size] as? Int64,
               size > 1000 {
                return
            }
        }

        let remoteURLString = "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/voices/\(sanitized).bin"
        guard let url = URL(string: remoteURLString) else { return }

        do {
            try fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
            let (data, response) = try await URLSession.shared.data(from: url)
            // Status check matters: a 404/error body over 1000 bytes would otherwise be
            // written as a .bin and pass the size check forever after.
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 1000 else {
                NSLog("KokoroTTS: voice pack fetch for \(sanitized) returned no usable data")
                return
            }
            try data.write(to: localURL, options: .atomic)
        } catch {
            // Non-fatal: KokoroAneManager handles the missing asset downstream. Log so a failed
            // voice-pack fetch is diagnosable from the Events log instead of silently swallowed.
            NSLog("KokoroTTS: voice pack download failed for \(sanitized): \(error.localizedDescription)")
        }
    }
}
