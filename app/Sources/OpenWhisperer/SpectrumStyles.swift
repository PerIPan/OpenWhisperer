import SwiftUI
import OpenWhispererKit

// Three analyzer styles, clean-room from audioMotion's multi-demo defaults
// (https://audiomotion.dev/demo/multi.html): LED Bars / Graph / Curtain.
// All consume the same 96-band analysis (SpectrumBands); colors live here,
// not in Kit. Constants are grouped up top per style for live tuning.

/// Reference box so Canvas draw closures can advance PeakHold without
/// mutating SwiftUI state from `body` (which would re-invalidate the view).
private final class PeakHoldBox {
    var hold = PeakHold()
}

// MARK: - LED Bars (default) — 24 columns × 12 segments, classic gradient,
// falling peak caps, mirrored reflection along the bottom.

struct LEDBarsStyleView: View {
    var bands: [Float]

    private static let columns = 24
    private static let segments = 12
    private static let reflexRatio: CGFloat = 0.10   // demo reflexRatio .1
    private static let reflexAlpha: CGFloat = 0.25   // demo reflexAlpha .25
    private static let barSpace: CGFloat = 0.3       // fraction of a column left as gap
    private static let green = Color(red: 0.18, green: 0.80, blue: 0.25)
    private static let yellow = Color(red: 1.00, green: 0.86, blue: 0.00)
    private static let red = Color(red: 1.00, green: 0.25, blue: 0.21)

    @State private var peakBox = PeakHoldBox()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let cols = SpectrumBands.aggregate(bands, into: Self.columns)
                let peaks = peakBox.hold.update(
                    bands: cols, at: timeline.date.timeIntervalSinceReferenceDate)
                let mainHeight = size.height * (1 - Self.reflexRatio)

                draw(&context, cols: cols, peaks: peaks,
                     rect: CGRect(x: 0, y: 0, width: size.width, height: mainHeight))

                // Reflection: same bars, flipped into the bottom strip, faded.
                context.opacity = Self.reflexAlpha
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -Self.reflexRatio / (1 - Self.reflexRatio))
                draw(&context, cols: cols, peaks: peaks,
                     rect: CGRect(x: 0, y: 0, width: size.width, height: mainHeight))
            }
        }
    }

    /// Segment color by vertical position: green base, yellow above 60%, red above 85%.
    private func segmentColor(_ frac: CGFloat) -> Color {
        if frac >= 0.85 { return Self.red }
        if frac >= 0.60 { return Self.yellow }
        return Self.green
    }

    private func draw(_ context: inout GraphicsContext, cols: [Float], peaks: [Float], rect: CGRect) {
        let colWidth = rect.width / CGFloat(Self.columns)
        let barWidth = colWidth * (1 - Self.barSpace)
        let segGap: CGFloat = 1.5
        let segHeight = (rect.height - CGFloat(Self.segments - 1) * segGap) / CGFloat(Self.segments)
        for c in 0..<Self.columns {
            let x = rect.minX + CGFloat(c) * colWidth + (colWidth - barWidth) / 2
            let lit = Int((CGFloat(cols[c]) * CGFloat(Self.segments)).rounded())
            for s in 0..<lit where s < Self.segments {
                let frac = CGFloat(s) / CGFloat(Self.segments - 1)
                let y = rect.maxY - CGFloat(s + 1) * segHeight - CGFloat(s) * segGap
                context.fill(
                    Path(roundedRect: CGRect(x: x, y: y, width: barWidth, height: segHeight),
                         cornerRadius: 1),
                    with: .color(segmentColor(frac)))
            }
            // Peak cap: the segment slot nearest the held peak, above the live bar.
            let peakSeg = Int((CGFloat(peaks[c]) * CGFloat(Self.segments)).rounded())
            if peakSeg > 0, peakSeg > lit {
                let s = min(peakSeg, Self.segments) - 1
                let frac = CGFloat(s) / CGFloat(Self.segments - 1)
                let y = rect.maxY - CGFloat(s + 1) * segHeight - CGFloat(s) * segGap
                context.fill(
                    Path(roundedRect: CGRect(x: x, y: y, width: barWidth, height: segHeight),
                         cornerRadius: 1),
                    with: .color(segmentColor(frac).opacity(0.85)))
            }
        }
    }
}

// MARK: - Graph — smooth filled spectrum curve, steel-blue fill, orange-red
// peak line (mono adaptation of the demo's stereo dual-fill).

struct GraphStyleView: View {
    var bands: [Float]

    private static let fill = Color(red: 0.27, green: 0.51, blue: 0.71)      // steelblue
    private static let peak = Color(red: 1.00, green: 0.27, blue: 0.00)      // orangered
    private static let fillAlpha: CGFloat = 0.55  // demo fillAlpha .3 is over black; ours sits on glass

    @State private var peakBox = PeakHoldBox()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                guard bands.count > 1 else { return }
                let peaks = peakBox.hold.update(
                    bands: bands, at: timeline.date.timeIntervalSinceReferenceDate)

                context.fill(Self.areaPath(levels: bands, in: size, closed: true),
                             with: .color(Self.fill.opacity(Self.fillAlpha)))
                context.stroke(Self.areaPath(levels: peaks, in: size, closed: false),
                               with: .color(Self.peak), lineWidth: 1.5)
            }
        }
    }

    /// Midpoint-quadratic smoothing through the level points; `closed` adds the
    /// baseline for a fillable area, open leaves a stroke-able curve.
    private static func areaPath(levels: [Float], in size: CGSize, closed: Bool) -> Path {
        let points = levels.enumerated().map { i, level in
            CGPoint(x: CGFloat(i) / CGFloat(levels.count - 1) * size.width,
                    y: size.height * (1 - CGFloat(level)))
        }
        var path = Path()
        if closed {
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: points[0])
        } else {
            path.move(to: points[0])
        }
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2,
                              y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        if closed {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Curtain — 96 thin full-height bars, prism hue sweep, opacity
// tracking level with a hotter response (demo runs −60…−30 dB).

struct CurtainStyleView: View {
    var bands: [Float]

    private static let responseGain: Float = 1.8   // remaps our −60…0 normalize toward the demo's hotter window
    private static let barSpace: CGFloat = 0.1     // demo barSpace .1
    private static let hueSweep = 300.0 / 360.0    // red → violet

    var body: some View {
        Canvas { context, size in
            let n = bands.count
            guard n > 0 else { return }
            let colWidth = size.width / CGFloat(n)
            let barWidth = colWidth * (1 - Self.barSpace)
            for i in 0..<n {
                let level = Double(min(1, bands[i] * Self.responseGain))
                guard level > 0.02 else { continue }
                let hue = Double(i) / Double(max(n - 1, 1)) * Self.hueSweep
                let rect = CGRect(x: CGFloat(i) * colWidth, y: 0,
                                  width: barWidth, height: size.height)
                context.fill(Path(rect),
                             with: .color(Color(hue: hue, saturation: 0.9, brightness: 1)
                                 .opacity(level)))
            }
        }
    }
}
