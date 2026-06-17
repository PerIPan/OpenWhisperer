import Foundation
import CryptoKit

/// Shared, dependency-free helpers for the voice-turn handshake between the
/// dictation app (signal writer) and the Claude Code hooks (signal readers).
///
/// The app records a hash of the exact text it dictated; the UserPromptSubmit
/// hook recomputes the hash of the prompt it receives and, on a match, knows
/// THIS session is the voice turn. Canonicalization lives here (and is unit
/// tested) to guard parity with the bash reader (`shasum -a 256`).
public enum VoiceSignal {

    /// Lowercase-hex SHA-256 of `text` after trimming leading/trailing
    /// whitespace and newlines. MUST match: `printf '%s' "<trimmed>" | shasum -a 256`.
    public static func canonicalHash(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `voice_turn` file body: line 1 = hash, line 2 = unix seconds.
    public static func signalContents(hash: String, timestamp: Int) -> String {
        "\(hash)\n\(timestamp)\n"
    }
}
