import OpenWhispererKit

/// Checks for `DesktopSkill` — the bundled Claude Desktop companion skill (SKILL.md).
func desktopSkillFailures() -> [String] {
    var failures: [String] = []

    let md = DesktopSkill.markdown

    if DesktopSkill.name != "openwhisperer-voice" {
        failures.append("DesktopSkill.name: expected 'openwhisperer-voice', got '\(DesktopSkill.name)'")
    }

    let lines = md.split(separator: "\n", omittingEmptySubsequences: false)
    let delimiterCount = lines.filter { $0 == "---" }.count
    if delimiterCount < 2 {
        failures.append("DesktopSkill.markdown: missing frontmatter delimiters ('---')")
    }
    if !md.contains("name: openwhisperer-voice") {
        failures.append("DesktopSkill.markdown: missing 'name: openwhisperer-voice'")
    }
    if !md.contains("\u{1F399}") {
        failures.append("DesktopSkill.markdown: missing the 🎙 glyph")
    }
    if !md.lowercased().contains("never ask") {
        failures.append("DesktopSkill.markdown: missing a 'never ask'-equivalent instruction")
    }
    if !md.contains("speak") {
        failures.append("DesktopSkill.markdown: missing a reference to the speak tool")
    }

    return failures
}
