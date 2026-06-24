# UX / UI Backlog — post-v1.5

Captured from the v1.5 design review (ui-designer + ux-researcher, 2026-06-24). The **visual
cohesion pass shipped in v1.5** (warm status tokens replacing system red/green/cyan/orange, card
spacing/radius/shadow, Fraunces wordmark, gold-tinted card headers + chevrons, warm-gold overlay
waveform, brand-tinted pickers/buttons/badges). The items below are **deferred** because they change
behavior, structure, or user-facing copy and deserve their own pass + sign-off.

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
  "Superpowers" → "Agent Skills (obra)"; "Setup" card → "Platform & Hooks".
- Move the Transcription Overlay toggle into the Voice Output sub-section (it's a display pref).
- Rename silence threshold to "Auto-submit after [N]s of silence".
- Model-download context label ("one-time, ~hundreds of MB") on the setup progress card.
- Distinguish "Hook (required)" vs "Superpowers (optional)" inline.
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

## Notes
- All deferred items are **non-blocking** for the v1.5 release. The shipped visual pass already removes
  the biggest brand mismatch (system colors) and tightens spacing/typography/iconography.
- When picking these up, keep the "zero behavior change unless intended" discipline and re-run
  `swift run OpenWhispererKitTests` + `HookTests`.
