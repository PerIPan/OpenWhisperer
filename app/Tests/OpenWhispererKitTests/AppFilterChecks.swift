import OpenWhispererKit

/// Checks for `AppFilter.match` — the searchable Automation app-picker filter.
/// Returns a list of human-readable failures (empty = all passed).
func appFilterFailures() -> [String] {
    var failures: [String] = []

    let apps = [
        AppEntry(bundleID: "com.microsoft.Word", name: "Microsoft Word"),
        AppEntry(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        AppEntry(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        AppEntry(bundleID: "com.apple.Notes", name: "Notes"),
    ]

    func expectIDs(_ query: String, _ expected: [String], _ name: String) {
        let got = AppFilter.match(apps, query: query).map { $0.bundleID }
        if got != expected {
            failures.append("AppFilter.\(name): match(\(query.debugDescription)) -> \(got); expected \(expected)")
        }
    }

    expectIDs("", apps.map { $0.bundleID }, "emptyReturnsAll")
    expectIDs("   ", apps.map { $0.bundleID }, "whitespaceReturnsAll")
    expectIDs("wo", ["com.microsoft.Word"], "nameSubstring")
    expectIDs("WHATS", ["net.whatsapp.WhatsApp"], "caseInsensitive")
    expectIDs("slack", ["com.tinyspeck.slackmacgap"], "byName")
    expectIDs("tinyspeck", ["com.tinyspeck.slackmacgap"], "byBundleIDFallback")
    expectIDs("zzz", [], "noMatch")
    // "app" hits WhatsApp (name) and Notes (bundle id "com.apple.Notes"); order preserved.
    expectIDs("app", ["net.whatsapp.WhatsApp", "com.apple.Notes"], "multiPreservesOrder")

    return failures
}
