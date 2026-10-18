import Foundation

/// The README's download link must name the version `Info.plist` ships.
///
/// It drifted once: 2.0.7 shipped with the README's Install link, its `xattr` example and its
/// build-output line all still saying 2.0.6, so anyone arriving from GitHub downloaded the
/// previous release (the site was right; only the README was stale). A version bump now fails
/// this check until every DMG name and release URL in the README follows it.
///
/// Version-agnostic wording (`OpenWhisperer-<version>.dmg`) is ignored on purpose — only a
/// concrete `X.Y.Z` can go stale.
func readmeVersionFailures() -> [String] {
    var failures: [String] = []

    let plistPath = Hook.repoRoot.appendingPathComponent("app/Resources/Info.plist")
    let readmePath = Hook.repoRoot.appendingPathComponent("README.md")
    guard let plist = try? String(contentsOf: plistPath, encoding: .utf8) else {
        return ["Info.plist could not be read at \(plistPath.path)"]
    }
    guard let readme = try? String(contentsOf: readmePath, encoding: .utf8) else {
        return ["README.md could not be read at \(readmePath.path)"]
    }

    func plistValue(_ key: String) -> String? {
        let pattern = "<key>\(key)</key>\\s*<string>([^<]+)</string>"
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let m = regex.firstMatch(in: plist, range: NSRange(plist.startIndex..., in: plist)),
              let r = Range(m.range(at: 1), in: plist) else { return nil }
        return String(plist[r])
    }

    guard let shortVersion = plistValue("CFBundleShortVersionString") else {
        return ["Info.plist: CFBundleShortVersionString not found"]
    }
    // AGENTS.md: the two keys move together; build-dmg.sh names the DMG from the short one.
    if let build = plistValue("CFBundleVersion"), build != shortVersion {
        failures.append("Info.plist: CFBundleVersion \(build) != CFBundleShortVersionString \(shortVersion) — bump both together")
    }

    // Every concrete version the README attaches to a DMG name or to this repo's release URL.
    let patterns = [
        #"OpenWhisperer-(\d+\.\d+\.\d+)\.dmg"#,
        #"PerIPan/OpenWhisperer/releases/download/v(\d+\.\d+\.\d+)/"#,
    ]
    var seen = 0
    for pattern in patterns {
        let regex = try! NSRegularExpression(pattern: pattern)
        for m in regex.matches(in: readme, range: NSRange(readme.startIndex..., in: readme)) {
            guard let r = Range(m.range(at: 1), in: readme), let whole = Range(m.range, in: readme) else { continue }
            seen += 1
            let version = String(readme[r])
            if version != shortVersion {
                let line = readme[..<whole.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                failures.append("README.md:\(line): `\(readme[whole])` says \(version), but Info.plist ships \(shortVersion)")
            }
        }
    }
    if seen == 0 {
        failures.append("README.md: no versioned download link found — the Install section lost its DMG link")
    }
    return failures
}
