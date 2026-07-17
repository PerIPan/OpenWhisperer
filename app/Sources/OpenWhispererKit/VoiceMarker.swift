import Foundation

/// The MCP-tier dictation marker. Apps with no hook system (Claude Desktop) get voice-gating
/// from a trailing instruction footer appended to the transcript: the MCP server's standing
/// instruction (`MCPInstructions`) tells the model to call `speak` first when the latest user
/// message ends with it. Only allowlisted bundles get the footer — a terminal's frontmost app
/// tells us nothing about whether an agent, a shell, or vim has focus, so CLI hosts must never
/// be listed (see docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md).
///
/// The marker is a trailing footer, not a leading tag, because Claude Desktop guarantees the
/// model sees ONLY the user message on a cold chat: tool descriptions load lazily, and
/// `initialize.instructions` is discarded. The footer both names the `speak` tool (which fires
/// Desktop's tool discovery) and carries the imperative (defeats ask-instead-of-call). It's
/// typed via the existing insertion tiers; if a composer ever treats an injected "\n" as submit,
/// the separator needs revisiting — see the spec's Live findings.
public enum VoiceMarker {
    /// U+1F399 STUDIO MICROPHONE, bare — text presentation (monochrome) where honored.
    public static let glyph = "\u{1F399}"

    /// The trailing instruction footer appended to marked transcripts. Phrased as the user's
    /// own first-person request ("please…") — live testing on Claude Desktop showed the model
    /// refuses third-person embedded instructions as injection-like ("If you actually want me
    /// to speak a reply aloud, say so directly"), but complies once the footer reads as a
    /// direct ask.
    public static let footer = "\(glyph) dictated — please reply aloud first using the OpenWhisperer speak tool."

    /// Bundle IDs whose dictations are marked (the MCP tier).
    public static let targetBundleIDs: Set<String> = ["com.anthropic.claudefordesktop"]

    public static func shouldMark(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return targetBundleIDs.contains(bundleID)
    }

    /// Append the footer, on its own paragraph, for MCP-tier targets; return the text
    /// unchanged otherwise. Empty text always passes through — a collapsed transcript must
    /// not become a bare footer.
    public static func apply(_ text: String, bundleID: String?) -> String {
        guard !text.isEmpty else { return text }
        return shouldMark(bundleID: bundleID) ? "\(text)\n\n\(footer)" : text
    }
}
