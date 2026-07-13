import AppKit
import SwiftUI
import Combine
import OpenWhispererKit

/// Hosting view that accepts the first click even while the app is inactive — the
/// band lives in a non-activating panel that is never key, and click-to-barge-in
/// must work on the first click with another app frontmost.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Panel allowed to occupy the menu-bar band. AppKit's default frame constraining
/// pushes windows below the menu bar; the band must hug the screen's top edge.
private final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Dynamic Island-style status band at the notch. Owns one non-activating panel per
/// screen — status is global, so every display shows the same state and nothing ever
/// moves between screens. Replaces the floating overlay.
final class NotchIndicator: NSObject, ObservableObject {
    static let shared = NotchIndicator()

    @Published var isVisible = false
    @Published var isTTSPlaying = false
    /// The current PTT key label shown in the hover flyout (e.g. "Ctrl", "fn").
    @Published var pttKeyLabel: String = "Ctrl"
    /// Current interaction mode — determines the flyout hint and the countdown line.
    @Published var interactionMode: InteractionMode = .pressToTalk
    /// Live recorder reference. Published so the SwiftUI panels react to recorder
    /// swaps without NSHostingView teardown (same pattern the overlay used — see
    /// its git history for the original bug).
    @Published var currentRecorder = AudioRecorder(skipPermissionCheck: true)
    /// Model/setup status mirrored for the menubar dropdown's status row; the band
    /// itself renders only the error dot.
    @Published var statusText: String?
    @Published var statusIsError = false

    /// Click-while-speaking barge-in, injected by AppDelegate.
    var onBargeIn: (() -> Void)?

    var dictationManager: DictationManager? {
        didSet {
            if let dm = dictationManager { currentRecorder = dm.recorder }
            wireStatus()
        }
    }
    weak var setupManager: SetupManager? {
        didSet { wireStatus() }
    }

    private var panels: [NSPanel] = []
    private var ttsTimer: Timer?
    private var statusCancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show() {
        try? FileManager.default.removeItem(at: Paths.overlayHidden)
        rebuildPanels()
        isVisible = true
        startTTSPolling()
    }

    func hide() {
        try? "on".write(to: Paths.overlayHidden, atomically: true, encoding: .utf8)
        stopTTSPolling()
        closePanels()
        isVisible = false
    }

    @objc private func screensChanged() {
        guard isVisible else { return }
        rebuildPanels()
    }

    private func closePanels() {
        panels.forEach { $0.close() }
        panels.removeAll()
    }

    /// One panel per screen. Idempotent — called on show() and whenever the screen
    /// configuration changes (display plugged/unplugged, resolution change).
    private func rebuildPanels() {
        closePanels()
        for screen in NSScreen.screens {
            let metrics = NotchGeometry.ScreenMetrics(
                frame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
                auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
                menuBarThickness: NSStatusBar.system.thickness
            )
            let geometry = NotchGeometry(metrics: metrics)
            let panel = NotchPanel(
                contentRect: geometry.windowFrame(),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = false
            panel.contentView = FirstMouseHostingView(
                rootView: NotchBandView(indicator: self, geometry: geometry))
            panel.setFrame(geometry.windowFrame(), display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    // MARK: - TTS lock polling (same mechanism the overlay used)

    private func startTTSPolling() {
        ttsTimer?.invalidate()
        let lockPath = Paths.appSupport.appendingPathComponent("tts_playing.lock").path
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            let playing = FileManager.default.fileExists(atPath: lockPath)
            if self?.isTTSPlaying != playing {
                self?.isTTSPlaying = playing
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ttsTimer = timer
    }

    private func stopTTSPolling() {
        ttsTimer?.invalidate()
        ttsTimer = nil
        isTTSPlaying = false
    }

    // MARK: - Status mirroring (ported unchanged from the overlay)

    /// Subscribe to the managers' published state so the status row stays in sync.
    private func wireStatus() {
        statusCancellables.removeAll()
        // Recompute on the next main-loop tick so the @Published value has settled
        // (sinks fire on willSet, i.e. before the new value is stored).
        let recompute: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.recomputeStatus() }
        }
        if let dm = dictationManager {
            dm.$sttModelReady.sink { _ in recompute() }.store(in: &statusCancellables)
            dm.$sttFailed.sink { _ in recompute() }.store(in: &statusCancellables)
            dm.$sttStatus.sink { _ in recompute() }.store(in: &statusCancellables)
        }
        if let sm = setupManager {
            sm.$state.sink { _ in recompute() }.store(in: &statusCancellables)
        }
        recomputeStatus()
    }

    /// Priority: STT failure (dictation-blocking) > STT still loading > setup failure > ready.
    private func recomputeStatus() {
        if let dm = dictationManager {
            if dm.sttFailed {
                statusText = dm.sttStatus ?? "Speech model failed to load."
                statusIsError = true
                return
            }
            if !dm.sttModelReady {
                statusText = dm.sttStatus ?? "Loading speech model…"
                statusIsError = false
                return
            }
        }
        if let sm = setupManager, case .failed(let reason) = sm.state {
            statusText = reason
            statusIsError = true
            return
        }
        statusText = nil
        statusIsError = false
    }
}
