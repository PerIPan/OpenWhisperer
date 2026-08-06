# Closing the voice loop

**Status:** proposal — not an approved design. Nothing here is committed.
**Date:** 2026-08-06
**Picking one up?** Jump to [If you're picking one up](#if-youre-picking-one-up).

> Docs in `specs/` are designs that were agreed and built. This directory is for
> the step before that: a case for doing something, with enough research attached
> that whoever picks it up doesn't start from zero. Expect to argue with it.

## The thesis

Wispr Flow and Quill are both **dictation**: one direction, mouth to text field.
Everything they compete on — filler removal, punctuation, tone matching, snippets
— is polish on that single arrow.

OpenWhisperer already has the other arrow. Kokoro and Supertonic-3 on the ANE, an
MCP server on `:8000`, and a `UserPromptSubmit` hook that gets the model to speak
*mid-turn* rather than after it. No competitor can copy that without building a
TTS stack, a playback queue, and a per-platform hook layer first. That asymmetry
is the moat, and right now we barely lean on it.

So the direction is not "catch up on dictation polish." It is:

**Make the round-trip the product.**

The agent should be able to *ask you something out loud and hear your answer*,
without you touching the keyboard, without the session breaking. That is one
feature — `ask_user` — and it is the only one of the three here that is a
differentiator rather than a gap.

The other two are in this PR because the round-trip is worthless if you can't
stay in it. Snippets cut the number of words you have to say. Whisper Mode covers
the case where you're in an open-plan office and can't say them loudly. They are
enablers, not features in their own right, and they should be framed that way.

### Where we stand

| | Wispr Flow | Quill | OpenWhisperer |
|---|---|---|---|
| Direction | in | in | **in + out** |
| Runs locally | no (cloud, Privacy Mode = not stored) | optional | **always** |
| Agent integration | none | MCP: `start_recording`, `list_transcripts`, … | **MCP `speak` + hooks on 4 platforms** |
| Cleanup / formatting | yes, core pitch | yes, core pitch | **no** |
| Snippets | yes | no | **no** |
| Tone / per-app | yes | app context | no |

Read that table twice. The row we win is the row nobody else is playing, and the
rows we lose are mostly *polish*. Quill's MCP tools are worth noting — the agent
can drive recording and read transcripts — but it's still one direction: the
agent reads what you said. It cannot talk back.

Cleanup is the one genuine product gap and it is **not** proposed here. See
[Deliberately not proposing](#deliberately-not-proposing).

---

## 1. `ask_user` — the spoken round-trip

**The differentiator. Largest effort. Do it last.**

### Problem

Today the loop is half-open. The model can speak (`speak`), and you can dictate,
but the two never meet. If the model needs a decision — "shall I force-push or
rebase?" — it prints the question and stops. You come back to a terminal, read,
type. The voice session is over.

Closing that is a genuinely new interaction: the agent asks aloud, the overlay
opens the mic, your spoken answer comes back as the tool result, and the turn
continues. Never touching the keyboard is not the point. **Not breaking the
session** is the point.

### Prior art, and why not to use it

MCP added **elicitation** (`elicitation/create`, server→client) in the
[2025-06-18 revision][elicit]. A server can ask the client for structured input
mid-request, validated against a JSON schema, with `form` and `url` modes.

That is the standard-shaped answer and it is the wrong one here. Elicitation
renders as a **client-side form** — the client owns the UI. A form is exactly the
keyboard interruption we're trying to remove, and the round-trip's whole value is
that it stays in audio. Client support is also uneven, where a plain tool call
works on all four platforms we support today.

So: a blocking `ask_user` **tool**, not elicitation. Worth stating explicitly in
the implementation, because the next reviewer will ask.

[elicit]: https://modelcontextprotocol.io/specification/draft/client/elicitation

### Sketch

Three pieces, in dependency order.

**(a) `MCPOutcome` needs a deferred case.** [`MCPServer.swift:5-12`][mcpout] has
three outcomes — `.json`, `.accepted`, `.speak` — and all three are answered
synchronously by the HTTP layer at [`TTSHTTPServer.swift:201-213`][dispatch].
`.speak` is fire-and-forget: it plays audio *and* replies in the same breath.
`ask_user` is the first outcome that cannot reply yet.

Add something like `.ask(prompt: String, voice: String?, timeout: TimeInterval)`
and have the HTTP layer hold `conn` open until an answer or a timeout lands.

This is less scary than it sounds. `POST /v1/audio/speech` at
[`TTSHTTPServer.swift:173-182`][async] **already** responds from inside a `Task`
long after `handle` returned — the deferred-response pattern exists in this file
and works. What's new is that the deferring is driven by the pure layer.

Keep `MCPServer` pure. It should shape the JSON and say "now go ask"; it must not
learn about `AVAudioEngine`. That boundary is why the dispatch logic is
unit-testable under Command Line Tools at all, and it's worth protecting.

**(b) `DictationManager` has no one-shot API.** The public surface is
`toggle()`, `holdToTalkDown()`, `holdToTalkUp()` — all hotkey-shaped, all
returning `Void`, all typing their result into whatever app had focus. `ask_user`
needs "record one utterance, hand me the text, type nothing."

The closest existing primitive is the hands-free path: `activateHandsFree()`
calibrates ambient noise, waits for silence, flushes, transcribes, resumes. That
is structurally the loop we want, minus the keyword detector and minus the
typing. Read it before writing anything new.

**(c) It inverts barge-in — the subtle part.** Every entry point into recording
calls `killTTS()` ([`DictationManager.swift:812-816`][killtts]), which calls
`TTSPlaybackController.bargeIn()`. The invariant today: *starting to listen stops
the speaking*, because STT and TTS contend for the same ANE, and because you
interrupting the agent should shut it up immediately.

`ask_user` needs the exact opposite ordering — speak the question **to
completion**, *then* open the mic. Get this wrong and the mic records the
speakers asking the question, and Whisper faithfully transcribes it back.

The primitive already exists: hands-free mode mutes the mic while
`tts_playing.lock` is present ([`DictationManager.swift:546,567`][lock]). Reuse
that gate rather than inventing a second one. Note this is a *sequencing*
problem, not a barge-in removal — a user saying "hold on" over the question
should still work.

[mcpout]: ../../../app/Sources/OpenWhispererKit/MCPServer.swift
[dispatch]: ../../../app/Sources/OpenWhisperer/TTSHTTPServer.swift
[async]: ../../../app/Sources/OpenWhisperer/TTSHTTPServer.swift
[killtts]: ../../../app/Sources/OpenWhisperer/DictationManager.swift
[lock]: ../../../app/Sources/OpenWhisperer/DictationManager.swift

### Done when

- `ask_user(question, timeout?)` appears in `tools/list` and returns the user's
  spoken answer as the tool result.
- The question finishes playing before the mic opens. Verify by asking a long
  question and checking the transcript doesn't contain it.
- A timeout returns a clear `isError` result rather than hanging the agent.
- Works on Claude Code and Codex at minimum. Pi needs its own path — the
  extension talks to `/v1/audio/play`, not MCP.
- `swift run OpenWhispererKitTests` covers the new outcome's JSON shaping.

### Open questions

- **Timeout, and what the agent sees.** 30 s? Configurable? A timeout should
  probably read as "user didn't answer" rather than a hard failure, so the model
  can carry on with a default instead of dying.
- **Cancellation.** What if the user hits the PTT hotkey during an `ask_user`
  window — abort, or treat it as the answer?
- **Does the nudge need to know?** `voice-context.sh` currently tells the model
  to `speak` first. It says nothing about asking. Leaving it unmentioned means
  the tool is available but rarely used; mentioning it risks the model asking
  permission constantly. Probably start silent and see.
- **Concurrency.** Two `ask_user` calls in flight is nonsense. Reject the second?
- **`--serve-tts` headless mode has no mic and no overlay.** `ask_user` should
  almost certainly not be registered there.

---

## 2. Snippets

**Cheapest thing on the list. Ship it first.**

### Problem

Anyone using this with a coding agent says the same twenty phrases all day. "Run
the tests and fix what breaks." "Commit this with a conventional message." Wispr
Flow ships **Text snippets** — trigger phrase in, canned expansion out — and
prices it as a headline feature. Quill has nothing here.

It is the only proposal on this list with no model, no download, no ANE
contention, and no new failure mode. It's a dictionary lookup.

### Sketch

Mirror the vocabulary feature exactly; it's the same shape and it already works.

- **`SnippetExpander`** in `OpenWhispererKit` — pure, no AppKit, unit-testable
  under CLT. Parse `trigger = expansion` lines, apply to a transcript.
- **`Paths.sttSnippets`**, a flat file in Application Support alongside
  `stt_vocabulary`.
- **A `SnippetsWindow`** cloned from
  [`VocabularyWindow.swift`][vocabwin] — a `TextEditor` that writes on change.
  Don't design a table UI. The vocabulary editor is a plain textarea and nobody
  has complained.
- **One line in the pipeline** at
  [`DictationManager.swift:229-232`][pipeline], after `VocabularyCorrector`.

```swift
let defillered = (language == "en") ? DisfluencyFilter.apply(text) : text
let corrected  = VocabularyCorrector.apply(defillered, glossary: glossary)
let expanded   = SnippetExpander.apply(corrected, snippets: snippets)  // new
```

Order matters and this is the right slot: expanding **after** correction means a
trigger still fires when Whisper misheard a word that the glossary then fixed.

[vocabwin]: ../../../app/Sources/OpenWhisperer/VocabularyWindow.swift
[pipeline]: ../../../app/Sources/OpenWhisperer/DictationManager.swift

### Done when

- A snippet defined in the editor expands in dictated text, in any app.
- `SnippetExpander` has check-group coverage in `OpenWhispererKitTests`.
- No snippets defined ⇒ provably zero behaviour change.

### Open questions

- **Whole-utterance or substring?** Substring risks "ship it" firing inside "I'd
  ship it if…". Whole-utterance-only is far safer and probably covers 90% of real
  use. Recommend starting there and loosening only on complaint.
- **Case and punctuation.** Whisper capitalizes and punctuates, so a raw literal
  match on `run the tests` will miss `Run the tests.` — normalize both sides.
- **Multi-line expansions** in a line-oriented flat file need an escape or a
  different format. Probably not worth solving in v1.
- **Does it belong in Settings → Dictate, or its own window?** Vocabulary got its
  own window. Follow suit unless there's a reason not to.

---

## 3. Whisper Mode

**Real, but the popular framing of it is wrong. Read this before estimating.**

### The premise is half wrong

The obvious pitch is "boost the gain and lower the VAD threshold so quiet speech
registers." That fixes *capture*. It does not fix *accuracy*, and it's important
nobody ships this believing otherwise.

Whispered speech isn't quiet normal speech. It has **no voiced excitation** — no
fundamental frequency, no harmonic structure — so its spectral envelope is
genuinely different, not just lower-amplitude. Amplifying it does not make it
look like normal speech to an acoustic model. Measured, on Whisper specifically:

| | CER | WER |
|---|---|---|
| Normal speech | ~3.95% | — |
| Whispered speech | 4.24% – 18.93% | **18.8%** |

Source: [*Leveraging Self-Supervised Models for Automatic Whispered Speech
Recognition*][whisperpaper] (arXiv 2407.21211), which also reports the 18.93% CER
figure from a separate evaluation. Roughly a **4–5× degradation**, and the fix in
the literature is fine-tuning on whispered corpora (wTIMIT, CHAINS) — well out of
scope for this app.

So scope it honestly:

- **In scope:** the mic reliably *captures* quiet speech. No clipped first
  syllable, no dropped utterance because RMS never crossed the gate.
- **Out of scope:** whispered accuracy matching normal speech. It won't.

That's still worth building. "It hears me at all" is the complaint; today quiet
speech frequently doesn't register. And it makes the existing accuracy levers —
`stt_vocabulary`, `VocabularyPrompt` — matter *more*, because there's more error
for them to absorb.

[whisperpaper]: https://arxiv.org/abs/2407.21211

### Sketch — and the good news

**The VAD half is nearly free.** [`AudioRecorder.swift:317-341`][silence] gates on
bare RMS against an ambient-noise multiplier:

```swift
let threshold = ambientNoiseFloor * speechThresholdMultiplier
let nowSilent = safeRawRMS < threshold
```

That is precisely what fails on whispers — low-amplitude, noise-like speech reads
as silence, so hands-free either never triggers or cuts you off mid-sentence.
Lowering the multiplier just trades that for false triggers on room noise.

FluidAudio — **already a dependency, no new package** — ships `VadManager`, a
public actor wrapping Silero VAD as CoreML ([FluidInference/silero-vad-coreml][hf]):

- `.cpuAndNeuralEngine`, `defaultThreshold: 0.85`, streaming API
- ~1 ms per 30 ms chunk on one CPU thread; the model is ~1–2 MB
- Learned speech/non-speech, not an energy threshold — the entire point

Two pieces of work:

1. **Swap the RMS gate for `VadManager`** in the hands-free silence path. This is
   worth doing *regardless* of Whisper Mode; the RMS gate is the weakest part of
   hands-free today.
2. **A gain stage** before the samples reach the ANE, plus a Settings toggle. Note
   the RMS-derived UI meters and `SpectrumBands` read pre-gain, so the overlay
   waveform needs checking or it'll look dead while Whisper Mode works fine.

[silence]: ../../../app/Sources/OpenWhisperer/AudioRecorder.swift
[hf]: https://huggingface.co/FluidInference/silero-vad-coreml

### Done when

- Quiet/whispered speech triggers and completes an utterance in hands-free mode
  without cutting off mid-sentence.
- Normal-volume dictation is measurably unchanged with the mode off.
- The overlay waveform still animates in Whisper Mode.
- The UI **does not** promise accuracy parity. Cite the number if it says
  anything at all.

### Open questions

- **Is it a mode, or just better defaults?** If `VadManager` alone fixes capture,
  a user-facing toggle may be unnecessary — and one fewer setting is a win.
  Measure before adding UI.
- **Where does gain go?** CoreAudio input-gain properties are device-dependent
  and not always writable; a software gain stage on the buffer is more portable
  and doesn't mutate the user's system settings. Unverified — needs a spike.
- **Model download.** VAD adds another first-run fetch. `~/.cache/fluidaudio`,
  same as Kokoro. Small, but the HuggingFace Xet CDN issue noted in `AGENTS.md`
  applies.
- **Does `VadManager` want 16 kHz?** Our pipeline is 16 kHz mono; confirm before
  building on it.

---

## If you're picking one up

Recommended order — **cheapest and most independent first**:

| # | Feature | Effort | Risk | New deps |
|---|---|---|---|---|
| 2 | Snippets | small | very low | none |
| 3 | Whisper Mode | medium | low | none (FluidAudio has VAD) |
| 1 | `ask_user` | large | medium | none |

They're independent — you can take any one without the others. But `ask_user`
touches the MCP layer, the HTTP layer, `DictationManager`, and the barge-in
invariant at once, so it is a poor first contribution to this codebase.

Whisper Mode has a **standalone piece worth doing on its own**: replacing the RMS
silence gate with `VadManager`. That improves hands-free mode today, for
everyone, with or without the rest of the proposal.

Read `AGENTS.md` first — worktree layout, the two test runners, why there's no
XCTest, and the Conventions section on code signing (ad-hoc builds drop your
Accessibility grant every rebuild, which will waste an afternoon otherwise).

## Deliberately not proposing

Considered and left out, so nobody has to re-derive why:

- **Local cleanup pass** (filler removal, punctuation, casing, list formatting).
  Honestly **the biggest gap** — it's the entire pitch of both competitors, and
  `DisfluencyFilter` is a stub next to it. It's excluded because it's a
  *different bet*: it needs an LLM in-process (Apple Foundation Models on macOS
  26+, or a bundled small MLX model for 14+), which means a model-size decision,
  a latency budget, and a quality bar. It deserves its own proposal, not a
  section in this one. **Someone should write that.**
- **Per-app profiles** — depends on cleanup existing first.
- **Voice edit on selection** — same, plus a text-selection capture path.
- **Parakeet as an engine option** — settled. The owner reversed the Parakeet
  migration on 2026-07-30 with the measurements in hand. See `AGENTS.md`; do not
  reopen.
- **System-audio capture** — a real feature (Quill has it, it opens meeting
  notes), but it's an input-source change, orthogonal to the round-trip.
- **Local stats** — retention telemetry for a product with no retention problem
  yet.

## Sources

- [MCP — Elicitation](https://modelcontextprotocol.io/specification/draft/client/elicitation)
- [Leveraging Self-Supervised Models for Automatic Whispered Speech Recognition (arXiv 2407.21211)](https://arxiv.org/abs/2407.21211)
- [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml)
- [snakers4/silero-vad](https://github.com/snakers4/silero-vad)
- [Wispr Flow](https://wisprflow.ai/)
- [Quill](https://github.com/woosublee/quill)
