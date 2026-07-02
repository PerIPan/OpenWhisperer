import AppKit
import Combine

/// Manages Accessibility permission state — prompts once on launch, then polls continuously
/// so a later *revocation* (or an ad-hoc-rebuild grant drop) is reflected live, not only at
/// the next launch. macOS gives no forced-quit prompt when Accessibility is revoked, so this
/// poll is the only thing that catches it.
class AccessibilityManager: ObservableObject {
    @Published var isGranted: Bool = false
    private var pollTimer: Timer?
    private var hasPrompted = false

    init() {
        isGranted = AXIsProcessTrusted()
        startPolling()
    }

    /// Show the system Accessibility prompt exactly once. The poll (started in `init`) keeps
    /// `isGranted` current afterward, in both directions — so this only handles the prompt.
    func requestIfNeeded() {
        guard !hasPrompted else { return }
        hasPrompted = true

        if AXIsProcessTrusted() {
            isGranted = true
            return
        }

        // Show the system prompt dialog once
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Poll every 2s (silently, no prompt), updating `isGranted` in *both* directions so a
    /// revocation is caught, not just an initial grant. Runs for the app's lifetime.
    /// Uses .common run loop mode so it fires during menu bar tracking.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            // Only publish on a real change to avoid needless SwiftUI invalidations.
            if self.isGranted != trusted {
                self.isGranted = trusted
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    deinit {
        pollTimer?.invalidate()
    }
}
