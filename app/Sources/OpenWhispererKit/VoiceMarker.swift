import Foundation

/// The MCP-tier dictation marker. Apps with no hook system (Claude Desktop) get voice-gating
/// from a trailing marker line: the MCP server's standing instruction (`MCPInstructions`)
/// tells the model to call `speak` first when the latest user message ends with it. Only
/// allowlisted bundles get marked — a terminal's frontmost app tells us nothing about whether
/// an agent, a shell, or vim has focus, so CLI hosts must never be listed (see
/// docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md).
///
/// The marker is a pure-ASCII, two-word imperative: `Speak back.` It names the `speak` tool's
/// exact name — the strongest live-measured discovery anchor for Desktop's lazy tool loading,
/// which loads MCP tool descriptions lazily and discards `initialize.instructions`, so even a
/// partially-delivered fragment of the connector/tool name fires discovery. Imperative wording
/// is the compliance-validated class (declarative sign-offs hedged less reliably in live
/// trials). Two ASCII words keep it tiny: no surrogate pairs, minimal exposure to the
/// Electron composer's synthetic-typing chunk-reorder race (observed live even at 8
/// units/8 ms — see `typeViaUnicodeEvents`). The standing instruction keys on the marker line
/// and treats it as invisible (never mentioned in the model's written reply). It's typed via
/// the existing insertion tiers; if a composer ever treats an injected "\n" as submit, the
/// separator needs revisiting.
public enum VoiceMarker {
    /// The trailing marker line appended to marked transcripts, on its own paragraph. A
    /// pure-ASCII two-word imperative naming the `speak` tool.
    public static let marker = "Speak back."

    /// Bundle IDs whose dictations are marked (the MCP tier).
    public static let targetBundleIDs: Set<String> = ["com.anthropic.claudefordesktop"]

    public static func shouldMark(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return targetBundleIDs.contains(bundleID)
    }

    /// Append the trailing marker line, on its own paragraph, for MCP-tier targets; return
    /// the text unchanged otherwise. Empty text always passes through — a collapsed transcript
    /// must not become a bare marker.
    public static func apply(_ text: String, bundleID: String?) -> String {
        guard !text.isEmpty else { return text }
        return shouldMark(bundleID: bundleID) ? "\(text)\n\n\(marker)" : text
    }
}
