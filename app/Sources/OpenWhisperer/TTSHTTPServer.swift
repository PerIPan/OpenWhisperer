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
    private let tts: TTSEngines
    private let playback: TTSPlaybackController
    private let queue = DispatchQueue(label: "tts.http.server")
    private var listener: NWListener?

    init(port: UInt16, tts: TTSEngines, playback: TTSPlaybackController) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.tts = tts
        self.playback = playback
    }

    /// Start listening. Throws only when Network.framework rejects the parameters; the bind
    /// itself is **asynchronous**, and a port already in use arrives later as `.failed`. So the
    /// outcome is reported through `bound`, exactly once, on the server's own queue: `.success`
    /// on the first `.ready`, `.failure` on `.failed` before that. Callers must not treat a
    /// non-throwing return as a bound port — 2.0.8's first cut did, and would have re-pointed
    /// every agent at a port another process owned.
    func start(bound: @escaping (Result<Void, Error>) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback  // localhost only
        let l = try NWListener(using: params, on: port)
        let boundPort = port.rawValue
        var reported = false
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard !reported else { return }
                reported = true
                bound(.success(()))
            case .failed(let err):
                // Surface a bind failure (e.g. port already in use) instead of silently
                // appearing healthy while the endpoint is dead.
                NSLog("TTSHTTPServer: listener failed on port \(boundPort): \(err)")
                guard !reported else { return }
                reported = true
                bound(.failure(err))
            default:
                break
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

    /// How long a connection may sit without completing a request before it is dropped.
    /// `while :; do nc localhost 8000 & done` otherwise holds NWConnections and file
    /// descriptors open indefinitely. Hook requests complete in milliseconds.
    private static let requestTimeout: TimeInterval = 10

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak conn] in
            // No-op once the request has been answered — `respond` cancels the connection,
            // and cancelling an already-cancelled NWConnection is harmless.
            conn?.cancel()
        }
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
        /// Present only when a browser sent the request. Any value at all means the caller is
        /// a web page, which no legitimate client of this server is.
        let origin: String?
        /// Used to reject DNS-rebinding, where a hostile name resolves to 127.0.0.1.
        let host: String?
    }

    /// Parse an HTTP request from `buf`, returning nil if more bytes are still needed.
    private static func parse(_ buf: Data) -> Request? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let header = String(data: buf[buf.startIndex..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines.first?.components(separatedBy: " ") ?? []
        guard request.count >= 2 else { return nil }

        func headerValue(_ name: String) -> String? {
            // First occurrence wins — a smuggled duplicate must not override the real one.
            lines.dropFirst().first { $0.lowercased().hasPrefix(name) }
                .map { String($0.dropFirst(name.count)).trimmingCharacters(in: .whitespaces) }
        }

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        // A negative Content-Length satisfies the `>=` check below and then traps in
        // `subdata` (lowerBound > upperBound), killing the whole in-process menubar app.
        // One `nc` packet was enough.
        guard contentLength >= 0 else { return nil }
        let bodyStart = sep.upperBound
        guard buf.distance(from: bodyStart, to: buf.endIndex) >= contentLength else { return nil }
        let body = buf.subdata(in: bodyStart..<buf.index(bodyStart, offsetBy: contentLength))
        return Request(method: request[0], path: request[1], body: body,
                       origin: headerValue("origin:"), host: headerValue("host:"))
    }

    /// Whether the request came from something other than a web page pointed at us.
    ///
    /// `POST /mcp` with `Content-Type: text/plain` is a CORS *simple* request — no preflight —
    /// and `MCPServer` is stateless, so without this any site the user visits could `fetch`
    /// its way to the `speak` tool and talk through their speakers in their own voice. The MCP
    /// Streamable HTTP spec requires exactly this check for local servers.
    ///
    /// No legitimate client sends `Origin`: not curl, not the bash hooks, not Claude Code's or
    /// agy's MCP client, not Pi's `fetch` (Node/Bun omit it). A localhost origin is allowed
    /// anyway so a future local web client isn't locked out for no reason.
    private static func isTrustedCaller(_ req: Request) -> Bool {
        if let origin = req.origin?.lowercased(), !origin.isEmpty {
            let allowed = ["http://localhost", "http://127.0.0.1", "http://[::1]"]
            guard allowed.contains(where: { origin == $0 || origin.hasPrefix($0 + ":") }) else {
                return false
            }
        }
        // Rebinding defense: the attacker controls DNS, not the Host header the browser sends.
        // A missing Host is HTTP/1.0 or a raw socket — not a browser — so it is allowed.
        if let host = req.host?.lowercased(), !host.isEmpty {
            let name = host.hasPrefix("[") ? "[::1]" : String(host.split(separator: ":").first ?? "")
            guard ["localhost", "127.0.0.1", "[::1]"].contains(name) else { return false }
        }
        return true
    }

    private func route(_ conn: NWConnection, _ req: Request) {
        guard Self.isTrustedCaller(req) else {
            respond(conn, "403 Forbidden",
                    Data(#"{"error":"cross-origin requests are not allowed"}"#.utf8),
                    contentType: "application/json")
            return
        }
        switch (req.method, req.path.split(separator: "?").first.map(String.init) ?? req.path) {
        case ("GET", "/v1/models"):
            let json = #"{"object":"list","data":[{"id":"prince-canuma/Kokoro-82M","object":"model"}]}"#
            respond(conn, "200 OK", Data(json.utf8), contentType: "application/json")

        case ("POST", "/v1/audio/speech"):
            let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
            let input = json?["input"] as? String ?? ""
            // Same validator the MCP `speak` tool uses: an unvalidated id reaches FluidAudio's
            // voice-pack cache, which keys on the raw string, so `af-heart`/`af.heart`/… each
            // cache another copy of the same pack.
            let voice = MCPServer.validVoiceID(json?["voice"] as? String) ?? Self.userVoice()
            // Guard finiteness so a non-finite override can't slip a NaN past clamp into synthesis
            // (JSON can't carry NaN/Inf today, but don't rely on the serializer for that safety).
            let speed = (json?["speed"] as? Double).flatMap { $0.isFinite ? TTSSpeed.clamp(Float($0)) : nil } ?? Self.userSpeed()
            Task { [tts] in
                do {
                    let wav = try await tts.synthesize(input, voice: voice, speed: speed)
                    self.respond(conn, "200 OK", wav, contentType: "audio/wav")
                } catch {
                    self.respond(conn, "500 Internal Server Error",
                                 Data(#"{"error":"TTS generation failed"}"#.utf8), contentType: "application/json")
                }
            }

        case ("POST", "/v1/audio/play"):
            // Fire-and-forget: hand the text to the in-app player and return immediately. The
            // player synthesizes sentence-by-sentence and queues sequential playback.
            let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
            let input = json?["input"] as? String ?? ""
            // Same validator the MCP `speak` tool uses: an unvalidated id reaches FluidAudio's
            // voice-pack cache, which keys on the raw string, so `af-heart`/`af.heart`/… each
            // cache another copy of the same pack.
            let voice = MCPServer.validVoiceID(json?["voice"] as? String) ?? Self.userVoice()
            let speed = (json?["speed"] as? Double).flatMap { $0.isFinite ? TTSSpeed.clamp(Float($0)) : nil } ?? Self.userSpeed()
            // Muted (menubar): accept and drop, saying so — the Pi extension reads the status.
            if FileManager.default.fileExists(atPath: Paths.ttsMuted.path) {
                respond(conn, "200 OK", Data(#"{"status":"muted"}"#.utf8), contentType: "application/json")
                return
            }
            Task { [playback] in await playback.play(text: input, voice: voice, speed: speed) }
            respond(conn, "202 Accepted",
                    Data(#"{"status":"accepted"}"#.utf8), contentType: "application/json")

        case ("POST", "/mcp"):
            // Minimal MCP over Streamable HTTP. All JSON-RPC shaping is pure (OpenWhispererKit);
            // here we only map the outcome onto HTTP and perform the one side effect (playback).
            let muted = FileManager.default.fileExists(atPath: Paths.ttsMuted.path)
            switch MCPServer().handle(req.body, isVoiceCached: VoiceCache.isCached, isMuted: muted) {
            case .json(let data):
                respond(conn, "200 OK", data, contentType: "application/json")
            case .accepted:
                respond(conn, "202 Accepted", Data())
            case .speak(let response, let text, let voice, let speed):
                let resolvedSpeed = speed.flatMap { $0.isFinite ? TTSSpeed.clamp(Float($0)) : nil } ?? Self.userSpeed()
                Task { [playback] in await playback.play(text: text, voice: voice ?? Self.userVoice(), speed: resolvedSpeed) }
                respond(conn, "200 OK", response, contentType: "application/json")
            }

        case ("GET", "/mcp"):
            // We don't offer the optional server→client SSE stream; say so rather than bare 404.
            respond(conn, "405 Method Not Allowed",
                    Data(#"{"error":"method_not_allowed","error_description":"GET not supported; use POST"}"#.utf8),
                    contentType: "application/json")

        default:
            // Return a JSON error object so MCP clients probing OAuth discovery endpoints
            // (e.g. /.well-known/oauth-authorization-server) receive valid JSON 404 rather than
            // an empty body that triggers JSON parse EOF errors during auth discovery.
            respond(conn, "404 Not Found",
                    Data(#"{"error":"not_found"}"#.utf8),
                    contentType: "application/json")
        }
    }

    /// The user's selected TTS voice (global `tts_voice` pref), or the Kokoro default. Used when a
    /// request omits a voice — notably the `speak` MCP tool, which the model calls with text only.
    private static func userVoice() -> String {
        let v = (try? String(contentsOf: Paths.ttsVoice, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v! : "af_heart"
    }

    /// The user's global TTS speed (`tts_speed`), clamped, or the 1.1× default.
    /// Used by the blocking WAV path when the request omits a `speed`.
    private static func userSpeed() -> Float {
        TTSSpeed.parse(try? String(contentsOf: Paths.ttsSpeed, encoding: .utf8))
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
