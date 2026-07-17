import Foundation

/// The MCP-tier dictation marker. Apps with no hook system (Claude Desktop) get voice-gating
/// from a leading "🎙 speak" typed with the transcript: the MCP server's standing instruction
/// (`MCPInstructions`) tells the model to call `speak` first when the latest user message
/// begins with it. The word exists because Claude Desktop loads MCP tools lazily by
/// relevance-matching the user message — a bare glyph never triggers the load, but "speak"
/// matches the speak tool. Only allowlisted bundles get the marker — a terminal's frontmost
/// app tells us nothing about whether an agent, a shell, or vim has focus, so CLI hosts must
/// never be listed (see docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md).
public enum VoiceMarker {
    /// U+1F399 STUDIO MICROPHONE, bare — text presentation (monochrome) where honored.
    public static let glyph = "\u{1F399}"

    /// The full typed marker: the glyph plus the word that trips Claude Desktop's
    /// on-demand tool matcher ("speak" matches the speak tool).
    public static let phrase = "\(glyph) speak"

    /// Bundle IDs whose dictations are marked (the MCP tier).
    public static let targetBundleIDs: Set<String> = ["com.anthropic.claudefordesktop"]

    public static func shouldMark(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return targetBundleIDs.contains(bundleID)
    }

    /// Prepend the marker for MCP-tier targets; return the text unchanged otherwise.
    /// Empty text always passes through — a collapsed transcript must not become a bare marker.
    public static func apply(_ text: String, bundleID: String?) -> String {
        guard !text.isEmpty else { return text }
        return shouldMark(bundleID: bundleID) ? "\(phrase) \(text)" : text
    }
}
