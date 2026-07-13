import Foundation
import CoreGraphics

/// Pure geometry for the notch status indicator band. Computes, from a screen's
/// metrics, where the band's panel sits and how wide the visible black band is in
/// each state. Lives in OpenWhispererKit so the math is unit-testable under CLT;
/// `NotchIndicator` (app target) feeds it real NSScreen values.
public struct NotchGeometry {
    /// The subset of NSScreen the geometry needs, as plain values.
    public struct ScreenMetrics {
        public let frame: CGRect
        public let safeAreaTop: CGFloat
        public let auxiliaryLeftWidth: CGFloat?
        public let auxiliaryRightWidth: CGFloat?
        public let menuBarThickness: CGFloat

        public init(frame: CGRect, safeAreaTop: CGFloat, auxiliaryLeftWidth: CGFloat?,
                    auxiliaryRightWidth: CGFloat?, menuBarThickness: CGFloat) {
            self.frame = frame
            self.safeAreaTop = safeAreaTop
            self.auxiliaryLeftWidth = auxiliaryLeftWidth
            self.auxiliaryRightWidth = auxiliaryRightWidth
            self.menuBarThickness = menuBarThickness
        }
    }

    /// Width of the synthesized notch on screens without one — a physical notch's
    /// footprint, so states render identically everywhere.
    public static let fakeNotchWidth: CGFloat = 200
    /// Wing width flanking the notch: collapsed (idle dot) vs expanded (waveform).
    public static let idleWingWidth: CGFloat = 16
    public static let activeWingWidth: CGFloat = 72
    /// Window strip below the band reserved for the hover flyout.
    public static let flyoutHeight: CGFloat = 30

    public let hasNotch: Bool
    public let bandHeight: CGFloat
    /// The notch's rect in global (AppKit, bottom-left-origin) screen coordinates.
    /// On non-notch screens this is the synthesized top-center rect.
    public let notchRect: CGRect

    public init(metrics: ScreenMetrics) {
        let notched = metrics.safeAreaTop > 0
            && metrics.auxiliaryLeftWidth != nil && metrics.auxiliaryRightWidth != nil
        hasNotch = notched
        bandHeight = metrics.safeAreaTop > 0 ? metrics.safeAreaTop : metrics.menuBarThickness
        let width: CGFloat
        if notched, let left = metrics.auxiliaryLeftWidth, let right = metrics.auxiliaryRightWidth {
            width = metrics.frame.width - left - right
        } else {
            width = Self.fakeNotchWidth
        }
        notchRect = CGRect(
            x: metrics.frame.midX - width / 2,
            y: metrics.frame.maxY - bandHeight,
            width: width,
            height: bandHeight
        )
    }

    /// The panel's frame in global coordinates: the notch plus a fully-expanded wing
    /// on each side, plus the flyout strip below. The panel never resizes; the view
    /// animates the visible band width inside it.
    public func windowFrame() -> CGRect {
        CGRect(
            x: notchRect.minX - Self.activeWingWidth,
            y: notchRect.minY - Self.flyoutHeight,
            width: notchRect.width + Self.activeWingWidth * 2,
            height: bandHeight + Self.flyoutHeight
        )
    }

    /// Visible black band width (notch + symmetric wings) for the view to draw.
    public func bandWidth(expanded: Bool) -> CGFloat {
        notchRect.width + (expanded ? Self.activeWingWidth : Self.idleWingWidth) * 2
    }
}
