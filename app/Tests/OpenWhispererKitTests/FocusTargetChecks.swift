import OpenWhispererKit

/// Checks for `FocusTarget` — the auto-focus saved-value classifier.
func focusTargetFailures() -> [String] {
    var failures: [String] = []

    func expect(_ stored: String, _ expected: FocusTarget, _ name: String) {
        let got = FocusTarget.parse(stored)
        if got != expected {
            failures.append("FocusTarget.\(name): parse(\(stored.debugDescription)) -> \(got); expected \(expected)")
        }
    }

    // Installed-app picks are tagged.
    expect("bundleid:com.microsoft.Word", .bundleID("com.microsoft.Word"), "taggedBundleID")
    expect("bundleid:net.whatsapp.WhatsApp", .bundleID("net.whatsapp.WhatsApp"), "taggedBundleID2")
    // Favorites + custom + legacy values are bare names (never misread as bundle ids).
    expect("Code", .name("Code"), "favoriteName")
    expect("Microsoft Word", .name("Microsoft Word"), "customName")
    expect("Code - Insiders", .name("Code - Insiders"), "nameWithDash")
    expect("My.App", .name("My.App"), "legacyNameWithDot")   // a dot no longer misroutes
    expect("", .name(""), "empty")

    // Round-trip: tag then parse yields the original bundle id.
    let tagged = FocusTarget.tag(bundleID: "com.apple.Notes")
    if FocusTarget.parse(tagged) != .bundleID("com.apple.Notes") {
        failures.append("FocusTarget.roundTrip: tag+parse did not yield com.apple.Notes (tagged=\(tagged))")
    }

    return failures
}
