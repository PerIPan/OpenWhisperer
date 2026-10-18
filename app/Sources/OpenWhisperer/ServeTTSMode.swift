import Foundation

/// Headless native-TTS server mode (`OpenWhisperer --serve-tts`). Starts `KokoroTTS` +
/// `TTSHTTPServer` on :8000 and blocks — no GUI, no setup manager. Useful for testing the
/// native TTS path with `curl` and for CI; the real GUI hosts the same pieces via `ServerManager`.
enum ServeTTSMode {
    static func run() {
        let tts = TTSEngines()
        let playback = TTSPlaybackController(tts: tts)
        let port = UInt16(ProcessInfo.processInfo.environment["TTS_PORT"] ?? "") ?? 8000
        let server = TTSHTTPServer(port: port, tts: tts, playback: playback)

        // Warm the model in the background so the first request isn't cold.
        Task { try? await tts.prepare() }

        do {
            // The bind is asynchronous: a port in use arrives through the callback, not the throw.
            try server.start { result in
                switch result {
                case .success:
                    FileHandle.standardError.write(Data("serve-tts: native TTS serving on http://127.0.0.1:\(port)\n".utf8))
                case .failure(let error):
                    FileHandle.standardError.write(Data("serve-tts: failed to bind :\(port) — \(error)\n".utf8))
                    exit(1)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("serve-tts: failed to bind :\(port) — \(error)\n".utf8))
            exit(1)
        }
        RunLoop.main.run()
    }
}
