import Foundation
import SwiftUI
import Combine

/// Borderless window that accepts keyboard input (enables Cmd+C for text selection).
private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

class TranscriptionOverlay: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = TranscriptionOverlay()

    private var window: NSWindow?
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    /// Serial queue for the log-tailing source. A serial target queue guarantees the
    /// event handler and the cancel handler (which closes the FileHandle) never run
    /// concurrently, so a queued read can't hit a closed handle during teardown (T1.1/H-4).
    private let tailQueue = DispatchQueue(label: "com.openwhisperer.overlay.tail", qos: .utility)

    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    @Published var lines: [Line] = []
    @Published var isVisible: Bool = false
    @Published var isTTSPlaying: Bool = false
    private var nextLineId = 0
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
    /// "Loading speech model…", a failure message, or a setup failure (e.g. spaCy)
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
        let hostingView = NSHostingView(rootView: OverlayView(overlay: self))

        // FIX: sizingOptions ensures the hosting view participates in layout
        // and does not clip the SwiftUI render layer, which can suppress CA commits.
        hostingView.sizingOptions = [.minSize, .intrinsicContentSize, .preferredContentSize]

        let w = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 130),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.delegate = self
        w.contentView = hostingView
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.minSize = NSSize(width: 160, height: 70)

        // Round corners
        if let contentView = w.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 12
            contentView.layer?.masksToBounds = true
            // Warm "Open Whisperer" surface (cream / warm-dark) to match the menubar + site.
            // Dark value matches OWColor.page dark (0x1E1B16). Near-opaque to avoid bleed-through.
            contentView.layer?.backgroundColor = NSColor.ow(0xFAF7F1, 0x1E1B16).withAlphaComponent(0.97).cgColor
        }

        // Position bottom-right of screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 300
            let y = screen.visibleFrame.minY + 20
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        w.orderFront(nil)
        self.window = w
        isVisible = true
        startTailing()
        startTTSPolling()
    }

    func hide() {
        stopTailing()
        stopTTSPolling()
        window?.close()
        window = nil
        isVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        stopTailing()
        stopTTSPolling()
        window = nil
        isVisible = false
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

    private func startTailing() {
        stopTailing()

        let logPath = Paths.serverLog.path
        guard FileManager.default.fileExists(atPath: logPath) else { return }

        guard let fh = FileHandle(forReadingAtPath: logPath) else { return }
        fh.seekToEndOfFile()
        fileHandle = fh

        let fd = fh.fileDescriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: tailQueue
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = fh.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }

            let newLines = text.components(separatedBy: "\n")
                .filter { $0.contains("Transcribed:") }
                .compactMap { line -> String? in
                    guard let range = line.range(of: "Transcribed: ") else { return nil }
                    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }

            if !newLines.isEmpty {
                DispatchQueue.main.async {
                    let tagged = newLines.map { text -> Line in
                        self.nextLineId += 1
                        return Line(id: self.nextLineId, text: text)
                    }
                    self.lines.append(contentsOf: tagged)
                    if self.lines.count > 3 {
                        self.lines = Array(self.lines.suffix(3))
                    }
                }
            }
        }

        src.setCancelHandler {
            try? fh.close()
        }

        src.resume()
        source = src
    }

    private func stopTailing() {
        // Cancel source first — its cancel handler exclusively closes the file handle (H-4)
        let src = source
        source = nil
        fileHandle = nil
        src?.cancel()
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

    var body: some View {
        // FIX: Derive recorder from overlay.currentRecorder each time body evaluates.
        // Because overlay is @ObservedObject and currentRecorder is @Published,
        // any assignment to overlay.currentRecorder triggers a body re-evaluation
        // here, giving WaveformBar the new live instance.
        let recorder = overlay.currentRecorder

        VStack(alignment: .leading, spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: { overlay.hide() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(OWColor.inkFaint)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .padding(.trailing, 6)
            }
            .frame(height: 14)

            // Waveform always visible — shows status label + bars
            WaveformBar(recorder: recorder, isTTSPlaying: overlay.isTTSPlaying, pttKeyLabel: overlay.pttKeyLabel, interactionMode: overlay.interactionMode)
                .frame(height: 36)
                .padding(.horizontal, 8)

            // Silence progress bar — always visible in hands-free mode
            if overlay.interactionMode == .handsFree {
                SilenceProgressBar(recorder: recorder)
                    .frame(height: 1.5)
                    .padding(.horizontal, 8)
                    .padding(.top, 3)
            }

            Divider().padding(.horizontal, 8).padding(.vertical, 4)

            if let status = overlay.statusText {
                // Model loading / failed, or a setup failure — never claim "Listening".
                VStack(spacing: 6) {
                    Label(status, systemImage: overlay.statusIsError ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                        .font(.custom("Outfit", size: 10))
                        .foregroundColor(overlay.statusIsError ? OWColor.danger : OWColor.inkSoft)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if overlay.statusIsError, let dm = overlay.dictationManager, dm.sttFailed {
                        Button("Retry") { dm.retrySTT() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
            } else if overlay.lines.isEmpty && recorder.state == .idle {
                Text("Listening for transcriptions...")
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(overlay.lines.reversed().enumerated()), id: \.element.id) { index, line in
                            if index > 0 {
                                Divider()
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                            }
                            Text(line.text)
                                .font(.custom("Outfit", size: 11))
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Waveform Bar

struct WaveformBar: View {
    @ObservedObject var recorder: AudioRecorder
    var isTTSPlaying: Bool = false
    var pttKeyLabel: String = "Ctrl"
    var interactionMode: InteractionMode = .pressToTalk

    /// Active/recording waveform: warm cream-gold → gold → deep gold (mirrors the site's EQ bars).
    private static let waveGradient = LinearGradient(
        colors: [Color.ow(0xE7CF9E, 0xE7CF9E), OWColor.accent, OWColor.accentDeep],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Idle/standby waveform: muted warm neutral.
    private static let idleGradient = LinearGradient(
        colors: [OWColor.inkFaint, OWColor.inkSoft, OWColor.inkFaint],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Listening gradient: gold tones.
    private static let listeningGradient = LinearGradient(
        colors: [OWColor.accent, OWColor.accentDeep, OWColor.accent],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// TTS-mode gradient: warm gold (the output counterpart to the recording gradient).
    private static let ttsGradient = LinearGradient(
        colors: [Color.ow(0xE7CF9E, 0xE7CF9E), OWColor.accent, OWColor.accentDeep],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(statusColor)
                Spacer()
                if recorder.state == .recording {
                    let hint: String = {
                        switch interactionMode {
                        case .holdToTalk: return "Release \(pttKeyLabel) to stop"
                        case .handsFree: return "silence submits"
                        case .pressToTalk: return "Press \(pttKeyLabel) to stop"
                        }
                    }()
                    Text(hint)
                        .font(.custom("Outfit", size: 9))
                        .foregroundColor(.secondary)
                }
            }

            // Mirrored line waveform
            GeometryReader { geo in
                if isTTSPlaying && recorder.state == .idle {
                    TimelineView(.animation(minimumInterval: 0.03)) { timeline in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let levels = Self.ttsLevels(count: 50, time: time)
                        Self.mirroredLines(levels: levels, size: geo.size)
                            .fill(Self.ttsGradient)
                    }
                } else {
                    let gradient = recorder.state == .listening ? Self.listeningGradient : Self.idleGradient
                    Self.mirroredLines(levels: recorder.levelHistory.map { CGFloat($0) }, size: geo.size)
                        .fill(gradient)
                        .opacity(recorder.state == .uploading ? 0.5 : recorder.state == .idle ? 0.25 : 1.0)
                }
            }
        }
    }

    // MARK: - Mirrored Lines

    /// Vertical bars mirrored around center line, tapered at edges.
    private static func mirroredLines(levels: [CGFloat], size: CGSize) -> Path {
        guard !levels.isEmpty else { return Path() }

        let n = levels.count
        let barWidth: CGFloat = 2
        let gap: CGFloat = max(1, (size.width - barWidth * CGFloat(n)) / CGFloat(n - 1))
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

    /// Generate sine-wave levels for TTS animation.
    private static func ttsLevels(count: Int, time: Double) -> [CGFloat] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let wave1 = sin(time * 3.0 + t * .pi * 4) * 0.35
            let wave2 = sin(time * 1.8 + t * .pi * 2.5) * 0.25
            let wave3 = sin(time * 5.0 + t * .pi * 7) * 0.1
            return CGFloat(max(0.05, (wave1 + wave2 + wave3 + 0.5) * 0.8))
        }
    }

    private var statusColor: Color {
        if isTTSPlaying && recorder.state == .idle { return OWColor.accent }
        switch recorder.state {
        case .recording: return OWColor.recording
        case .uploading: return OWColor.warn
        case .listening: return OWColor.accentDeep
        case .idle: return OWColor.live
        }
    }

    private var statusText: String {
        if isTTSPlaying && recorder.state == .idle { return "Speaking..." }
        switch recorder.state {
        case .recording: return "Recording..."
        case .uploading: return "Transcribing..."
        case .listening: return "Listening..."
        case .idle: return "Standby"
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
