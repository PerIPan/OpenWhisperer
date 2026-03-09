import AppKit
import Combine

/// Manages Accessibility permission state — prompts once on launch, then polls silently.
class AccessibilityManager: ObservableObject {
    @Published var isGranted: Bool = false
    private var pollTimer: Timer?
    private var hasPrompted = false

    init() {
        isGranted = AXIsProcessTrusted()
    }

    /// Show the system Accessibility prompt exactly once, then poll silently.
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
        startPolling()
    }

    /// Poll every 2s (silently, no prompt) until granted.
    /// Uses .common run loop mode so it fires during menu bar tracking.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] t in
            let trusted = AXIsProcessTrusted()
            DispatchQueue.main.async {
                self?.isGranted = trusted
            }
            if trusted {
                t.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    deinit {
        pollTimer?.invalidate()
    }
}
