import Foundation
import Combine

/// Hosts the in-process native TTS: a `KokoroTTS` actor (FluidAudio CoreML/ANE) behind a
/// tiny embedded HTTP server (`TTSHTTPServer`) on :8000. Ported from the former out-of-process Python
/// `unified_server.py` (now deleted). STT is native in-app (`ParakeetTranscriber`) and needs no server.
class ServerManager: ObservableObject {
    enum ServerStatus: String {
        case stopped = "Stopped"
        case starting = "Starting..."
        case running = "Running"
        case error = "Error"
    }

    @Published var status: ServerStatus = .stopped
    @Published var port: Int = 8000
    @Published var sttModel: String = "parakeet-tdt-0.6b-v3"  // native FluidAudio
    @Published var ttsModel: String = "kokoro-82m"              // native FluidAudio
    @Published var lastError: String = ""

    private let tts = KokoroTTS()
    /// In-process TTS playback (Phase 3). Shared with `DictationManager` (via `AppDelegate`) for
    /// instant barge-in, and with `TTSHTTPServer` to serve `/v1/audio/play`.
    let playback: TTSPlaybackController
    private var httpServer: TTSHTTPServer?
    private var prepareTask: Task<Void, Never>?

    init() {
        playback = TTSPlaybackController(tts: tts)
    }

    var isRunning: Bool { status == .running }
    var statusLabel: String { status.rawValue }

    /// Start the embedded server and load the TTS model. `.starting` until the model is
    /// resident, then `.running`; `.error` (with `lastError`) on bind/load failure.
    func startAll() {
        let work = { [self] in
            guard httpServer == nil else { return }
            Paths.ensureDirectories()
            status = .starting
            lastError = ""

            let server = TTSHTTPServer(port: UInt16(port), tts: tts, playback: playback)
            do {
                try server.start()
                httpServer = server
            } catch {
                status = .error
                lastError = "Failed to bind port \(port): \(error.localizedDescription)"
                NSLog("TTS server failed to start: \(error)")
                return
            }

            prepareTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.tts.prepare()
                    await MainActor.run { self.status = .running }
                } catch {
                    await MainActor.run {
                        self.status = .error
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Stop the embedded server. In-process, so there is no child process to reap — stop is
    /// immediate (the `synchronous` flag is retained for call-site compatibility).
    func stopAll(synchronous: Bool = false) {
        prepareTask?.cancel()
        prepareTask = nil
        httpServer?.stop()
        httpServer = nil
        status = .stopped
    }

    func restartAll() {
        stopAll()
        startAll()
    }
}

// MARK: - FileHandle Helper

extension FileHandle {
    static func forWritingOrCreate(at url: URL) -> FileHandle {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
    }
}
