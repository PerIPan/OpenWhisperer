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

    // Unparseable existing content must be refused (fail closed), not silently replaced.
    if DesktopConfigMerge.merged(existingJSON: Data("nonsense".utf8), executablePath: "/p") != nil {
        failures.append("merged(garbage): must refuse (return nil) rather than silently replace")
    }

    // A valid JSON document whose root is not an object (e.g. an array) must also be refused.
    if DesktopConfigMerge.merged(existingJSON: Data("[1,2]".utf8), executablePath: "/p") != nil {
        failures.append("merged(non-object root): must refuse (return nil)")
    }

    // A valid object root whose mcpServers key is present but not a dictionary must be refused.
    let badServers = Data(#"{"mcpServers":"oops"}"#.utf8)
    if DesktopConfigMerge.merged(existingJSON: badServers, executablePath: "/p") != nil {
        failures.append("merged(non-dict mcpServers): must refuse (return nil)")
    }

    // isConfigured: true only when command matches the given executablePath AND args has --mcp-stdio.
    let freshAtP = DesktopConfigMerge.merged(existingJSON: nil, executablePath: "/p")
    if !DesktopConfigMerge.isConfigured(configJSON: freshAtP, executablePath: "/p") {
        failures.append("isConfigured: freshly merged config not recognized")
    }
    if DesktopConfigMerge.isConfigured(configJSON: freshAtP, executablePath: "/other") {
        failures.append("isConfigured: mismatched executablePath must be false")
    }
    if DesktopConfigMerge.isConfigured(configJSON: nil, executablePath: "/p") {
        failures.append("isConfigured(nil): must be false")
    }
    if DesktopConfigMerge.isConfigured(configJSON: existing, executablePath: "/new/path") {
        failures.append("isConfigured: stale entry without --mcp-stdio must be false")
    }
    let missingCommand = Data(#"{"mcpServers":{"OpenWhisperer":{"args":["--mcp-stdio"]}}}"#.utf8)
    if DesktopConfigMerge.isConfigured(configJSON: missingCommand, executablePath: "/p") {
        failures.append("isConfigured: missing command must be false")
    }

    return failures
}
