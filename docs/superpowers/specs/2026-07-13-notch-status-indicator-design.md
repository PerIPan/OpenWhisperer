# Notch Status Indicator — Design

**Date:** 2026-07-13
**Status:** Approved (brainstorm with Hakan, 2026-07-13)
**Phase 2 of the overlay split.** Phase 1 (menubar transcription history, PR #23) moved
history out of the floating overlay; this phase replaces the overlay's remaining job —
live status — with a Dynamic Island-style indicator at the notch, then deletes the
overlay.

## Problem

After phase 1 the floating overlay is a pure status widget in the bottom-right corner: a
window that competes with terminal content for a job — "am I recording / standby /
speaking?" — that wants to be ambient. The notch-app genre shows the better home: black
wings flush against the MacBook notch (so the notch just reads a touch wider), expanding
with activity, hover-revealing detail.

## Decisions

| Question | Decision |
|---|---|
| Overlay fate | **Replaced everywhere and deleted.** One status surface; no styles to choose. |
| Presence | **Always visible, minimal at idle** — a 4pt status dot in a slim black band. |
| Multi-display | **Mirror on every screen.** Status is global; each display gets a fixed band; nothing ever moves or jumps between screens. |
| Non-notch screens | **Fake notch:** a self-contained black lozenge top-center, sized to a physical notch's footprint (menu-bar height, notch-typical width) so states render identically on every screen. |
| Text states | Move to the **menubar dropdown** (status row + Retry); the band carries only color/animation, plus the hands-free countdown line. |

## Visual states

Menu-bar-height black band hugging the notch: left and right wings, rounded outer-bottom
corners. Warm status tokens reused from the overlay (`OWColor`).

```
idle          ▐■■■■ NOTCH ■■■■·▌            · = 4pt dot, "live" sage green
recording     ▐■■■■ NOTCH ■■■■▁▂▅▃▆▁▌       right wing widens ~60pt: red dot + live waveform
transcribing  ▐■■■■ NOTCH ■■■■▁▂▅▃▆▁▌       waveform frozen at 50% opacity, amber ("warn") dot
speaking      ▐■■■■ NOTCH ■■■■▁▃▂▅▃▁▌       gold synthetic waveform (existing TTS animation)
hands-free    recording state + a 1.5pt gold countdown line along the wing's bottom edge
error         idle sliver, dot in "danger" red
```

The waveform path drawing (`mirroredLines`, `ttsLevels`) moves over from the overlay's
`WaveformBar` mostly intact; only the container changes.

## Interactions

- **Hover** on the band reveals a small flyout below it with the state word and hint —
  e.g. "Recording… — release Ctrl to stop", "Standby". This replaces the overlay's
  always-on status text and hint.
- **Click while speaking = barge-in** (calls `TTSPlaybackController.bargeIn()`, the same
  path the mic uses). No other click behavior.
- No close button. Visibility is the existing menu toggle (renamed, see Migration).

## Where the overlay's text states go

The band cannot carry sentences:

- **Model download progress and load failure** → a status row at the top of the menubar
  dropdown (below the history section), with **Retry** inline on failure. The menubar
  icon already shows an hourglass during loads, so the dropdown is where the user looks
  next. The band contributes only its red error dot.
- **Hands-free silence countdown** → stays on the band (the gold bottom line).
- **Recording hotkey hint** → the hover flyout.

## Architecture

New `NotchIndicator` controller replaces `TranscriptionOverlay`:

- Owns one borderless, non-activating panel per screen; rebuilds the set on
  `NSApplication.didChangeScreenParametersNotification`.
- Window level above the menu bar; `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary, .stationary]` so the band survives fullscreen apps and Space
  switches — fullscreen terminals are where the old overlay earned its keep.
- Geometry: real notch from `NSScreen.safeAreaInsets` + `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea`; otherwise a synthesized top-center rect matching a physical
  notch's footprint (menu-bar height, notch-typical width).
- **`NotchGeometry`** (struct, `OpenWhispererKit`) holds the pure math — band and wing
  frames from screen metrics (frame, safe-area top, auxiliary widths, expansion state) —
  unit-tested under CLT. The controller applies frames; the struct computes them.
- State feeds are exactly the overlay's: `AudioRecorder.state` + level history, the
  `tts_playing.lock` poll, `DictationManager.$sttModelReady/$sttFailed/$sttStatus`,
  `SetupManager.$state`, `InteractionMode`, PTT key label. One SwiftUI view per panel
  observes the shared controller.

## Migration & cleanup

- Menu toggle "Show Overlay" → **"Show Status Indicator"**, still backed by the
  `overlay_hidden` flag file (no pref migration needed).
- `TranscriptionOverlay.swift` is deleted — including `KeyableWindow` and the two
  phase-1 review nits that lived there (stale Cmd+C comment, vestigial `minSize`).
- The dropdown gains the model-status row + Retry (menu is the new home for that text).

## Error handling

No new failure modes: no disk, no network. If notch geometry APIs return nil on a
notched screen (unexpected), the fake-notch path renders — degraded, not broken.

## Testing

- **`OpenWhispererKitTests`** — new check group for `NotchGeometry`: notched vs
  non-notch frames, wing expansion math, multi-screen rects, menu-bar-height fallback.
- **Manual smoke** (two-display setup, signed build): both bands idle; dictation
  animates both; hover flyout wording; click-to-barge-in while speaking; hands-free
  countdown line; fullscreen terminal keeps the band; unplug/replug the external
  (screen-change rebuild); model-load row + Retry in the dropdown; light/dark.

## Named risks (verify in smoke, don't over-engineer)

- Menu bar auto-hide: the band floats alone at the top edge — accepted, matches the
  genre.
- Stage Manager / Space transitions: `.stationary` should hold; verify.
- The macOS orange mic dot coexists near the right wing on notched screens — accepted
  (it signals mic-in-use; the band signals app state).

## Non-goals

- Media/now-playing widgets, file shelves, or any notch-app feature beyond voice status.
- Per-screen styles or a floating-overlay fallback mode.
- Click-to-open menus or drag interactions.
- Any change to dictation, typing, or TTS behavior.

## Workflow

Multi-file, user-visible, deletes a subsystem → PR path: worktree off `main`, both test
targets green, `gh pr create`, merge gated on the manual smoke.
