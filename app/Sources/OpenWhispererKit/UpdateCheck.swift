import Foundation

/// A dotted numeric version: "2.0.8", "v2.1", "2.0.10". Compared numerically per component,
/// missing components as zero — so 2.0.10 > 2.0.9 and 2.1 == 2.1.0, which plain string
/// comparison gets wrong.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// nil for anything that isn't 1–4 non-negative integers joined by dots (an optional
    /// leading "v" is allowed). Pre-release tags ("2.1.0-beta") are rejected on purpose: the
    /// check must never offer one.
    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            out.append(n)
        }
        components = out
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A published release worth offering.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    /// The release page. Built from the validated version — never taken from the response's
    /// `html_url` — so whatever the API returns, the app can only ever open this repo's page.
    public let pageURL: URL
}

/// Pure decisions behind the once-a-day "is there a newer OpenWhisperer?" check.
///
/// Why it exists: the app is distributed as a DMG with no updater, so nobody who installed a
/// release ever heard about the next one. Deliberately minimal: it asks GitHub for the latest
/// release's version and offers its page; it never downloads or installs (an unsigned build
/// replaced in place would drop the Accessibility grant anyway — see README, First launch).
public enum UpdateCheck {
    public static let repo = "PerIPan/OpenWhisperer"
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    /// How often to ask. GitHub's unauthenticated limit is 60 requests an hour per IP.
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func releasePage(for version: AppVersion) -> URL {
        URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")!
    }

    /// Parse a `releases/latest` response. nil for a draft, a prerelease, or a tag that isn't a
    /// plain version — `releases/latest` excludes both already, this is belt and braces.
    public static func parseLatest(_ data: Data) -> ReleaseInfo? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              (json["draft"] as? Bool) != true,
              (json["prerelease"] as? Bool) != true,
              let version = AppVersion(tag) else { return nil }
        return ReleaseInfo(version: version, pageURL: releasePage(for: version))
    }

    /// The release to offer, or nil when `current` is up to date (or either side won't parse —
    /// a check that can't compare must stay quiet rather than nag).
    public static func available(current: String, latest: ReleaseInfo?) -> ReleaseInfo? {
        guard let latest, let mine = AppVersion(current), mine < latest.version else { return nil }
        return latest
    }

    /// Due when never checked, when a day has passed, or when the clock went backwards.
    public static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        let elapsed = now.timeIntervalSince(lastChecked)
        return elapsed >= interval || elapsed < 0
    }

    /// The on-disk memo: unix time of the last successful check, then the latest tag seen, so
    /// a relaunch inside the day can still show the offer without asking again.
    public static func memo(checkedAt: Date, latest: ReleaseInfo?) -> String {
        "\(Int(checkedAt.timeIntervalSince1970))\n\(latest.map { "v\($0.version)" } ?? "")\n"
    }

    public static func parseMemo(_ raw: String?) -> (checkedAt: Date?, latest: ReleaseInfo?) {
        guard let raw else { return (nil, nil) }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let checked = lines.first.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
        let latest = lines.count > 1 ? AppVersion(lines[1]).map { ReleaseInfo(version: $0, pageURL: releasePage(for: $0)) } : nil
        return (checked, latest)
    }
}
