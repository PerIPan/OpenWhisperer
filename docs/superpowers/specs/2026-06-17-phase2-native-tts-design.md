# Phase 2 — Native TTS Port (Design Notes)

**Date:** 2026-06-17
**Status:** Pre-implementation design, captured from the Phase-1 feasibility survey + the
2026-06-17 working session. **Not yet brainstormed/approved for implementation.** When Phase 2
starts, the first move is the **g2p parity spike** below — it is the go/no-go gate.
**Relation:** follows [`2026-06-17-pure-swift-stt-port-design.md`](2026-06-17-pure-swift-stt-port-design.md) (Phase 1, STT, done).

## Goal

Replace the out-of-process Python TTS (`mlx_audio` running **Kokoro-82M**, with a `spaCy`/`misaki`
phonemizer) with **native in-process Swift**, removing the Python venv from the TTS path. Phase 1
already moved STT native; the Python server currently survives only for TTS.

## Non-goals (Phase 2)

- Streaming audio player + in-process barge-in + the bash-hook IPC redesign — those are **Phase 3**.
- Notarization / venv-deletion — **Phase 4** (the venv only fully disappears once TTS is native).

## Recommended stack

| Piece | Recommended | Fallback | License |
|---|---|---|---|
| Acoustic model (Kokoro-82M) | **`mlalma/kokoro-ios`** (MLX-Swift, same weights, 24 kHz) | `FluidInference/FluidAudio` (Kokoro on CoreML/ANE) | MIT / Apache-2.0 |
| g2p / phonemizer | **`mlalma/MisakiSwift`** | FluidAudio's CoreML G2P | Apache-2.0 |

**Why MisakiSwift is the key piece:** Kokoro's net takes *phonemes* (misaki's bespoke 49-symbol
set), not text. MisakiSwift replaces **both** `spaCy` (POS for heteronyms → Apple `NaturalLanguage`)
**and** the `espeak-ng` OOV fallback (→ BART-on-MLX). That kills the Python dep **and** the GPLv3
licensing trap in one move.

**Do NOT use sherpa-onnx for TTS:** its Kokoro pipeline requires **espeak-ng (GPLv3)** even for
English (`DataDir → espeak-ng-data`), which would contaminate a permissive/closed app.

## THE GATING RISK: g2p parity — and how to A/B test it

The architecture and licensing are solved. The **unverified** thing is whether MisakiSwift's g2p
**pronounces as well as** Python `misaki` on heteronyms / numbers / OOV. If it's noticeably worse,
native TTS regresses. So **Phase 2 starts with a spike**, not a build.

### Key insight: compare phonemes, not audio

Kokoro's net is deterministic — **same phonemes in → same audio out**. So the only thing that can
make native TTS sound different is the g2p. Therefore:
- If two phonemizers emit the **same phoneme string**, the audio is identical → nothing to listen to.
- They only diverge where the g2p disagrees.

So the test is a **batch, offline, text → phoneme-string diff** — exact and scriptable — **not**
live "switch back and forth and listen" (subjective, slow, misses the long tail).

### Mechanism (a throwaway spike, like the STT `STTDiag` tool)

Two tiny harnesses over one shared corpus:
1. **Python side** — script using the *same* `misaki` the app uses: each phrase → phoneme string → JSON `{text, phonemes}`.
2. **Swift side** — a small standalone tool using **MisakiSwift**: same phrases → `{text, phonemes}`.
3. **Diff** — join on text, flag every mismatch, bucket by category, report `% exact match` + the divergence list.

### The corpus is the whole game — stress what g2p gets wrong

- **Heteronyms** in disambiguating context — "I *read* it yesterday" vs "I will *read* it"
  (`/rɛd/` vs `/riːd/`); also lead, live, bass, tear, wind, present, record, object, content…
- **Numbers / money / dates / times** — "$5.99", "3.14", "2026", "1st", "555-1234", ranges.
- **Abbreviations & acronyms** — "Dr.", "e.g.", "NASA", "API".
- **OOV / names / technical terms** — where the neural fallback fires (mispronunciations hide here).
- **Real `[VOICE:]`-style conversational text** — that's what it actually speaks.

### Audio only comes in for the divergences

A phoneme mismatch isn't automatically a regression — Python misaki could itself be the wrong one.
So for each disagreement: synthesize **both** phoneme strings through the same Kokoro net → two clips
→ **blind A/B listen** (pick A/B/same without knowing which). The bar is **"native is not worse,"**
not "native is identical." This is a handful of clips, not the whole corpus.

### Decision gate

Pass if: high exact-phoneme match on common text **and** no clearly-worse pronunciations on frequent
cases. Rare-OOV-tail mistakes are acceptable. Fail → fall back (FluidAudio CoreML g2p, or keep Python
TTS longer).

## Phasing

1. **Phase 2a — g2p parity spike** (above). Go/no-go before any real porting.
2. **Phase 2b — engine integration**: `kokoro-ios` + MisakiSwift wired into the app, behind the same
   in-process pattern as `SpeechTranscriber` (an actor; offline-first model load — see the Xet/Little
   Snitch note below). Produce audio buffers in-process.
3. **Phase 3** — `AVAudioPlayerNode` streaming player; in-process barge-in (`playerNode.stop()`); the
   bash-hook IPC decision (keep a tiny embedded localhost server vs. redesign). Out of scope for Phase 2.

## Constraints / open decisions

- **Hardware floor:** the MLX path (kokoro-ios + MisakiSwift) is **Apple-Silicon-only, macOS 15+**.
  FluidAudio's CoreML path runs wider (Intel + lower OS) but trades misaki dict transparency for a
  neural g2p. Decide based on the user base.
- **Voice continuity:** today's default is Kokoro `af_heart` (`lang_code="a"`, US-English female).
  Native ports load the **same** Kokoro-82M weights, so `af_heart` *should* reproduce — but perceived
  voice = weights × phonemes, so continuity depends on g2p parity (above).
- **Weights:** ship in the DMG (bigger, zero first-run download, notarizable) vs download at first run.
- **Xet/Little Snitch:** the native Kokoro weights also come from HuggingFace, so Phase 2 will hit the
  **same Xet-CDN blocking** we solved for STT (see Phase-1 spec + the offline-load pattern in
  `SpeechTranscriber`). Apply the same `download:false` + local-folder offline load.

## Why this port matters — evidence from the 2026-06-17 session

The Python TTS stack proved **fragile** in exactly the ways native removes:
- **mlx-audio version drift broke the Kokoro vocoder.** Unpinned `uv pip install mlx-audio` pulled
  0.4.4, whose `istftnet.py` `SineGen` has a length bug: `_f02sine` runs an interpolate down→up
  round-trip that isn't length-preserving (`round(round(L/s)·s) ≠ L`), while `_f02uv` skips
  interpolation — so `sine_waves` (e.g. 75900) and `uv`/`noise_amp` (75600) mismatch, and
  `noise_amp * mx.random.normal(sine_waves.shape)` fails to broadcast → HTTP 500 on most real text.
  - **Confirmed upstream (2026-06-17 GH sweep).** This is a known, in-flight `mlx-audio` bug, not a
    local quirk: open issues [#784](https://github.com/Blaizzy/mlx-audio/issues/784) and
    [#786](https://github.com/Blaizzy/mlx-audio/issues/786) report the identical
    `[broadcast_shapes] Shapes (1,N,1) and (1,N+300,9)` crash on 0.4.4 (works on 0.4.1), same env
    (Apple Silicon, Kokoro-82M, `af_heart`). The fix is PR
    [#785](https://github.com/Blaizzy/mlx-audio/pull/785) "Fix SineGen length alignment" (aligns the
    generated sine length to the F0 length before UV/noise; covers Kokoro **and** Kitten; ships a
    regression test) — **approved but unmerged**, blocked only on a signed commit; the duplicate PR
    [#788](https://github.com/Blaizzy/mlx-audio/pull/788) was closed in its favor. As of the sweep,
    0.4.4 (2026-06-06) is the latest release and `main`'s `SineGen` is byte-for-byte the buggy 0.4.4
    — **the fix is in no release and not even on `main`**, so waiting for an upstream version won't
    help.
  - **The trigger (why 0.4.1 works, 0.4.4 crashes).** The round-trip is the *latent* defect; commit
    `aaf5ee6` ("Fix Kokoro usage from worker threads", #745, 2026-05-27) made it deterministic by
    swapping `mx.ceil` → Python `math.ceil` in `interpolate.py`. float64 precision
    (`296400 × 1/300 = 988.0000000000001` → `math.ceil` → `989`) lands the upsample one frame (×300)
    too long; 0.4.1's `mx.ceil` rounded back down, so it never fired.
- **Setup under-declared deps.** The venv was missing `soundfile`, `fastapi`, `uvicorn`, `webrtcvad`,
  `python-multipart`, **and** `misaki` — `unified_server.py` imports them directly but
  `mlx-audio`/the setup never installed them. (Fixed this session in `SetupManager.swift` + `setup.sh`
  + the smoke test now imports the real server stack.)
- **Little Snitch blocks the HF Xet CDN**, breaking model downloads.

Native Swift (kokoro-ios + MisakiSwift, statically linked, offline-first) eliminates all three classes
of failure.

## Status at the start of Phase 2 — what's done & what's open (2026-06-17)

**Done & committed** on branch `phase1-native-stt`:
- `8eace97` — **Phase 1: STT ported to native WhisperKit** (in-process; replaced the HTTP
  `uploadToWhisper`). Working, confirmed by the user. Detail in the Phase-1 spec "As-Built" section.
- `90b866d` — **offline WhisperKit load** (resilient to the blocked Xet CDN) + **STT/setup failures
  surfaced in the standby overlay** with a Retry button.
- `c99085e` — **complete TTS server dependency set** (`soundfile`, `fastapi`, `uvicorn`, `webrtcvad`,
  `python-multipart`, `misaki[en]`) + the smoke test now imports the real server stack. The venv was
  under-specified; the TTS server now boots.
- `9df2ee1` — this Phase-2 pre-plan + gitignore local Claude settings.

Also done (not code): a clean **security review** of the branch (no findings); the **`STTDiag`**
diagnostic kept on disk but gitignored (`app/Tools/STTDiag`, standalone package — `swift run STTDiag`).

**Open / not done:**
- **TTS synthesis** — the Python `mlx-audio` 0.4.4 Kokoro vocoder bug (`SineGen._f02sine` length
  mismatch → broadcast error → HTTP 500; confirmed upstream — see the evidence section's #784/#786/#785
  detail). **Worked around 2026-06-17: pinned `mlx-audio==0.4.1`.** Applied in `setup.sh` +
  `SetupManager.swift` (Step 2) and installed into the live venv. Verified end-to-end with a before/after
  probe: on 0.4.4 even `"Hello there."` 500'd `(1,36600,1) vs (1,36900,9)`; on 0.4.1 the same input, a
  33s paragraph, and a direct `SineGen(upsample_scale=300)` case all synthesize, and setup's smoke-test
  import chain passes. This unblocks TTS but keeps Python in the loop — the native port (below) remains
  the durable fix that also removes the whole version-drift failure class. Drop the pin once upstream PR
  #785 ships. (Caveat: the reinstall wiped the kokoro.py voice-cache perf patch — re-apply it as a
  runtime monkeypatch in `unified_server.py`, not a venv edit, since venv edits don't survive reinstall.)
- **Voice output end-to-end** — the `[VOICE:]` instruction half works (`CLAUDE.md`; Codex = `AGENTS.md`),
  and the **Stop hook is configured repo-locally** (`.claude/settings.local.json`, gitignored →
  `hooks/tts-hook.sh`), but it needs a **session restart** to load AND working synthesis before any
  audio plays.
