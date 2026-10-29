import Foundation

/// One-shot migration helper: removes the legacy `## Voice Mode` block that the
/// app used to inject into CLAUDE.md / AGENTS.md. Pure so it is unit-tested.
public enum VoiceMigration {
    /// 2.1: the `tts_voice` value to write so someone on Kokoro's af_heart moves to Heart on Pocket
    /// TTS — the same voice, cloned (owner, 2026-10-29: "yes move them to Heart"); nil to leave the
    /// file alone. Only af_heart moves: every other voice was a deliberate choice of something else,
    /// and an unset voice already means Heart. Runs once (the app keeps a marker), so choosing
    /// "Heart (Kokoro)" again afterwards sticks.
    public static func pocketHeart(current: String?) -> String? {
        current?.trimmingCharacters(in: .whitespacesAndNewlines) == TTSVoiceRouter.defaultKokoroVoice
            ? TTSVoiceRouter.defaultVoice : nil
    }


    /// Remove the `## Voice Mode` section (header through the next `## ` or EOF),
    /// then strip trailing blank lines.
    public static func stripVoiceBlock(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var skipping = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("## Voice Mode") {
                skipping = true
                continue
            }
            if skipping && line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") {
                skipping = false
            }
            if !skipping { result.append(line) }
        }
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }
}
