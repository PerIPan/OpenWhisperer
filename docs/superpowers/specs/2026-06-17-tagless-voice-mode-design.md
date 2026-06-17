# Tagless Voice Mode — Design

**Date:** 2026-06-17
**Status:** Approved design, ready for planning
**Sequencing:** Implement after Phase 2 (native TTS). The Stop-hook playback path is engine-agnostic, so this work does not depend on *which* TTS engine ships — but it is scheduled to land right after native TTS.

## Problem

Voice output today is driven by a `[VOICE: ...]` tag that the model must append to **every** response. The tag is:

- **Mandated in CLAUDE.md.** `ConfigManager.applyVoiceTag(...)` auto-writes a `## Voice Mode` block into the user's `~/.claude/CLAUDE.md` (and `AGENTS.md` for Codex), verbosity driven by `voice_detail`. That pollutes the user's project/global instructions and is a maintenance burden.
- **Distracting in the transcript.** The bracketed tag appears on every turn, which reads as clutter even when it isn't a context-size concern.
- **Unconditional.** `tts-hook.sh` (a Stop hook) extracts the tag and speaks on *every* response — typed turns included. There is no notion of "this turn came from voice."
- **Session-blind.** With multiple `claude` sessions running, every session that emits a tag tries to speak; the only arbitration is the global audio lock (newest playback barges in). Nothing routes speech to the session the user is actually talking to.

## Goals

- Remove the `[VOICE: ...]` tag entirely. Nothing extra in the transcript, nothing the model must emit.
- Remove the voice instruction from CLAUDE.md / AGENTS.md, and migrate existing installs to strip the old block.
- Speak **only voice turns** — turns whose input came from dictation — not typed turns.
- Route speech to the **correct session** under concurrency, including multiple `claude` tabs in the same terminal app.
- Keep the existing playback machinery (streaming player, afplay fallback, barge-in, locks) untouched.

## Non-goals

- Codex pre-turn nudge (Codex still gets signal-gated speaking, no nudge — see Scope).
- A "spoken scope" UI knob beyond repurposing `voice_detail`.
- Removing the *project's own* dogfood `[VOICE:]` instruction in this repo's `CLAUDE.md` (separate cleanup once the hook is proven).
- Smart-quote / autocorrect normalization (deferred; cannot occur on a terminal target — revisit only if a rich-text destination is ever supported).

## Why a handshake, not a lookup

The app and the hooks live in **separate process trees** and share **no session identifier**:

- The app (the dictation sender) only knows the OS window / PID it typed into. It never sees a `session_id`, so it cannot write a side channel keyed by session, and it cannot set an env var the hook would inherit.
- The hook is the only actor that knows its `session_id` (from its stdin JSON).

Therefore the binding between "this dictation" and "the session that should speak" cannot be handed *down* from the app — it must be **claimed upward** by the hook. The only artifact that provably travels into the exact session that received the dictation is the **prompt text itself**. The hook recognizes its own prompt, declares itself the voice turn, and stamps its own `session_id`.

## Architecture

A two-hook state machine. The app emits anonymous evidence; the hooks establish session identity.

```
Dictation insert (DictationManager.insertText — the single voice funnel)
  └─► write voice_turn = { sha256(final_text), timestamp }   [BEFORE the auto-submit Enter]
  └─► type the dictated text verbatim (no marker, no quotes)

UserPromptSubmit hook (Claude Code), fires in EVERY session:
  sha256(trim(prompt)) == voice_turn.hash  AND  voice_turn fresh?
    ├─ yes ─► this session received the dictation:
    │         • inject nudge as hookSpecificOutput.additionalContext, suppressOutput: true
    │         • create speak_pending.<session_id>
    │         • delete voice_turn   (atomic claim)
    └─ no ──► ordinary typed turn — do nothing

Claude responds, opening with a plain spoken first paragraph
(the nudge is visible to Claude but hidden from the transcript)

Stop hook (tts-hook.sh), fires per session:
  speak_pending.<session_id> exists?
    ├─ yes ─► strip markdown, extract FIRST PARAGRAPH, speak it (existing playback path);
    │         delete speak_pending.<session_id>; age-sweep orphans
    └─ no ──► exit silently
```

### Data flow properties

- **Input serialization:** `voice_turn` is one fixed-name file, overwritten per dictation, claimed+deleted near-instantly (sub-second under auto-submit). You dictate one thing at a time, so there is no practical write/claim collision.
- **Output routing:** `speak_pending.<session_id>` is per-session and may legitimately coexist (dictate to B while A is still answering → two pending responses). Routing is exact because each Stop hook only consumes its own marker.
- **Output serialization:** the existing global playback lock (`tts_hook.lockdir`) keeps only one voice audible at a time; the newest response barges in over the older. This is what makes speech single-threaded — not the single signal file.

## Components

### App (Swift)

- **`DictationManager.insertText(...)`** — write `voice_turn` with `sha256(final_text) + timestamp` on every voice insertion. Both push-to-talk (`:586`) and hands-free (`:420`) route through here. The hash must cover the **final** text — i.e. *after* the spoken `SubmitTrigger` phrase is stripped — and must be written **before** the auto-submit Enter CGEvent (`:657`) so the signal exists when `UserPromptSubmit` fires.
- **`Paths.swift`** — add `voiceTurn` and a `speakPending` location (directory or filename prefix in App Support). `voiceDetail` stays; its meaning changes to nudge verbosity.
- **`ConfigManager.swift`** — delete the CLAUDE.md/AGENTS.md voice-block injection (`applyVoiceTag`, `voiceBlockForDetail`, `removeVoiceBlock` becomes migration-only, `checkVoiceTagConfigured`, the "Step 2: …Voice Tag" setup cards). Replace with:
  - Register the `UserPromptSubmit` hook in `~/.claude/settings.json` (already manages this file and the Stop hook).
  - **Migration:** on launch/setup, strip the old `## Voice Mode` block from existing users' `~/.claude/CLAUDE.md` and `AGENTS.md` (reuse `removeVoiceBlock`).
  - Setup UI "Voice Tag" card → a "voice hook installed" status, or removed.

### Hooks

- **New `voice-context.sh` (UserPromptSubmit, Claude Code).** Pure bash + `jq` + `shasum -a 256` (no venv dependency). Reads `prompt` and `session_id` from stdin JSON, hashes `trim(prompt)`, compares against `voice_turn` (and checks freshness). On match: emit JSON `{ hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: "<nudge>" }, suppressOutput: true }`, create `speak_pending.<session_id>`, delete `voice_turn`.
- **`tts-hook.sh` (Stop).** Replace the `[VOICE:]` extraction block (`:73–97`) with: read `session_id`, gate on `speak_pending.<session_id>`, extract the **first paragraph** from the markdown-stripped `last_assistant_message`, then hand off to the **existing** streaming/afplay playback path (lock, PID, barge-in unchanged). Delete the marker after speaking; extend the existing temp-file age-sweep to orphaned `speak_pending.*`.
- **`codex-tts-hook.sh`.** Minimal parity: since the AGENTS.md tag is also gone, switch Codex to the same signal-gated **first-paragraph** speak (the app writes `voice_turn` regardless of platform; the Stop-equivalent extracts the first paragraph). **No Codex nudge** — deferred until Codex hook-injection capability is confirmed.

### Settings

The app wires both hooks into `~/.claude/settings.json`: the new `UserPromptSubmit` entry and the existing `Stop` entry.

## The nudge

Injected as `additionalContext` with `suppressOutput: true` so the model sees it but the transcript does not. Content is selected from `voice_detail`:

- `terse` → "This turn was dictated. Open with one short, plain spoken sentence that stands alone as a summary; details can follow."
- `normal` → "…one plain spoken sentence…"
- `rich` → "…a sentence or two…"

`voice_detail` shapes **only** the nudge wording. The Stop hook is dumb — it always speaks the first paragraph — so the spoken length is whatever the model wrote in that first paragraph, guided by the nudge. There is no coupling between `voice_detail` and the Stop hook.

## First-paragraph extraction (Stop hook)

1. Skip any leading code fence or heading to find the first prose block.
2. First paragraph = text up to the first blank line (`\n\n`).
3. Strip inline markdown (bold, code spans, links) — reuse the existing `sed` pipeline.
4. Safety cap (~600 chars, truncated at a sentence boundary) so a model that ignores the nudge and writes a giant first paragraph does not read endlessly.
5. If no prose paragraph is found, speak nothing rather than something awkward.

## State files

All in `~/Library/Application Support/OpenWhisperer/` (existing dir, `0700`).

| File | Writer | Reader | Lifecycle |
|------|--------|--------|-----------|
| `voice_turn` | app (`insertText`) | UPS hook | one fixed-name file, overwritten per dictation, deleted on claim |
| `speak_pending.<session_id>` | UPS hook | that session's Stop hook | created on claim, deleted after speaking; age-swept if orphaned |

No accumulation: `voice_turn` is a single overwritten file; `speak_pending.*` markers are deleted within the turn, with an age-sweep (extend the existing `find … -mmin +1 -delete`) for sessions that die between prompt and response. Files are tiny (a hash + timestamp, or an empty marker).

## Concurrency

- **Wrong session steals the turn:** prevented — the content hash matches only the session whose prompt equals the dictated text. Two tabs in the same terminal app are disambiguated because only the tab that actually received the keystrokes has a matching prompt.
- **Wrong session speaks:** prevented — `speak_pending` is session-scoped; a Stop hook only consumes its own.
- **Two sessions speak at once:** prevented — the existing global playback lock serializes audio (newest barges in).
- **Residual:** in *manual*-submit mode, if you type the *identical* string in another session before submitting the dictated one, that session can claim the turn. Requires identical text + same freshness window + cross-session ordering. Contrived; not engineered against.

## Edge cases

- **Edit before submitting (manual mode):** the prompt no longer matches the recorded hash → treated as a typed turn → not spoken. This is **correct behavior**: editing means the user took over by keyboard.
- **Normalization:** the app hashes the final post-`SubmitTrigger` text; both sides `trim()`. Get this wrong and it silently never matches — pin it with a test.
- **`voice_detail` missing:** default `normal`.
- **Interrupted turn (no Stop):** stale `voice_turn` bounded by freshness window; orphan `speak_pending.*` age-swept.
- **Barge-in / overlapping playback:** unchanged — existing lock/PID logic.

## Testing

- **Hash + freshness claim:** shell-level test of `voice-context.sh` — matching prompt claims and stamps `speak_pending.<id>`; non-matching prompt does nothing; stale `voice_turn` is rejected; trim normalization holds.
- **First-paragraph extraction:** table-driven test feeding messy markdown (leading code fence, heading, multi-paragraph, inline markdown, oversize paragraph) and asserting the spoken string.
- **State-machine integration:** voice insertion → claim → speak → cleanup; plus a typed-turn negative case (no `voice_turn` → never speaks) and an orphan-sweep case.
- **App:** unit-test the hashing of `final_text` (post-trigger-strip) so it matches what the hook computes.

## Migration

On launch/setup for existing installs:

1. Strip the `## Voice Mode` / `[VOICE:]` block from `~/.claude/CLAUDE.md` and `AGENTS.md` (`removeVoiceBlock`).
2. Register the `UserPromptSubmit` hook in `~/.claude/settings.json`.
3. Leave the existing `Stop` hook in place (its internals change, its registration does not).

## Scope summary

| Concern | Claude Code | Codex |
|---------|-------------|-------|
| App writes `voice_turn` | yes | yes (platform-agnostic) |
| Speak first paragraph (signal-gated) | yes | yes |
| Pre-turn nudge | yes (`UserPromptSubmit` + `additionalContext` + `suppressOutput`) | no (deferred) |
| CLAUDE.md / AGENTS.md tag | removed + migrated | removed + migrated |

## Open questions / risks

- **Freshness window length.** Sub-second under auto-submit; manual-submit needs a longer window (dictate → review → submit). Because the match is content-specific, a generous window (a few minutes) is low-risk. Pick a value during planning.
- **`UserPromptSubmit` + `suppressOutput` behavior.** Confirmed via docs that `additionalContext` is visible to the model and `suppressOutput: true` hides hook stdout from the transcript. Verify empirically that the injected nudge does not surface as a visible transcript line on the target Claude Code version.
- **Hook portability.** `shasum -a 256` and `jq` availability — `jq` is already bundled/probed by `tts-hook.sh`; confirm `shasum` (standard on macOS) or fall back to `openssl dgst -sha256`.
