import Foundation
import OpenWhispererKit

/// Checks for `MCPBridge` — pure shaping for the --mcp-stdio bridge's failure path.
func mcpBridgeFailures() -> [String] {
    var failures: [String] = []

    func decode(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // A request (has id) gets a JSON-RPC error echoing the id.
    let request = Data(#"{"jsonrpc":"2.0","id":42,"method":"tools/list"}"#.utf8)
    if let r = decode(MCPBridge.transportFailureResponse(for: request)) {
        if (r["jsonrpc"] as? String) != "2.0" { failures.append("transportFailure: jsonrpc != 2.0") }
        if (r["id"] as? Int) != 42 { failures.append("transportFailure: id not echoed") }
        let error = r["error"] as? [String: Any]
        if (error?["code"] as? Int) != -32603 { failures.append("transportFailure: expected code -32603") }
        if ((error?["message"] as? String)?.contains("not running")) != true {
            failures.append("transportFailure: message should say the app is not running")
        }
    } else {
        failures.append("transportFailure: expected a response for a request with id")
    }

    // A string id is echoed as a string.
    let stringID = Data(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8)
    if (decode(MCPBridge.transportFailureResponse(for: stringID))?["id"] as? String) != "abc" {
        failures.append("transportFailure: string id not echoed")
    }

    // Notifications (no id) and garbage produce nothing — the bridge stays silent.
    let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
    if MCPBridge.transportFailureResponse(for: notification) != nil {
        failures.append("transportFailure: notification must yield nil")
    }
    if MCPBridge.transportFailureResponse(for: Data("not json".utf8)) != nil {
        failures.append("transportFailure: garbage must yield nil")
    }

    return failures
}
