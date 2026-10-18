import Foundation

/// The port the in-app TTS / MCP server listens on, and the URL every agent is pointed at.
///
/// It used to be a literal `8000` written into all four agents' configs while Settings →
/// Advanced let you change the port — and didn't persist it. Change it and every agent lost
/// `speak` with no error (until the next relaunch put the server back on 8000). Now the port is
/// stored (`tts_port`) once the server has bound it, and connected agents are re-applied.
public enum TTSPort {
    /// What every pre-2.0.8 config already says; changing it would make every install stale.
    public static let defaultPort = 8000
    /// Unprivileged ports only. MUST stay equal to Settings → Advanced's `PortField` check.
    public static let validRange = 1024...65535

    /// A stored value, or the default for anything missing, malformed or out of range.
    public static func parse(_ raw: String?) -> Int {
        guard let raw, let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              validRange.contains(port) else { return defaultPort }
        return port
    }

    public static func mcpURL(port: Int) -> String { "http://localhost:\(port)/mcp" }
}
