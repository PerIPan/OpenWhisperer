# Multilingual TTS via Piper (speak languages Kokoro can't)

> **Status: idea-level proposal, not scheduled.** Written for a possible pickup by @hakanensari.
> No code yet. This is the "what & why & where it plugs in", specific enough to implement from,
> but the numbers (bundle size, exact voice ids) are to be confirmed during implementation.

## Goal

Speak replies in languages the current TTS engine (Kokoro-82M) does not support — **Dutch first**,
then a small curated set of common European languages. Today a Dutch-dictated turn gets a Dutch
reply spoken by an *English* Kokoro voice, which mangles the pronunciation ("Dutch in an English
accent"). We want a Dutch-sounding voice for Dutch text.

### Why this, why now

- Kokoro-82M's entire roster is 9 languages: English (US/UK), French, Italian, Spanish, Brazilian
  Portuguese, Hindi, Japanese, Mandarin. **No Dutch, German, Polish, Russian, …** — see
  [`TTSVoiceRegistry.swift`](../../../app/Sources/OpenWhispererKit/TTSVoiceRegistry.swift). This has
  been true in every version (the pre-1.5.0 Python server also used Kokoro-82M).
- **STT is already fine.** Parakeet TDT v3 transcribes Dutch (and 24 other European languages)
  correctly. The gap is TTS only.
- Real user report: a Dutch speaker uses STT+TTS heavily and can't understand the spoken Dutch
  because it's rendered by an English voice.

### Non-goals (YAGNI)

- **Not** replacing Kokoro. Kokoro stays the default and the only engine for its 9 languages — it's
  faster (ANE) and higher quality where it has a voice.
- **Not** every Piper language. Ship a curated shortlist; adding more later is a one-line registry
  edit once the mechanism exists.
- **Not** auto-detecting reply language and switching voices. The user picks a voice; language
  follows from that choice. (Auto-detect is a possible future follow-up.)
- **Not** changing STT.

## User-visible behavior (all gated on selection)

Everything below happens **only if the user selects a non-English (Piper) voice.** Default English
users see zero change — no extra downloads, no bundle behavior differences, no nudge changes.

1. User opens Settings → Voice, picks e.g. **Dutch → Nathalie**.
2. On first use of that voice, the app downloads its Piper model (~20–60 MB) with the same progress
   UX as a Kokoro voice-pack download. Nothing is downloaded until selected ("install only if we
   need them").
3. From then on, dictated turns are spoken in Dutch by that voice. The spoken summary text is
   **written in Dutch** (see §4) so the voice has Dutch to read.

## Approach

Two engines behind one seam. Kokoro (ANE, in-process, default) and Piper (CPU, for the extra
languages) both conform to a shared synth protocol; a router picks by voice id. Downstream playback,
sentence streaming, the `speak` MCP tool, and `/v1/audio/speech` are unchanged.

## Components

### 1. Synth seam — `TTSSynthesizer` protocol + router

Extract the method `TTSPlaybackController` and the blocking speech endpoint already call:

```swift
protocol TTSSynthesizer: Sendable {
    func synthesizeSamples(_ text: String, voice: String, speed: Float) async throws
        -> (samples: [Float], sampleRate: Int)
}
```

`KokoroTTS` (already an actor with this exact method — see `KokoroTTS.swift:61`) conforms as-is.
Add `PiperTTS` (also an actor; serializes the piper subprocess and dedups model load, matching the
Kokoro/`SpeechTranscriber` actor pattern).

A router resolves a voice id to an engine:

- Kokoro ids stay bare: `af_heart`, `nl`… → **no**, collision risk. Use an explicit source tag.
- **Piper ids carry a `piper:` prefix:** `piper:nl_NL-mls_medium`. The router: prefix present →
  `PiperTTS`; otherwise `KokoroTTS`. This keeps existing prefs/values valid and needs no migration.

`TTSPlaybackController` (`TTSPlaybackController.swift:89`) and `/v1/audio/speech` call the router
instead of `KokoroTTS` directly. `AudioPlaybackEngine` already accepts a per-item `sampleRate`, so
Piper's rate (typically 22050 Hz vs Kokoro's 24000) needs no special handling — return it from
`synthesizeSamples` as today.

### 2. Piper runtime — bundled & signed; voice models on-demand

The runtime must be present and **notarization-safe**; the voice models are large and per-language,
so they download on demand.

- **Bundle at build time** the `piper` arm64 macOS binary + its `espeak-ng-data` phonemizer data
  into `Contents/Resources/piper/`, and **sign them** in `build-dmg.sh` exactly like the existing
  bundled `jq` (the `OW_NOTARIZE` path already `codesign`s nested Mach-O with hardened runtime +
  timestamp — extend it to cover the piper binary; espeak-ng-data is data, not code). This avoids
  the Gatekeeper/hardened-runtime problem of downloading and executing an unsigned binary at
  runtime.
- **Download voice models on demand** into `~/.cache/fluidaudio/piper/<voice>/` (`.onnx` +
  `.onnx.json`), mirroring `KokoroTTS.ensureVoicePack` (`KokoroTTS.swift:72`): fetch on first use,
  re-fetch if the file is missing or implausibly small, reject non-200 so an error page is never
  cached as a model. Source: the piper voices repo on Hugging Face
  (`rhasspy/piper-voices`, `resolve/main/<lang>/<voice>/...`).

`PiperTTS.synthesizeSamples` shells out: `piper --model <path> --espeak_data <path> --output_raw`,
feeds the sentence on stdin, reads raw 16-bit PCM mono from stdout, converts to `[Float]` (reuse
`PCMConversion` in `OpenWhispererKit`), returns `(samples, 22050)`. One subprocess per sentence is
acceptable — summaries are short and the pipeline already synthesizes sentence-by-sentence.

> **Bundle-size note (confirm during impl):** the piper binary + espeak-ng-data add ~15–25 MB to
> the base app (currently a ~4 MB DMG). If that's unacceptable, the fallback is to download the
> runtime too, but only with a signing strategy for the downloaded binary — deferred; bundling is
> the clean first cut.

### 3. Voice registry — curated Piper groups

Extend `TTSVoiceRegistry` with Piper groups. `TTSVoice` already has the fields we need; add a way to
mark the source (either a `source: .kokoro/.piper` enum, or infer from the `piper:` id prefix — pick
one and be consistent). Initial curated shortlist (exact voice ids/names TBD from `piper-voices`
during impl):

- **Dutch** (`nl_NL`) — one female, one male
- **German** (`de_DE`)
- **Polish** (`pl_PL`)
- **Russian** (`ru_RU`)
- **Ukrainian** (`uk_UA`)

The picker renders these as additional language groups, identical UX to Kokoro groups; the `cached`
flag drives the download affordance (already used for non-default Kokoro voices).

### 4. Language-aware nudge — the easy-to-miss essential

A Dutch voice reading English text is pointless. For Piper to help, the **spoken summary must be in
the voice's language.** This lives in the hooks, not Swift:

- `voice-shared.sh` gains a voice-id → language map covering the Piper ids (e.g. `piper:nl_*` →
  Dutch). Today's persona map keys off the first char of Kokoro ids
  (`a`→American, `b`→British, …); Piper ids won't fit that scheme, so add an explicit lookup.
- When the active voice is non-English, `voice-context.sh` appends one instruction to the speak
  nudge: **write the `speak` summary in `<language>`.** The `speak` MCP tool already carries the
  `voice` arg, so the app plays it with the right engine; the hook just ensures the *text* matches.
- The English national-persona layer stays exactly as-is for English voices; Piper voices get the
  "reply in this language" line instead of a persona (personas are an English-tone device).
- `HookTests` guards this with a Dutch-voice fixture asserting the nudge carries the
  "write … in Dutch" instruction. Keep any Swift/bash parity (as with `VoiceSignal.canonicalHash`)
  if a language map is duplicated in Swift; prefer keeping the map only in the hook, like the
  persona map.

### 5. Settings UI

Settings → Voice lists the new groups alongside the Kokoro ones, grouped by language, with the
existing download-state indicator. A one-line footnote notes these voices are neural but run on CPU
(heavier/slower than the ANE Kokoro voices). Per-project `OW_TTS_VOICE` already overrides the global
voice and works unchanged (a `piper:` id is a valid value).

## Testing

- **Pure logic (`OpenWhispererKitTests`, runs under CLT):** the router's id→engine resolution
  (`piper:` prefix vs bare); registry integrity (every Piper voice has a resolvable download URL
  shape); `PCMConversion` on Piper's 16-bit/22050 raw output.
- **Hook (`HookTests`):** Dutch-voice fixture → nudge contains the "write the summary in Dutch"
  instruction; English voice → unchanged persona behavior.
- **Manual (needs a Mac with audio — not verifiable in the CLT-only dev box):** select Dutch, dictate
  Dutch, confirm the reply is spoken intelligibly in Dutch; confirm first-use download + progress;
  confirm barge-in still cancels mid-Piper-synthesis; confirm notarized build runs the signed piper
  binary under hardened runtime on a clean Mac.

## Open questions

1. **Bundle vs download the runtime.** Bundling (recommended) adds ~15–25 MB but is notarization-clean.
   Acceptable, or optimize later?
2. **Exact voice roster.** Which specific `piper-voices` models/qualities (`x_low`/`low`/`medium`)
   per language? Medium is the quality/size sweet spot; confirm per language.
3. **In-process alternative.** `sherpa-onnx` could run Piper/VITS in-process (no subprocess, no
   bundled binary) but adds an onnxruntime C++ xcframework dep that's fiddly under the CLT-only
   SwiftPM build. Rejected for the first cut; revisit if the subprocess proves problematic.
4. **Reply-language robustness.** The nudge asks the model to write the summary in the target
   language; some models may drift back to English. Accept as best-effort (KISS, matching the
   "no Stop-hook fallback" philosophy), or add a guard?

## Success criteria (the feel-test)

A Dutch speaker picks **Dutch → Nathalie**, dictates a Dutch prompt, and hears a natural Dutch reply
— no English mangling — with the model downloaded only because they chose that voice, and nothing
changed for everyone still on an English voice.
