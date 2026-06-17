# Phase 2a — g2p Parity Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a throwaway harness that measures whether Swift `MisakiSwift` pronounces as well as Python `misaki`, producing a go/no-go report plus blind A/B audio for the divergences.

**Architecture:** Three language-appropriate pieces under a gitignored `app/Tools/G2PParity/`: a Python misaki harness, a Swift `MisakiSwift` harness, a Python diff/report, and a Python audio-A/B that feeds raw phonemes through the venv's 0.4.1 Kokoro. Front-load two feasibility gates that can kill the approach early.

**Tech Stack:** Swift 5.9 / SwiftPM (macOS 14+), `mlalma/MisakiSwift`; Python 3.13 in the existing venv (`misaki` 0.9.4, `mlx_audio` 0.4.1, `soundfile`, `numpy`).

**Spec:** [`docs/superpowers/specs/2026-06-17-phase2a-g2p-parity-spike-design.md`](../specs/2026-06-17-phase2a-g2p-parity-spike-design.md)

## Global Constraints

- All artifacts live under `app/Tools/G2PParity/` and are **gitignored** (mirror `app/Tools/STTDiag`). Nothing ships, no app code changes.
- Python pieces run with the venv interpreter: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python"`.
- Set `HF_HUB_OFFLINE=1` and `HF_HUB_DISABLE_XET=1` for any script that loads Kokoro (cached model; dodge the Little Snitch / Xet block).
- Swift package: `// swift-tools-version: 5.9`, `platforms: [.macOS(.v14)]`, dependency `mlalma/MisakiSwift`.
- Phoneme comparison is like-for-like in misaki's bespoke 49-symbol set.
- TTS model `prince-canuma/Kokoro-82M`, voice `af_heart`, `lang_code="a"` (US English) — matches the app.

---

### Task 1: Scaffold + gitignore

**Files:**
- Create: `app/Tools/G2PParity/README.md`
- Modify: `.gitignore`

- [ ] **Step 1: Create the folder + README**

```bash
mkdir -p "app/Tools/G2PParity"
```

`app/Tools/G2PParity/README.md`:
```markdown
# G2PParity (throwaway spike)

Measures Python `misaki` vs Swift `MisakiSwift` phoneme parity for the Phase 2a go/no-go gate.
Gitignored — nothing here ships. See docs/superpowers/specs/2026-06-17-phase2a-g2p-parity-spike-design.md.

Run order:
  swift run --package-path Swift G2PParity --selftest        # feasibility gate A
  ./py inject_selftest.py                                     # feasibility gate B
  ./py misaki_phonemes.py corpus/*.txt > out/misaki.jsonl
  swift run --package-path Swift G2PParity corpus/*.txt > out/swift.jsonl
  ./py diff.py out/misaki.jsonl out/swift.jsonl
  ./py ab_audio.py out/divergences.jsonl
```

- [ ] **Step 2: Gitignore it**

Add to `.gitignore` (check it isn't already covered):
```
app/Tools/G2PParity/
```

- [ ] **Step 3: Add the venv python shim** `app/Tools/G2PParity/py` (chmod +x):

```bash
#!/bin/bash
exec "$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" "$@"
```

- [ ] **Step 4: Verify** `cd app/Tools/G2PParity && ./py -c "import misaki, mlx_audio; print('ok')"` → prints `ok`.

- [ ] **Step 5: Commit** — NOTE: contents are gitignored, so only `.gitignore` is committable.
```bash
git add .gitignore
git commit -m "chore: gitignore G2PParity spike tooling"
```

---

### Task 2: Feasibility Gate A — MisakiSwift builds + emits phonemes

This is a spike: the deliverable is evidence (printed phonemes), not a passing unit test. If `MisakiSwift` does not resolve/compile, STOP and report — that is itself the finding (fallback: FluidAudio CoreML g2p).

**Files:**
- Create: `app/Tools/G2PParity/Swift/Package.swift`
- Create: `app/Tools/G2PParity/Swift/Sources/G2PParity/main.swift`

**Interfaces:**
- Produces: an executable `G2PParity` that, with `--selftest`, prints `text \t phonemes` for a few sentences; with a corpus path, emits JSONL (Task 6).

- [ ] **Step 1: Package.swift** (template = `app/Tools/STTDiag/Package.swift`):

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "G2PParity",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/mlalma/MisakiSwift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "G2PParity",
            dependencies: [.product(name: "MisakiSwift", package: "MisakiSwift")],
            path: "Sources"
        ),
    ]
)
```

- [ ] **Step 2: Resolve the dependency** — this is the first real feasibility check.

Run: `cd app/Tools/G2PParity/Swift && swift package resolve`
Expected: resolves a `MisakiSwift` version. If it fails (repo/path/product name wrong), inspect the real module/product name via `swift package describe` or the repo README and correct `Package.swift` before continuing.

- [ ] **Step 3: Minimal `--selftest` main** `Sources/G2PParity/main.swift`:

```swift
import Foundation
import MisakiSwift

// NOTE: MisakiSwift's exact API (type + call) is verified in Step 4 — adjust the two
// marked lines to the real symbols if they differ.
let samples = [
    "I read it yesterday.",
    "I will read it tomorrow.",
    "It costs $5.99.",
    "NASA and the API.",
]

let g2p = MisakiG2P(british: false)            // <-- ADJUST to real initializer
for s in samples {
    let phonemes = g2p.phonemize(s)            // <-- ADJUST to real method (-> String)
    FileHandle.standardError.write("\(s)\t\(phonemes)\n".data(using: .utf8)!)
}
```

- [ ] **Step 4: Build + run; learn the real API** 

Run: `swift run G2PParity --selftest`
Expected: prints each sentence with phonemes. If it fails to compile on the two marked lines, run `swift package describe` / read the MisakiSwift source under `.build/checkouts/MisakiSwift/` to find the correct type name and phonemize entry point, fix the two lines, rebuild.

- [ ] **Step 5: Record the finding** — paste the four output lines into `app/Tools/G2PParity/out/gateA.txt`. Confirm the alphabet visually matches Python misaki (e.g. capital `I`/`A`, stress marks `ˈˌ`). Compare against `./py -c "from misaki import en; g=en.G2P(trf=False,british=False); print(g('I read it yesterday.')[0])"`.

- [ ] **Step 6: Commit** — Swift sources are gitignored; nothing to commit. Note the result in the next commit's body instead.

---

### Task 3: Feasibility Gate B — phoneme injection into Kokoro

The A/B test needs to synthesize a *given phoneme string* (bypassing misaki). Verify we can do this in the 0.4.1 venv.

**Files:**
- Create: `app/Tools/G2PParity/kokoro_phonemes.py`
- Create: `app/Tools/G2PParity/inject_selftest.py`

**Interfaces:**
- Produces: `synth_from_phonemes(phonemes: str, out_wav: str, voice="af_heart") -> int` (returns sample count), used by Task 8.

- [ ] **Step 1: Write `kokoro_phonemes.py`** — the injection helper:

```python
import os
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
import numpy as np, soundfile as sf
from mlx_audio.server import model_provider

_MODEL = "prince-canuma/Kokoro-82M"

def synth_from_phonemes(phonemes: str, out_wav: str, voice: str = "af_heart") -> int:
    """Synthesize a raw misaki phoneme string through Kokoro, bypassing its g2p.
    Strategy: monkeypatch the KokoroPipeline so its grapheme->phoneme step returns
    OUR phonemes verbatim. The exact hook point is confirmed in Step 2."""
    model = model_provider.load_model(_MODEL)
    # The pipeline is created lazily per lang_code inside model.generate. We patch the
    # pipeline class's g2p call to return our phoneme string. Verified in Step 2.
    import mlx_audio.tts.models.kokoro.pipeline as kp  # adjust if module path differs
    # See Step 2 for the actual attribute to patch.
    raise NotImplementedError("filled in Step 2 once the hook point is confirmed")
```

- [ ] **Step 2: Discover the real hook point** — inspect how the pipeline turns text into phonemes:

Run: `cd app/Tools/G2PParity && ./py -c "import mlx_audio.tts.models.kokoro.pipeline as p; import inspect; print(inspect.getsourcefile(p))"`
Then read that file (and `kokoro.py`) to find where it calls misaki (e.g. a `self.g2p(text)` returning `(phonemes, tokens)` or similar). Identify the smallest patch that makes synthesis use a supplied phoneme string. Document the exact symbol in a comment.

- [ ] **Step 3: Implement the patch in `synth_from_phonemes`** based on Step 2's finding. Typical shape (adjust to reality):

```python
    # Example pattern — replace with the confirmed hook from Step 2:
    pipeline = model.pipelines["a"] if hasattr(model, "pipelines") else None
    # Patch g2p to yield our phonemes, then run one generate() and collect audio.
    audio_parts, sr = [], 24000
    # ... confirmed injection + generate loop ...
    audio = np.concatenate(audio_parts)
    sf.write(out_wav, audio, sr)
    return len(audio)
```

- [ ] **Step 4: Self-test `inject_selftest.py`:**

```python
from kokoro_phonemes import synth_from_phonemes
# Phonemes for "Hello there." taken from gate B notes / misaki.
n = synth_from_phonemes("həlˈO ðˈɛɹ", "out/inject_hello.wav")
print("samples:", n)
```

Run: `cd app/Tools/G2PParity && ./py inject_selftest.py && afplay out/inject_hello.wav`
Expected: prints a positive sample count; the clip says "hello there". If injection proves infeasible, STOP and report — the phoneme diff (Tasks 4-7) still stands; the audio A/B is what's blocked.

- [ ] **Step 5: Commit** — gitignored; record the finding in the README.

---

### Task 4: Corpus

**Files:**
- Create: `app/Tools/G2PParity/corpus/stress.txt` (~100 lines)
- Create: `app/Tools/G2PParity/corpus/real.txt` (~50 lines)

Format per line: `bucket<TAB>text`. Buckets: `heteronym`, `number`, `acronym`, `oov`, `real`.

- [ ] **Step 1: Write `stress.txt`** — ~100 lines across `heteronym`/`number`/`acronym`/`oov`. Examples (write the full set):
```
heteronym	I read it yesterday.
heteronym	I will read it tomorrow.
heteronym	The bass guitar sat by the bass pond.
number	It costs $5.99 plus tax.
number	Pi is about 3.14159.
number	Call 555-1234 before 2026.
acronym	NASA published the API docs.
acronym	See Dr. Smith, e.g. on Monday.
oov	Kubernetes orchestrates the containers.
oov	Siobhan visited Worcestershire.
```

- [ ] **Step 2: Write `real.txt`** — ~50 `real`-bucket lines sampled from actual `[VOICE:]`-style summaries, e.g.:
```
real	I fixed the bug in the login page.
real	The server is on the fixed version and the hook is loaded.
real	I pinned the library to the older version to dodge the crash.
```

- [ ] **Step 3: Verify counts** — `wc -l corpus/*.txt` shows ~100 / ~50.

- [ ] **Step 4: Commit** — gitignored.

---

### Task 5: Python misaki harness

**Files:**
- Create: `app/Tools/G2PParity/misaki_phonemes.py`

**Interfaces:**
- Produces: JSONL lines `{"text": str, "phonemes": str, "bucket": str}` on stdout.

- [ ] **Step 1: Implement**

```python
import sys, json
from misaki import en
g2p = en.G2P(trf=False, british=False)
for path in sys.argv[1:]:
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or "\t" not in line:
                continue
            bucket, text = line.split("\t", 1)
            phonemes, _ = g2p(text)
            print(json.dumps({"text": text, "phonemes": phonemes, "bucket": bucket}, ensure_ascii=False))
```

- [ ] **Step 2: Run** `./py misaki_phonemes.py corpus/stress.txt corpus/real.txt > out/misaki.jsonl`
Expected: one JSON object per corpus line. `wc -l out/misaki.jsonl` ≈ 150.

- [ ] **Step 3: Commit** — gitignored.

---

### Task 6: Swift harness over the corpus

**Files:**
- Modify: `app/Tools/G2PParity/Swift/Sources/G2PParity/main.swift`

**Interfaces:**
- Consumes: the `MisakiSwift` API confirmed in Task 2.
- Produces: JSONL `{"text","phonemes","bucket"}` on stdout (same schema as Task 5).

- [ ] **Step 1: Extend main.swift** to read corpus paths (when arg isn't `--selftest`), split on tab, phonemize, print JSONL:

```swift
import Foundation
import MisakiSwift

let g2p = MisakiG2P(british: false)            // <-- same symbols as Task 2
func emit(_ text: String, _ bucket: String) {
    let ph = g2p.phonemize(text)               // <-- same as Task 2
    let obj: [String: String] = ["text": text, "phonemes": ph, "bucket": bucket]
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
}
let args = Array(CommandLine.arguments.dropFirst())
for path in args {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    for line in content.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { continue }
        emit(String(parts[1]), String(parts[0]))
    }
}
```

- [ ] **Step 2: Run** `swift run G2PParity ../corpus/stress.txt ../corpus/real.txt > ../out/swift.jsonl`
Expected: ~150 JSONL lines, same schema as misaki.jsonl.

- [ ] **Step 3: Commit** — gitignored.

---

### Task 7: Diff + report

**Files:**
- Create: `app/Tools/G2PParity/diff.py`
- Create: `app/Tools/G2PParity/test_diff.py`

**Interfaces:**
- Consumes: two JSONL files (misaki, swift).
- Produces: `out/report.md`, `out/divergences.jsonl` (lines `{"text","bucket","misaki","swift"}`).

- [ ] **Step 1: Write the failing test** `test_diff.py`:

```python
from diff import normalize, compare_rows

def test_normalize_strips_stress_and_space():
    assert normalize("ɹˈɛd  ɪt") == normalize("ɹɛd ɪt")

def test_compare_counts_exact_and_normalized():
    misaki = [{"text": "a", "bucket": "real", "phonemes": "ˈfu"},
              {"text": "b", "bucket": "real", "phonemes": "bar"}]
    swift  = [{"text": "a", "bucket": "real", "phonemes": "fu"},   # normalized-equal
              {"text": "b", "bucket": "real", "phonemes": "baz"}]  # divergent
    stats, divergences = compare_rows(misaki, swift)
    assert stats["real"]["exact"] == 0      # "fu" != "ˈfu", "bar" != "baz"
    assert stats["real"]["normalized"] == 1 # only "a" matches after normalize
    assert len(divergences) == 1 and divergences[0]["text"] == "b"
```

- [ ] **Step 2: Run to verify it fails** — `./py -m pytest test_diff.py -v` → FAIL (no module `diff` attrs).

- [ ] **Step 3: Implement `diff.py`:**

```python
import sys, json, re
from collections import defaultdict

_STRESS = "ˈˌ"
def normalize(p: str) -> str:
    p = "".join(c for c in p if c not in _STRESS)
    return re.sub(r"\s+", " ", p).strip()

def _load(path):
    rows = {}
    with open(path) as f:
        for line in f:
            if line.strip():
                o = json.loads(line)
                rows[o["text"]] = o
    return rows

def compare_rows(misaki_rows, swift_rows):
    if isinstance(misaki_rows, dict): misaki_rows = list(misaki_rows.values())
    swift_by_text = {r["text"]: r for r in (swift_rows.values() if isinstance(swift_rows, dict) else swift_rows)}
    stats = defaultdict(lambda: {"exact": 0, "normalized": 0, "total": 0})
    divergences = []
    for m in misaki_rows:
        s = swift_by_text.get(m["text"])
        if s is None: continue
        b = m["bucket"]; stats[b]["total"] += 1
        if m["phonemes"] == s["phonemes"]: stats[b]["exact"] += 1
        if normalize(m["phonemes"]) == normalize(s["phonemes"]):
            stats[b]["normalized"] += 1
        else:
            divergences.append({"text": m["text"], "bucket": b,
                                "misaki": m["phonemes"], "swift": s["phonemes"]})
    return dict(stats), divergences

def _report(stats, divergences):
    lines = ["# g2p Parity Report", ""]
    lines.append("| bucket | total | exact | exact% | normalized% |")
    lines.append("|---|---|---|---|---|")
    for b, s in sorted(stats.items()):
        t = s["total"] or 1
        lines.append(f"| {b} | {s['total']} | {s['exact']} | {100*s['exact']//t}% | {100*s['normalized']//t}% |")
    lines += ["", f"## Divergences ({len(divergences)})", ""]
    for d in divergences:
        lines.append(f"- [{d['bucket']}] `{d['text']}`\n  - misaki: `{d['misaki']}`\n  - swift:  `{d['swift']}`")
    return "\n".join(lines) + "\n"

if __name__ == "__main__":
    m, s = _load(sys.argv[1]), _load(sys.argv[2])
    stats, divergences = compare_rows(m, s)
    open("out/report.md", "w").write(_report(stats, divergences))
    with open("out/divergences.jsonl", "w") as f:
        for d in divergences: f.write(json.dumps(d, ensure_ascii=False) + "\n")
    print(open("out/report.md").read())
```

- [ ] **Step 4: Run tests** — `./py -m pytest test_diff.py -v` → PASS.

- [ ] **Step 5: Run for real** — `./py diff.py out/misaki.jsonl out/swift.jsonl` → prints report; writes `out/report.md` + `out/divergences.jsonl`.

- [ ] **Step 6: Commit** — gitignored.

---

### Task 8: Audio A/B for divergences

**Files:**
- Create: `app/Tools/G2PParity/ab_audio.py`

**Interfaces:**
- Consumes: `out/divergences.jsonl`, `synth_from_phonemes` (Task 3).
- Produces: `out/ab/<i>_A.wav`, `out/ab/<i>_B.wav`, and `out/ab/key.json` (which of A/B is misaki vs swift — blind).

- [ ] **Step 1: Implement** (deterministic blind assignment from the row index — no RNG):

```python
import os, json
from kokoro_phonemes import synth_from_phonemes
os.makedirs("out/ab", exist_ok=True)
key = {}
with open("out/divergences.jsonl") as f:
    rows = [json.loads(l) for l in f if l.strip()]
for i, d in enumerate(rows):
    swap = (i % 2 == 1)  # alternate which side is A, recorded in key
    a_label, b_label = ("swift", "misaki") if swap else ("misaki", "swift")
    synth_from_phonemes(d[a_label], f"out/ab/{i}_A.wav")
    synth_from_phonemes(d[b_label], f"out/ab/{i}_B.wav")
    key[str(i)] = {"text": d["text"], "bucket": d["bucket"], "A": a_label, "B": b_label}
json.dump(key, open("out/ab/key.json", "w"), ensure_ascii=False, indent=2)
print(f"wrote {len(rows)} A/B pairs to out/ab/")
```

- [ ] **Step 2: Run** — `./py ab_audio.py` → writes pairs + key. Spot-check: `afplay out/ab/0_A.wav; afplay out/ab/0_B.wav`.

- [ ] **Step 3: Commit** — gitignored.

---

### Task 9: Run end-to-end, assemble the verdict

- [ ] **Step 1: Full run** in order:
```bash
cd app/Tools/G2PParity
swift run --package-path Swift G2PParity --selftest        # gate A evidence
./py inject_selftest.py                                     # gate B evidence
./py misaki_phonemes.py corpus/*.txt > out/misaki.jsonl
swift run --package-path Swift G2PParity corpus/*.txt > out/swift.jsonl
./py diff.py out/misaki.jsonl out/swift.jsonl
./py ab_audio.py out/divergences.jsonl
```

- [ ] **Step 2: Read `out/report.md`** — note real-set exact% and the divergence list.

- [ ] **Step 3: Blind-listen** the A/B pairs for the *frequent* (non-OOV) divergences; record A-or-B picks, then reveal with `key.json`.

- [ ] **Step 4: Apply the gate** — PASS if real-set exact ≈≥90% AND native ≥ Python on the frequent divergences. Write the go/no-go conclusion at the top of `out/report.md`.

- [ ] **Step 5: Report the verdict** to the user with the report + a few representative clips.

## Self-Review

- **Spec coverage:** feasibility gates (Tasks 2-3), corpus split (Task 4), exact+normalized metrics (Task 7), pragmatic gate (Task 9), throwaway/gitignored (Task 1) — all present.
- **Placeholder note:** the two `<-- ADJUST` lines in Tasks 2/6 and the Step 2/3 hook in Task 3 are *intentional* spike-discovery points (the real `MisakiSwift` API and Kokoro g2p hook are unknown until run); each has an explicit discovery step rather than a silent TODO.
- **Type consistency:** `synth_from_phonemes` signature matches between Tasks 3 and 8; JSONL schema `{text,phonemes,bucket}` matches between Tasks 5, 6, 7.
