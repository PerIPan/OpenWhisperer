import Foundation

/// What `MCPServer.handle` decided to do with one JSON-RPC message. The pure layer shapes the
/// reply; the HTTP layer performs the I/O (send the body, or play audio for a `speak` call).
public enum MCPOutcome {
    /// Send this JSON body as `200 application/json` (a JSON-RPC result or error).
    case json(Data)
    /// Send `202 Accepted` with an empty body (JSON-RPC notification — nothing to reply).
    case accepted
    /// Send `response` (200) AND play `text` aloud (optionally in `voice`/`speed`). The one side effect.
    case speak(response: Data, text: String, voice: String?, speed: Double?)
}

/// Pure, transport-free dispatch for the minimal slice of MCP that Claude Code needs to register
/// the in-app `speak` tool over Streamable HTTP: `initialize`, `notifications/initialized`,
/// `tools/list`, `tools/call`. Stateless (no session header). All JSON shaping lives here so it
/// is unit-testable under CLT; `TTSHTTPServer` owns only the socket and the playback side effect.
public struct MCPServer {
    public static let protocolVersion = "2025-11-25"

    public init() {}

    public func handle(_ body: Data, isVoiceCached: (String) -> Bool = { _ in false }, guidance: String? = nil) -> MCPOutcome {
        guard let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .json(Self.errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
        }
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]  // absent for notifications; NSNumber/String for requests

        // A message with no `id` (or any `notifications/*` method) is a notification: just ack it.
        if id == nil || method.hasPrefix("notifications/") {
            return .accepted
        }
        let requestID = id!
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            // Echo the client's requested protocol version when it sends one, so we interop with
            // whatever Claude Code release connects; fall back to ours otherwise.
            let version = (params["protocolVersion"] as? String) ?? Self.protocolVersion
            var result: [String: Any] = [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "OpenWhisperer", "version": "1.0"],
            ]
            // The standing voice instruction (MCP tier): marker-gated, so it is inert for
            // clients whose prompts never carry the marker (hook platforms).
            if let guidance { result["instructions"] = guidance }
            return .json(Self.resultResponse(id: requestID, result: result))

        case "ping":
            return .json(Self.resultResponse(id: requestID, result: [String: Any]()))

        case "tools/list":
            var speakDescription = "Synthesize and play the given text aloud through OpenWhisperer's "
                + "local voice (text-to-speech). Fire-and-forget: returns immediately while audio plays; subsequent requests are automatically queued by the engine to play sequentially and gaplessly. To orchestrate a multi-actor conversation or dialogue, do NOT write scripts or add delays/sleeps; instead, call this tool sequentially multiple times with different voice IDs (discovered using the list_voices tool)."
            if let guidance { speakDescription += "\n\n" + guidance }
            let speak: [String: Any] = [
                "name": "speak",
                "description": speakDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The text to speak aloud."],
                        "voice": ["type": "string", "description": "Optional Kokoro voice id (e.g., 'af_heart', 'bf_emma', 'jf_alpha'). Discover available IDs using list_voices. Pass different voice IDs in consecutive speak calls to script multi-character dialogue without external code."],
                        "speed": ["type": "number", "description": "Optional playback speed, 0.7–1.5; defaults to the user's setting."],
                    ],
                    "required": ["text"],
                ],
            ]
            let listVoices: [String: Any] = [
                "name": "list_voices",
                "description": "Retrieve the list of available text-to-speech voices, including their language, region, gender, and local cache status. Use these voice IDs in the 'speak' tool's 'voice' parameter to orchestrate multi-voice/multi-actor conversations.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            ]
            return .json(Self.resultResponse(id: requestID, result: ["tools": [speak, listVoices]]))

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            if name == "list_voices" {
                let voiceList = TTSVoiceRegistry.allVoices.map { voice -> [String: Any] in
                    return [
                        "id": voice.id,
                        "name": voice.name,
                        "language": voice.language,
                        "region": voice.region,
                        "gender": voice.gender,
                        "cached": isVoiceCached(voice.id)
                    ]
                }
                let voiceData = (try? JSONSerialization.data(withJSONObject: ["voices": voiceList], options: [.prettyPrinted])) ?? Data()
                let response = Self.resultResponse(id: requestID, result: [
                    "content": [["type": "text", "text": String(data: voiceData, encoding: .utf8) ?? ""]],
                    "isError": false,
                ])
                return .json(response)
            }
            guard name == "speak" else {
                return .json(Self.toolError(id: requestID, message: "Unknown tool: \(name)"))
            }
            guard let text = args["text"] as? String, !text.isEmpty else {
                return .json(Self.toolError(id: requestID, message: "Missing required argument: text"))
            }
            let voice = Self.validVoiceID(args["voice"] as? String)
            let speed = args["speed"] as? Double
            let response = Self.resultResponse(id: requestID, result: [
                "content": [["type": "text", "text": "Speaking."]],
                "isError": false,
            ])
            return .speak(response: response, text: text, voice: voice, speed: speed)

        default:
            return .json(Self.errorResponse(id: requestID, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - JSON-RPC envelope helpers

    private static func resultResponse(id: Any, result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// A tool-level failure: a successful JSON-RPC result whose payload is flagged `isError`.
    private static func toolError(id: Any, message: String) -> Data {
        resultResponse(id: id, result: ["content": [["type": "text", "text": message]], "isError": true])
    }

    private static func validVoiceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let voice = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else { return nil }
        let chars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        guard voice.rangeOfCharacter(from: chars.inverted) == nil,
              let underscore = voice.firstIndex(of: "_"),
              voice.distance(from: voice.startIndex, to: underscore) == 2,
              underscore < voice.index(before: voice.endIndex) else { return nil }
        let prefix = voice[..<underscore]
        guard prefix.allSatisfy(\.isLetter) else { return nil }
        return voice
    }

    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}
