import Foundation

/// The MCP-tier dictation marker. Apps with no hook system (Claude Desktop) get voice-gating
/// from a trailing signature line: the MCP server's standing instruction (`MCPInstructions`)
/// tells the model to call `speak` first when the latest user message ends with it. Only
/// allowlisted bundles get marked — a terminal's frontmost app tells us nothing about whether
/// an agent, a shell, or vim has focus, so CLI hosts must never be listed (see
/// docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md).
///
/// The signature line is the "Sent from my iPhone" idiom: it pre-reads as an email-style
/// sign-off, so Desktop's injection-wary model has nothing instruction-shaped in the message
/// to refuse. Naming the connector is the discovery anchor — Claude Desktop loads MCP tool
/// descriptions lazily and discards `initialize.instructions`, so a cold chat needs the
/// connector's name in the one channel guaranteed visible, the transcript itself, to fire tool
/// discovery. The standing instruction keys on the signature line and is treated as invisible
/// (never mentioned in the model's written reply). It's typed via the existing insertion
/// tiers; if a composer ever treats an injected "\n" as submit, the separator needs revisiting.
public enum VoiceMarker {
    /// U+1F399 STUDIO MICROPHONE, bare — text presentation (monochrome) where honored.
    public static let glyph = "\u{1F399}"

    /// The trailing signature line appended to marked transcripts, on its own paragraph. Reads
    /// as a sign-off, not an instruction — nothing for an injection-wary model to refuse — while
    /// naming the connector to fire Desktop's lazy tool discovery.
    public static let signature = "\(glyph) Sent with OpenWhisperer."

    /// Bundle IDs whose dictations are marked (the MCP tier).
    public static let targetBundleIDs: Set<String> = ["com.anthropic.claudefordesktop"]

    public static func shouldMark(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return targetBundleIDs.contains(bundleID)
    }

    /// Append the trailing signature line, on its own paragraph, for MCP-tier targets; return
    /// the text unchanged otherwise. Empty text always passes through — a collapsed transcript
    /// must not become a bare marker.
    public static func apply(_ text: String, bundleID: String?) -> String {
        guard !text.isEmpty else { return text }
        return shouldMark(bundleID: bundleID) ? "\(text)\n\n\(signature)" : text
    }
}
