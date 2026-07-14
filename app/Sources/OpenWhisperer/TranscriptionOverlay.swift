import Foundation
import SwiftUI
import Combine
import OpenWhispererKit

/// Borderless window that accepts keyboard input (enables Cmd+C for text selection).
private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Custom hosting view that forwards the very first mouse click to active elements even when the window is inactive.
private class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class TranscriptionOverlay: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = TranscriptionOverlay()

    private var window: NSWindow?

    @Published var isVisible: Bool = false
    @Published var isTTSPlaying: Bool = false
    private var ttsTimer: Timer?

    /// The current PTT key label shown in the overlay (e.g. "Ctrl", "fn").
    @Published var pttKeyLabel: String = "Ctrl"

    /// Current interaction mode — determines hint text during recording.
    @Published var interactionMode: InteractionMode = .pressToTalk

    /// Reference to dictation manager for waveform display.
    ///
    /// FIX: Use a @Published wrapper so the SwiftUI root view can observe
    /// the recorder reference changing, instead of tearing down NSHostingView.
    /// Tearing down NSHostingView cancels the TimelineView render loop and
    /// creates a new @ObservedObject subscription to a potentially stale instance.
    var dictationManager: DictationManager? {
        didSet {
            // FIX: Rather than recreating the entire NSHostingView (which kills
            // the TimelineView animation loop and risks observing a stale recorder),
            // publish the new recorder reference through a @Published property on
            // the overlay so the live SwiftUI tree picks it up reactively.
            if let dm = dictationManager {
                currentRecorder = dm.recorder
            }
            wireStatus()
        }
    }

    /// Mirrors the speech-model / setup status into the standby overlay so it shows
    /// "Loading speech model…", a failure message, or a model-load failure
    /// instead of always claiming "Listening for transcriptions…".
    @Published var statusText: String?
    @Published var statusIsError: Bool = false

    /// Setup manager reference so the overlay can mirror setup failures.
    weak var setupManager: SetupManager? {
        didSet { wireStatus() }
    }

    private var statusCancellables = Set<AnyCancellable>()

    /// The live recorder reference. Published so the SwiftUI view tree reacts
    /// to recorder swaps without NSHostingView teardown.
    ///
    /// FIX: This is the critical fix. @ObservedObject inside NSHostingView works
    /// correctly, but ONLY if it holds the same instance that is actually recording.
    /// Previously, show() could capture a throwaway AudioRecorder() when
    /// dictationManager was nil, and that dead instance would be observed forever.
    @Published var currentRecorder: AudioRecorder = AudioRecorder(skipPermissionCheck: true)

    func show() {
        try? FileManager.default.removeItem(at: Paths.overlayHidden)
        if let w = window {
            // FIX: Never recreate NSHostingView on an already-constructed window.
            // Recreating it tears down the entire SwiftUI render tree, cancels
            // TimelineView subscriptions, and forces a new @ObservedObject binding
            // cycle. Instead, update currentRecorder (above) and just re-front the window.
            if let dm = dictationManager {
                currentRecorder = dm.recorder
            }
            w.orderFront(nil)
            isVisible = true
            return
        }

        // Capture the real recorder now, or use the already-initialised placeholder.
        if let dm = dictationManager {
            currentRecorder = dm.recorder
        }

        // FIX: Pass `self` (the overlay) as the single source of truth. The SwiftUI
        // view will derive its recorder from overlay.currentRecorder. This way,
        // when the recorder changes, SwiftUI's normal @ObservedObject diffing handles
        // the update inside the existing live view tree — no NSHostingView rebuild needed.
        let hostingView = FirstMouseHostingView(rootView: OverlayView(overlay: self))

        // FIX: sizingOptions ensures the hosting view participates in layout
        // and does not clip the SwiftUI render layer, which can suppress CA commits.
        hostingView.sizingOptions = [.minSize, .intrinsicContentSize, .preferredContentSize]

        let w = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 44),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.delegate = self
        // Frosted capsule: system HUD blur of whatever is behind the window, with a
        // faint warm tint so the surface still reads as OpenWhisperer. Shaped via
        // maskImage — mutating the effect view's own layer (cornerRadius/masksToBounds)
        // silently breaks the behind-window blur.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.capsuleMask(height: OverlayView.pillHeight)

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.ow(0xFAF7F1, 0x1E1B16).withAlphaComponent(0.18).cgColor

        tint.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        effect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        w.contentView = effect
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true

        // Position bottom-right of screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 200
            let y = screen.visibleFrame.minY + 20
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        w.orderFront(nil)
        self.window = w
        isVisible = true
        startTTSPolling()
    }

    func hide() {
        try? "on".write(to: Paths.overlayHidden, atomically: true, encoding: .utf8)
        stopTTSPolling()
        window?.close()
        window = nil
        isVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        stopTTSPolling()
        window = nil
        isVisible = false
    }

    /// Stretchable capsule mask for the effect view — the sanctioned way to shape an
    /// NSVisualEffectView (touching its layer breaks the material).
    private static func capsuleMask(height: CGFloat) -> NSImage {
        let radius = height / 2
        let image = NSImage(size: NSSize(width: height + 1, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 0, left: radius, bottom: 0, right: radius)
        image.resizingMode = .stretch
        return image
    }

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

    // MARK: - Status mirroring

    /// Subscribe to the managers' published state so the overlay headline stays in sync.
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

// MARK: - Overlay View

struct OverlayView: View {
    /// FIX: Observe the overlay as the single source of truth. The overlay's
    /// @Published currentRecorder is how we get the live recorder reference.
    /// We do NOT take recorder as a direct init parameter anymore — doing so
    /// would freeze the reference at the moment NSHostingView was constructed.
    @ObservedObject var overlay: TranscriptionOverlay
    /// Hover reveals the close affordance; the pill is otherwise control-free.
    @State private var hovered = false

    static let pillHeight: CGFloat = 44
    static let pillWidth: CGFloat = 180

    var body: some View {
        // Derive the live recorder from overlay.currentRecorder each time body evaluates,
        // so WaveformBar always observes the instance that is actually recording.
        let recorder = overlay.currentRecorder

        ZStack(alignment: .bottom) {
            HStack(spacing: 8) {
                WaveformBar(recorder: recorder, isTTSPlaying: overlay.isTTSPlaying, statusIsError: overlay.statusIsError)
                if hovered {
                    Button(action: { overlay.hide() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(OWColor.inkFaint)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            // Silence countdown — hands-free only, along the pill's bottom edge.
            if overlay.interactionMode == .handsFree {
                SilenceProgressBar(recorder: recorder)
                    .frame(height: 1.5)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 3)
            }
        }
        .frame(width: Self.pillWidth, height: Self.pillHeight)
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.12)) { hovered = inside }
        }
    }
}

// MARK: - Waveform Bar

struct WaveformBar: View {
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject private var playbackMeter = PlaybackLevelMeter.shared
    var isTTSPlaying: Bool = false
    /// Paints the dot danger-red while model status is failed (the words live in the menu).
    var statusIsError: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            // Vintage segmented spectrum display — see `spectrum(bands:)`.
            Group {
                if isTTSPlaying && recorder.state == .idle {
                    if !playbackMeter.spectrumBands.isEmpty {
                        // Real playback bands — the meter's own @Published drives
                        // re-render, no TimelineView needed.
                        spectrum(bands: playbackMeter.spectrumBands)
                    } else {
                        // Fallback: synthetic band animation (meter silent — e.g. bands
                        // haven't arrived yet, or between sentences).
                        TimelineView(.animation(minimumInterval: 0.03)) { timeline in
                            let time = timeline.date.timeIntervalSinceReferenceDate
                            spectrum(bands: Self.syntheticBands(time: time))
                        }
                    }
                } else {
                    spectrum(bands: recorder.spectrumBands)
                        .opacity(recorder.state == .uploading ? 0.5 : recorder.state == .idle ? 0.25 : 1.0)
                }
            }
        }
    }

    // MARK: - Segmented Spectrum

    /// Vintage spectrum columns: one column per band, `segmentCount` discrete
    /// segments each; lit count tracks band energy, unlit segments stay ghosted.
    /// Top lit segment gets the deep-gold "peak" accent.
    private static let segmentCount = 7

    @ViewBuilder
    private func spectrum(bands: [Float]) -> some View {
        GeometryReader { geo in
            let columns = max(bands.count, 1)
            let columnWidth = geo.size.width / CGFloat(columns)
            let segmentHeight = (geo.size.height - CGFloat(Self.segmentCount - 1)) / CGFloat(Self.segmentCount)
            HStack(spacing: 0) {
                ForEach(0..<columns, id: \.self) { band in
                    let level = band < bands.count ? bands[band] : 0
                    let lit = Int((CGFloat(level) * CGFloat(Self.segmentCount)).rounded())
                    VStack(spacing: 1) {
                        ForEach((0..<Self.segmentCount).reversed(), id: \.self) { segment in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(segment < lit
                                      ? (segment == lit - 1 ? OWColor.accentDeep : OWColor.accent)
                                      : OWColor.accent.opacity(0.12))
                                .frame(height: segmentHeight)
                        }
                    }
                    .frame(width: max(columnWidth - 2, 1))
                    .padding(.horizontal, 1)
                }
            }
        }
        .clipped()
    }

    /// Synthetic band animation for the speaking fallback (meter silent).
    static func syntheticBands(time: Double) -> [Float] {
        (0..<SpectrumBands.bandCount).map { band in
            let t = Double(band) / Double(SpectrumBands.bandCount - 1)
            let v = 0.35 + 0.3 * sin(time * 2.4 + t * .pi * 3) + 0.15 * sin(time * 5.1 + t * .pi * 7)
            return Float(min(max(v, 0), 1)) * Float(1 - t * 0.45)
        }
    }

    private var statusColor: Color {
        if statusIsError { return OWColor.danger }
        if isTTSPlaying && recorder.state == .idle { return OWColor.accent }
        switch recorder.state {
        case .recording: return OWColor.recording
        case .uploading: return OWColor.warn
        case .listening: return OWColor.accentDeep
        case .idle: return OWColor.live
        }
    }

}

// MARK: - Silence Progress Bar

struct SilenceProgressBar: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            GeometryReader { geo in
                let progress = silenceProgress(at: timeline.date)
                ZStack(alignment: .leading) {
                    // Track (always visible)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(OWColor.line)
                    // Fill — gold reads as "completing a valuable action" (auto-submit countdown)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(OWColor.accent)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
        }
    }

    private func silenceProgress(at now: Date) -> CGFloat {
        // Only show fill during active recording (not listening/idle)
        guard recorder.state == .recording,
              let start = recorder.silenceStart,
              recorder.silenceThresholdSeconds > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        return CGFloat(min(max(elapsed / recorder.silenceThresholdSeconds, 0), 1))
    }
}
