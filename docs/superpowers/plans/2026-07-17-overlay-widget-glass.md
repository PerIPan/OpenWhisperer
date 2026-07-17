# Overlay Widget-Glass Faceplate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the overlay's near-opaque dark faceplate with widget-style glass — Liquid Glass (`NSGlassEffectView`) on macOS 26, untinted `NSVisualEffectView` blur on macOS 14–25 — per `docs/superpowers/specs/2026-07-17-overlay-widget-glass-design.md`.

**Architecture:** A throwaway click-to-cycle spike tool first proves glass doesn't dim when unfocused and picks the winning variant; then `TranscriptionOverlay.swift`'s window construction gains an availability-gated `makeFaceplate(hosting:)` helper and loses the 0.75-alpha dark tint layer. Nothing outside window construction changes.

**Tech Stack:** Swift / AppKit only. No new dependencies. CLT 26.5 SDK has `NSGlassEffectView` (verified).

## Global Constraints

- Deployment floor stays `.macOS(.v14)`; all `NSGlassEffectView` use behind `if #available(macOS 26.0, *)`.
- Corner radius **10 pt** on every variant (matches the existing `faceplateMask()`).
- **No TDD cycle in this plan:** the change is AppKit-only; per AGENTS.md only pure logic in `OpenWhispererKit` is unit-testable. Verification = `swift build` + both existing test runners staying green + the on-device manual matrix.
- The spike (Task 1) lives in `app/Tools/GlassSpike/` which is **gitignored — never commit it**.
- Tasks 2–3 run in a worktree branch `overlay-widget-glass` under `.claude/worktrees/` (create via `superpowers:using-git-worktrees` / EnterWorktree). Task 1 can run from the `main` checkout — the spike is untracked either way.
- Commits: Conventional Commits, subject ≤ 72 chars including prefix, `Claude-Session:` trailer only (no Co-Authored-By), per AGENTS.md.
- **Task 1 is a gate with a human verdict.** Do not start Task 2 until Hakan reports (a) whether glass dims when unfocused, (b) whether the gold foreground renders clean, and (c) the winning variant.

---

### Task 1: GlassSpike de-risk tool (local-only, not committed)

**Files:**
- Create: `app/Tools/GlassSpike/Package.swift`
- Create: `app/Tools/GlassSpike/Sources/main.swift`

**Interfaces:**
- Consumes: nothing from the repo (standalone SwiftPM package, zero dependencies).
- Produces: a human verdict recorded in the conversation — `dimsWhenUnfocused: yes/no`, `foregroundClean: yes/no`, `winner: glassRegular | glassTinted | glassClear | fallbackEffect`. Task 2's default derives from it.

- [ ] **Step 1: Write the spike package manifest**

```swift
// swift-tools-version: 5.9
import PackageDescription

// Standalone, gitignored spike. Run from this directory:
//   swift run GlassSpike
// De-risk harness for the widget-glass overlay spec
// (docs/superpowers/specs/2026-07-17-overlay-widget-glass-design.md):
// floating never-key panel, click cycles background variants (Liquid Glass
// regular / dark-tinted / clear + untinted NSVisualEffectView fallback)
// under gold sample LED content.
let package = Package(
    name: "GlassSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GlassSpike", path: "Sources")
    ]
)
```

- [ ] **Step 2: Write the spike (`Sources/main.swift`)**

```swift
import AppKit

// GlassSpike — click anywhere on the panel (no focus needed) to cycle
// variants; the variant name flashes ~1.5 s and is also printed to the
// terminal. Quit with Ctrl+C in the terminal that ran `swift run`.
//
// Verifies, per the spec's spike gate:
//   1. Glass does NOT dim while the window is unfocused (it can never become key).
//   2. Bright gold foreground renders unaltered on top of the glass.
//   3. Which variant reads best over light + dark desktops.

func nsColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// OWColor.accent's dark-appearance gold (Theme.swift) — the color the real
// LED segments show on the faceplate.
let goldHex: UInt32 = 0xCBA86A

enum Variant: Int, CaseIterable {
    case glassRegular, glassTinted, glassClear, fallbackEffect

    var label: String {
        switch self {
        case .glassRegular: return "glass .regular, untinted"
        case .glassTinted: return "glass .regular, dark tint 0.35"
        case .glassClear: return "glass .clear"
        case .fallbackEffect: return "fallback .hudWindow, untinted"
        }
    }
}

/// Static stand-in for the analyzer: 24 gold LED columns at fixed pseudo-levels.
final class GoldBarsView: NSView {
    private static let levels: [CGFloat] = [
        0.2, 0.35, 0.5, 0.7, 0.85, 1.0, 0.9, 0.75,
        0.6, 0.8, 0.95, 0.7, 0.5, 0.65, 0.8, 0.55,
        0.4, 0.6, 0.45, 0.3, 0.5, 0.35, 0.25, 0.15,
    ]

    override func draw(_ dirtyRect: NSRect) {
        let gold = nsColor(goldHex)
        let inset = bounds.insetBy(dx: 12, dy: 12)
        let count = Self.levels.count
        let slot = inset.width / CGFloat(count)
        let segments = 12
        let gap: CGFloat = 2
        let segmentHeight = (inset.height - CGFloat(segments - 1) * gap) / CGFloat(segments)
        for (i, level) in Self.levels.enumerated() {
            let lit = Int((level * CGFloat(segments)).rounded())
            let x = inset.minX + CGFloat(i) * slot
            for s in 0..<lit {
                let y = inset.minY + CGFloat(s) * (segmentHeight + gap)
                gold.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: x + 1, y: y, width: slot - 2, height: segmentHeight),
                    xRadius: 1.5, yRadius: 1.5
                ).fill()
            }
        }
    }
}

/// Reports clicks even when the window is inactive (the state under test).
final class ClickCatcherView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Copy of TranscriptionOverlay.faceplateMask() — the sanctioned way to shape
/// an NSVisualEffectView (touching its layer breaks the material).
func faceplateMask() -> NSImage {
    let radius: CGFloat = 10
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

func makeVariantView(_ variant: Variant, size: NSSize) -> NSView {
    let content = NSView(frame: NSRect(origin: .zero, size: size))
    content.autoresizingMask = [.width, .height]

    let bars = GoldBarsView(frame: content.bounds)
    bars.autoresizingMask = [.width, .height]
    content.addSubview(bars)

    let label = NSTextField(labelWithString: variant.label)
    label.textColor = .white
    label.backgroundColor = nsColor(0x000000, alpha: 0.55)
    label.drawsBackground = true
    label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
    label.sizeToFit()
    label.frame.origin = NSPoint(
        x: (size.width - label.frame.width) / 2,
        y: (size.height - label.frame.height) / 2
    )
    content.addSubview(label)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak label] in
        label?.isHidden = true
    }

    switch variant {
    case .glassRegular, .glassTinted, .glassClear:
        guard #available(macOS 26.0, *) else {
            fatalError("glass variants need macOS 26")
        }
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 10
        if variant == .glassTinted {
            glass.tintColor = nsColor(0x1E1B16, alpha: 0.35)  // ghost of the old smoked face
        }
        if variant == .glassClear {
            glass.style = .clear
        }
        glass.contentView = content
        return glass
    case .fallbackEffect:
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = faceplateMask()
        effect.addSubview(content)
        return effect
    }
}

/// Never becomes key — unfocused rendering is exactly what we're testing.
final class SpikeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let size = NSSize(width: 320, height: 120)
let window = SpikeWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.level = .floating
window.backgroundColor = .clear
window.isOpaque = false
window.hasShadow = true  // spec: try the widget-style shadow; judge the rim live
window.isReleasedWhenClosed = false

let catcher = ClickCatcherView(frame: NSRect(origin: .zero, size: size))
catcher.autoresizingMask = [.width, .height]

var current = Variant.glassRegular

func showVariant(_ variant: Variant) {
    catcher.subviews.forEach { $0.removeFromSuperview() }
    let v = makeVariantView(variant, size: size)
    v.frame = catcher.bounds
    v.autoresizingMask = [.width, .height]
    catcher.addSubview(v)
    print("variant: \(variant.label)")
}

catcher.onClick = {
    current = Variant(rawValue: (current.rawValue + 1) % Variant.allCases.count) ?? .glassRegular
    showVariant(current)
}

window.contentView = catcher

if let screen = NSScreen.main {
    let x = screen.visibleFrame.maxX - size.width - 20
    let y = screen.visibleFrame.minY + 20
    window.setFrameOrigin(NSPoint(x: x, y: y))
}

showVariant(current)
window.orderFrontRegardless()
app.run()
```

- [ ] **Step 3: Build the spike**

Run: `cd app/Tools/GlassSpike && swift build`
Expected: `Build complete!` (no dependencies, seconds). If `NSGlassEffectView` is unresolved, the CLT SDK is stale — stop and report; do not work around it.

- [ ] **Step 4: Run it and hand off to Hakan**

Run: `cd app/Tools/GlassSpike && swift run GlassSpike`
Expected: a floating rounded panel bottom-right, gold LEDs on glass, variant label flashing. It never takes focus; clicks cycle variants (terminal echoes each). This process blocks the terminal — run it in the background or a separate terminal, and stop it with Ctrl+C (or `kill`) when done.

Hakan's checklist (over a **light** desktop, then a **dark** one — swap wallpaper or drag the panel over light/dark windows; also confirm while another app is frontmost and busy):
1. Does any glass variant visibly dim/gray compared to the moment a click lands on it? (`dimsWhenUnfocused`)
2. Do the gold LEDs look identical across variants — no washing, tinting, or vibrancy shift? (`foregroundClean`)
3. Which variant wins? (`winner`)
4. Does the window shadow read like the widget's soft rim, or as an ugly border? (feeds Task 2's `hasShadow`)

**GATE: record all four answers in the conversation before Task 2.**

---

### Task 2: Wire the winning variant into TranscriptionOverlay.swift

**Files:**
- Modify: `app/Sources/OpenWhisperer/TranscriptionOverlay.swift:121-157` (the effect/tint/window-chrome block in `show()`) and add one private helper next to `faceplateMask()` (~line 196).

**Interfaces:**
- Consumes: Task 1's verdict. The code below assumes the expected outcome — `winner: glassRegular`, no dimming, shadow OK. Exact substitutions for other verdicts are listed in Step 3.
- Produces: `private static func makeFaceplate(hosting: NSView) -> NSView` used only by `show()`. `faceplateMask()` stays (the fallback path uses it).

- [ ] **Step 1: Enter the worktree**

Run: `git worktree add .claude/worktrees/overlay-widget-glass -b overlay-widget-glass` (or EnterWorktree). All remaining steps run there.

- [ ] **Step 2: Replace the construction block in `show()`**

Delete lines 121–157 of `TranscriptionOverlay.swift` — from the `// Smoked-glass dark instrument face...` comment through `w.hasShadow = false` inclusive (the `NSVisualEffectView` + tint creation, the constraints block, and the window chrome lines). In their place:

```swift
        // Widget-style glass faceplate (2026-07-17 spec): macOS 26 gets real
        // Liquid Glass; earlier versions keep the untinted behind-window blur.
        w.contentView = Self.makeFaceplate(hosting: hostingView)
        w.backgroundColor = .clear
        w.isOpaque = false
        if #available(macOS 26.0, *) {
            // The widget-style soft shadow reads correctly on glass; the old
            // "light rim" objection was specific to the dark faceplate.
            w.hasShadow = true
        } else {
            w.hasShadow = false
        }
```

- [ ] **Step 3: Add the `makeFaceplate` helper**

Insert directly above `faceplateMask()` (~line 196):

```swift
    /// Builds the faceplate that fills the window: Liquid Glass on macOS 26,
    /// untinted behind-window blur (masked to the same 10 pt corners) earlier.
    private static func makeFaceplate(hosting: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 10
            // contentView placement is managed by the glass view; track its
            // bounds via autoresizing (verified against drag-resize in the
            // on-device matrix).
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            hosting.frame = glass.bounds
            return glass
        }
        // Pre-26: system HUD blur of whatever is behind the window. Shaped via
        // maskImage — mutating the effect view's own layer silently breaks the blur.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = faceplateMask()
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        return effect
    }
```

**Verdict substitutions** (apply whichever Task 1 recorded, then continue):
- `winner: glassTinted` → after `glass.cornerRadius = 10` add `glass.tintColor = NSColor.ow(0x1E1B16, 0x1E1B16).withAlphaComponent(0.35)`.
- `winner: glassClear` → change `glass.style = .regular` to `glass.style = .clear`.
- `winner: fallbackEffect` **or** `dimsWhenUnfocused: yes` → delete the entire `if #available` glass branch from `makeFaceplate` (the effect-view path runs on all versions) and delete the `hasShadow` availability check in `show()`, keeping `w.hasShadow = false`.
- Shadow read as an ugly border in the spike → `w.hasShadow = false` unconditionally (drop the availability check).

- [ ] **Step 4: Build and run both test runners**

Run, from the worktree's `app/`: `swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: build succeeds; both runners exit 0 (this change touches no Kit logic or hooks — any failure is pre-existing or a broken edit; investigate before proceeding).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenWhisperer/TranscriptionOverlay.swift
git commit -m "feat(overlay): widget-glass faceplate, Liquid Glass on macOS 26"
```

(Body optional; if used, note the spike verdict in one line. `Claude-Session:` trailer per AGENTS.md.)

---

### Task 3: Packaged on-device verification, version bump, PR

**Files:**
- Modify: `app/Resources/Info.plist` (`CFBundleVersion`, `CFBundleShortVersionString`: `1.10.0` → `1.11.0`)

**Interfaces:**
- Consumes: the committed Task 2 change in the worktree.
- Produces: an installed `/Applications/OpenWhisperer.app` verified live, and an open PR.

- [ ] **Step 1: Build a signed bundle and install it**

From the worktree's `app/`:
```bash
OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh
killall OpenWhisperer || true
rm -rf /Applications/OpenWhisperer.app
cp -R .build/OpenWhisperer.app /Applications/
```
Then launch it (note: `open /Applications/OpenWhisperer.app` fails with error -600 in sandboxed Bash — rerun that one command with the sandbox disabled, or have Hakan click it). The stable "OpenWhisperer Dev" identity keeps TCC grants; the cert is in the login keychain even though `security find-identity -v` hides it.

- [ ] **Step 2: On-device manual matrix (Hakan, per the spec)**

Focused **and** unfocused, over light **and** dark desktops:
- 3 analyzer styles × (recording / TTS playback)
- LOADING and ERROR marquees
- Hands-free silence bar
- Drag-resize: corners stay crisp at any size **and the analyzer tracks the window** (if content freezes at the old size on the glass path, replace the autoresizing lines in `makeFaceplate` with the same four-anchor constraint block the fallback uses, pinning `hosting` to `glass` — legal, since `contentView` makes it a descendant — then rebuild and re-check)
- Shadow: keep `hasShadow = true` only if it doesn't double-rim against the glass edge highlight; otherwise set false, rebuild, reinstall

Fix-ups discovered here amend the Task 2 commit (`git commit --amend --no-edit`) — they're the same logical change.

- [ ] **Step 3: Bump the version**

In the worktree's `app/Resources/Info.plist`, set **both** `CFBundleVersion` and `CFBundleShortVersionString` to `1.11.0`. Then:

```bash
git add app/Resources/Info.plist
git commit -m "build: bump version to 1.11.0"
```

- [ ] **Step 4: Push and open the PR**

```bash
git fetch origin && git rebase origin/main   # only if origin/main moved
git push -u origin overlay-widget-glass
gh pr create --title "feat(overlay): widget-glass faceplate" --body "..."
```
PR body: link the spec (`docs/superpowers/specs/2026-07-17-overlay-widget-glass-design.md`), state the spike verdict, and note the manual matrix passed. After merge: `git pull --ff-only` on `main`, `git worktree remove .claude/worktrees/overlay-widget-glass`, delete the branch.
