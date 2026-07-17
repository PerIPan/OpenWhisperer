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
        if props?["speed"] == nil { failures.append("tools/list: speak missing speed property") }
    } else {
        failures.append("tools/list: expected speak tool in .json outcome")
    }

    // tools/call speak (text + voice + speed) → .speak side effect, all args passed through.
    switch req(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hello there","voice":"af_bella","speed":1.25}}}"#) {
    case let .speak(response, text, voice, speed):
        if text != "hello there" { failures.append("tools/call: text not passed through") }
        if voice != "af_bella" { failures.append("tools/call: voice not passed through") }
        if speed != 1.25 { failures.append("tools/call: speed not passed through") }
        if let r = decode(response)?["result"] as? [String: Any] {
            if (r["isError"] as? Bool) != false { failures.append("tools/call: isError should be false") }
            if ((r["content"] as? [[String: Any]])?.first?["type"] as? String) != "text" { failures.append("tools/call: content[0].type != \"text\"") }
        } else { failures.append("tools/call: response not decodable") }
    default:
        failures.append("tools/call(speak): expected .speak outcome")
    }

    // tools/call speak without voice/speed → both nil (handler must not invent them).
    switch req(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hi"}}}"#) {
    case let .speak(_, text, voice, speed):
        if text != "hi" { failures.append("tools/call(no voice): text wrong") }
        if voice != nil { failures.append("tools/call(no voice): voice should be nil") }
        if speed != nil { failures.append("tools/call(no speed): speed should be nil") }
    default:
        failures.append("tools/call(no voice): expected .speak outcome")
    }

    // tools/call speak with a persona/display voice name → ignore it so playback falls back to
    // the user's configured Kokoro voice instead of forwarding an invalid synthesis voice.
    switch req(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hello","voice":"British English"}}}"#) {
    case let .speak(_, text, voice, _):
        if text != "hello" { failures.append("tools/call(display voice): text wrong") }
        if voice != nil { failures.append("tools/call(display voice): voice should be nil") }
    default:
        failures.append("tools/call(display voice): expected .speak outcome")
    }
    switch req(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hello","voice":"british_english"}}}"#) {
    case let .speak(_, _, voice, _):
        if voice != nil { failures.append("tools/call(display voice slug): voice should be nil") }
    default:
        failures.append("tools/call(display voice slug): expected .speak outcome")
    }
    switch req(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hello","voice":"12_voice"}}}"#) {
    case let .speak(_, _, voice, _):
        if voice != nil { failures.append("tools/call(invalid voice prefix): voice should be nil") }
    default:
        failures.append("tools/call(invalid voice prefix): expected .speak outcome")
    }

    // tools/call speak with missing text → tool error, and crucially NOT a playback.
    switch req(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"speak","arguments":{}}}"#) {
    case let .json(data):
        if ((decode(data)?["result"] as? [String: Any])?["isError"] as? Bool) != true { failures.append("tools/call(missing text): expected isError true") }
    case .speak:
        failures.append("tools/call(missing text): must NOT play")
    case .accepted:
        failures.append("tools/call(missing text): expected .json error")
    }

    // tools/call unknown tool → tool error.
    switch req(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nope","arguments":{"text":"x"}}}"#) {
    case let .json(data):
        if ((decode(data)?["result"] as? [String: Any])?["isError"] as? Bool) != true { failures.append("tools/call(unknown tool): expected isError true") }
    default:
        failures.append("tools/call(unknown tool): expected .json error")
    }

    // unknown method → JSON-RPC error -32601, id echoed.
    if case let .json(data) = req(#"{"jsonrpc":"2.0","id":11,"method":"resources/list","params":{}}"#),
       let r = decode(data) {
        if (r["id"] as? Int) != 11 { failures.append("unknown method: id not echoed") }
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

    // tools/list → advertises `list_voices`
    if case let .json(data) = req(#"{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{}}"#),
       let result = decode(data)?["result"] as? [String: Any],
       let tools = result["tools"] as? [[String: Any]],
       let listVoices = tools.first(where: { ($0["name"] as? String) == "list_voices" }) {
        let schema = listVoices["inputSchema"] as? [String: Any]
        if schema?["properties"] == nil { failures.append("tools/list: list_voices inputSchema properties missing") }
    } else {
        failures.append("tools/list: expected list_voices tool in .json outcome")
    }

    // tools/call list_voices → returns the serialized voices list with correct cached state
    let mockIsCached: (String) -> Bool = { $0 == "af_heart" }
    switch server.handle(Data(#"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"list_voices"}}"#.utf8), isVoiceCached: mockIsCached) {
    case let .json(data):
        if let r = decode(data)?["result"] as? [String: Any],
           let content = r["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String,
           let bodyData = text.data(using: .utf8),
           let voicesObj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
           let voicesList = voicesObj["voices"] as? [[String: Any]] {
            if voicesList.count != 54 { failures.append("list_voices tool: expected 54 voices, got \(voicesList.count)") }
            if let heart = voicesList.first(where: { ($0["id"] as? String) == "af_heart" }) {
                if (heart["cached"] as? Bool) != true { failures.append("list_voices tool: af_heart cached should be true") }
            } else { failures.append("list_voices tool: missing af_heart") }
            if let bella = voicesList.first(where: { ($0["id"] as? String) == "af_bella" }) {
                if (bella["cached"] as? Bool) != false { failures.append("list_voices tool: af_bella cached should be false") }
            } else { failures.append("list_voices tool: missing af_bella") }
        } else { failures.append("list_voices tool: invalid response shape") }
    default:
        failures.append("list_voices tool: expected .json outcome")
    }

    // initialize with guidance → instructions field present; without → absent.
    let initReq = #"{"jsonrpc":"2.0","id":9,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Claude Desktop","version":"1"}}}"#
    if case let .json(data) = server.handle(Data(initReq.utf8), guidance: "SPEAK-FIRST GUIDANCE"),
       let r = decode(data) {
        let result = r["result"] as? [String: Any]
        if (result?["instructions"] as? String) != "SPEAK-FIRST GUIDANCE" {
            failures.append("initialize: guidance not surfaced as instructions")
        }
    } else {
        failures.append("initialize+guidance: expected .json outcome")
    }
    if case let .json(data) = server.handle(Data(initReq.utf8)), let r = decode(data) {
        if (r["result"] as? [String: Any])?["instructions"] != nil {
            failures.append("initialize: instructions present without guidance")
        }
    }

    // tools/list with guidance → speak description carries it; list_voices does not.
    let listReq = #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#
    if case let .json(data) = server.handle(Data(listReq.utf8), guidance: "SPEAK-FIRST GUIDANCE"),
       let r = decode(data),
       let tools = (r["result"] as? [String: Any])?["tools"] as? [[String: Any]] {
        let speak = tools.first { ($0["name"] as? String) == "speak" }
        let voices = tools.first { ($0["name"] as? String) == "list_voices" }
        if ((speak?["description"] as? String)?.contains("SPEAK-FIRST GUIDANCE")) != true {
            failures.append("tools/list: speak description missing guidance")
        }
        if ((voices?["description"] as? String)?.contains("SPEAK-FIRST GUIDANCE")) == true {
            failures.append("tools/list: guidance leaked into list_voices description")
        }
    } else {
        failures.append("tools/list+guidance: expected .json outcome with tools")
    }

    return failures
}
