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

    // MARK: - Waveform drawing (ported from the deleted floating overlay)

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
/// (ported from the deleted floating overlay's countdown bar, restyled for the band).
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
