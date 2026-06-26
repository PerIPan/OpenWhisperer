import Foundation
import OpenWhispererKit

/// Checks for `MCPServer` — the pure JSON-RPC dispatch behind the in-app `speak` MCP tool.
/// Locks the wire shapes Claude Code's Streamable HTTP client expects (protocol `2025-11-25`).
func mcpServerFailures() -> [String] {
    var failures: [String] = []
    let server = MCPServer()

    func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func req(_ json: String) -> MCPOutcome { server.handle(Data(json.utf8)) }

    // initialize → echoes id, advertises tools capability + serverInfo, returns a protocol version.
    if case let .json(data) = req(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Claude Code","version":"1"}}}"#),
       let r = decode(data) {
        if (r["jsonrpc"] as? String) != "2.0" { failures.append("initialize: jsonrpc != \"2.0\"") }
        if (r["id"] as? Int) != 1 { failures.append("initialize: id not echoed") }
        let result = r["result"] as? [String: Any]
        if (result?["protocolVersion"] as? String) != "2025-11-25" { failures.append("initialize: protocolVersion wrong") }
        if (result?["capabilities"] as? [String: Any])?["tools"] == nil { failures.append("initialize: missing capabilities.tools") }
        if ((result?["serverInfo"] as? [String: Any])?["name"] as? String)?.isEmpty != false { failures.append("initialize: missing serverInfo.name") }
    } else {
        failures.append("initialize: expected .json outcome")
    }

    // initialize echoes a *different* requested version → compatibility across Claude Code releases.
    if case let .json(data) = req(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#),
       let result = decode(data)?["result"] as? [String: Any] {
        if (result["protocolVersion"] as? String) != "2025-06-18" { failures.append("initialize: did not echo requested protocolVersion") }
    } else {
        failures.append("initialize(alt version): expected .json outcome")
    }

    // notifications/initialized → 202, nothing to reply.
    if case .accepted = req(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) {} else {
        failures.append("notifications/initialized: expected .accepted")
    }

    // tools/list → advertises `speak` with a required `text` and an optional `voice`.
    if case let .json(data) = req(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#),
       let result = decode(data)?["result"] as? [String: Any],
       let tools = result["tools"] as? [[String: Any]],
       let speak = tools.first(where: { ($0["name"] as? String) == "speak" }) {
        let schema = speak["inputSchema"] as? [String: Any]
        if (schema?["required"] as? [String])?.contains("text") != true { failures.append("tools/list: speak.required missing \"text\"") }
        let props = schema?["properties"] as? [String: Any]
        if props?["text"] == nil { failures.append("tools/list: speak missing text property") }
        if props?["voice"] == nil { failures.append("tools/list: speak missing voice property") }
        if (speak["title"] as? String)?.isEmpty != false { failures.append("tools/list: speak missing display title") }
    } else {
        failures.append("tools/list: expected speak tool in .json outcome")
    }

    // tools/call speak (text + voice) → .speak side effect, args passed through, isError false.
    switch req(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hello there","voice":"af_bella"}}}"#) {
    case let .speak(response, text, voice):
        if text != "hello there" { failures.append("tools/call: text not passed through") }
        if voice != "af_bella" { failures.append("tools/call: voice not passed through") }
        if let r = decode(response)?["result"] as? [String: Any] {
            if (r["isError"] as? Bool) != false { failures.append("tools/call: isError should be false") }
            if ((r["content"] as? [[String: Any]])?.first?["type"] as? String) != "text" { failures.append("tools/call: content[0].type != \"text\"") }
        } else { failures.append("tools/call: response not decodable") }
    default:
        failures.append("tools/call(speak): expected .speak outcome")
    }

    // tools/call speak without voice → voice nil (handler must not invent one).
    switch req(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hi"}}}"#) {
    case let .speak(_, text, voice):
        if text != "hi" { failures.append("tools/call(no voice): text wrong") }
        if voice != nil { failures.append("tools/call(no voice): voice should be nil") }
    default:
        failures.append("tools/call(no voice): expected .speak outcome")
    }

    // tools/call speak with missing text → tool error, and crucially NOT a playback.
    switch req(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"speak","arguments":{}}}"#) {
    case let .json(data):
        if ((decode(data)?["result"] as? [String: Any])?["isError"] as? Bool) != true { failures.append("tools/call(missing text): expected isError true") }
    case .speak:
        failures.append("tools/call(missing text): must NOT play")
    case .accepted:
        failures.append("tools/call(missing text): expected .json error")
    }

    // tools/call unknown tool → tool error.
    switch req(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"nope","arguments":{"text":"x"}}}"#) {
    case let .json(data):
        if ((decode(data)?["result"] as? [String: Any])?["isError"] as? Bool) != true { failures.append("tools/call(unknown tool): expected isError true") }
    default:
        failures.append("tools/call(unknown tool): expected .json error")
    }

    // unknown method → JSON-RPC error -32601, id echoed.
    if case let .json(data) = req(#"{"jsonrpc":"2.0","id":8,"method":"resources/list","params":{}}"#),
       let r = decode(data) {
        if (r["id"] as? Int) != 8 { failures.append("unknown method: id not echoed") }
        if ((r["error"] as? [String: Any])?["code"] as? Int) != -32601 { failures.append("unknown method: code != -32601") }
    } else {
        failures.append("unknown method: expected .json error")
    }

    // Malformed JSON body → parse error -32700.
    if case let .json(data) = req("not json"),
       let err = decode(data)?["error"] as? [String: Any] {
        if (err["code"] as? Int) != -32700 { failures.append("malformed: code != -32700") }
    } else {
        failures.append("malformed: expected .json parse error")
    }

    return failures
}
