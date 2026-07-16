import Foundation
import OpenWhispererKit

/// Checks for `OverlaySize` — parse/clamp/format of the overlay's persisted
/// window size pref ("220x84").
func overlaySizeFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("OverlaySize.\(name): \(detail)") }
    }

    let parsed = OverlaySize.parse("300x120")
    expect(parsed.width == 300 && parsed.height == 120, "parse", "got \(parsed.fileValue)")

    let trimmed = OverlaySize.parse(" 300x120\n")
    expect(trimmed.width == 300 && trimmed.height == 120, "trims", "got \(trimmed.fileValue)")

    let def = OverlaySize.parse(nil)
    expect(def.width == 220 && def.height == 84, "nilDefault", "got \(def.fileValue)")
    expect(OverlaySize.parse("garbage") == OverlaySize.defaultSize, "garbageDefault",
           "got \(OverlaySize.parse("garbage").fileValue)")
    expect(OverlaySize.parse("300x") == OverlaySize.defaultSize, "partialDefault",
           "got \(OverlaySize.parse("300x").fileValue)")

    let low = OverlaySize.parse("100x40")
    expect(low.width == 180 && low.height == 64, "clampLow", "got \(low.fileValue)")
    let high = OverlaySize.parse("2000x900")
    expect(high.width == 800 && high.height == 400, "clampHigh", "got \(high.fileValue)")
    let mixed = OverlaySize.parse("100x120")
    expect(mixed.width == 180 && mixed.height == 120, "clampIndependent", "got \(mixed.fileValue)")

    expect(def.fileValue == "220x84", "fileValue", "got \(def.fileValue)")
    let roundTrip = OverlaySize.parse(OverlaySize.parse("300x120").fileValue)
    expect(roundTrip.width == 300 && roundTrip.height == 120, "roundTrip", "got \(roundTrip.fileValue)")

    return failures
}
