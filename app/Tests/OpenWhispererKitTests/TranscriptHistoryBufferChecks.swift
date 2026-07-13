import OpenWhispererKit

/// Checks for `TranscriptHistoryBuffer` — the session-only history behind the menubar
/// dropdown's "Recent Transcriptions" section. Cap and order here MUST match what the
/// menu assumes (50 kept, newest first, 50-char labels).
func transcriptHistoryBufferFailures() -> [String] {
    var failures: [String] = []

    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("TranscriptHistoryBuffer.\(name): \(detail)") }
    }

    // Newest first.
    var buf = TranscriptHistoryBuffer()
    buf.append("first")
    buf.append("second")
    expect(buf.items == ["second", "first"], "newestFirst", "got \(buf.items)")

    // Stored text is trimmed.
    buf = TranscriptHistoryBuffer()
    buf.append("  hello \n")
    expect(buf.items == ["hello"], "trims", "got \(buf.items)")

    // Empty / whitespace-only input is ignored.
    buf = TranscriptHistoryBuffer()
    buf.append("")
    buf.append("   \n\t")
    expect(buf.items.isEmpty, "ignoresEmpty", "got \(buf.items)")

    // Cap: 55 appends keep the 50 newest.
    buf = TranscriptHistoryBuffer()
    for i in 1...55 { buf.append("entry \(i)") }
    expect(buf.items.count == 50, "capCount", "got \(buf.items.count)")
    expect(buf.items.first == "entry 55", "capNewest", "got \(buf.items.first ?? "nil")")
    expect(buf.items.last == "entry 6", "capOldest", "got \(buf.items.last ?? "nil")")

    // Clear empties.
    buf.clear()
    expect(buf.items.isEmpty, "clear", "got \(buf.items)")

    // menuLabel: short and exactly-at-limit strings pass through unchanged.
    let fifty = String(repeating: "a", count: 50)
    expect(TranscriptHistoryBuffer.menuLabel("hi") == "hi", "labelShort",
           "got \(TranscriptHistoryBuffer.menuLabel("hi"))")
    expect(TranscriptHistoryBuffer.menuLabel(fifty) == fifty, "labelAtLimit",
           "got \(TranscriptHistoryBuffer.menuLabel(fifty))")

    // menuLabel: one over the limit → 49 chars + ellipsis (50 total).
    let fiftyOne = String(repeating: "a", count: 51)
    let truncated = TranscriptHistoryBuffer.menuLabel(fiftyOne)
    expect(truncated == String(repeating: "a", count: 49) + "…", "labelTruncates", "got \(truncated)")
    expect(truncated.count == 50, "labelTruncatedCount", "got \(truncated.count)")

    // menuLabel: newlines (incl. CRLF) collapse to single spaces; result is trimmed.
    expect(TranscriptHistoryBuffer.menuLabel("a\nb\r\nc\r") == "a b c", "labelNewlines",
           "got \(TranscriptHistoryBuffer.menuLabel("a\nb\r\nc\r"))")

    // menuLabel: truncation counts grapheme clusters — a multi-scalar emoji never splits.
    let family = String(repeating: "👨‍👩‍👧‍👦", count: 60)
    let emojiLabel = TranscriptHistoryBuffer.menuLabel(family)
    expect(emojiLabel.count == 50, "labelEmojiCount", "got \(emojiLabel.count)")
    expect(emojiLabel == String(repeating: "👨‍👩‍👧‍👦", count: 49) + "…", "labelEmojiBoundary",
           "truncation split a grapheme cluster")

    return failures
}
