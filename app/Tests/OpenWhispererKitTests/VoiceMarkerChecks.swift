import OpenWhispererKit

/// Checks for `VoiceMarker` — the MCP-tier leading dictation marker.
func voiceMarkerFailures() -> [String] {
    var failures: [String] = []

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

    // The glyph is a bare, single-scalar U+1F399 STUDIO MICROPHONE.
    if VoiceMarker.glyph != "\u{1F399}" {
        failures.append("VoiceMarker.glyph: unexpected text, got '\(VoiceMarker.glyph)'")
    }

    // apply prepends the glyph for targets; passes through unchanged otherwise.
    if VoiceMarker.apply("hello", bundleID: "com.anthropic.claudefordesktop") != "\u{1F399} hello" {
        failures.append("VoiceMarker.apply: glyph not applied for Claude Desktop")
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
