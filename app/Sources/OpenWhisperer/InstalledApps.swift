import Foundation
import OpenWhispererKit

/// Enumerates user-launchable apps from the standard application directories so
/// the Automation picker can offer "any installed app" (Word, WhatsApp, Slack, …)
/// alongside the curated dev/terminal favorites.
///
/// Synchronous and cheap (a few hundred bundles at most). The result is cached
/// for the process — apps installed mid-session appear after a relaunch, which
/// is an acceptable trade for an instant second open.
enum InstalledApps {
    private static let searchDirs: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
    ]

    /// All installed apps as `(bundleID, display name)`, de-duplicated by bundle
    /// id and sorted by localized name. Scanned once per process — Swift guarantees
    /// the `static let` initializer runs exactly once and thread-safely, so this is
    /// safe to call from any queue (no manual locking).
    static func all() -> [AppEntry] { cache }

    private static let cache: [AppEntry] = scan()

    private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var apps: [AppEntry] = []
        for dir in searchDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(entry)
                guard let bundle = Bundle(path: path),
                      let bid = bundle.bundleIdentifier,
                      !seen.contains(bid) else { continue }
                seen.insert(bid)
                var name = fm.displayName(atPath: path)
                if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                apps.append(AppEntry(bundleID: bid, name: name))
            }
        }
        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
