# TTS Speed Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose FluidAudio Kokoro's existing `speed` parameter as a global, user-settable playback rate, driven by a slider in the menubar's Voice Settings card.

**Architecture:** A tiny pure `TTSSpeed` helper (in `OpenWhispererKit`) owns the clamp/parse of a new flat `tts_speed` pref. `speed` threads into the two `KokoroTTS` synthesis entry points. It is *read* from disk exactly where the sibling `tts_volume` pref is already read — inside `TTSPlaybackController.play` and the `TTSHTTPServer` `/v1/audio/speech` path — so no call signature between the HTTP/MCP layer and the controller changes. The UI adds the app's first `Slider`.

**Tech Stack:** Swift 5.9 (SwiftPM), SwiftUI/AppKit, FluidAudio (Kokoro TTS on the ANE). Command Line Tools only.

## Global Constraints

- **Speed range `[0.7, 1.5]`, default `1.0`, slider `step: 0.05`.** The `Slider(in:)` bounds and `TTSSpeed.min`/`.max` MUST be equal — copied verbatim in Tasks 1 and 5.
- **No version bump.** Do not touch `build-dmg.sh` or `Info.plist`.
- **Global-only pref.** No per-project `OW_*` env override (structurally impossible — the `speak` path never sees a project's env).
- **Testing reality (per AGENTS.md):** this machine has **CLT only, no XCTest**. Only `OpenWhispererKit` (pure, dependency-free) is unit-testable, via plain `@main` runners that aggregate `*Failures() -> [String]` groups and `exit(1)` on failure. Code touching AppKit/FluidAudio (`KokoroTTS`, `TTSPlaybackController`, `TTSHTTPServer`, `MenuBarView`) is **not** unit-testable — its objective check is `swift build` success plus the two existing runners passing as regression. All `swift` commands run from `app/`.
- **Commits:** Conventional Commits (`type(scope): subject`, ≤72 incl. prefix). End each commit message body with the trailer `Claude-Session: https://claude.ai/code/session_01TXnhiqywjpp3QBKe1gxet9`. No tool/co-author attribution.

---

### Task 1: `TTSSpeed` clamp/parse helper (pure, unit-tested)

**Files:**
- Create: `app/Sources/OpenWhispererKit/TTSSpeed.swift`
- Create: `app/Tests/OpenWhispererKitTests/TTSSpeedChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (register the new check group)

**Interfaces:**
- Produces: `enum TTSSpeed` with `static let min: Float`, `max: Float`, `default: Float`; `static func clamp(_ v: Float) -> Float`; `static func parse(_ raw: String?) -> Float`. Consumed by Tasks 3, 4, 5.

- [ ] **Step 1: Write the failing test group**

Create `app/Tests/OpenWhispererKitTests/TTSSpeedChecks.swift`:

```swift
import OpenWhispererKit

/// Checks for `TTSSpeed` — the clamp/parse shared by TTSPlaybackController.readSpeed()
/// and TTSHTTPServer.userSpeed(). Bounds MUST match the menubar Slider's `in:` range.
func ttsSpeedFailures() -> [String] {
    var failures: [String] = []

    func expect(_ raw: String?, _ expected: Float, _ name: String) {
        let r = TTSSpeed.parse(raw)
        if r != expected {
            failures.append("TTSSpeed.\(name): parse(\(raw.debugDescription)) -> \(r); expected \(expected)")
        }
    }

    // Absent / empty / garbage → default.
    expect(nil, 1.0, "nilDefault")
    expect("", 1.0, "emptyDefault")
    expect("   \n", 1.0, "whitespaceDefault")
    expect("fast", 1.0, "garbageDefault")
    // In-range values pass through (whitespace trimmed).
    expect("1.15", 1.15, "inRange")
    expect("  0.90\n", 0.90, "trimsWhitespace")
    // Out-of-range clamps to the bounds.
    expect("9", 1.5, "clampHigh")
    expect("0.1", 0.7, "clampLow")

    // Constants are the agreed bounds.
    if TTSSpeed.min != 0.7 { failures.append("TTSSpeed.min: got \(TTSSpeed.min); expected 0.7") }
    if TTSSpeed.max != 1.5 { failures.append("TTSSpeed.max: got \(TTSSpeed.max); expected 1.5") }
    if TTSSpeed.default != 1.0 { failures.append("TTSSpeed.default: got \(TTSSpeed.default); expected 1.0") }

    return failures
}
```

Register it in the runner — in `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift`, after the line `failures += mcpServerFailures()`, add:

```swift
        failures += ttsSpeedFailures()
```

- [ ] **Step 2: Run to verify it fails (RED = build error)**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: **build failure** — `cannot find 'TTSSpeed' in scope` (the type doesn't exist yet).

- [ ] **Step 3: Implement `TTSSpeed`**

Create `app/Sources/OpenWhispererKit/TTSSpeed.swift`:

```swift
/// Clamp/parse for the global `tts_speed` preference (Kokoro playback rate).
/// Pure and dependency-free so it unit-tests under CLT; shared by every read
/// site so the bounds/default can't drift. Bounds MUST equal the menubar
/// Slider's `in:` range (see MenuBarView).
public enum TTSSpeed {
    public static let min: Float = 0.7
    public static let max: Float = 1.5
    public static let `default`: Float = 1.0

    /// Clamp any rate into `[min, max]`.
    public static func clamp(_ v: Float) -> Float {
        Swift.min(Swift.max(v, min), max)
    }

    /// Parse a stored pref string. `nil`/empty/unparseable → `default`; valid
    /// numbers are clamped into range.
    public static func parse(_ raw: String?) -> Float {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, let v = Float(s) else { return `default` }
        return clamp(v)
    }
}
```

- [ ] **Step 4: Run to verify it passes (GREEN)**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: PASS — `✅ OpenWhispererKit: all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhispererKit/TTSSpeed.swift app/Tests/OpenWhispererKitTests/TTSSpeedChecks.swift app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(tts): add TTSSpeed clamp/parse helper"
```
(Append the `Claude-Session:` trailer to the commit message body.)

---

### Task 2: Thread `speed` through `KokoroTTS`

**Files:**
- Modify: `app/Sources/OpenWhisperer/KokoroTTS.swift`

**Interfaces:**
- Consumes: FluidAudio `manager.synthesize(text:voice:speed:)` / `manager.synthesizeDetailed(text:voice:speed:)` (both take `speed: Float`, default `KokoroAneConstants.defaultSpeed` = 1.0).
- Produces: `KokoroTTS.synthesize(_:voice:speed:)` and `synthesizeSamples(_:voice:speed:)`, both with `speed: Float = 1.0`. Consumed by Tasks 3 and 4.

- [ ] **Step 1: Add `speed` to `synthesize`**

In `app/Sources/OpenWhisperer/KokoroTTS.swift`, replace:

```swift
    func synthesize(_ text: String, voice: String = "af_heart") async throws -> Data {
        if !loaded { try await prepare() }
        await ensureVoicePack(voice)
        let spoken = NumberNormalizer.normalize(text)
        return try await manager.synthesize(text: spoken, voice: voice)
    }
```

with:

```swift
    func synthesize(_ text: String, voice: String = "af_heart", speed: Float = 1.0) async throws -> Data {
        if !loaded { try await prepare() }
        await ensureVoicePack(voice)
        let spoken = NumberNormalizer.normalize(text)
        return try await manager.synthesize(text: spoken, voice: voice, speed: speed)
    }
```

- [ ] **Step 2: Add `speed` to `synthesizeSamples`**

In the same file, replace:

```swift
    func synthesizeSamples(_ text: String, voice: String = "af_heart") async throws
        -> (samples: [Float], sampleRate: Int) {
        if !loaded { try await prepare() }
        await ensureVoicePack(voice)
        let spoken = NumberNormalizer.normalize(text)
        let result = try await manager.synthesizeDetailed(text: spoken, voice: voice)
        return (result.samples, result.sampleRate)
    }
```

with:

```swift
    func synthesizeSamples(_ text: String, voice: String = "af_heart", speed: Float = 1.0) async throws
        -> (samples: [Float], sampleRate: Int) {
        if !loaded { try await prepare() }
        await ensureVoicePack(voice)
        let spoken = NumberNormalizer.normalize(text)
        let result = try await manager.synthesizeDetailed(text: spoken, voice: voice, speed: speed)
        return (result.samples, result.sampleRate)
    }
```

- [ ] **Step 3: Verify it builds**

Run: `cd app && swift build`
Expected: build succeeds. (Not unit-testable — depends on FluidAudio/ANE. Default `1.0` keeps every existing caller behaviourally identical.)

- [ ] **Step 4: Commit**

```bash
git add app/Sources/OpenWhisperer/KokoroTTS.swift
git commit -m "feat(tts): forward speed into KokoroTTS synthesis"
```
(Append the `Claude-Session:` trailer.)

---

### Task 3: `Paths.ttsSpeed` + `TTSPlaybackController` reads and applies speed

**Files:**
- Modify: `app/Sources/OpenWhisperer/Paths.swift`
- Modify: `app/Sources/OpenWhisperer/TTSPlaybackController.swift`

**Interfaces:**
- Consumes: `TTSSpeed.parse` (Task 1); `KokoroTTS.synthesizeSamples(_:voice:speed:)` (Task 2).
- Produces: `Paths.ttsSpeed` (URL). `play(text:voice:)` signature **unchanged** — so `/v1/audio/play` and `/mcp` `speak` need no edits.

- [ ] **Step 1: Add the pref path**

In `app/Sources/OpenWhisperer/Paths.swift`, immediately after the `ttsVolume` line:

```swift
    static let ttsVolume = appSupport.appendingPathComponent("tts_volume")
```

add:

```swift
    static let ttsSpeed = appSupport.appendingPathComponent("tts_speed")
```

- [ ] **Step 2: Add `readSpeed()` and apply it in `play`**

In `app/Sources/OpenWhisperer/TTSPlaybackController.swift`, add a `readSpeed()` helper next to the existing `readVolume()` (in the "Lock file + volume" section). After:

```swift
    private static func readVolume() -> Float {
        let url = Paths.appSupport.appendingPathComponent("tts_volume")
        guard let raw = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let v = Float(raw) else { return 1 }
        return v
    }
```

add:

```swift
    private static func readSpeed() -> Float {
        TTSSpeed.parse(try? String(contentsOf: Paths.ttsSpeed, encoding: .utf8))
    }
```

Then, in `play(text:voice:)`, replace:

```swift
        let volume = Self.readVolume()
        writeLock()
```

with:

```swift
        let volume = Self.readVolume()
        let speed = Self.readSpeed()
        writeLock()
```

and replace the synthesis call:

```swift
                    let (samples, _) = try await self.tts.synthesizeSamples(sentence, voice: voice)
```

with:

```swift
                    let (samples, _) = try await self.tts.synthesizeSamples(sentence, voice: voice, speed: speed)
```

(`TTSPlaybackController.swift` already `import OpenWhispererKit`, so `TTSSpeed` resolves.)

- [ ] **Step 3: Verify it builds**

Run: `cd app && swift build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/OpenWhisperer/Paths.swift app/Sources/OpenWhisperer/TTSPlaybackController.swift
git commit -m "feat(tts): apply tts_speed pref in playback controller"
```
(Append the `Claude-Session:` trailer.)

---

### Task 4: `TTSHTTPServer` `/v1/audio/speech` — pref + per-request override

**Files:**
- Modify: `app/Sources/OpenWhisperer/TTSHTTPServer.swift`

**Interfaces:**
- Consumes: `TTSSpeed.parse` / `TTSSpeed.clamp` (Task 1); `KokoroTTS.synthesize(_:voice:speed:)` (Task 2).
- Produces: `static func userSpeed() -> Float`.

- [ ] **Step 1: Add `userSpeed()`**

In `app/Sources/OpenWhisperer/TTSHTTPServer.swift`, after the existing `userVoice()`:

```swift
    private static func userVoice() -> String {
        let v = (try? String(contentsOf: Paths.ttsVoice, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v! : "af_heart"
    }
```

add:

```swift
    /// The user's global TTS speed (`tts_speed`), clamped, or 1.0. Used by the
    /// blocking WAV path when the request omits a `speed`.
    private static func userSpeed() -> Float {
        TTSSpeed.parse(try? String(contentsOf: Paths.ttsSpeed, encoding: .utf8))
    }
```

- [ ] **Step 2: Resolve and pass `speed` in `/v1/audio/speech`**

Replace:

```swift
        case ("POST", "/v1/audio/speech"):
            let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
            let input = json?["input"] as? String ?? ""
            let voice = json?["voice"] as? String ?? Self.userVoice()
            Task { [tts] in
                do {
                    let wav = try await tts.synthesize(input, voice: voice)
                    self.respond(conn, "200 OK", wav, contentType: "audio/wav")
```

with:

```swift
        case ("POST", "/v1/audio/speech"):
            let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
            let input = json?["input"] as? String ?? ""
            let voice = json?["voice"] as? String ?? Self.userVoice()
            let speed = (json?["speed"] as? Double).map { TTSSpeed.clamp(Float($0)) } ?? Self.userSpeed()
            Task { [tts] in
                do {
                    let wav = try await tts.synthesize(input, voice: voice, speed: speed)
                    self.respond(conn, "200 OK", wav, contentType: "audio/wav")
```

(`TTSHTTPServer.swift` already `import OpenWhispererKit`.)

- [ ] **Step 3: Verify it builds**

Run: `cd app && swift build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/OpenWhisperer/TTSHTTPServer.swift
git commit -m "feat(tts): honor tts_speed on /v1/audio/speech"
```
(Append the `Claude-Session:` trailer.)

---

### Task 5: Menubar Speed slider

**Files:**
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift`

**Interfaces:**
- Consumes: `TTSSpeed.parse` (Task 1); `Paths.ttsSpeed` (Task 3).

- [ ] **Step 1: Add the `selectedSpeed` state**

In `app/Sources/OpenWhisperer/MenuBarView.swift`, after:

```swift
    @State private var selectedVoice = "af_heart"
```

add:

```swift
    @State private var selectedSpeed: Double = 1.0
```

- [ ] **Step 2: Add the label formatter**

Add this private helper to the `MenuBarView` struct (place it just above the `// MARK: - Header` line, alongside the other view/helpers):

```swift
    /// "1×", "1.15×", "1.2×" — trims trailing zeros so the slider readout stays tidy.
    private func speedLabel(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s + "×"
    }
```

- [ ] **Step 3: Load the saved value on appear**

In the `.onAppear` load block, immediately after the `savedVolume` block (the one that sets `selectedVolume`), add:

```swift
            selectedSpeed = Double(TTSSpeed.parse(try? String(contentsOf: Paths.ttsSpeed, encoding: .utf8)))
```

- [ ] **Step 4: Insert the Speed row in Voice Settings**

In the Voice Settings `expandedContent`, find the Voice row's `.onChange` block followed by the "No visible separator" comment:

```swift
                .onChange(of: selectedVoice) { _, newValue in
                    try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
                }

                // No visible separator between Voice and Response, but keep the same
```

Insert the Speed row between the Voice `.onChange` closing brace and the comment, so it reads:

```swift
                .onChange(of: selectedVoice) { _, newValue in
                    try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
                }

                OWInternalDivider()

                OWPickerRow(label: "Speed", labelWidth: 62) {
                    HStack(spacing: 8) {
                        Slider(value: $selectedSpeed, in: 0.7...1.5, step: 0.05)
                            .tint(OWColor.accent)
                            .help("How fast replies are read aloud. 1× is the default Kokoro rate; higher is faster. Spoken output only.")
                        Text(speedLabel(selectedSpeed))
                            .font(OWFont.body(11))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedSpeed) { _, newValue in
                    try? String(format: "%.2f", newValue)
                        .write(to: Paths.ttsSpeed, atomically: true, encoding: .utf8)
                }

                // No visible separator between Voice and Response, but keep the same
```

- [ ] **Step 5: Verify it builds**

Run: `cd app && swift build`
Expected: build succeeds. (SwiftUI view code is not unit-testable under CLT.)

- [ ] **Step 6: Commit**

```bash
git add app/Sources/OpenWhisperer/MenuBarView.swift
git commit -m "feat(tts): add Speed slider to Voice Settings"
```
(Append the `Claude-Session:` trailer.)

---

### Task 6: Documentation

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add `tts_speed` to the prefs list**

In `AGENTS.md`, in the *State & IPC* section's "Notable ones" sentence, add `tts_speed` to the list of pref files (next to `tts_volume`), described as: the global TTS playback rate (default 1.0, clamped 0.7–1.5).

- [ ] **Step 2: Note the knob in the TTS section**

In the TTS section, add one sentence: the global `tts_speed` pref (a Voice Settings slider, 0.7–1.5, default 1.0) is threaded into `KokoroTTS` synthesis, read where `tts_volume` is read (`TTSPlaybackController` + `/v1/audio/speech`), and clamped via `TTSSpeed` in `OpenWhispererKit`. README stays untouched (obsolete).

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document tts_speed pref"
```
(Append the `Claude-Session:` trailer.)

---

### Task 7: Final regression + manual smoke

- [ ] **Step 1: Run both test runners**

Run: `cd app && swift run OpenWhispererKitTests && swift run HookTests`
Expected: both PASS (`✅` lines; no `exit(1)`). Task 1's `TTSSpeedChecks` is included; nothing else should have regressed.

- [ ] **Step 2: Manual smoke (requires a running server: GUI app or `swift run OpenWhisperer --serve-tts`)**

- With the GUI running, open the menubar → Voice Settings, drag the Speed slider to ~1.4×, then run:
  `echo "one two three four five" | scripts/speak.sh`
  Expected: audibly faster than at 1×. Drag to ~0.8× and repeat — audibly slower.
- Dictate a turn and confirm the spoken reply tracks the slider.
- Per-request override check:
  `curl -s -X POST localhost:8000/v1/audio/speech -H 'content-type: application/json' -d '{"input":"testing speed override","speed":1.5}' -o /tmp/fast.wav && afplay /tmp/fast.wav`
  Expected: renders at 1.5× regardless of the slider.

---

## Self-Review

**Spec coverage:**
- `tts_speed` pref file → Task 3 (`Paths.ttsSpeed`). ✓
- `TTSSpeed` clamp/parse helper, unit-tested, `[0.7,1.5]`/1.0 → Task 1. ✓
- `speed` in `KokoroTTS.synthesize`/`synthesizeSamples` → Task 2. ✓
- `TTSPlaybackController` reads pref (like volume), `play` signature unchanged → Task 3. ✓
- `/v1/audio/speech` pref + optional body override → Task 4. ✓
- Slider 0.7–1.5/step 0.05 in Voice Settings between Voice and Response; load + persist → Task 5. ✓
- AGENTS.md prefs + TTS note; README untouched; no version bump → Task 6 + Global Constraints. ✓
- Global-only (no env override) → honored by reading only the global file. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `TTSSpeed.parse(String?) -> Float`, `.clamp(Float) -> Float`, `.min/.max/.default: Float` used identically in Tasks 1, 3, 4, 5. `synthesize(_:voice:speed:)`/`synthesizeSamples(_:voice:speed:)` defined in Task 2, called with matching labels in Tasks 3–4. Slider `in: 0.7...1.5` matches `TTSSpeed.min/max`. ✓
