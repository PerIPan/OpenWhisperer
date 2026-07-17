import Foundation

/// The MCP-tier dictation marker. Apps with no hook system (Claude Desktop) get voice-gating
/// from a leading glyph typed with the transcript: the MCP server's standing instruction
/// (`MCPInstructions`) tells the model to call `speak` first when the latest user message
/// begins with it. Only allowlisted bundles get the marker — a terminal's frontmost app tells
/// us nothing about whether an agent, a shell, or vim has focus, so CLI hosts must never be
/// listed (see docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md).
///
/// Owner-final (2026-07-17), after a day of live iteration through worded triggers, a
/// trailing footer, a skill channel (vetoed), and several closing-line variants: the pure
/// leading glyph, nothing else. The known cost is accepted rather than papered over — on a
/// brand-new Desktop chat the model's tools may not be loaded yet, so the first dictated
/// turn can land silent; any message that mentions OpenWhisperer (or asks it to speak) wakes
/// the chat, and every leading-glyph turn after that speaks reliably (see "Live findings" in
/// the spec). The glyph is a surrogate pair typed as the very first chunk of the transcript —
/// minimal exposure to the Electron composer's synthetic-typing chunk-reorder race (see
/// `typeViaUnicodeEvents`).
public enum VoiceMarker {
    /// U+1F399 STUDIO MICROPHONE, bare — text presentation (monochrome) where honored.
    public static let glyph = "\u{1F399}"

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
        return shouldMark(bundleID: bundleID) ? "\(glyph) \(text)" : text
    }
}
