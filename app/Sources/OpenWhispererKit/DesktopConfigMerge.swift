import Foundation

/// Shapes Claude Desktop's `claude_desktop_config.json`: merge in (or verify) the
/// OpenWhisperer stdio MCP entry while preserving every foreign key. Claude Desktop only
/// launches stdio servers from this file, hence `--mcp-stdio` rather than an HTTP URL.
/// Pure so it's testable in Kit; ConfigManager does the file I/O.
public enum DesktopConfigMerge {
    /// The merged config document. `nil` `existingJSON` (file absent) produces a fresh config
    /// with just our entry, as before. Non-nil `existingJSON` that does NOT decode to a
    /// top-level JSON object (invalid JSON, or a valid document whose root is an array/string/
    /// number), or whose existing `mcpServers` key is present but is not itself a dictionary,
    /// is refused: this returns `nil` rather than silently discarding unrecognized user data.
    /// Callers must treat a `nil` result here as a failure to surface, not as "nothing to do."
    public static func merged(existingJSON: Data?, executablePath: String) -> Data? {
        var root: [String: Any] = [:]
        if let existingJSON {
            guard let json = (try? JSONSerialization.jsonObject(with: existingJSON)) as? [String: Any] else {
                return nil
            }
            root = json
        }
        if let existingServers = root["mcpServers"], !(existingServers is [String: Any]) {
            return nil
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["OpenWhisperer"] = ["command": executablePath, "args": ["--mcp-stdio"]]
        root["mcpServers"] = servers
        return try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Whether the config already carries a current OpenWhisperer stdio entry: `command` must
    /// equal `executablePath` exactly and `args` must contain `--mcp-stdio`. A stale entry
    /// pointing at a moved/old binary, or one missing `command` entirely, is not "configured."
    public static func isConfigured(configJSON: Data?, executablePath: String) -> Bool {
        guard let configJSON,
              let json = (try? JSONSerialization.jsonObject(with: configJSON)) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let entry = servers["OpenWhisperer"] as? [String: Any],
              let command = entry["command"] as? String,
              let args = entry["args"] as? [String] else { return false }
        return command == executablePath && args.contains("--mcp-stdio")
    }
}
