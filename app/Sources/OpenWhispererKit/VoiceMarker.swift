import Foundation

/// The MCP-tier dictation marker. Apps with no hook system (Claude Desktop) get voice-gating
/// from a leading bare glyph plus a trailing trigger line: the MCP server's standing
/// instruction (`MCPInstructions`) tells the model to call `speak` first when the latest user
/// message begins with the glyph. Only allowlisted bundles get marked — a terminal's frontmost
/// app tells us nothing about whether an agent, a shell, or vim has focus, so CLI hosts must
/// never be listed (see docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md).
///
/// The leading bare glyph is the voice marker — the standing instruction keys on it, and it's
/// treated as invisible (never mentioned in the model's written reply). The trailing trigger
/// line is a separate, terse concern: Claude Desktop loads MCP tool descriptions lazily and
/// discards `initialize.instructions`, so a cold chat needs *something* in the transcript that
/// relevance-matches and fires tool discovery. A direct first-person ask naming the connector —
/// "Use OpenWhisperer." — live-validated as the shortest line that clears Desktop's three gates
/// (lazy tool loading, ask-hedging, injection-wariness); see the spec's Live findings. A
/// "first-dictation-per-chat-only" trigger (skip it once tools are already loaded) is parked
/// pending a reliable chat-boundary signal. Both lines are typed via the existing insertion
/// tiers; if a composer ever treats an injected "\n" as submit, the separator needs revisiting.
public enum VoiceMarker {
    /// U+1F399 STUDIO MICROPHONE, bare — text presentation (monochrome) where honored.
    public static let glyph = "\u{1F399}"

    /// The trailing trigger line appended to marked transcripts, on its own paragraph. A
    /// terse, direct first-person ask naming the connector — the shortest wording that
    /// live-validated through Desktop's tool-loading, ask-hedging, and injection-wariness gates.
    public static let trigger = "Use OpenWhisperer."

    /// Bundle IDs whose dictations are marked (the MCP tier).
    public static let targetBundleIDs: Set<String> = ["com.anthropic.claudefordesktop"]

    public static func shouldMark(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return targetBundleIDs.contains(bundleID)
    }

    /// Prefix the leading glyph and append the trailing trigger line, on its own paragraph,
    /// for MCP-tier targets; return the text unchanged otherwise. Empty text always passes
    /// through — a collapsed transcript must not become a bare marker.
    public static func apply(_ text: String, bundleID: String?) -> String {
        guard !text.isEmpty else { return text }
        return shouldMark(bundleID: bundleID) ? "\(glyph) \(text)\n\n\(trigger)" : text
    }
}
