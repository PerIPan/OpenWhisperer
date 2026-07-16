import Foundation
import OpenWhispererKit

/// Checks for `OverlayStyle` — the overlay analyzer-style pref (led_bars/graph/curtain).
func overlayStyleFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("OverlayStyle.\(name): \(detail)") }
    }

    expect(OverlayStyle.parse("led_bars") == .ledBars, "parseLed", "got \(OverlayStyle.parse("led_bars"))")
    expect(OverlayStyle.parse("graph") == .graph, "parseGraph", "got \(OverlayStyle.parse("graph"))")
    expect(OverlayStyle.parse("curtain") == .curtain, "parseCurtain", "got \(OverlayStyle.parse("curtain"))")
    expect(OverlayStyle.parse(" curtain\n") == .curtain, "trims", "got \(OverlayStyle.parse(" curtain\n"))")
    expect(OverlayStyle.parse(nil) == .ledBars, "nilDefault", "got \(OverlayStyle.parse(nil))")
    expect(OverlayStyle.parse("vintage") == .ledBars, "garbageDefault", "got \(OverlayStyle.parse("vintage"))")
    expect(OverlayStyle.parse("") == .ledBars, "emptyDefault", "got \(OverlayStyle.parse(""))")
    expect(OverlayStyle.defaultStyle == .ledBars, "default", "got \(OverlayStyle.defaultStyle)")
    return failures
}
