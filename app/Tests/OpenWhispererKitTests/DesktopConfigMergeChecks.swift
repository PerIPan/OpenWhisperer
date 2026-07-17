import Foundation
import OpenWhispererKit

/// Checks for `DesktopConfigMerge` — read-modify-write shaping for claude_desktop_config.json.
func desktopConfigMergeFailures() -> [String] {
    var failures: [String] = []

    func decode(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func entry(_ root: [String: Any]?) -> [String: Any]? {
        ((root?["mcpServers"] as? [String: Any])?["OpenWhisperer"]) as? [String: Any]
    }

    // No existing file → a fresh config with just our entry.
    let fresh = decode(DesktopConfigMerge.merged(existingJSON: nil, executablePath: "/Applications/OpenWhisperer.app/Contents/MacOS/OpenWhisperer"))
    if (entry(fresh)?["command"] as? String) != "/Applications/OpenWhisperer.app/Contents/MacOS/OpenWhisperer" {
        failures.append("merged(nil): command wrong or missing")
    }
    if (entry(fresh)?["args"] as? [String]) != ["--mcp-stdio"] {
        failures.append("merged(nil): args wrong or missing")
    }

    // Foreign top-level keys and sibling servers survive; a stale entry is replaced.
    let existing = Data(#"""
    {"coworkUserFilesPath":"/Users/x/Claude",
     "preferences":{"sidebarMode":"chat"},
     "mcpServers":{"other":{"command":"/bin/other"},
                   "OpenWhisperer":{"command":"/old/path","args":["--old-flag"]}}}
    """#.utf8)
    let merged = decode(DesktopConfigMerge.merged(existingJSON: existing, executablePath: "/new/path"))
    if (merged?["coworkUserFilesPath"] as? String) != "/Users/x/Claude" {
        failures.append("merged: foreign top-level key dropped")
    }
    if ((merged?["preferences"] as? [String: Any])?["sidebarMode"] as? String) != "chat" {
        failures.append("merged: preferences dropped")
    }
    if (((merged?["mcpServers"] as? [String: Any])?["other"] as? [String: Any])?["command"] as? String) != "/bin/other" {
        failures.append("merged: sibling server dropped")
    }
    if (entry(merged)?["command"] as? String) != "/new/path" || (entry(merged)?["args"] as? [String]) != ["--mcp-stdio"] {
        failures.append("merged: stale OpenWhisperer entry not replaced")
    }

    // Unparseable existing content is treated as absent (don't crash, don't propagate garbage).
    if decode(DesktopConfigMerge.merged(existingJSON: Data("nonsense".utf8), executablePath: "/p")) == nil {
        failures.append("merged(garbage): should still produce a valid config")
    }

    // isConfigured: true only for an entry with --mcp-stdio in args.
    if !DesktopConfigMerge.isConfigured(configJSON: DesktopConfigMerge.merged(existingJSON: nil, executablePath: "/p")) {
        failures.append("isConfigured: freshly merged config not recognized")
    }
    if DesktopConfigMerge.isConfigured(configJSON: nil) {
        failures.append("isConfigured(nil): must be false")
    }
    if DesktopConfigMerge.isConfigured(configJSON: existing) {
        failures.append("isConfigured: stale entry without --mcp-stdio must be false")
    }

    return failures
}
