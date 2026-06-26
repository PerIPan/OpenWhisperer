import Foundation

/// A pickable application: bundle identifier + Finder display name.
///
/// Pure value type shared by the installed-apps scanner (app target) and the
/// searchable Automation picker. It lives in `OpenWhispererKit` so the match
/// logic stays unit-testable under Command Line Tools (no AppKit needed).
public struct AppEntry: Equatable, Hashable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Case-insensitive substring search over a list of `AppEntry`, for the
/// type-to-find Automation app picker.
public enum AppFilter {
    /// Returns entries whose display name (or, as a fallback, bundle id)
    /// contains `query`, preserving input order. An empty/whitespace query
    /// returns the list unchanged.
    public static func match(_ entries: [AppEntry], query: String) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
    }
}
