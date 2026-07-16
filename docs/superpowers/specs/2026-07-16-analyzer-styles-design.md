# Overlay analyzer styles — design

**Date:** 2026-07-16
**Status:** Approved (Hakan, in-session)
**Supersedes:** the fixed vintage 8×7 gold LED spectrum from PR #25 (`feat(overlay): eight columns, breathing lamp`). This is a deliberate, user-directed direction change, recorded here per the project's decision-record rule.

## What

The transcription overlay's spectrum display becomes **selectable between three analyzer styles**, clean-room reimplementations of the three default instances in audioMotion-analyzer's multi-instance demo (<https://audiomotion.dev/demo/multi.html>), at their demo defaults — no per-style toggles or options:

1. **LED Bars** (default) — ~24 columns × ~12 LED segments, classic green→yellow→red vertical gradient, falling peak caps, mirrored reflection along the bottom (~10% height, 25% alpha).
2. **Graph** — smooth filled spectrum curve, steel-blue fill, orange-red peak line. (The demo draws two fills for stereo L/R; our feeds are mono, so the two-color spirit survives as fill + peak line.)
3. **Curtain** — ~96 thin full-height bars, each filled with a *vertical* prism ramp (crimson top → blue bottom, matching the demo's rendered output), per-bar opacity tracking band level, hotter response curve (demo runs −60…−30 dB). *(Corrected 2026-07-16 after an on-device comparison: the first cut swept hues horizontally across bars, which is not the demo's look.)*

The style is chosen from **Settings → General → Overlay → "Analyzer style"** and applies to both spectrum sources (mic while recording, TTS playback via `PlaybackLevelMeter`).

**Licensing:** audioMotion-analyzer is AGPL-3.0. This is a clean-room reimplementation of the *visual behavior* observed in the demo (band layouts, colors, peak physics as measured constants) — no code is translated from the library.

## Geometry & chrome

- Overlay window grows from 220×52 to **220×84** (`OverlayView.pillHeight`; a single tunable constant — Hakan iterates exact values live on-device).
- Kept unchanged: smoked-glass faceplate (10 pt corners), REC lamp, hands-free silence bar.
- **Marquee kept, de-vintaged:** the LOADING/ERROR takeover still scrolls `DotMatrix` text, but cells lose the ghosted unlit sockets (unlit = transparent on the dark faceplate). Its grid width becomes its own constant instead of borrowing the spectrum band count. Gold for LOADING, danger red for ERROR.
- **Deleted:** the vintage 8×7 gold spectrum renderer (`WaveformBar.spectrum(bands:)` and its segment constants). `OWColor.accentDeep` goes if orphaned.

## Architecture

### Analysis layer (`OpenWhispererKit`, pure, CLT-testable)

- `SpectrumBands` grows from 8 fixed bands to one shared analysis resolution: **96 log-spaced Goertzel bands, 50 Hz–7.5 kHz** (top band stays under the mic's 8 kHz Nyquist; the existing above-Nyquist guard covers any source mismatch). Both audio taps keep publishing through this one path — switching styles never touches audio plumbing. Cost ≈ 12× today's, still ≪ 1 ms per tap callback.
- New `PeakHold`: per-band peak tracker with hold time + time-based gravity fall (LED caps, graph peak line). Pure function of (bands, timestamp); constants tunable.
- New `aggregate(bands:into:)`: max-pooling reducer for styles that render fewer columns than the analysis resolution (LED Bars: 96→24).
- New `OverlayStyle`: `ledBars` / `graph` / `curtain`, string parse with `ledBars` default (same shape as `TTSSpeed`).

### Render layer (app target)

One SwiftUI `Canvas` renderer per style in a new `SpectrumStyles.swift`, all consuming the same published `[Float]` bands (+ `PeakHold` output where relevant). Gradients/colors are defined here, not in Kit. `WaveformBar` switches on the active style; marquee takeover behavior is unchanged.

### Settings & persistence

- New flat pref file `overlay_style` in `~/Library/Application Support/OpenWhisperer` (values: `led_bars` / `graph` / `curtain`; missing/garbage → default).
- Picker in Settings → General, new "Overlay" section; live propagation to the overlay follows the same in-process pattern existing prefs use (as `tts_volume` reaches `TTSPlaybackController`).
- No per-project env override (YAGNI; add `OW_OVERLAY_STYLE` later only if asked).

## Accepted trade-offs

- Playback audio above 7.5 kHz doesn't register (Kokoro speech energy is negligible there); one shared band layout for both sources is worth it.
- The graph style is a mono adaptation, not the demo's stereo dual-fill.
- Fidelity is "faithful at 220×84", not pixel parity: exact bar counts, segment counts, gravity, and response curves are constants chosen to read well at this size, tuned live.

## Testing

- Kit runner (`swift run OpenWhispererKitTests`): `OverlayStyle` parsing (valid/garbage/nil), `aggregate` edge cases (exact multiple, remainder, empty), `PeakHold` (holds during hold window, falls with gravity after, never below live band), updated `SpectrumBands` layout checks (count, range, monotonic centers, above-Nyquist zero).
- `HookTests` unaffected (no hook/bash surface in this change).
- On-device manual matrix: 3 styles × (recording / TTS playback / LOADING marquee / ERROR marquee), plus hands-free silence bar and REC lamp on the taller faceplate.
