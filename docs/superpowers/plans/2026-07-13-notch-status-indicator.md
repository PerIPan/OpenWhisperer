# Notch Status Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the floating status overlay with a Dynamic Island-style black band at the notch (mirrored on every screen), then delete the overlay.

**Architecture:** Pure geometry (`NotchGeometry`) in `OpenWhispererKit`; a `NotchIndicator` controller (app target) owning one non-activating panel per screen, rebuilt on screen-configuration changes; a `NotchBandView` SwiftUI view per panel with the ported waveform drawing; menu gains a model-status row and the renamed visibility toggle; `TranscriptionOverlay.swift` is deleted last.

**Tech Stack:** Swift/SwiftUI, AppKit (`NSPanel`, `NSScreen` safe-area/auxiliary APIs), Combine, plain-executable test runner (no XCTest — Command Line Tools only).

**Spec:** `docs/superpowers/specs/2026-07-13-notch-status-indicator-design.md`

## Global Constraints

- All Swift commands run from `app/` (the SwiftPM package root).
- Work in a worktree off `main` at `.claude/worktrees/notch-indicator` (branch `notch-indicator`) — never branch in place.
- No XCTest. Kit checks are `[String]`-returning functions registered in `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift`; run with `swift run OpenWhispererKitTests`.
- The band is **always visible, minimal at idle** (4pt dot); **mirrored on every screen**; nothing ever moves between screens.
- Non-notch screens get a synthesized notch: `fakeNotchWidth = 200`pt wide, menu-bar-height (`NSStatusBar.system.thickness`) tall, top-center.
- Visibility reuses the existing `overlay_hidden` flag file (`Paths.overlayHidden`); menu toggle copy becomes **"Show Status Indicator"**.
- Do not name competitor products anywhere in committed files or commit messages.
- Commits: Conventional Commits, imperative, subject hard cap 72 chars including `type(scope):`. No `Co-Authored-By`. End each commit body with the trailer line `Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5`.

---

### Task 1: `NotchGeometry` (Kit, TDD)

**Files:**
- Create: `app/Sources/OpenWhispererKit/NotchGeometry.swift`
- Create: `app/Tests/OpenWhispererKitTests/NotchGeometryChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (register the check group)

**Interfaces:**
- Consumes: nothing.
- Produces (Tasks 2–3 rely on these exact signatures):
  - `public struct NotchGeometry` with `init(metrics: ScreenMetrics)`
  - `public struct NotchGeometry.ScreenMetrics` with `init(frame: CGRect, safeAreaTop: CGFloat, auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?, menuBarThickness: CGFloat)`
  - `public static let fakeNotchWidth: CGFloat = 200`, `idleWingWidth: CGFloat = 16`, `activeWingWidth: CGFloat = 72`, `flyoutHeight: CGFloat = 30`
  - `public let hasNotch: Bool`, `public let bandHeight: CGFloat`, `public let notchRect: CGRect`
  - `public func windowFrame() -> CGRect`, `public func bandWidth(expanded: Bool) -> CGFloat`

- [ ] **Step 1: Write the failing checks**

Create `app/Tests/OpenWhispererKitTests/NotchGeometryChecks.swift`:

```swift
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
```

- [ ] **Step 2: Register the check group**

In `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift`, after the line `failures += transcriptHistoryBufferFailures()` add:

```swift
        failures += notchGeometryFailures()
```

- [ ] **Step 3: Run to verify it fails**

Run (from `app/`): `swift run OpenWhispererKitTests`
Expected: **build error** — `cannot find 'NotchGeometry' in scope` (with no XCTest, the red step is a compile failure).

- [ ] **Step 4: Write the implementation**

Create `app/Sources/OpenWhispererKit/NotchGeometry.swift`:

```swift
import Foundation

/// Pure geometry for the notch status indicator band. Computes, from a screen's
/// metrics, where the band's panel sits and how wide the visible black band is in
/// each state. Lives in OpenWhispererKit so the math is unit-testable under CLT;
/// `NotchIndicator` (app target) feeds it real NSScreen values.
public struct NotchGeometry: Equatable {
    /// The subset of NSScreen the geometry needs, as plain values.
    public struct ScreenMetrics: Equatable {
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
```

- [ ] **Step 5: Run to verify it passes**

Run (from `app/`): `swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenWhispererKit/NotchGeometry.swift \
        Tests/OpenWhispererKitTests/NotchGeometryChecks.swift \
        Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(notch): add NotchGeometry to Kit" \
  -m "Pure band/window math for the notch status indicator: real-notch
detection, fake-notch fallback, wing expansion, flyout strip.

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 2: `NotchIndicator` controller + `NotchBandView`

**Files:**
- Create: `app/Sources/OpenWhisperer/NotchIndicator.swift`
- Create: `app/Sources/OpenWhisperer/NotchBandView.swift`

**Interfaces:**
- Consumes: `NotchGeometry` / `ScreenMetrics` from Task 1 (exact signatures in Task 1's Produces block); existing app types: `AudioRecorder` (`.state` ∈ `idle|recording|uploading|listening`, `.levelHistory: [Float]`, `.silenceStart: Date?`, `.silenceThresholdSeconds: TimeInterval`, `init(skipPermissionCheck:)`), `DictationManager` (`$sttModelReady/$sttFailed/$sttStatus`, `.recorder`, `.retrySTT()`), `SetupManager` (`.state`, case `.failed(String)`), `InteractionMode`, `Paths.overlayHidden`, `Paths.appSupport`, `OWColor` tokens, `Color.ow(_:_:)`.
- Produces (Tasks 3–4 rely on): `NotchIndicator.shared` with `@Published isVisible/isTTSPlaying/pttKeyLabel/interactionMode/currentRecorder/statusText/statusIsError`, `var dictationManager: DictationManager?`, `weak var setupManager: SetupManager?`, `var onBargeIn: (() -> Void)?`, `func show()`, `func hide()`. `NotchBandView(indicator:geometry:)`.

Nothing is wired into the app yet — this task only has to compile. The controller intentionally mirrors the overlay's proven patterns (published `currentRecorder` to survive recorder swaps without NSHostingView teardown; `tts_playing.lock` polling; the status-mirroring priority chain), because those patterns fixed real bugs documented in the overlay's comments.

- [ ] **Step 1: Create the controller**

Create `app/Sources/OpenWhisperer/NotchIndicator.swift`:

```swift
import AppKit
import SwiftUI
import Combine
import OpenWhispererKit

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
            let panel = NSPanel(
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
            panel.contentView = NSHostingView(
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
```

- [ ] **Step 2: Create the band view**

Create `app/Sources/OpenWhisperer/NotchBandView.swift`:

```swift
import SwiftUI
import OpenWhispererKit

/// The black band hugging the notch (or the synthesized lozenge on screens without
/// one): a 4pt status dot at idle, expanding waveform wings during activity, the
/// hands-free countdown line, and a hover flyout with the state word and hotkey hint.
struct NotchBandView: View {
    @ObservedObject var indicator: NotchIndicator
    let geometry: NotchGeometry

    @State private var hovered = false

    /// Gold gradient shared by the record/speak waveforms (reads well on black).
    private static let goldGradient = LinearGradient(
        colors: [Color.ow(0xE7CF9E, 0xE7CF9E), OWColor.accent, OWColor.accentDeep],
        startPoint: .leading, endPoint: .trailing
    )
    /// Waveform bars shown in the wing.
    private static let wingLevelCount = 12

    var body: some View {
        let recorder = indicator.currentRecorder
        VStack(spacing: 3) {
            band(recorder: recorder)
                .onHover { inside in
                    withAnimation(.easeInOut(duration: 0.12)) { hovered = inside }
                }
                .onTapGesture {
                    if isSpeaking(recorder) { indicator.onBargeIn?() }
                }
            if hovered {
                flyout(recorder: recorder)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Band

    private func band(recorder: AudioRecorder) -> some View {
        let expanded = isExpanded(recorder)
        return NotchShape(cornerRadius: 8)
            .fill(.black)
            .frame(width: geometry.bandWidth(expanded: expanded), height: geometry.bandHeight)
            .overlay(alignment: .trailing) {
                wingContent(recorder: recorder, expanded: expanded)
            }
            .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    @ViewBuilder
    private func wingContent(recorder: AudioRecorder, expanded: Bool) -> some View {
        if expanded {
            ZStack(alignment: .bottomLeading) {
                waveform(recorder: recorder)
                if indicator.interactionMode == .handsFree, recorder.state == .recording {
                    SilenceCountdownLine(recorder: recorder)
                        .frame(height: 1.5)
                }
            }
            .frame(width: NotchGeometry.activeWingWidth - 10, height: geometry.bandHeight - 6)
            .padding(.trailing, 6)
        } else {
            Circle()
                .fill(dotColor(recorder))
                .frame(width: 4, height: 4)
                .padding(.trailing, 6)
        }
    }

    @ViewBuilder
    private func waveform(recorder: AudioRecorder) -> some View {
        GeometryReader { geo in
            if isSpeaking(recorder) {
                TimelineView(.animation(minimumInterval: 0.03)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    Self.mirroredLines(
                        levels: Self.ttsLevels(count: Self.wingLevelCount, time: time),
                        size: geo.size)
                        .fill(Self.goldGradient)
                }
            } else {
                Self.mirroredLines(
                    levels: recorder.levelHistory.suffix(Self.wingLevelCount).map { CGFloat($0) },
                    size: geo.size)
                    .fill(Self.goldGradient)
                    .opacity(recorder.state == .uploading ? 0.5 : 1.0)
            }
        }
    }

    // MARK: - Flyout

    private func flyout(recorder: AudioRecorder) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dotColor(recorder)).frame(width: 6, height: 6)
            Text(stateWord(recorder))
                .font(.custom("Outfit", size: 10))
            if recorder.state == .recording {
                Text(hint)
                    .font(.custom("Outfit", size: 9))
                    .foregroundColor(OWColor.inkSoft)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.ow(0xFAF7F1, 0x1E1B16).opacity(0.97)))
        .foregroundColor(OWColor.ink)
    }

    private var hint: String {
        switch indicator.interactionMode {
        case .holdToTalk: return "release \(indicator.pttKeyLabel) to stop"
        case .handsFree: return "silence submits"
        case .pressToTalk: return "press \(indicator.pttKeyLabel) to stop"
        }
    }

    // MARK: - State helpers

    private func isSpeaking(_ recorder: AudioRecorder) -> Bool {
        indicator.isTTSPlaying && recorder.state == .idle
    }

    private func isExpanded(_ recorder: AudioRecorder) -> Bool {
        recorder.state != .idle || isSpeaking(recorder)
    }

    private func dotColor(_ recorder: AudioRecorder) -> Color {
        if indicator.statusIsError { return OWColor.danger }
        if isSpeaking(recorder) { return OWColor.accent }
        switch recorder.state {
        case .recording: return OWColor.recording
        case .uploading: return OWColor.warn
        case .listening: return OWColor.accentDeep
        case .idle: return OWColor.live
        }
    }

    private func stateWord(_ recorder: AudioRecorder) -> String {
        if indicator.statusIsError { return "Attention needed — see menu" }
        if isSpeaking(recorder) { return "Speaking…" }
        switch recorder.state {
        case .recording: return "Recording…"
        case .uploading: return "Transcribing…"
        case .listening: return "Listening…"
        case .idle: return "Standby"
        }
    }

    // MARK: - Waveform drawing (ported from the overlay's WaveformBar)

    /// Vertical bars mirrored around the center line, tapered at the edges.
    static func mirroredLines(levels: [CGFloat], size: CGSize) -> Path {
        guard !levels.isEmpty else { return Path() }
        let n = levels.count
        let barWidth: CGFloat = 2
        let gap: CGFloat = max(1, (size.width - barWidth * CGFloat(n)) / CGFloat(max(n - 1, 1)))
        let step = barWidth + gap
        let midY = size.height / 2
        let maxHalf = midY - 1  // leave 1pt breathing room
        var path = Path()
        for (i, level) in levels.enumerated() {
            let t = CGFloat(i) / CGFloat(max(n - 1, 1))
            let taper = min(t * 5, (1 - t) * 5, 1.0)
            let h = max(1, level * taper * maxHalf)
            let x = CGFloat(i) * step
            let rect = CGRect(x: x, y: midY - h, width: barWidth, height: h * 2)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }

    /// Synthetic sine-wave levels for the TTS (speaking) animation.
    static func ttsLevels(count: Int, time: Double) -> [CGFloat] {
        (0..<count).map { i in
            let t = Double(i) / Double(max(count - 1, 1))
            let wave1 = sin(time * 3.0 + t * .pi * 4) * 0.35
            let wave2 = sin(time * 1.8 + t * .pi * 2.5) * 0.25
            let wave3 = sin(time * 5.0 + t * .pi * 7) * 0.1
            return CGFloat(max(0.05, (wave1 + wave2 + wave3 + 0.5) * 0.8))
        }
    }
}

/// Rect with rounded bottom corners only — flush against the screen's top edge, so
/// beside a real notch it reads as the notch being a touch wider.
struct NotchShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Hands-free auto-submit countdown as a thin gold line along the wing's bottom edge
/// (ported from the overlay's SilenceProgressBar, restyled for the band).
struct SilenceCountdownLine: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1)
                    .fill(OWColor.accent)
                    .frame(width: max(0, geo.size.width * progress(at: timeline.date)))
            }
        }
    }

    private func progress(at now: Date) -> CGFloat {
        // Only fill during active recording (not listening/idle).
        guard recorder.state == .recording,
              let start = recorder.silenceStart,
              recorder.silenceThresholdSeconds > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        return CGFloat(min(max(elapsed / recorder.silenceThresholdSeconds, 0), 1))
    }
}
```

- [ ] **Step 3: Build**

Run (from `app/`): `swift build`
Expected: `Build complete!` (nothing is wired yet; both files must simply compile).

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenWhisperer/NotchIndicator.swift Sources/OpenWhisperer/NotchBandView.swift
git commit -m "feat(notch): add indicator band view and controller" \
  -m "One non-activating panel per screen at .statusBar level, mirrored
global state, hover flyout, click-to-barge-in hook. Not yet wired in.

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 3: Swap the app onto the indicator

**Files:**
- Modify: `app/Sources/OpenWhisperer/AppDelegate.swift` (lines 87, 92, 120–127 area + barge-in injection)
- Modify: `app/Sources/OpenWhisperer/OpenWhispererApp.swift` (`SettingsMenuItems`: observed object, status row, toggle rename)
- Modify: `app/Sources/OpenWhisperer/DictationManager.swift:30` (one line)
- Modify: `app/Sources/OpenWhisperer/Settings/InputTab.swift:74,258` (two lines)

**Interfaces:**
- Consumes: `NotchIndicator.shared` (Task 2's Produces block), `ServerManager.playback: TTSPlaybackController` (actor; `func bargeIn()` called as `Task { await playback.bargeIn() }`), `TranscriptionHistory` (unchanged).
- Produces: the running app shows the band instead of the overlay. `TranscriptionOverlay` is left in the tree but unreferenced (Task 4 deletes it).

Line numbers refer to files as of commit `29311e8`; anchor on the quoted code if they have drifted.

- [ ] **Step 1: Rewire AppDelegate**

In `app/Sources/OpenWhisperer/AppDelegate.swift`:

a. In `setupDictation()`, replace (line 87):

```swift
            TranscriptionOverlay.shared.pttKeyLabel = key.label
```

with:

```swift
            NotchIndicator.shared.pttKeyLabel = key.label
```

b. Replace (line 92):

```swift
        TranscriptionOverlay.shared.interactionMode = dictationManager.interactionMode
```

with:

```swift
        NotchIndicator.shared.interactionMode = dictationManager.interactionMode
```

c. Replace the block (lines 120–127):

```swift
        TranscriptionOverlay.shared.dictationManager = dictationManager
        TranscriptionOverlay.shared.setupManager = setupManager
        transcriptionHistory.wire(to: dictationManager)

        // Show the overlay on launch unless the user hid it last session
        // (overlay_hidden flag — maintained by TranscriptionOverlay.show()/hide()).
        if !FileManager.default.fileExists(atPath: Paths.overlayHidden.path) {
            TranscriptionOverlay.shared.show()
        }
```

with:

```swift
        NotchIndicator.shared.dictationManager = dictationManager
        NotchIndicator.shared.setupManager = setupManager
        // Click-while-speaking on the band stops playback — the same barge-in the
        // mic path uses.
        let playback = serverManager.playback
        NotchIndicator.shared.onBargeIn = { Task { await playback.bargeIn() } }
        transcriptionHistory.wire(to: dictationManager)

        // Show the indicator on launch unless the user hid it last session
        // (overlay_hidden flag — maintained by NotchIndicator.show()/hide()).
        if !FileManager.default.fileExists(atPath: Paths.overlayHidden.path) {
            NotchIndicator.shared.show()
        }
```

- [ ] **Step 2: Rewire the two satellite call sites**

In `app/Sources/OpenWhisperer/DictationManager.swift` (line 30), replace:

```swift
                TranscriptionOverlay.shared.interactionMode = interactionMode
```

with:

```swift
                NotchIndicator.shared.interactionMode = interactionMode
```

In `app/Sources/OpenWhisperer/Settings/InputTab.swift` (lines 74 and 258 — both occurrences), replace:

```swift
                        TranscriptionOverlay.shared.pttKeyLabel = key.label
```

with:

```swift
                        NotchIndicator.shared.pttKeyLabel = key.label
```

(Preserve each line's original indentation.)

- [ ] **Step 3: Update the menu**

In `app/Sources/OpenWhisperer/OpenWhispererApp.swift`, inside `SettingsMenuItems`:

a. Replace the observed object (line 80):

```swift
    @ObservedObject private var overlay = TranscriptionOverlay.shared
```

with:

```swift
    @ObservedObject private var indicator = NotchIndicator.shared
```

b. Replace the toggle block (lines 104–109), currently:

```swift
        Divider()

        Toggle("Show Overlay", isOn: Binding(
            get: { overlay.isVisible },
            set: { $0 ? overlay.show() : overlay.hide() }
        ))
```

with the status row plus the renamed toggle:

```swift
        Divider()

        // Model/setup status — the band shows only a red dot; the words live here.
        if let status = indicator.statusText {
            if indicator.statusIsError, let dm = indicator.dictationManager, dm.sttFailed {
                Button("\(status) — Retry") { dm.retrySTT() }
            } else {
                Text(status)
            }
            Divider()
        }

        Toggle("Show Status Indicator", isOn: Binding(
            get: { indicator.isVisible },
            set: { $0 ? indicator.show() : indicator.hide() }
        ))
```

- [ ] **Step 4: Build and run both suites**

Run (from `app/`):

```bash
swift build && swift run OpenWhispererKitTests && swift run HookTests
```

Expected: `Build complete!` and both suites green. (`TranscriptionOverlay.swift` still compiles standalone; it is deleted in Task 4.)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenWhisperer/AppDelegate.swift Sources/OpenWhisperer/OpenWhispererApp.swift \
        Sources/OpenWhisperer/DictationManager.swift Sources/OpenWhisperer/Settings/InputTab.swift
git commit -m "feat(notch): swap the app onto the indicator" \
  -m "AppDelegate, menu toggle (\"Show Status Indicator\"), and the two
satellite call sites now target NotchIndicator; the dropdown gains the
model-status row with inline Retry. Overlay left unreferenced.

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 4: Delete the floating overlay

**Files:**
- Delete: `app/Sources/OpenWhisperer/TranscriptionOverlay.swift`

**Interfaces:**
- Consumes: Task 3 must be complete (no live references remain).
- Produces: none.

- [ ] **Step 1: Verify nothing references the overlay's symbols**

Run (from `app/`):

```bash
grep -rn "TranscriptionOverlay\|OverlayView\|WaveformBar\|SilenceProgressBar\|KeyableWindow\|FirstMouseHostingView" Sources/ Tests/ --include="*.swift" | grep -v "Sources/OpenWhisperer/TranscriptionOverlay.swift"
```

Expected: **no output**. If any line prints, STOP — Task 3 missed a call site; report it instead of deleting.

- [ ] **Step 2: Delete the file**

```bash
git rm Sources/OpenWhisperer/TranscriptionOverlay.swift
```

- [ ] **Step 3: Build and run both suites**

Run (from `app/`):

```bash
swift build && swift run OpenWhispererKitTests && swift run HookTests
```

Expected: `Build complete!` and both suites green.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(overlay): delete the floating overlay" \
  -m "The notch indicator now carries every state the overlay showed.
KeyableWindow and its stale Cmd+C comment go with it.

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 5: Verification, PR, manual smoke handoff

**Files:**
- No source changes. Build artifacts only.

**Interfaces:**
- Consumes: all prior tasks merged into the `notch-indicator` branch.
- Produces: an open PR and a signed local build for the user's smoke test.

- [ ] **Step 1: Full test pass**

Run (from `app/`): `swift run OpenWhispererKitTests && swift run HookTests`
Expected: both green, exit 0.

- [ ] **Step 2: Signed local build**

Run (from `app/`):

```bash
OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh
```

Expected: `.app` + `.dmg` under `app/.build/`. (The cert exists in the login keychain even though `security find-identity -v` hides it — do not fall back to ad-hoc.)

- [ ] **Step 3: Rebase and open the PR**

```bash
git fetch origin && git rebase origin/main
git push -u origin notch-indicator
gh pr create --title "feat: replace the floating overlay with a notch status indicator" --body "$(cat <<'EOF'
## Summary
- Dynamic Island-style black band at the notch: 4pt status dot at idle, waveform wings while recording/transcribing/speaking, hands-free countdown line, hover flyout with state + hotkey hint, click-while-speaking barge-in
- Mirrored on every screen (real notch on the MacBook, synthesized lozenge top-center elsewhere); panels rebuild on display changes; visible over fullscreen apps
- Model/setup status moves to the menubar dropdown (status row + inline Retry); menu toggle renamed "Show Status Indicator" (same `overlay_hidden` flag)
- `TranscriptionOverlay.swift` deleted; pure geometry (`NotchGeometry`) unit-tested in OpenWhispererKit

Spec: `docs/superpowers/specs/2026-07-13-notch-status-indicator-design.md`

## Test plan
- [x] `swift run OpenWhispererKitTests` (new `notchGeometryFailures` group)
- [x] `swift run HookTests`
- [ ] Manual smoke (Hakan): both screens show idle bands; dictation expands + animates both; hover flyout wording per mode; click stops speech; hands-free countdown line; fullscreen terminal keeps the band; unplug/replug external; model-load row + Retry in dropdown; light/dark
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 4: Install and hand off the manual smoke**

```bash
killall OpenWhisperer 2>/dev/null; rm -rf /Applications/OpenWhisperer.app
cp -R .build/OpenWhisperer.app /Applications/
open /Applications/OpenWhisperer.app
```

(If `open` fails with Launch Services error -600, rerun just the `open` command outside the sandbox.) Then report the PR link and the smoke checklist to the user. Do not merge before the smoke passes.

---

## Self-Review Notes

- **Spec coverage:** visual states incl. transcribing opacity + error dot (Task 2 view), always-visible/mirrored/never-moves (Task 2 controller), fake-notch fallback + degenerate safe-area case (Task 1), hover flyout + click-barge-in (Task 2), status row + Retry + toggle rename (Task 3), overlay deletion incl. `KeyableWindow` and the stale-comment/`minSize` nits (Task 4), fullscreen via `collectionBehavior` (Task 2), Kit tests (Task 1), smoke incl. display hot-plug (Task 5).
- **Type consistency:** `NotchGeometry` members and constants used in Tasks 2–3 match Task 1's definitions; `NotchIndicator` members used in Task 3 match Task 2's; `onBargeIn` wiring matches `TTSPlaybackController.bargeIn()`'s actor isolation (`Task { await … }`).
- **Known judgment call:** the band claims clicks only via the SwiftUI band shape; the transparent flyout strip below it stays hit-test-free (NSHostingView returns nil where no SwiftUI content is hit-testable). Verify during smoke that clicks just under the band pass through to the app beneath.
