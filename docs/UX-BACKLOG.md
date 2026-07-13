# UX / UI Backlog — post-v1.5

Captured from the v1.5 design review (ui-designer + ux-researcher, 2026-06-24). The **visual
cohesion pass shipped in v1.5** (warm status tokens replacing system red/green/cyan/orange, card
spacing/radius/shadow, Fraunces wordmark, gold-tinted card headers + chevrons, warm-gold overlay
waveform, brand-tinted pickers/buttons/badges). The items below are **deferred** because they change
behavior, structure, or user-facing copy and deserve their own pass + sign-off.

> **2026-07-09 — the native tabbed Settings window (PR #20,
> `docs/superpowers/specs/2026-07-08-native-settings-window-design.md`) superseded the card UI
> and shipped much of this list.** Done: merge Voice Input/Voice Settings (now Input/Voice tabs),
> label clarity ("Language", "Reply detail", "Press Enter after inserting", "Return to previous
> app"), overlay toggle placement (Input), silence-threshold rename ("Auto-submit after N s of
> silence"), Speech Recognition annotated Hands-Free-only (row hidden otherwise), permissions
> always visible (General), "Server & Logs" → Advanced with Diagnostics section, Remove-models
> button. Still open: first-run checklist, always-visible "Server reachable" (it's in Advanced,
> not the first screen), persist the PTT-restart notice, periodic diagnostic refresh,
> "TTS unreachable" cue while in Standby, per-project hooks, hook validity check, re-apply
> affordance after upgrades, menubar icon ambient TTS state, WER harness.

## UX / Information architecture (ux-researcher)

### P0 candidates (next)
- **First-run checklist card** — a numbered, self-dismissing prerequisite card above the status card:
  (1) Microphone → (2) Accessibility → (3) pick platform → (4) Apply hooks → (5) Ready. Each row a
  tappable deep-link. Today these are scattered across three cards; a new user can't see the path.
- **Promote "Server reachable"** out of the collapsed Server card into the always-visible status card
  (third row). It's the most actionable runtime health signal and is currently hidden.
- **Surface hands-free wake words in-menu** — when Hands-Free is selected, the description must state
  "say 'initiate' to start, 'hold on' to interrupt" (currently only in the README).
- **Persist the PTT-restart notice** — `pttKeyChanged` resets on popover close; write a flag file so
  the "Restart app to apply new hotkey" badge survives until the app actually restarts.
- **Periodic diagnostic refresh** while the popover is open (timer), not only `.onAppear` — so granting
  a permission with the popover open updates the row live.
- **"TTS unreachable" warning** inside the Voice Input card when `!serverReachable` — today a user in
  Standby has no cue the speech-back half is broken.

### P1 candidates
- Merge Voice Input + Voice Settings into one card (mode/key/state visible; voice/language/style/volume
  in an expandable "Voice Output" sub-section).
- Make the Automation card collapsible with a state summary in the header.
- Label clarity: "Style" → "Reply Detail"; "Dictate" → "Language"; title-case "Auto-Focus" /
  "Auto-Submit (presses Enter after dictation)"; "with return" → "Return to previous app after insert";
  "Setup" card → "Platform & Hooks".
- Move the Transcription Overlay toggle into the Voice Output sub-section (it's a display pref).
- Rename silence threshold to "Auto-submit after [N]s of silence".
- Model-download context label ("one-time, ~hundreds of MB") on the setup progress card.
- Annotate "Speech Recognition" permission as Hands-Free-only.

### P2 candidates
- "Server & Logs" → "Diagnostics & Logs".
- Replace the ":local" port pill on the Whisper STT row with "on-device".
- Re-apply/Update affordance on the hook Auto-Apply button after version upgrades.
- **Per-project hook option (vs. global-only).** Today Auto-Apply writes hooks to the global
  `~/.claude/settings.json`, so voice mode is on for every Claude Code session. Consider an option to
  register hooks **per project** (the repo's `.claude/settings.json`) so voice can be scoped to
  specific projects. Trade-off: global is one-and-done; per-project is more granular but needs setup
  per repo — likely a menu toggle ("Apply to: this project / globally") in the Setup card.
- Hook validity check (file exists + executable) alongside "HOOK configured".
- Mode comparison mini-reference off the mode picker.
- Menubar icon ambient state during TTS playback.
- **Notch status indicator (overlay split, phase 2).** Move the recording/standby/speaking status out
  of the floating overlay into a small dynamic indicator beside the MacBook notch (VoiceInk "notch
  recorder" pattern; cf. Dynamic Island). Phase 1 — moving transcription history into the menubar
  dropdown — is specced separately (2026-07-13 discussion). Open problems to solve in its own design
  pass: fallback for non-notch displays (fake-notch pill vs. keeping the floating overlay as an
  alternate style, as VoiceInk does); new homes for the overlay's text states (model download
  progress, errors, "Transcribing…", hands-free silence countdown); fullscreen behavior
  (`canJoinAllSpaces` + window level); overlap with the macOS orange mic dot.
- **Manage storage → Remove downloaded models.** No in-app way to delete the models today (~1.7 GB:
  WhisperKit STT at `~/Documents/huggingface/models/argmaxinc/` + `…/openai/` ≈ 1.5 GB; FluidAudio
  Kokoro at `~/.cache/fluidaudio` ≈ 196 MB). Add a Server/Diagnostics-card row showing the on-disk
  size with a "Remove downloaded models" button (deletes the model folders; next use re-downloads
  + recompiles the ANE ~90s). Useful for a wider audience and for testing a clean first-run.

## UI polish not yet done (ui-designer P2 leftovers)
- **Wordmark:** considered icon removal for a serif-only header; v1.5 kept the icon (smaller, 24pt) and
  bumped the wordmark to Fraunces 17. Revisit if a cleaner header is wanted.
- **PortField:** still uses native `.roundedBorder`; restyle to match `OWMenuPicker`
  (pickerBg + pickerBorder) for full control-grammar consistency.
- **Picker menu selection:** use `checkmark.circle.fill` + `.tint(OWColor.accent)` for gold selection
  feedback in the dropdown.
- **Footer Quit:** drop the `power` glyph (reads as system shutdown) — plain "Quit" text link.
- **Typography ramp:** the ux/ui note to lift 10pt hints to 11pt and tighten the 10–13 ramp to three
  clear tiers (partially applied; full pass deferred).

## Dev tooling
- **STTDiag → WER harness.** Extend `app/Tools/STTDiag` (today: loads the model offline and transcribes
  1 s of silence) into a fixed-corpus WER runner: 10–20 recorded reference clips + expected texts,
  report per-clip and aggregate WER. Run before any WhisperKit bump — would have caught the 1.0.0
  tokenizer regression (Jun 24 → Jul 8) on day one. Context: `docs/superpowers/specs/2026-07-08-stt-accuracy-levers-design.md`.

## Notes
- All deferred items are **non-blocking** for the v1.5 release. The shipped visual pass already removes
  the biggest brand mismatch (system colors) and tightens spacing/typography/iconography.
- When picking these up, keep the "zero behavior change unless intended" discipline and re-run
  `swift run OpenWhispererKitTests` + `HookTests`.
