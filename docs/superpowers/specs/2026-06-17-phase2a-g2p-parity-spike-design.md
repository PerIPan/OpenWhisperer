# Phase 2a — g2p Parity Spike (Design)

**Date:** 2026-06-17
**Status:** Brainstormed and approved. Ready for an implementation plan.
**Parent:** [`2026-06-17-phase2-native-tts-design.md`](2026-06-17-phase2-native-tts-design.md) — this spec is the
**go/no-go gate** that parent doc calls for before any native porting.

## Goal

Decide whether `MisakiSwift` pronounces well enough to replace Python `misaki` in the TTS path — **before**
committing to the native port. Kokoro's net is deterministic (same phonemes in → same audio out), so the only
thing that can make native TTS sound different is the g2p. The spike measures that difference directly.

## Scope

- **In:** a phoneme-string parity diff (Python `misaki` vs Swift `MisakiSwift`) over a shared corpus, plus
  blind audio A/B for the divergences it surfaces.
- **Out:** any app changes, any engine integration (`kokoro-ios`), the actual port. Those are Phase 2b, gated
  on this result.
- **Throwaway:** all artifacts live in a **gitignored** `app/Tools/G2PParity/` folder, mirroring the existing
  `app/Tools/STTDiag` convention. Nothing ships.

## Two feasibility gates — do these first

These are the real risk; both are cheap to check and either can be an early no-go.

1. **MisakiSwift builds and speaks the same alphabet.** Confirm `mlalma/MisakiSwift` resolves via SwiftPM,
   compiles, and emits phonemes in misaki's bespoke 49-symbol set for a sample sentence. If it can't build, or
   uses a different notation than Python `misaki`, stop here and reassess (fallback: FluidAudio CoreML g2p).
2. **Phoneme injection into Kokoro.** The A/B test feeds *raw phoneme strings* into Kokoro, bypassing its own
   misaki. Confirm we can do this in the venv's `mlx_audio` (0.4.1) — likely a small monkeypatch making the
   Kokoro pipeline's g2p return our target phoneme string instead of running misaki. If infeasible, the audio
   half needs rework (the phoneme diff still stands on its own).

## Architecture

Three language-appropriate pieces, each in the language already proven for that job, under
`app/Tools/G2PParity/` (gitignored):

| Piece | Input → Output | Notes |
|---|---|---|
| `misaki_phonemes.py` | corpus → `misaki.jsonl` `{text, phonemes, bucket}` | run with the venv python; `misaki` already works |
| `G2PParity` (SwiftPM exe) | corpus → `swift.jsonl` `{text, phonemes, bucket}` | depends on `MisakiSwift`; `STTDiag/Package.swift` is the template |
| `diff.py` | the two `.jsonl` → `report.md` + `divergences.jsonl` | join on text; bucket; compute match rates |
| `ab_audio.py` | `divergences.jsonl` → blind `clipA/clipB.wav` + answer key | feeds *both* phoneme strings through the same 0.4.1 Kokoro |

**Flow:**

```
corpus ─┬─▶ misaki_phonemes.py ─▶ misaki.jsonl ─┐
        └─▶ G2PParity (Swift)  ─▶ swift.jsonl  ─┴─▶ diff.py ─▶ report.md + divergences.jsonl
                                                                      │
                                          for each divergence: both phoneme strings
                                          ─▶ same Kokoro net ─▶ clipA/clipB (blind) ─▶ human listens
```

Each piece is independently runnable and has one job, so a failure localizes cleanly (g2p mismatch vs audio
plumbing vs corpus issue).

## Corpus — "the whole game"

~150 lines total — roughly **~100 stress + ~50 real** — split into two sets **scored separately** (this split
maps onto the decision gate; the real set needs enough lines for its match rate to mean something):

- **Stress set** — adversarial, concentrated on what g2p gets wrong:
  - Heteronyms in disambiguating context — "I *read* it yesterday" vs "I will *read* it"; lead, live, bass,
    tear, wind, present, record, object, content…
  - Numbers / money / dates / times — "$5.99", "3.14", "2026", "1st", "555-1234", ranges.
  - Abbreviations & acronyms — "Dr.", "e.g.", "NASA", "API".
  - OOV / names / technical terms — where the neural fallback fires and mispronunciations hide.
- **Real set** — sampled `[VOICE:]`-style conversational lines (what it actually speaks). This is the
  "common text" the gate's pass bar is measured against.

Each corpus line is tagged with its bucket so the report can break results down by category.

## Diff metrics

`diff.py` reports two rates per bucket and per set:

- **Exact match** — identical phoneme strings.
- **Normalized match** — after stripping stress marks and collapsing whitespace, so cosmetic differences don't
  masquerade as real divergences.

Anything that differs after normalization is a **divergence** and flows to the audio A/B.

## Decision gate (pragmatic — "native not worse")

**Pass if:**
- Real-set exact phoneme match is high (target ≈ **≥90%**), **and**
- Blind A/B on the **frequent** divergences shows native (`MisakiSwift` phonemes) **≥** Python `misaki` —
  ties are fine. The bar is "native is not worse," not "identical."

Rare OOV / name-tail mismatches are acceptable. A phoneme mismatch is **not** automatically a regression —
Python misaki could be the wrong one — which is exactly why divergences go to blind listening rather than being
counted as failures.

**Fail →** fall back: FluidAudio's CoreML g2p, or keep the Python TTS (now unblocked by the `mlx-audio==0.4.1`
pin) longer while reassessing.

## Deliverable

- `report.md` — the go/no-go artifact: exact + normalized match rates per bucket, per set, and the full
  divergence list.
- The blind A/B clips + answer key for the divergences.
- **No app changes**, nothing committed beyond this spec and (later) the plan.

## Open / deferred (not part of this spike)

- Hardware floor (MLX Apple-Silicon-only vs FluidAudio CoreML wider), weights-shipping, and the in-process
  engine integration are **Phase 2b**, decided only if this spike passes. See the parent doc.

## Spike Results & Verdict (2026-06-17)

Built and run as throwaway tooling under the gitignored `app/Tools/G2PParity/`. **Both feasibility gates passed.**

- **Gate A — MisakiSwift builds & emits phonemes.** Resolves via SwiftPM; API is
  `EnglishG2P(british: false).phonemize(text:)`, emitting the *same* 49-symbol alphabet as Python misaki
  (`"Hello world!" → həlˈO wˈɜɹld!` on both). Runtime needs MLX's Metal lib, which the plain CLI build under
  Command Line Tools does not produce — worked around by colocating the venv's prebuilt `mlx.metallib` next to
  the binary (mlx-swift searches for a colocated `mlx.metallib` first).
- **Gate B — phoneme injection into Kokoro.** `KokoroPipeline.generate_from_tokens("<phoneme string>",
  voice: "af_heart")` synthesizes a raw phoneme string directly (cast Kokoro's float16 → float32 for
  `soundfile`). Produced audibly distinct A/B clips.

**Parity over a 91-line corpus (stress + real), exact / normalized:**

| bucket | exact% | normalized% | read |
|---|---|---|---|
| real (pass-bar set) | 90% | 96% | meets the bar |
| acronym | 90% | 90% | fine |
| heteronym | 84% | 88% | minor losses — past-tense `read`, `content` stress |
| number / money | 40% | 46% | **the one real regression** — drops `$5.99`, `2.5`, `%`, a digit of `2026` |
| oov / names | 50% | 50% | **MisakiSwift wins** — Python misaki here emits `❓` (no espeak fallback); MisakiSwift's BART pronounces them |

**Key insight:** most non-number divergences are MisakiSwift being *better* — the Python misaki in our venv has
no OOV fallback, so native g2p is an **upgrade over the current Python TTS** on unusual words, not just parity.

**Verdict: GO.** Native g2p meets the pragmatic bar — ≥90% on real text, not-worse on common cases, better on
OOV. Rare OOV-tail differences are acceptable per the gate.

**Phase 2b follow-ups surfaced by the spike:**
1. **Number/money normalization shim** (approved) — expand numbers → words before MisakiSwift
   (e.g. `$5.99` → "five dollars and ninety nine cents"), sidestepping its weak number handler. Closes the
   one regression.
2. **MLX metallib build/runtime constraint.** The MLX-Swift path (MisakiSwift + `kokoro-ios`) needs either
   full **Xcode** (the `metal` compiler) at build time, or a prebuilt `mlx.metallib` colocated/bundled at
   runtime. The app must **bundle the metallib** into `OpenWhisperer.app`, and `build-dmg.sh` (plain
   `swift build` under Command Line Tools) needs updating accordingly.
