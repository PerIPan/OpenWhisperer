import Foundation
import Combine
import OpenWhispererKit

/// Hosts the in-process native TTS: a `KokoroTTS` actor (FluidAudio CoreML/ANE) behind a
/// tiny embedded HTTP server (`TTSHTTPServer`) on :8000. Ported from the former out-of-process Python
/// `unified_server.py` (now deleted). STT is native in-app (`SpeechTranscriber`) and needs no server.
class ServerManager: ObservableObject {
    enum ServerStatus: String {
        case stopped = "Stopped"
        case starting = "Starting..."
        case running = "Running"
        case error = "Error"
    }

    @Published var status: ServerStatus = .stopped
    /// Edited in Settings → Advanced while stopped; committed (stored + agents re-pointed) only
    /// once the server has actually bound it — see `startAll()`.
    @Published var port: Int = TTSPort.stored
    /// Computed, never stored: "Translate to English" swaps the checkpoint, and a value
    /// captured at init would describe whichever model happened to be active at launch.
    var sttModel: String { SpeechTranscriber.activeChoice.displayName }  // native WhisperKit
    /// Computed, like `sttModel`: which engine speaks follows the selected voice.
    var ttsModel: String {
        let voice = (try? String(contentsOf: Paths.ttsVoice, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch TTSVoiceRouter.route(voice).engine {
        case .pocket: return "Pocket TTS, Kokoro as stand-in"
        case .kokoro: return "Kokoro-82M"
        case .supertonic: return "Supertonic-3"
        }
    }
    @Published var lastError: String = ""

    private let tts = TTSEngines()
    /// In-process TTS playback (Phase 3). Shared with `DictationManager` (via `AppDelegate`) for
    /// instant barge-in, and with `TTSHTTPServer` to serve `/v1/audio/play`.
    let playback: TTSPlaybackController
    private var httpServer: TTSHTTPServer?
    private var prepareTask: Task<Void, Never>?
    /// `.running` needs both: the listener reached `.ready` AND the TTS model is resident.
    /// Either alone used to flip the status — a dead listener read as "Running".
    private var listenerReady = false
    private var ttsReady = false
    /// Which `startAll` a late listener/prepare callback belongs to; a stale one is ignored.
    private var startGeneration = 0

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
            listenerReady = false
            ttsReady = false
            startGeneration += 1
            let generation = startGeneration
            let requestedPort = port

            let server = TTSHTTPServer(port: UInt16(requestedPort), tts: tts, playback: playback)
            do {
                // `start` throws only for bad parameters; the bind is asynchronous and reports
                // through the callback. Nothing is committed until the listener is `.ready`.
                try server.start { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, generation == self.startGeneration else { return }
                        switch result {
                        case .success:
                            self.listenerReady = true
                            // NOW this is the port: store it and re-point every connected agent.
                            // Done here rather than as the field is edited, which would rewrite
                            // four agents' configs on every keystroke ("1800" on the way to "18000").
                            if requestedPort != TTSPort.stored {
                                TTSPort.store(requestedPort)
                                ConfigManager.reapplyConnectedAgents()
                            }
                            self.settleStatus()
                        case .failure(let error):
                            // Port in use, most likely. The stored port and the agents' configs
                            // are untouched, so a relaunch comes back on the last good port.
                            self.httpServer?.stop()
                            self.httpServer = nil
                            self.status = .error
                            self.lastError = "Failed to bind port \(requestedPort): \(error.localizedDescription)"
                        }
                    }
                }
                httpServer = server
            } catch {
                status = .error
                lastError = "Failed to bind port \(requestedPort): \(error.localizedDescription)"
                NSLog("TTS server failed to start: \(error)")
                return
            }

            prepareTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.tts.prepare()
                    await MainActor.run {
                        guard generation == self.startGeneration else { return }
                        self.ttsReady = true
                        self.settleStatus()
                    }
                } catch {
                    await MainActor.run {
                        guard generation == self.startGeneration else { return }
                        self.status = .error
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// `.running` only once both halves are up; a failure has already set `.error` and wins.
    private func settleStatus() {
        guard status == .starting, listenerReady, ttsReady else { return }
        status = .running
    }

    /// Stop the embedded server. In-process, so there is no child process to reap — stop is
    /// immediate (the `synchronous` flag is retained for call-site compatibility).
    func stopAll(synchronous: Bool = false) {
        startGeneration += 1   // a late callback from the stopped server must not revive it
        prepareTask?.cancel()
        prepareTask = nil
        httpServer?.stop()
        httpServer = nil
        listenerReady = false
        ttsReady = false
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

extension TTSPort {
    /// The port the server last bound — what every agent config must point at.
    static var stored: Int { parse(try? String(contentsOf: Paths.ttsPort, encoding: .utf8)) }

    /// Persist `port`; the default removes the file, so an install that never changed it has
    /// nothing new on disk.
    static func store(_ port: Int) {
        if port == defaultPort {
            try? FileManager.default.removeItem(at: Paths.ttsPort)
        } else {
            try? "\(port)".write(to: Paths.ttsPort, atomically: true, encoding: .utf8)
        }
    }
}
