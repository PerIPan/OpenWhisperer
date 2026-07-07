# TTS speed control — configurable playback rate

**Date:** 2026-07-01
**Status:** Approved (brainstorming) — pending implementation plan

## Goal

Let the user set how fast spoken replies are read, from the menubar, the same
way they already pick a voice and a volume. FluidAudio's Kokoro already accepts a
`speed` argument on every synthesis entry point
(`synthesize(text:voice:speed:)` / `synthesizeDetailed(text:voice:speed:)`,
`speed: Float = KokoroAneConstants.defaultSpeed` = `1.0`); our `KokoroTTS`
wrapper simply never passes it, so today everything renders at `1.0`. This
exposes that knob as a global `tts_speed` preference driven by a slider.

### Why this, why now

Speed is a first-class model parameter that costs nothing to wire up — the
engine work is already done upstream. Users who find the default cadence a touch
slow (or fast) currently have no recourse. It slots cleanly beside the existing
`tts_voice` / `tts_volume` prefs and reuses their exact plumbing pattern.

## Decisions (settled during brainstorming)

- **Continuous slider, range 0.7–1.5, default 1.0**, `step: 0.05`. This is the
  app's first `Slider` (everything else is `OWMenuPicker`); it lives in the
  **Voice Settings** card, between Voice and Response.
- **Global-only, no per-project override.** Like `tts_voice`, speed is applied
  in-process by the `speak` tool / playback path, which never sees a project's
  env block — so a per-repo `OW_*` override is structurally impossible, same as
  voice. Not a limitation to "fix".
- **We own the clamp.** FluidAudio does not bound `speed` internally, so a shared
  helper clamps to `[0.7, 1.5]` on every read.
- **No version bump.** (Explicitly dropped during brainstorming.)

## Non-goals (YAGNI)

- No preset picker, no per-project env override, no per-voice default speed.
- No pitch control — speed only.
- No change to volume handling, the voice-turn handshake, barge-in, or
  sentence-by-sentence streaming playback.

## Approach

Speed differs from volume in one important way: **volume is a playback-time gain
applied to finished samples** (`AudioPlaybackEngine.schedule(_:volume:)`),
whereas **speed changes synthesis** and must be passed *into* `synthesize`. So it
threads through the two `KokoroTTS` entry points rather than the audio engine —
but it is *read* from disk at the same place and in the same way volume is, so no
call signature between the HTTP/MCP layer and the controller changes.

### Changes by file

1. **`app/Sources/OpenWhispererKit/TTSSpeed.swift` (new, pure, unit-tested).** A
   tiny value helper shared by the two read sites so the clamp lives in one
   place:
   - `static let min: Float = 0.7`, `max: Float = 1.5`, `default: Float = 1.0`
   - `static func clamp(_ v: Float) -> Float` — clamp into `[min, max]`
   - `static func parse(_ raw: String?) -> Float` — trim, `Float(_:)`, clamp;
     `nil`/empty/garbage → `default`
   Lives in `OpenWhispererKit` because that target is the fast-to-test, dependency
   -free home for exactly this kind of logic (per AGENTS.md).

2. **`app/Sources/OpenWhisperer/KokoroTTS.swift`.** Add `speed: Float = 1.0` to
   `synthesize(_:voice:speed:)` and `synthesizeSamples(_:voice:speed:)`, forwarded
   to `manager.synthesize(text:voice:speed:)` /
   `manager.synthesizeDetailed(text:voice:speed:)`. Default `1.0` keeps every
   existing caller behaviourally identical until it opts in.

3. **`app/Sources/OpenWhisperer/TTSPlaybackController.swift`.** Add a
   `static func readSpeed() -> Float` mirroring the existing `readVolume()`
   (reads `Paths.ttsSpeed` via `TTSSpeed.parse`). In `play(text:voice:)`, read it
   **once** next to the existing `readVolume()` call and pass it into
   `synthesizeSamples(sentence, voice:, speed:)`. **`play`'s signature is
   unchanged** — so `/v1/audio/play` and the `/mcp` `speak` tool (the model's
   main path) need no changes and pick up the global speed automatically, exactly
   as they already pick up the global voice/volume.

4. **`app/Sources/OpenWhisperer/TTSHTTPServer.swift`.** The blocking
   `POST /v1/audio/speech` path (used by `scripts/speak.sh`) calls
   `tts.synthesize` directly, bypassing the controller, so it resolves speed
   itself: add a `static func userSpeed() -> Float` (`TTSSpeed.parse` of
   `Paths.ttsSpeed`), and — for parity with how this endpoint already accepts a
   `voice` in the JSON body — honor an optional numeric `"speed"` field
   (`TTSSpeed.clamp(Float(n))`), falling back to `userSpeed()`. Pass the result to
   `tts.synthesize(_:voice:speed:)`.

5. **`app/Sources/OpenWhisperer/Paths.swift`.** Add
   `static let ttsSpeed = appSupport.appendingPathComponent("tts_speed")`.

6. **`app/Sources/OpenWhisperer/MenuBarView.swift`.**
   - `@State private var selectedSpeed: Double = 1.0` (SwiftUI `Slider` wants a
     floating binding; store `Double`, persist/read as `Float`-compatible string).
   - In the `.onAppear` load block, parse `Paths.ttsSpeed` via `TTSSpeed.parse`
     and assign (clamped).
   - In the Voice Settings `expandedContent`, add an `OWPickerRow(label: "Speed",
     labelWidth: 62)` between the Voice row and the Response row, containing a
     `Slider(value: $selectedSpeed, in: 0.7...1.5, step: 0.05)` tinted
     `OWColor.accent`, plus a fixed-width trailing value label
     (e.g. `"1.15×"`; `1.0` shown as `"1×"` — format `%.2f`, strip trailing
     `0`/`.`, append `×`). `.onChange` writes `String(format: "%.2f", newValue)`
     to `Paths.ttsSpeed`.

7. **`AGENTS.md`.** Add `tts_speed` to the "notable prefs" list in the
   *State & IPC* section, and a sentence in the TTS section noting the global
   speed knob (default 1.0, clamped 0.7–1.5). README stays untouched (obsolete).

### Data flow

Model calls `speak(text)` → `POST /mcp` → `TTSPlaybackController.play` reads
`tts_speed` (clamped) alongside `tts_volume` → `KokoroTTS.synthesizeSamples(…,
speed:)` → FluidAudio renders at that rate → gapless streaming playback.
`scripts/speak.sh` → `POST /v1/audio/speech` reads the same pref (or a body
override) → `KokoroTTS.synthesize(…, speed:)` → WAV.

## Sync points

`tts_speed` is read in exactly two places — `TTSPlaybackController.readSpeed()`
and `TTSHTTPServer.userSpeed()` — both delegating to `TTSSpeed.parse`, so the
clamp/default can never drift between them. The slider's `in:` range and
`TTSSpeed.min/max` must stay equal; keep them side by side in review.

## Testing

- **`swift run OpenWhispererKitTests`** — new `TTSSpeedChecks`: empty/`nil`/garbage
  → `1.0`; `"1.15"` → `1.15`; over-range `"9"` → `1.5`; under-range `"0.1"` →
  `0.7`; whitespace trimmed.
- **`swift run HookTests`** — unaffected; run as a regression check.
- **Manual:** move the slider, then `echo "one two three" | scripts/speak.sh` and
  confirm the WAV audibly speeds up/slows down; dictate a turn and confirm the
  spoken reply tracks the setting.
