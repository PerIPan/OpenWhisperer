# Overlay Analyzer Styles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the overlay's fixed vintage 8×7 gold spectrum with three selectable analyzer styles (LED Bars / Graph / Curtain), clean-room from audioMotion's multi-demo defaults, picked in Settings → General.

**Architecture:** One shared 96-band Goertzel analysis layer in `OpenWhispererKit` feeds three SwiftUI `Canvas` renderers in the app target. Style is a flat pref file (`overlay_style`) surfaced as a `@Published` on `TranscriptionOverlay`. Spec: `docs/superpowers/specs/2026-07-16-analyzer-styles-design.md`.

**Tech Stack:** Swift/SwiftUI (no new dependencies), plain-executable Kit test runner (no XCTest — CLT only).

## Global Constraints

- All Swift commands run from `app/` (SwiftPM root). Tests: `swift run OpenWhispererKitTests` (exits non-zero on failure).
- Kit stays pure Foundation (no AppKit/SwiftUI/Accelerate) — that's what keeps it CLT-testable.
- Overlay window: 220×84 (`OverlayView.pillWidth`/`pillHeight` are the source of truth; the `NSWindow` contentRect must use them, not literals).
- Analysis layout: **96 log-spaced bands, 50 Hz – 7.5 kHz** (top center below the mic's 8 kHz Nyquist).
- Style ids (pref file values): `led_bars` | `graph` | `curtain`; missing/garbage → `led_bars`.
- Clean-room: constants are our own measurements of the demo's look; never translate audioMotion source (AGPL).
- Commits: Conventional Commits, ≤72 chars incl. prefix, `Claude-Session:` trailer only.
- Work in worktree `.claude/worktrees/analyzer-styles`, branch `analyzer-styles`.

---

### Task 1: `OverlayStyle` (Kit)

**Files:**
- Create: `app/Sources/OpenWhispererKit/OverlayStyle.swift`
- Test: `app/Tests/OpenWhispererKitTests/OverlayStyleChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (add `failures += overlayStyleFailures()` after the `dotMatrixFailures()` line)

**Interfaces:**
- Produces: `public enum OverlayStyle: String, CaseIterable { case ledBars = "led_bars", graph, curtain }`, `public static let defaultStyle: OverlayStyle = .ledBars`, `public static func parse(_ raw: String?) -> OverlayStyle` (trims whitespace/newlines).

- [ ] **Step 1: Write the failing checks**

```swift
// app/Tests/OpenWhispererKitTests/OverlayStyleChecks.swift
import Foundation
import OpenWhispererKit

/// Checks for `OverlayStyle` — the overlay analyzer-style pref (led_bars/graph/curtain).
func overlayStyleFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("OverlayStyle.\(name): \(detail)") }
    }

    expect(OverlayStyle.parse("led_bars") == .ledBars, "parseLed", "got \(OverlayStyle.parse("led_bars"))")
    expect(OverlayStyle.parse("graph") == .graph, "parseGraph", "got \(OverlayStyle.parse("graph"))")
    expect(OverlayStyle.parse("curtain") == .curtain, "parseCurtain", "got \(OverlayStyle.parse("curtain"))")
    expect(OverlayStyle.parse(" curtain\n") == .curtain, "trims", "got \(OverlayStyle.parse(" curtain\n"))")
    expect(OverlayStyle.parse(nil) == .ledBars, "nilDefault", "got \(OverlayStyle.parse(nil))")
    expect(OverlayStyle.parse("vintage") == .ledBars, "garbageDefault", "got \(OverlayStyle.parse("vintage"))")
    expect(OverlayStyle.parse("") == .ledBars, "emptyDefault", "got \(OverlayStyle.parse(""))")
    expect(OverlayStyle.defaultStyle == .ledBars, "default", "got \(OverlayStyle.defaultStyle)")
    return failures
}
```

Also add to the runner (`SubmitTriggerTests.swift`), after `failures += dotMatrixFailures()`:

```swift
        failures += overlayStyleFailures()
```

- [ ] **Step 2: Run to verify failure**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: build error — `cannot find 'OverlayStyle' in scope` (a compile failure is this harness's "failing test").

- [ ] **Step 3: Implement**

```swift
// app/Sources/OpenWhispererKit/OverlayStyle.swift
import Foundation

/// Overlay analyzer style pref (`overlay_style` flat file). Same parse-with-default
/// shape as `TTSSpeed`: bad/missing input never breaks the overlay.
public enum OverlayStyle: String, CaseIterable {
    case ledBars = "led_bars"
    case graph
    case curtain

    public static let defaultStyle: OverlayStyle = .ledBars

    /// Trims and parses a raw pref-file string; anything unrecognized → default.
    public static func parse(_ raw: String?) -> OverlayStyle {
        guard let raw else { return defaultStyle }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return OverlayStyle(rawValue: trimmed) ?? defaultStyle
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenWhispererKit/OverlayStyle.swift Tests/OpenWhispererKitTests/OverlayStyleChecks.swift Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(kit): add OverlayStyle analyzer-style pref type"
```

---

### Task 2: 96-band analysis + `aggregate` (Kit)

**Files:**
- Modify: `app/Sources/OpenWhispererKit/SpectrumBands.swift`
- Test: `app/Tests/OpenWhispererKitTests/SpectrumBandsChecks.swift`

**Interfaces:**
- Consumes: existing `SpectrumBands.bands(samples:sampleRate:gainDb:)` (unchanged signature).
- Produces: `SpectrumBands.bandCount == 96`, centers 50 Hz–7.5 kHz; `public static func aggregate(_ bands: [Float], into count: Int) -> [Float]` (max-pooling; `count <= 0` → `[]`, empty input → zeros).

- [ ] **Step 1: Add failing checks** (append inside `spectrumBandsFailures()` in `SpectrumBandsChecks.swift`; keep existing checks — they're written against `bandCount`/`centerFrequencies` and survive the resize)

```swift
    // 96-band layout (overlay analyzer styles, 2026-07-16 spec)
    expect(SpectrumBands.bandCount == 96, "bandCount96", "got \(SpectrumBands.bandCount)")
    expect(abs(SpectrumBands.centerFrequencies.first! - 50) < 0.5, "lo50", "got \(SpectrumBands.centerFrequencies.first!)")
    expect(abs(SpectrumBands.centerFrequencies.last! - 7_500) < 0.5, "hi7500", "got \(SpectrumBands.centerFrequencies.last!)")
    expect(SpectrumBands.centerFrequencies.last! < 8_000, "underMicNyquist", "top center must stay below 8 kHz")
    expect(zip(SpectrumBands.centerFrequencies, SpectrumBands.centerFrequencies.dropFirst()).allSatisfy { $0 < $1 },
           "monotonic", "centers must ascend")

    // aggregate: max-pooling reducer
    let agg = SpectrumBands.aggregate([0.1, 0.9, 0.2, 0.3, 0.8, 0.1], into: 3)
    expect(agg == [0.9, 0.3, 0.8], "aggregateMax", "got \(agg)")
    let remainder = SpectrumBands.aggregate([1, 2, 3, 4, 5], into: 2)
    expect(remainder == [2, 5], "aggregateRemainder", "got \(remainder)")
    expect(SpectrumBands.aggregate([], into: 4) == [0, 0, 0, 0], "aggregateEmpty", "empty input → zeros")
    expect(SpectrumBands.aggregate([1, 2], into: 0) == [], "aggregateZero", "count 0 → []")
    let identity = SpectrumBands.aggregate([0.5, 0.6], into: 2)
    expect(identity == [0.5, 0.6], "aggregateIdentity", "got \(identity)")
```

- [ ] **Step 2: Run to verify failure**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: compile error on `aggregate` (not defined) — then after stubbing, `bandCount96` fails with `got 8`.

- [ ] **Step 3: Implement** — in `SpectrumBands.swift` change the layout constants and add `aggregate`:

```swift
    /// One shared analysis resolution for every overlay style (styles that render
    /// fewer columns reduce via `aggregate`). 96 log-spaced centers, 50 Hz … 7.5 kHz —
    /// the top center stays under the 16 kHz mic feed's 8 kHz Nyquist.
    public static let bandCount = 96
    public static let centerFrequencies: [Float] = {
        let lo: Float = 50, hi: Float = 7_500
        let ratio = pow(hi / lo, 1 / Float(bandCount - 1))
        return (0..<bandCount).map { lo * pow(ratio, Float($0)) }
    }()

    /// Max-pool `bands` down to `count` columns (e.g. 96 → 24 for LED bars).
    /// Group boundaries are proportional, so non-divisible counts distribute evenly.
    public static func aggregate(_ bands: [Float], into count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !bands.isEmpty else { return [Float](repeating: 0, count: count) }
        return (0..<count).map { i in
            let j0 = i * bands.count / count
            let j1 = max(j0 + 1, (i + 1) * bands.count / count)
            return bands[j0..<min(j1, bands.count)].max() ?? 0
        }
    }
```

(Keep the doc comment on the old `centerFrequencies` updated — it currently says "80 Hz … 6 kHz (voice-focused)"; replace with the text above.)

- [ ] **Step 4: Run to verify pass**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: all checks pass. Note: the app target still compiles because `AudioRecorder`/`AudioPlaybackEngine`/the overlay reference the *constant*, not the number 8.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenWhispererKit/SpectrumBands.swift Tests/OpenWhispererKitTests/SpectrumBandsChecks.swift
git commit -m "feat(kit): 96-band analysis layout + aggregate reducer"
```

---

### Task 3: `PeakHold` (Kit)

**Files:**
- Create: `app/Sources/OpenWhispererKit/PeakHold.swift`
- Test: `app/Tests/OpenWhispererKitTests/PeakHoldChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (add `failures += peakHoldFailures()`)

**Interfaces:**
- Produces: `public struct PeakHold` with `public init(holdSeconds: Double = 0.5, fallPerSecond: Float = 1.5)` and `public mutating func update(bands: [Float], at time: Double) -> [Float]`.

- [ ] **Step 1: Write the failing checks**

```swift
// app/Tests/OpenWhispererKitTests/PeakHoldChecks.swift
import Foundation
import OpenWhispererKit

/// Checks for `PeakHold` — per-band peak markers with hold + gravity fall
/// (LED bar caps, graph peak line).
func peakHoldFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("PeakHold.\(name): \(detail)") }
    }

    var hold = PeakHold(holdSeconds: 0.5, fallPerSecond: 1.0)

    // Rising band sets the peak immediately.
    var peaks = hold.update(bands: [0.8, 0.2], at: 0)
    expect(peaks == [0.8, 0.2], "rise", "got \(peaks)")

    // Within the hold window the peak stays even though the band dropped.
    peaks = hold.update(bands: [0.1, 0.1], at: 0.3)
    expect(peaks[0] == 0.8, "holds", "got \(peaks[0])")

    // After the hold window the peak falls at fallPerSecond.
    peaks = hold.update(bands: [0.1, 0.1], at: 0.7)   // 0.2 s past hold → fell ~0.2
    expect(abs(peaks[0] - 0.6) < 0.011, "falls", "got \(peaks[0])")

    // The peak never falls below the live band.
    peaks = hold.update(bands: [0.55, 0.1], at: 0.8)
    expect(peaks[0] == 0.55, "floorsAtBand", "got \(peaks[0])")

    // A new maximum re-arms the hold.
    peaks = hold.update(bands: [0.9, 0.1], at: 1.0)
    expect(peaks[0] == 0.9, "rearm", "got \(peaks[0])")
    peaks = hold.update(bands: [0.0, 0.0], at: 1.4)
    expect(peaks[0] == 0.9, "rearmHolds", "got \(peaks[0])")

    // Band-count changes (style switch mid-flight) reset cleanly.
    peaks = hold.update(bands: [0.3], at: 2.0)
    expect(peaks == [0.3], "resize", "got \(peaks)")

    return failures
}
```

Runner: add `failures += peakHoldFailures()` after the `overlayStyleFailures()` line.

- [ ] **Step 2: Run to verify failure**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: compile error — `cannot find 'PeakHold' in scope`.

- [ ] **Step 3: Implement**

```swift
// app/Sources/OpenWhispererKit/PeakHold.swift
import Foundation

/// Per-band peak markers with a hold window then a constant-rate fall —
/// the classic analyzer "peak cap" physics. Pure state machine over
/// (bands, timestamp) so it stays CLT-testable; rendering owns the instance.
public struct PeakHold {
    private var peaks: [Float] = []
    private var heldAt: [Double] = []
    private let holdSeconds: Double
    private let fallPerSecond: Float

    public init(holdSeconds: Double = 0.5, fallPerSecond: Float = 1.5) {
        self.holdSeconds = holdSeconds
        self.fallPerSecond = fallPerSecond
    }

    /// Advance to `time` and fold in the live `bands`; returns current peak levels.
    public mutating func update(bands: [Float], at time: Double) -> [Float] {
        if peaks.count != bands.count {
            peaks = bands
            heldAt = [Double](repeating: time, count: bands.count)
            return peaks
        }
        for i in bands.indices {
            if bands[i] >= peaks[i] {
                peaks[i] = bands[i]
                heldAt[i] = time
            } else {
                let overdue = time - heldAt[i] - holdSeconds
                if overdue > 0 {
                    // Fall only for the time elapsed past the hold window, then keep falling
                    // from the last position: advance heldAt so the next frame's overdue is
                    // measured from now.
                    peaks[i] = max(bands[i], peaks[i] - fallPerSecond * Float(overdue))
                    heldAt[i] = time - holdSeconds
                }
            }
        }
        return peaks
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: all checks passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenWhispererKit/PeakHold.swift Tests/OpenWhispererKitTests/PeakHoldChecks.swift Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(kit): PeakHold peak-cap tracker with gravity fall"
```

---

### Task 4: Style renderers (app target)

**Files:**
- Create: `app/Sources/OpenWhisperer/SpectrumStyles.swift`

**Interfaces:**
- Consumes: `SpectrumBands.aggregate`, `PeakHold` (Task 2/3).
- Produces: `struct LEDBarsStyleView: View { var bands: [Float] }`, `struct GraphStyleView: View { var bands: [Float] }`, `struct CurtainStyleView: View { var bands: [Float] }` — all expect the 96-band array.

No Kit test cycle (SwiftUI); the verify step is a clean build. Constants are deliberately grouped at the top of each view for live tuning.

- [ ] **Step 1: Write the file**

```swift
// app/Sources/OpenWhisperer/SpectrumStyles.swift
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
            // Peak cap: the segment slot nearest the held peak, drawn even when unlit below.
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
```

- [ ] **Step 2: Verify it builds**

Run: `cd app && swift build`
Expected: `Build complete!` (new file compiles; nothing references it yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenWhisperer/SpectrumStyles.swift
git commit -m "feat(overlay): LED bars, graph, curtain style renderers"
```

---

### Task 5: Overlay integration — geometry, style switch, vintage removal, marquee de-vintage

**Files:**
- Modify: `app/Sources/OpenWhisperer/TranscriptionOverlay.swift`

**Interfaces:**
- Consumes: the three style views (Task 4), `OverlayStyle` (Task 1).
- Produces: `TranscriptionOverlay.analyzerStyle: OverlayStyle` (`@Published`; read from `Paths.overlayStyle` in `show()`, written to by Settings in Task 6). `Paths.overlayStyle` is added in Task 6 — for this task, read via `Paths.appSupport.appendingPathComponent("overlay_style")` is NOT used; instead add the `Paths` entry here since this task reads it first (one-line addition to `Paths.swift`).

Changes, in order:

- [ ] **Step 1: Add the pref path** — in `Paths.swift`, after the `overlayHidden` entry:

```swift
    /// Overlay analyzer style: led_bars | graph | curtain (see OverlayStyle.parse).
    static let overlayStyle = appSupport.appendingPathComponent("overlay_style")
```

- [ ] **Step 2: Grow the faceplate** — in `OverlayView`:

```swift
    static let pillHeight: CGFloat = 84   // was 52; "a bit taller" per 2026-07-16 spec
    static let pillWidth: CGFloat = 220
```

and in `TranscriptionOverlay.show()` replace the literal contentRect:

```swift
        let w = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: OverlayView.pillWidth, height: OverlayView.pillHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
```

- [ ] **Step 3: Publish the style** — on `TranscriptionOverlay`, next to the other `@Published` vars:

```swift
    /// Active analyzer style (LED bars / graph / curtain). Read from the pref
    /// file on show(); Settings writes the file and updates this directly.
    @Published var analyzerStyle: OverlayStyle = .defaultStyle
```

and at the top of `show()` (before the early-return-if-window-exists branch so re-shows refresh it):

```swift
        analyzerStyle = OverlayStyle.parse(try? String(contentsOf: Paths.overlayStyle, encoding: .utf8))
```

Add `import OpenWhispererKit` if not present (it is — line 4).

- [ ] **Step 4: Swap the spectrum for the style switch** — in `OverlayView.body`, pass the style through: `WaveformBar(recorder: recorder, isTTSPlaying: overlay.isTTSPlaying, statusIsError: overlay.statusIsError, statusText: overlay.statusText, style: overlay.analyzerStyle)`. In `WaveformBar`, add `var style: OverlayStyle = .defaultStyle` and replace the `Group` body:

```swift
            Group {
                if statusText != nil {
                    marquee(word: statusIsError ? "ERROR" : "LOADING",
                            color: statusIsError ? OWColor.danger : OWColor.accent)
                } else {
                    let live = (isTTSPlaying && recorder.state == .idle)
                        ? playbackMeter.spectrumBands : recorder.spectrumBands
                    let bands = live.isEmpty
                        ? [Float](repeating: 0, count: SpectrumBands.bandCount) : live
                    switch style {
                    case .ledBars: LEDBarsStyleView(bands: bands)
                    case .graph: GraphStyleView(bands: bands)
                    case .curtain: CurtainStyleView(bands: bands)
                    }
                }
            }
```

- [ ] **Step 5: Delete the vintage renderer** — remove `WaveformBar.spectrum(bands:)`, the `segmentCount` constant, and the `// MARK: - Segmented Spectrum` block entirely. Update the stale comment above the `Group` ("Vintage segmented spectrum display…") to describe the style switch.

- [ ] **Step 6: De-vintage the marquee** — the marquee keeps `DotMatrix` scrolling but loses ghost sockets and the band-count coupling:

In `marquee(word:color:)`, replace `let gridWidth = SpectrumBands.bandCount` with a private constant on `WaveformBar`:

```swift
    /// Marquee window width in dot-matrix cell columns — its own constant now
    /// (the old code borrowed the spectrum band count).
    private static let marqueeColumns = 24
```

…and use `let gridWidth = Self.marqueeColumns`.

In `matrix(window:color:)`, unlit cells become transparent (no ghost sockets — the vintage look retired with the gold grid). Replace the cell fill logic:

```swift
                        ForEach(0..<DotMatrix.rows, id: \.self) { row in
                            let isLit = window[columnIndex][row]
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(isLit ? color : Color.clear)
                                .shadow(color: isLit ? color.opacity(0.7) : .clear, radius: 2.5)
                                .frame(height: segmentHeight)
                        }
```

Also update `matrix`'s doc comment (no more "ghost sockets", no more "same LED cell styling as the spectrum").

- [ ] **Step 7: Verify build + tests**

Run: `cd app && swift build && swift run OpenWhispererKitTests`
Expected: clean build, all checks pass. Grep for leftovers: `grep -rn "accentDeep" app/Sources` — if the overlay was its only consumer, remove the token from `Theme.swift`; if the menubar/history views use it, leave it.

- [ ] **Step 8: Commit**

```bash
git add Sources/OpenWhisperer/TranscriptionOverlay.swift Sources/OpenWhisperer/Paths.swift Sources/OpenWhisperer/Theme.swift
git commit -m "feat(overlay): selectable analyzer styles, retire vintage grid"
```

---

### Task 6: Settings picker

**Files:**
- Modify: `app/Sources/OpenWhisperer/Settings/GeneralTab.swift`

**Interfaces:**
- Consumes: `OverlayStyle` (Task 1), `Paths.overlayStyle` (Task 5), `TranscriptionOverlay.shared.analyzerStyle` (Task 5).

- [ ] **Step 1: Add the picker** — `import OpenWhispererKit` at the top of `GeneralTab.swift`; add state next to the existing `@State` vars:

```swift
    @State private var overlayStyle: OverlayStyle = .defaultStyle
    @State private var overlayStyleLoaded = false
```

Insert a new section between the launch-at-login `Section` and `Section("Permissions")`:

```swift
            Section("Overlay") {
                Picker("Analyzer style", selection: $overlayStyle) {
                    Text("LED Bars").tag(OverlayStyle.ledBars)
                    Text("Graph").tag(OverlayStyle.graph)
                    Text("Curtain").tag(OverlayStyle.curtain)
                }
                .onChange(of: overlayStyle) { _, newValue in
                    guard overlayStyleLoaded else { return }
                    try? newValue.rawValue.write(to: Paths.overlayStyle, atomically: true, encoding: .utf8)
                    TranscriptionOverlay.shared.analyzerStyle = newValue
                }
            }
```

In `.onAppear`, load it (same guarded-load pattern as the other prefs):

```swift
            overlayStyle = OverlayStyle.parse(try? String(contentsOf: Paths.overlayStyle, encoding: .utf8))
            DispatchQueue.main.async { overlayStyleLoaded = true }
```

- [ ] **Step 2: Verify build + both test targets**

Run: `cd app && swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: clean build, both runners green (HookTests untouched by this feature — a red run means something unrelated broke; stop and investigate).

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenWhisperer/Settings/GeneralTab.swift
git commit -m "feat(settings): overlay analyzer style picker"
```

---

### Task 7: Version bump, verify, ship

**Files:**
- Modify: `app/Resources/Info.plist` (both `CFBundleVersion` and `CFBundleShortVersionString`: `1.7.0` → `1.8.0`)

- [ ] **Step 1: Bump version** — edit both keys in `Info.plist` to `1.8.0`.

- [ ] **Step 2: Full verification**

Run from `app/`: `swift build -c release && swift run OpenWhispererKitTests && swift run HookTests`
Expected: release build completes; both runners green.

- [ ] **Step 3: Commit + PR**

```bash
git add Resources/Info.plist
git commit -m "build: bump version to 1.8.0"
git push -u origin analyzer-styles
gh pr create --title "feat(overlay): selectable analyzer styles" --body "..."
```

PR body: summary of the three styles + settings picker, link to the spec, note the vintage retirement and the on-device tuning expectation (constants grouped for live iteration).

- [ ] **Step 4: Merge + clean up** (per AGENTS.md): merge the PR, `git pull --ff-only` on main, `git worktree remove .claude/worktrees/analyzer-styles`, delete the branch. Update the auto-memory note `overlay-instrument-design.md` (vintage superseded 2026-07-16 by selectable analyzer styles).

- [ ] **Step 5: On-device manual matrix** (post-merge, user-driven): 3 styles × (recording / TTS playback / LOADING / ERROR), silence bar + REC lamp on the 84 pt faceplate. Constants to tune live are grouped at the top of each style view.
