import Foundation

/// Pure shaping for the `--mcp-stdio` bridge (stdio⇄HTTP proxy for MCP clients that only
/// launch stdio servers, e.g. Claude Desktop). The bridge itself lives in the app target;
/// the one decision worth testing — what to write when the menubar app's HTTP server is
/// unreachable — lives here.
public enum MCPBridge {
    /// A JSON-RPC internal error echoing the request's `id`, for when `POST /mcp` cannot be
    /// reached. Returns nil for notifications (no `id`) or unparseable frames: per JSON-RPC,
    /// nothing may be written in reply to those.
    public static func transportFailureResponse(for request: Data) -> Data? {
        guard let msg = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any],
              let id = msg["id"], !(id is NSNull) else { return nil }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32603,
                "message": "OpenWhisperer is not running — start the menubar app and retry",
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}
