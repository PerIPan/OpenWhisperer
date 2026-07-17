import OpenWhispererKit

/// Checks for `VoiceMarker` — the MCP-tier trailing dictation marker.
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

    // The marker is an exact-match trailing line.
    if VoiceMarker.marker != "Speak back." {
        failures.append("VoiceMarker.marker: unexpected text, got '\(VoiceMarker.marker)'")
    }

    // apply appends the marker line, on its own paragraph, for targets; passes through
    // unchanged otherwise.
    if VoiceMarker.apply("hello", bundleID: "com.anthropic.claudefordesktop") != "hello\n\nSpeak back." {
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
