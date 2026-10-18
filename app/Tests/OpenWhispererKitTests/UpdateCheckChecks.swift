import Foundation
import OpenWhispererKit

/// Checks for `AppVersion` and `UpdateCheck` — the once-a-day "newer release?" decision.
func updateCheckFailures() -> [String] {
    var failures: [String] = []
    func v(_ s: String) -> AppVersion? { AppVersion(s) }

    // Numeric, not lexicographic: the classic bug is "2.0.10" < "2.0.9" as strings.
    if !(v("2.0.9")! < v("2.0.10")!) { failures.append("AppVersion: 2.0.9 should be < 2.0.10") }
    if !(v("2.0.7")! < v("2.0.8")!) { failures.append("AppVersion: 2.0.7 should be < 2.0.8") }
    if !(v("2.0.8")! < v("2.1")!) { failures.append("AppVersion: 2.0.8 should be < 2.1") }
    if v("2.1")! != v("2.1.0")! { failures.append("AppVersion: 2.1 should equal 2.1.0") }
    if v("v2.0.8")! != v("2.0.8")! { failures.append("AppVersion: leading v not stripped") }
    if v("2.0.8")!.description != "2.0.8" { failures.append("AppVersion.description round-trip") }
    for bad in ["", "v", "2..1", "2.0.8-beta", "2.0.8 ", "x.y", "1.2.3.4.5", "２.0"] where v(bad) != nil && bad != "2.0.8 " {
        failures.append("AppVersion(\(bad.debugDescription)) should be nil")
    }
    if v("2.0.8 ") == nil { failures.append("AppVersion: surrounding whitespace should be trimmed") }

    // parseLatest — a real releases/latest shape, trimmed.
    let ok = Data(#"{"tag_name":"v2.0.8","html_url":"https://evil.example/x","draft":false,"prerelease":false}"#.utf8)
    if let r = UpdateCheck.parseLatest(ok) {
        if r.version != v("2.0.8")! { failures.append("parseLatest: wrong version") }
        // The page comes from the tag, never from html_url.
        if r.pageURL.absoluteString != "https://github.com/PerIPan/OpenWhisperer/releases/tag/v2.0.8" {
            failures.append("parseLatest: pageURL must be built from the tag, got \(r.pageURL)")
        }
    } else { failures.append("parseLatest: valid response rejected") }
    for (name, body) in [
        ("prerelease", #"{"tag_name":"v2.1.0","prerelease":true}"#),
        ("draft", #"{"tag_name":"v2.1.0","draft":true}"#),
        ("bad tag", #"{"tag_name":"nightly"}"#),
        ("no tag", #"{"message":"API rate limit exceeded"}"#),
        ("not json", "<html>"),
    ] where UpdateCheck.parseLatest(Data(body.utf8)) != nil {
        failures.append("parseLatest(\(name)): should be nil")
    }

    // available — offer only a strictly newer release.
    let latest = UpdateCheck.parseLatest(ok)
    if UpdateCheck.available(current: "2.0.7", latest: latest) == nil { failures.append("available: 2.0.7 vs 2.0.8 should offer") }
    if UpdateCheck.available(current: "2.0.8", latest: latest) != nil { failures.append("available: same version must not offer") }
    if UpdateCheck.available(current: "2.1.0", latest: latest) != nil { failures.append("available: newer local build must not offer a downgrade") }
    if UpdateCheck.available(current: "garbage", latest: latest) != nil { failures.append("available: unparseable current must stay quiet") }
    if UpdateCheck.available(current: "2.0.7", latest: nil) != nil { failures.append("available: no latest must stay quiet") }

    // isDue — daily, and a backwards clock doesn't silence it forever.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    if !UpdateCheck.isDue(lastChecked: nil, now: now) { failures.append("isDue: never checked should be due") }
    if UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-3600), now: now) { failures.append("isDue: 1 h ago should not be due") }
    if !UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-UpdateCheck.interval), now: now) { failures.append("isDue: 24 h ago should be due") }
    if !UpdateCheck.isDue(lastChecked: now.addingTimeInterval(3600), now: now) { failures.append("isDue: a future timestamp (clock went back) should be due") }

    // memo round-trip — a relaunch inside the day keeps the offer without asking again.
    let memo = UpdateCheck.memo(checkedAt: now, latest: latest)
    let back = UpdateCheck.parseMemo(memo)
    if back.checkedAt != now { failures.append("memo: checkedAt didn't round-trip") }
    if back.latest != latest { failures.append("memo: latest didn't round-trip") }
    let empty = UpdateCheck.parseMemo(UpdateCheck.memo(checkedAt: now, latest: nil))
    if empty.latest != nil || empty.checkedAt != now { failures.append("memo: no-latest round-trip") }
    if UpdateCheck.parseMemo(nil).checkedAt != nil { failures.append("memo: missing file should read as never checked") }
    if UpdateCheck.parseMemo("junk").checkedAt != nil { failures.append("memo: junk should read as never checked") }

    return failures
}
