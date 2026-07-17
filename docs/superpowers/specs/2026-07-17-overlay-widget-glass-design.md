# Overlay widget-glass faceplate — design

**Date:** 2026-07-17
**Status:** **Rejected after live on-device trial** (Hakan, 2026-07-17, same day). Fully implemented on branch `overlay-widget-glass` (commit `019c7cd`), installed, and reverted: the analyzer palettes don't read over dark backdrops through untinted `.regular` glass, and Hakan chose reversion over tuning — the escalation knobs below (faint dark `tintColor`, brighter palettes) were deliberately left untried. The smoked-glass dark faceplate stays shipped. Don't re-propose glass without new evidence; if revived, start at those knobs. Findings that remain valid: `NSGlassEffectView` is in the CLT 26.5 SDK, glass does **not** dim in a never-key floating window, foreground RGB content renders unaltered, and `.regular` frost handles mixed light/dark backdrops best of the four spiked variants.
**Supersedes:** the smoked-glass *dark* instrument face (`.hudWindow` blur + `0x1E1B16` @ 0.75-alpha tint, PRs #27/#28). Hakan judged the overlay too opaque against a macOS desktop-widget reference; this records the direction change per the project's decision-record rule.

## What

The transcription overlay's background becomes **widget-style glass** — the very translucent, frosted, desktop-shows-through material macOS desktop widgets use — replacing the near-opaque dark faceplate. Everything *on* the faceplate (analyzer styles, marquee, silence bar) is unchanged.

- **macOS 26 path (primary — Hakan's machine):** the window's content view becomes an `NSGlassEffectView` (Liquid Glass, in the CLT 26.5 SDK) with `style = .regular`, `cornerRadius = 10`, and the SwiftUI hosting view as its `contentView`. No `maskImage` hack — glass shapes its own corners. Default is **no `tintColor`** (pending the spike below).
- **Fallback path (macOS 14–25):** the existing `NSVisualEffectView` construction (`.hudWindow`, `.behindWindow`, `state = .active`, `faceplateMask()`) minus the dark tint layer, which is deleted. A decent glass approximation, not pixel-identical.

All changes live in `TranscriptionOverlay.swift`'s window construction, behind an `if #available(macOS 26.0, *)` branch.

## De-risk spike (before wiring into the overlay)

`NSGlassEffectView` has no equivalent of `NSVisualEffectView.state` — nothing to pin against inactive-window dimming, and the overlay is almost never key. Before touching the overlay, a throwaway standalone window (floating level, borderless, never made key) verifies on-device:

1. **No dimming when unfocused** — the glass must stay live like `state = .active` does today. If it dims, the glass path is abandoned and the untinted `NSVisualEffectView` fallback ships on *all* OS versions.
2. **Foreground unaltered** — bright gold sample content (explicit RGB, non-vibrancy colors) must render untinted on top of the glass.
3. **Dark-face comparison** — **each click on the spike window cycles to the next variant** (accepts-first-mouse, so clicking never requires focusing it; the variant name flashes briefly so you know what you're looking at), each with sample gold LED content, eyeballed over light *and* dark desktops: untinted `.regular` glass, `.regular` with a faint dark `tintColor` (a ghost of the old smoked face), `.clear` style, and the untinted `NSVisualEffectView` fallback (what macOS 14–25 users get). Whichever reads best becomes the default; the others remain one-line tweaks. Click-to-cycle is spike-only — the shipped overlay keeps a fixed default (a click handler would fight drag-to-move and Cmd+C).

## Kept unchanged

- Always-on-top: `window.level = .floating` is a window property, untouched by the content-view swap. Glass samples what's visually behind the window regardless of focus, same as the current behind-window blur.
- Borderless + resizable style mask, drag-by-background, size persistence, bottom-right placement, `canBecomeKey` for Cmd+C.
- Analyzer renderers, marquee takeover, hands-free silence bar, and all their colors — no pre-emptive contrast changes.

## Shadow

`hasShadow = false` today exists because the system shadow's light rim read as a border on the *dark* face. The reference widget has a soft shadow and light rim, so on the glass path try `hasShadow = true` first; keep it only if it doesn't double up with the glass's own edge highlight. On-device judgment call, one line.

## Accepted trade-offs

- LED/analyzer contrast now varies with what's behind the window; a light desktop may mute the gold. Escalation knobs, in order: faint dark `tintColor` on the glass, then brighter segment colors — both tunable live.
- The macOS 14–25 fallback approximates rather than matches the widget material.
- Two code paths in window construction (availability-gated) instead of one.

## Testing

- No Kit-testable logic changes; both test runners should stay green (`swift run OpenWhispererKitTests`, `swift run HookTests`).
- The fallback branch is verified compile-time only (no macOS ≤ 25 machine here); the glass branch is verified live.
- On-device manual matrix, focused and unfocused, over light and dark desktops: 3 analyzer styles × (recording / TTS playback), LOADING and ERROR marquees, hands-free silence bar, drag-resize (corners stay crisp at any size).
