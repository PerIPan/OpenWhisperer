import Foundation

/// What `MCPServer.handle` decided to do with one JSON-RPC message. The pure layer shapes the
/// reply; the HTTP layer performs the I/O (send the body, or play audio for a `speak` call).
public enum MCPOutcome {
    /// Send this JSON body as `200 application/json` (a JSON-RPC result or error).
    case json(Data)
    /// Send `202 Accepted` with an empty body (JSON-RPC notification — nothing to reply).
    case accepted
    /// Send `response` (200) AND play `text` aloud (optionally in `voice`). The one side effect.
    case speak(response: Data, text: String, voice: String?)
}

/// Pure, transport-free dispatch for the minimal slice of MCP that Claude Code needs to register
/// the in-app `speak` tool over Streamable HTTP: `initialize`, `notifications/initialized`,
/// `tools/list`, `tools/call`. Stateless (no session header). All JSON shaping lives here so it
/// is unit-testable under CLT; `TTSHTTPServer` owns only the socket and the playback side effect.
public struct MCPServer {
    public static let protocolVersion = "2025-11-25"

    public init() {}

    public func handle(_ body: Data) -> MCPOutcome {
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
            return .json(Self.resultResponse(id: requestID, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "OpenWhisperer", "version": "1.0"],
            ]))

        case "ping":
            return .json(Self.resultResponse(id: requestID, result: [String: Any]()))

        case "tools/list":
            let speak: [String: Any] = [
                "name": "speak",
                // Human-readable label for the tool-call chip. `title` is the current MCP spec field;
                // `annotations.title` covers clients that read the older location.
                "title": "Speak aloud",
                "annotations": ["title": "Speak aloud"],
                "description": "Synthesize and play the given text aloud through OpenWhisperer's "
                    + "local voice (text-to-speech). Fire-and-forget: returns immediately while audio plays.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The text to speak aloud."],
                        "voice": ["type": "string", "description": "Optional voice name; defaults to the user's selected voice."],
                    ],
                    "required": ["text"],
                ],
            ]
            return .json(Self.resultResponse(id: requestID, result: ["tools": [speak]]))

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard name == "speak" else {
                return .json(Self.toolError(id: requestID, message: "Unknown tool: \(name)"))
            }
            guard let text = args["text"] as? String, !text.isEmpty else {
                return .json(Self.toolError(id: requestID, message: "Missing required argument: text"))
            }
            let voice = args["voice"] as? String
            let response = Self.resultResponse(id: requestID, result: [
                "content": [["type": "text", "text": "Speaking."]],
                "isError": false,
            ])
            return .speak(response: response, text: text, voice: voice)

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

    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}
