import OpenWhispererKit

/// Checks for `VoiceMarker` — the MCP-tier leading dictation marker.
func voiceMarkerFailures() -> [String] {
    var failures: [String] = []

    // The glyph is exactly bare U+1F399 (no variation selector).
    if VoiceMarker.glyph != "\u{1F399}" {
        failures.append("VoiceMarker.glyph: expected bare U+1F399, got \(VoiceMarker.glyph.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))")
    }
    if VoiceMarker.glyph.unicodeScalars.count != 1 {
        failures.append("VoiceMarker.glyph: expected a single scalar, got \(VoiceMarker.glyph.unicodeScalars.count)")
    }

    // Claude Desktop is in the v1 allowlist.
    if !VoiceMarker.shouldMark(bundleID: "com.anthropic.claudefordesktop") {
        failures.append("VoiceMarker.shouldMark: Claude Desktop bundle not matched")
    }
    if VoiceMarker.shouldMark(bundleID: nil) {
        failures.append("VoiceMarker.shouldMark: nil bundle must not match")
    }
    if VoiceMarker.shouldMark(bundleID: "com.apple.Terminal") {
        failures.append("VoiceMarker.shouldMark: Terminal must not match (terminal-focus problem)")
    }
    if VoiceMarker.shouldMark(bundleID: "com.tinyspeck.slackmacgap") {
        failures.append("VoiceMarker.shouldMark: Slack must not match")
    }

    // The trigger is an exact-match trailing line naming the connector.
    if VoiceMarker.trigger != "Use OpenWhisperer." {
        failures.append("VoiceMarker.trigger: unexpected text, got '\(VoiceMarker.trigger)'")
    }

    // apply prefixes the leading glyph and appends the trigger, on its own paragraph, for
    // targets; passes through unchanged otherwise.
    if VoiceMarker.apply("hello", bundleID: "com.anthropic.claudefordesktop") != "\u{1F399} hello\n\nUse OpenWhisperer." {
        failures.append("VoiceMarker.apply: marker not applied for Claude Desktop")
    }
    if VoiceMarker.apply("hello", bundleID: "com.apple.Notes") != "hello" {
        failures.append("VoiceMarker.apply: text changed for non-target bundle")
    }
    if VoiceMarker.apply("hello", bundleID: nil) != "hello" {
        failures.append("VoiceMarker.apply: text changed for nil bundle")
    }

    // Empty text must never gain a marker.
    if VoiceMarker.apply("", bundleID: "com.anthropic.claudefordesktop") != "" {
        failures.append("VoiceMarker.apply: empty text must never gain a marker")
    }

    return failures
}
