import AppKit
import SwiftUI
import CoreText

// MARK: - Color helpers (warm "Open Whisperer" palette from openwhisperer.com)
//
// Tokens are appearance-aware: a light value (the site's cream/gold) and a warm-dark
// value so the menubar popover never shows a bright cream panel against a dark menu bar.

extension NSColor {
    /// Build an opaque sRGB color from a 0xRRGGBB literal.
    fileprivate convenience init(owHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// A dynamic color that resolves to `light` in Aqua and `dark` in Dark Aqua.
    static func ow(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(owHex: isDark ? dark : light)
        }
    }
}

extension Color {
    /// Wrap a dynamic NSColor as a SwiftUI Color (keeps light/dark adaptation).
    static func ow(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: .ow(light, dark))
    }
}

// MARK: - Design tokens

// Warm "Open Whisperer" palette (openwhisperer.com). Tokens are light/dark dynamic —
// via the `Color.ow(light, dark)` helper above. Used by the branded menubar popover
// (MenuBarView) and the transcription overlay.
enum OWColor {
    // Surfaces
    static let page = Color.ow(0xFAF7F1, 0x1E1B16)            // popover / overlay background (cream / warm-dark)
    static let surface = Color.ow(0xFFFFFF, 0x2A2520)          // card surface
    static let cardBackground = surface                        // legacy alias (OWCard)
    // Lines
    static let line = Color.ow(0xDCCFB8, 0x3A332B)             // borders + dividers (deepened for visible cards)
    static let divider = line                                  // legacy alias
    // Text ramp (warm ink → cream)
    static let ink = Color.ow(0x2A2520, 0xF3ECDF)
    static let inkSoft = Color.ow(0x6A6157, 0xB6AC9C)
    static let inkFaint = Color.ow(0x978C7E, 0x877D6F)
    static let muted = inkSoft                                 // legacy alias
    // Accent (gold)
    static let accent = Color.ow(0xC0A06A, 0xCBA86A)
    static let accentDeep = Color.ow(0x98763F, 0xD8B677)
    static let onAccent = Color.ow(0x2A2520, 0x211B12)         // text/icon on a gold fill (WCAG-safe ink)
    static let success = accentDeep                            // "applied" state → deep gold (WCAG-safe as text)
    // Fills
    static let pillFill = Color.ow(0xEADFC8, 0x342D24)
    static let pickerBg = Color.ow(0xF3EBDD, 0x332C23)
    static let pickerBorder = Color.ow(0xE0D4BD, 0x423A30)
    static let checkboxBorder = Color.ow(0xCBBFA9, 0x4A4136)
    static let pillBackground = pillFill                       // legacy alias
    // Status semantics — warm equivalents of system red/amber/green so dots + badges don't
    // clash with the cream/gold palette (the system colors are especially jarring in dark mode).
    static let recording = Color.ow(0xCC3D33, 0xE2675A)        // recording / error
    static let warn = Color.ow(0xB8822E, 0xE0B25C)             // transient / warning
    static let live = Color.ow(0x5E8C4E, 0x86C06A)             // listening / running / ready
    static let danger = recording                             // alias for error states
}

// MARK: - Bundled font registration
//
// Registered as early as possible (App.init) so the custom faces are available before
// SwiftUI composes the first layout pass — otherwise the system fallback gets cached.

// Both call sites (App.init, applicationDidFinishLaunching) run on the main thread, so this
// is never contended; `nonisolated(unsafe)` documents that and silences strict-concurrency.
private nonisolated(unsafe) var owFontsRegistered = false

func registerBundledFonts() {
    guard !owFontsRegistered else { return }
    owFontsRegistered = true
    for resource in ["Outfit-VariableFont_wght", "Fraunces"] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf") else {
            NSLog("OpenWhisperer: bundled font missing: \(resource).ttf")
            continue
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            NSLog("OpenWhisperer: font registration failed for \(resource): \(String(describing: error?.takeRetainedValue()))")
        }
    }
}


/// Tints the popover's window chrome to the warm cream/dark background so the branded
/// MenuBarExtra(.window) has no default material edge. Restored 2026-07-19 with the popover UI.
struct OWWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.backgroundColor = .ow(0xFAF7F1, 0x1E1B16)
    }
}
