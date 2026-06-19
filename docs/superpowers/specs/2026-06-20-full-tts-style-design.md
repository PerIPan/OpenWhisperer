# `full` TTS style — speak the whole reply

**Date:** 2026-06-20
**Status:** Approved (brainstorming) — pending implementation plan

## Goal

Add a fourth spoken-summary style, `full`, alongside the existing
`terse`/`normal`/`rich`. The first three control the *length of a front-loaded
summary*; `full` is qualitatively different — the model stops writing a
standalone summary and instead writes its **entire reply** to be read aloud, and
the Stop hook speaks the whole thing (markdown-stripped) with **no length cap**.

The point is hands-free narration: hear everything the model says, written as
speakable prose rather than as a screen-first coding answer dense with acronyms,
AI-isms, and long numbers.

### Why this, why now

`terse`/`normal`/`rich` only ever vary one phrase in the nudge (the summary
length); the Stop hook always speaks `first-paragraph.sh`'s output regardless.
That ceiling — "a summary of the first paragraph" — is exactly what a user who
wants to *listen* to the whole turn runs into. `full` lifts both halves: a
different nudge (whole reply as prose) and a different extraction (whole body,
uncapped).

## Decisions (settled during brainstorming)

- **No length cap.** Speak the entire reply however long it runs. A long reply
  is a long monologue; barge-in (start a recording / "hold on") still stops it
  instantly, so there is an escape hatch.
- **Readability is the model's job**, via a stronger per-turn nudge — not a new
  hook/pipeline rewriting layer. The app's existing app-side
  `NumberNormalizer.normalize` (in `KokoroTTS`) stays as a backstop for numbers
  in every mode.
- **Name:** `full`.

## Non-goals (YAGNI)

- No pipeline/hook acronym or AI-ism rewriting. The nudge asks the model to do
  it; we do not post-process.
- No new length cap, slider, or per-mode cap setting.
- No app-side awareness of `full` beyond the picker entry — the app synthesizes
  whatever text it is POSTed, unchanged.
- No change to the `:8000` HTTP shim, the voice-turn handshake, barge-in, or
  sentence-by-sentence streaming playback.

## Deliberate behaviour: code blocks and tables are still dropped in `full`

"Speak all" means all the *prose*, not literal code. A spoken code fence or
markdown table is gibberish through TTS, so `full` keeps the existing
fenced-code / heading / table stripping. The nudge instructs the model to
describe code in words instead of relying on a block being read. This is the one
place "full" is not literally everything, and it is intentional.

## Approach

The style already lives in three synchronized places: the menubar picker, the
nudge `case` in `voice-context.sh`, and (newly) the Stop hooks, which until now
never read the style at all. `full` is added to each, plus a generalized
extraction script.

### Changes by file

1. **`hooks/first-paragraph.sh` → rename to `hooks/speakable-text.sh`, add a
   `--full` mode.** The markdown-stripping rules (drop fenced code, headings,
   tables; de-bullet/de-number; strip inline markdown, links, URLs; collapse
   whitespace) are subtle and must stay in **one** place — so the same script
   serves both modes:
   - **default** (no arg): unchanged — first prose paragraph, ~600-char cap on a
     sentence boundary.
   - **`--full`**: take *all* prose paragraphs (do not `exit` at the first blank
     line after prose starts), join them so sentence boundaries survive for
     `SentenceSplitter` (see detail below), **no cap**.

   The rename keeps the filename honest now that it can emit the whole body. It
   ripples to exactly: the two Stop hooks and the one `HookTests` reference.

2. **`hooks/tts-hook.sh` (Claude Code) + `hooks/codex-tts-hook.sh` (Codex).**
   Read the style with the **same precedence** `voice-context.sh` uses:
   `OW_TTS_STYLE` env → `tts_style` file → legacy `voice_detail` file. If the
   resolved style is `full`, invoke the extractor with `--full`; otherwise
   default. Voice resolution and the `/v1/audio/play` POST are untouched.

3. **`hooks/voice-context.sh`.** Add a `full)` branch that replaces the **whole**
   `NUDGE` (not just the length phrase) with a "write your entire reply to be
   spoken" instruction: the whole reply will be read aloud; write it as natural
   spoken prose — short sentences, expand acronyms, avoid AI-isms and filler,
   keep code/paths/tables out of the spoken flow (describe them in words); do
   not write a separate summary. `terse`/`normal`/`rich` keep today's summary
   template via the existing `LEN` mechanism.

4. **`app/Sources/OpenWhisperer/MenuBarView.swift`.** Add `("full", "Full")` to
   `styleLevels`. That single line both adds the picker row and lets the value
   pass the existing load-time membership validation. No other Swift change.

5. **`HookTests`** (three existing check groups extended):
   - `VoiceContextChecks`: with style `full`, the injected nudge says
     "entire"/"whole reply" and does **not** ask for a summary / first sentence.
   - Full-extraction checks (extend `FirstParagraphChecks` or a sibling): a
     multi-paragraph input yields *all* paragraphs; fenced code and tables are
     dropped; no 600-char truncation.
   - `TTSHookGateChecks`: with style `full`, the Stop hook speaks the whole body,
     not just the first paragraph.

6. **`CLAUDE.md`.** Update the `tts_style` description
   (`terse`/`normal`/`rich` → add `full`) and the "speaks the first paragraph"
   sentences in the TTS / voice-turn sections, which become mode-dependent (first
   paragraph for terse/normal/rich, whole body for `full`).

### Data flow (`full` mode)

dictation → app writes `voice_turn` hash → `voice-context.sh` matches the hash →
injects the "speak your entire reply" nudge + marks the session pending → model
writes a prose reply → Stop hook reads style `full` → `speakable-text.sh --full`
(whole body, markdown-stripped, uncapped) → POST `/v1/audio/play` →
sentence-by-sentence synth + gapless playback. Barge-in unchanged.

### Implementation detail: paragraph joining for `SentenceSplitter`

The app splits the POSTed text into sentences for gapless streaming playback.
Each prose paragraph normally ends in terminal punctuation, so joining
paragraphs with a single space keeps boundaries intact. To avoid two paragraphs
fusing into one run-on when a paragraph ends without terminal punctuation (e.g.
a bare line), `--full` preserves a separator the splitter treats as a boundary
(newline / sentence break) rather than collapsing all paragraph breaks to a
single space the way the first-paragraph path does.

## Sync points (the "three places" rule, now four)

Adding a style value means touching, in lockstep:

1. `MenuBarView.styleLevels` (picker + load validation),
2. the `case` in `hooks/voice-context.sh` (nudge),
3. the style read + `--full` branch in `hooks/tts-hook.sh` and
   `hooks/codex-tts-hook.sh` (extraction), and
4. the rename/extension of `hooks/speakable-text.sh`.

`HookTests` is the parity guard for 2–4; run it after any change here.

## Testing

- `swift run HookTests` — must pass (extended as above).
- `swift run OpenWhispererKitTests` — unaffected, run as a regression check.
- Manual: select **Full** in the menubar, dictate a turn that elicits a
  multi-paragraph reply with a code block, confirm the whole prose (minus the
  code) is read aloud and that starting a new recording barges in cleanly.
