import Foundation
import OpenWhispererKit

/// Checks for `NotchGeometry` — the pure band/window math behind the notch status
/// indicator. The notched case uses real 14" MacBook Pro numbers.
func notchGeometryFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("NotchGeometry.\(name): \(detail)") }
    }

    // Notched screen: 3456×2234 with a 180pt notch (auxiliary areas 1638pt each), 32pt tall.
    let notched = NotchGeometry(metrics: .init(
        frame: CGRect(x: 0, y: 0, width: 3456, height: 2234),
        safeAreaTop: 32, auxiliaryLeftWidth: 1638, auxiliaryRightWidth: 1638,
        menuBarThickness: 24))
    expect(notched.hasNotch, "hasNotch", "expected true")
    expect(notched.bandHeight == 32, "bandHeight", "got \(notched.bandHeight)")
    expect(notched.notchRect == CGRect(x: 1638, y: 2202, width: 180, height: 32),
           "notchRect", "got \(notched.notchRect)")

    // Window frame: fully-expanded wings both sides + flyout strip below; contains the notch.
    let frame = notched.windowFrame()
    expect(frame == CGRect(x: 1638 - NotchGeometry.activeWingWidth,
                           y: 2202 - NotchGeometry.flyoutHeight,
                           width: 180 + NotchGeometry.activeWingWidth * 2,
                           height: 32 + NotchGeometry.flyoutHeight),
           "windowFrame", "got \(frame)")
    expect(frame.contains(notched.notchRect), "windowContainsNotch", "got \(frame)")

    // Non-notch screen at an offset origin (external): fake notch centered in ITS frame.
    let external = NotchGeometry(metrics: .init(
        frame: CGRect(x: 3456, y: 500, width: 5120, height: 2880),
        safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
        menuBarThickness: 24))
    expect(!external.hasNotch, "noNotch", "expected false")
    expect(external.bandHeight == 24, "fallbackHeight", "got \(external.bandHeight)")
    expect(external.notchRect.width == NotchGeometry.fakeNotchWidth, "fakeWidth",
           "got \(external.notchRect.width)")
    expect(external.notchRect.midX == 3456 + 5120 / 2, "fakeCenteredX",
           "got \(external.notchRect.midX)")
    expect(external.notchRect.maxY == 500 + 2880, "fakeFlushTop",
           "got \(external.notchRect.maxY)")

    // Degenerate: safe-area top without auxiliary areas → treated as no notch, but the
    // band keeps the safe-area height so it never overlaps content below the camera housing.
    let odd = NotchGeometry(metrics: .init(
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        safeAreaTop: 30, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
        menuBarThickness: 24))
    expect(!odd.hasNotch, "degenerateNoNotch", "expected false")
    expect(odd.bandHeight == 30, "degenerateHeight", "got \(odd.bandHeight)")
    expect(odd.notchRect.width == NotchGeometry.fakeNotchWidth, "degenerateFakeWidth",
           "got \(odd.notchRect.width)")

    // Band widths: notch + symmetric wings; expanded strictly wider than idle.
    expect(notched.bandWidth(expanded: true) == 180 + NotchGeometry.activeWingWidth * 2,
           "expandedWidth", "got \(notched.bandWidth(expanded: true))")
    expect(notched.bandWidth(expanded: false) == 180 + NotchGeometry.idleWingWidth * 2,
           "idleWidth", "got \(notched.bandWidth(expanded: false))")
    expect(notched.bandWidth(expanded: true) > notched.bandWidth(expanded: false),
           "widthMonotonic", "expanded must exceed idle")

    return failures
}
