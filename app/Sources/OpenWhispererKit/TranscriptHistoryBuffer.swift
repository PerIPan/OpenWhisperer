import Foundation

/// Session-only buffer behind the menubar "Recent Transcriptions" section.
/// Pure logic (cap, order, menu-row truncation) so it stays testable under CLT;
/// the app-side `TranscriptionHistory` store owns an instance and feeds SwiftUI.
public struct TranscriptHistoryBuffer {
    /// Entries kept in memory. The menu shows fewer (its choice); the larger cap
    /// matches the old overlay buffer and leaves room for a future "show more".
    public static let maxEntries = 50

    /// Stored transcriptions — newest first, trimmed, full (untruncated) text.
    public private(set) var items: [String] = []

    public init() {}

    /// Prepend a transcription. Whitespace-only input is dropped.
    public mutating func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(trimmed, at: 0)
        if items.count > Self.maxEntries {
            items.removeLast(items.count - Self.maxEntries)
        }
    }

    public mutating func clear() {
        items.removeAll()
    }

    /// Single-line menu-row label: newlines collapse to spaces, the result is trimmed
    /// and tail-truncated to `limit` characters (grapheme clusters, so multi-scalar
    /// emoji never split), the last one an ellipsis.
    public static func menuLabel(_ text: String, limit: Int = 50) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit >= 1, flattened.count > limit else { return flattened }
        return flattened.prefix(limit - 1) + "…"
    }
}
