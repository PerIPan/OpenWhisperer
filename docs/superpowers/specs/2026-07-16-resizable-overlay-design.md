# Resizable overlay + idle-energy fix — design

**Date:** 2026-07-16
**Status:** Approved (Hakan, in-session — design discussed and confirmed in chat)
**Builds on:** `2026-07-16-analyzer-styles-design.md` (the 220×84 faceplate + three analyzer styles, PR #27)

## What

Two changes, one branch:

1. **Resizable overlay.** The floating faceplate becomes user-resizable by its edges/corners (no visible chrome — the borderless window gains `.resizable`, macOS provides invisible grips). Size persists across launches; position keeps its bottom-right anchor with the same margins.
2. **Idle-energy fix.** LED Bars and Graph currently run their 30 fps `TimelineView` even when the overlay is idle (all-zero bands redrawn forever). The timeline pauses when the incoming bands are all zero, and `PeakHold` zeroes its caps immediately on all-zero input so the pause never freezes caps mid-air. Trade-off (accepted): caps vanish instead of finishing their fall at the exact moment audio stops; during real audio the mic/TTS noise floor keeps bands non-zero, so the animation is unaffected. Curtain is stateless/timeline-free already.

## Design

### Kit (pure, tested)

- **`OverlaySize`** — parse/clamp/format for the new `overlay_size` flat pref (`"220x84"` format):
  - bounds: min 180×64 (marquee + lamp stay legible), max 800×400;
  - defaults: 220×84 (today's size);
  - `parse(_ raw: String?) -> OverlaySize` (trims; garbage/missing → default; each dimension clamped independently), `fileValue: String`.
- **`PeakHold.update`** — new early path: all-zero `bands` reset `peaks`/`heldAt` wholesale and return zeros. Existing "hold while band is low" checks move off exact-zero inputs (0.01 floor) since exact all-zeros now means "idle, clear the display".

### App

- `TranscriptionOverlay.show()`: window `styleMask` becomes `[.borderless, .resizable]`; `contentMinSize`/`contentMaxSize` from `OverlaySize` bounds; initial `contentRect` from the parsed pref; bottom-right position derived from the actual width (`maxX - width - 20`, `minY + 20`).
- `OverlayView` drops its fixed `frame(width:height:)` (the hosting view fills the window; renderers/marquee/silence bar are already geometry-relative, and the faceplate mask already stretches via cap insets). `pillWidth`/`pillHeight` remain only as the defaults inside `OverlaySize`.
- Persistence: `windowDidEndLiveResize` writes `OverlaySize.fileValue` to `Paths.overlaySize`.
- `LEDBarsStyleView`/`GraphStyleView`: `TimelineView(.animation(minimumInterval: 1/30, paused: bands.allSatisfy { $0 == 0 }))`.

### Versioning & testing

- Version 1.8.0 → 1.9.0 (user-visible feature).
- Kit checks: `OverlaySize` (parse happy path, trim, clamp low/high per-dimension, garbage/nil → default, round-trip via `fileValue`), `PeakHold` quiet-reset (built-up peak → all-zero input → zeros immediately), existing checks adjusted off exact zeros.
- On-device: drag-resize each style, relaunch to confirm size restore, confirm idle overlay stops redrawing (CPU near zero in Activity Monitor when silent).
