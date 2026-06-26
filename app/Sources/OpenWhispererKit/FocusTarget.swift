import Foundation

/// How a saved auto-focus target string is interpreted.
///
/// The `auto_focus_app` flat file holds one of two forms:
/// - `bundleid:<id>` — an app chosen from the installed-apps picker (matched by
///   `bundleIdentifier`).
/// - a bare display name — a curated favorite or a custom-typed name (matched by
///   `localizedName`). This is also the legacy format, so old values keep working.
///
/// Centralized here (instead of an inline `contains(".")` guess scattered across
/// the UI and the resolver) so the contract has one tested source of truth.
public enum FocusTarget: Equatable {
    case bundleID(String)
    case name(String)

    public static let bundleIDPrefix = "bundleid:"

    /// Classify a stored `auto_focus_app` value.
    public static func parse(_ stored: String) -> FocusTarget {
        if stored.hasPrefix(bundleIDPrefix) {
            return .bundleID(String(stored.dropFirst(bundleIDPrefix.count)))
        }
        return .name(stored)
    }

    /// The string to persist for an installed-app pick.
    public static func tag(bundleID: String) -> String {
        bundleIDPrefix + bundleID
    }
}
