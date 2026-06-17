import Foundation

/// One-shot migration helper: removes the legacy `## Voice Mode` block that the
/// app used to inject into CLAUDE.md / AGENTS.md. Pure so it is unit-tested.
public enum VoiceMigration {

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
