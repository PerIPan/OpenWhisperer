import Foundation
import Network
import OpenWhispererKit

/// Tiny embedded HTTP/1.1 server (Network.framework, zero deps) ported from the former Python
/// TTS server for the bash hook. Loopback-only. Serves exactly what the hook + health
/// checks need:
///   GET  /v1/models        -> 200 minimal models JSON
///   POST /v1/audio/speech  -> 200 WAV (FluidAudio Kokoro) | 500 on failure
///   POST /v1/audio/play    -> 202 Accepted; plays sentence-by-sentence via the in-app player
///   POST /mcp              -> MCP (Streamable HTTP) JSON-RPC; exposes the `speak` tool to agents
///
/// One request per connection (`Connection: close`), which is all `curl` (the hook) needs.
final class TTSHTTPServer {
    private let port: NWEndpoint.Port
    private let tts: KokoroTTS
    private let playback: TTSPlaybackController
    private let queue = DispatchQueue(label: "tts.http.server")
    private var listener: NWListener?

    init(port: UInt16, tts: KokoroTTS, playback: TTSPlaybackController) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.tts = tts
        self.playback = playback
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback  // localhost only
        let l = try NWListener(using: params, on: port)
        let boundPort = port.rawValue
        l.stateUpdateHandler = { state in
            // Surface a bind failure (e.g. port already in use) instead of silently appearing
            // healthy while the endpoint is dead.
            if case .failed(let err) = state {
                NSLog("TTSHTTPServer: listener failed on port \(boundPort): \(err)")
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulate bytes until the full request (headers + Content-Length body) is present.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            // Loopback hook bodies are tiny; cap accumulation so a malformed/huge Content-Length
            // can't grow the buffer unbounded.
            guard buf.count <= 1 << 20 else {
                self.respond(conn, "413 Payload Too Large", Data())
                return
            }
            if let req = Self.parse(buf) {
                self.route(conn, req)
            } else if isComplete || error != nil {
                self.respond(conn, "400 Bad Request", Data())
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let body: Data
    }

    /// Parse an HTTP request from `buf`, returning nil if more bytes are still needed.
    private static func parse(_ buf: Data) -> Request? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let header = String(data: buf[buf.startIndex..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines.first?.components(separatedBy: " ") ?? []
        guard request.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = sep.upperBound
        guard buf.distance(from: bodyStart, to: buf.endIndex) >= contentLength else { return nil }
        let body = buf.subdata(in: bodyStart..<buf.index(bodyStart, offsetBy: contentLength))
        return Request(method: request[0], path: request[1], body: body)
    }

    private func route(_ conn: NWConnection, _ req: Request) {
        switch (req.method, req.path.split(separator: "?").first.map(String.init) ?? req.path) {
        case ("GET", "/v1/models"):
            let json = #"{"object":"list","data":[{"id":"prince-canuma/Kokoro-82M","object":"model"}]}"#
            respond(conn, "200 OK", Data(json.utf8), contentType: "application/json")

        case ("POST", "/v1/audio/speech"):
            let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
            let input = json?["input"] as? String ?? ""
            let voice = json?["voice"] as? String ?? Self.userVoice()
            Task { [tts] in
                do {
                    let wav = try await tts.synthesize(input, voice: voice)
                    self.respond(conn, "200 OK", wav, contentType: "audio/wav")
                } catch {
                    self.respond(conn, "500 Internal Server Error",
                                 Data(#"{"error":"TTS generation failed"}"#.utf8), contentType: "application/json")
                }
            }

        case ("POST", "/v1/audio/play"):
            // Fire-and-forget: hand the text to the in-app player and return immediately. The
            // player synthesizes sentence-by-sentence and supersedes any current playback.
            let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
            let input = json?["input"] as? String ?? ""
            let voice = json?["voice"] as? String ?? Self.userVoice()
            Task { [playback] in await playback.play(text: input, voice: voice) }
            respond(conn, "202 Accepted",
                    Data(#"{"status":"accepted"}"#.utf8), contentType: "application/json")

        case ("POST", "/mcp"):
            // Minimal MCP over Streamable HTTP. All JSON-RPC shaping is pure (OpenWhispererKit);
            // here we only map the outcome onto HTTP and perform the one side effect (playback).
            switch MCPServer().handle(req.body) {
            case .json(let data):
                respond(conn, "200 OK", data, contentType: "application/json")
            case .accepted:
                respond(conn, "202 Accepted", Data())
            case .speak(let response, let text, let voice):
                Task { [playback] in await playback.play(text: text, voice: voice ?? Self.userVoice()) }
                respond(conn, "200 OK", response, contentType: "application/json")
            }

        case ("GET", "/mcp"):
            // We don't offer the optional server→client SSE stream; say so rather than 404.
            respond(conn, "405 Method Not Allowed", Data())

        default:
            respond(conn, "404 Not Found", Data())
        }
    }

    /// The user's selected TTS voice (global `tts_voice` pref), or the Kokoro default. Used when a
    /// request omits a voice — notably the `speak` MCP tool, which the model calls with text only.
    private static func userVoice() -> String {
        let v = (try? String(contentsOf: Paths.ttsVoice, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v! : "af_heart"
    }

    private func respond(_ conn: NWConnection, _ status: String, _ body: Data, contentType: String = "text/plain") {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var resp = Data(head.utf8)
        resp.append(body)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }
}
