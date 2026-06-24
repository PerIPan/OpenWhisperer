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

// MARK: - Window background

/// Sets the popover NSWindow's background to the warm surface so the window chrome
/// (rounded corners, edge) blends with the content in both light and dark mode.
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
