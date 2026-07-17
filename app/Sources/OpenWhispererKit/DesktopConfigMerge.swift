import Foundation

/// Shapes Claude Desktop's `claude_desktop_config.json`: merge in (or verify) the
/// OpenWhisperer stdio MCP entry while preserving every foreign key. Claude Desktop only
/// launches stdio servers from this file, hence `--mcp-stdio` rather than an HTTP URL.
/// Pure so it's testable in Kit; ConfigManager does the file I/O.
public enum DesktopConfigMerge {
    /// The merged config document, or nil only if serialization itself fails.
    /// Unparseable existing content is treated as an empty config.
    public static func merged(existingJSON: Data?, executablePath: String) -> Data? {
        var root: [String: Any] = [:]
        if let existingJSON,
           let json = (try? JSONSerialization.jsonObject(with: existingJSON)) as? [String: Any] {
            root = json
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["OpenWhisperer"] = ["command": executablePath, "args": ["--mcp-stdio"]]
        root["mcpServers"] = servers
        return try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Whether the config already carries a current OpenWhisperer stdio entry.
    public static func isConfigured(configJSON: Data?) -> Bool {
        guard let configJSON,
              let json = (try? JSONSerialization.jsonObject(with: configJSON)) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let entry = servers["OpenWhisperer"] as? [String: Any],
              let args = entry["args"] as? [String] else { return false }
        return args.contains("--mcp-stdio")
    }
}
