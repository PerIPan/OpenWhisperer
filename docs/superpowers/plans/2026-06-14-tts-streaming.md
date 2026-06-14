# TTS Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream TTS audio sentence-by-sentence so playback starts after the first sentence is synthesized instead of the whole response, cutting time-to-first-audio ~60–80%.

**Architecture:** A server producer thread runs `model.generate()` one segment at a time, holding the MLX GPU lock only during each segment's synthesis, and enqueues raw float32 PCM onto a bounded queue (backpressure without holding the lock). A new `/v1/audio/stream` endpoint drains that queue to a chunked HTTP response. A shared Python `sounddevice` player streams the PCM to the audio device gaplessly, owns the lock/PID files, and stops fast on SIGTERM for barge-in. The legacy WAV endpoint + afplay path remain as a fallback.

**Tech Stack:** Python 3.11+ (FastAPI/Starlette, MLX, numpy, soundfile, sounddevice + bundled PortAudio, stdlib `urllib`/`queue`/`threading`), bash hooks, pytest.

**Spec:** `docs/superpowers/specs/2026-06-14-tts-streaming-design.md`

**Conventions used in every command below:**
- Venv Python: `VPY="$HOME/Library/Application Support/OpenWhisperer/venv/bin/python"`
- Run tests with the venv Python (it has numpy/sounddevice/mlx): `"$VPY" -m pytest tests/ -v`
- Repo root is the working directory.
- Commits: conventional messages, **no `Co-Authored-By` line** (project preference).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `servers/tts_stream.py` | **new** | Pure streaming helpers (no MLX import): `pcm_bytes()`, `produce()`, constants, `SENTINEL`. Unit-tested. |
| `servers/unified_server.py` | modify | Add `/v1/audio/stream` endpoint wiring; extend `kill_tts()` to target the player. |
| `scripts/tts_stream_player.py` | **new** | Client: POST stdin JSON → stream PCM → `sounddevice` playback; owns lock/PID; SIGTERM-fast. Pure `iter_frames()` unit-tested. |
| `hooks/tts-hook.sh` | modify | Capability gate + launch streaming player; keep afplay fallback; prior-kill update. |
| `hooks/codex-tts-hook.sh` | modify | Same as above. |
| `scripts/speak.sh` | modify | Use streaming player when available, else afplay. |
| `app/build-dmg.sh` | modify | Bundle `servers/tts_stream.py` and `scripts/tts_stream_player.py` into Resources. |
| `tests/conftest.py` | **new** | Put `servers/` and `scripts/` on `sys.path`. |
| `tests/test_tts_stream.py` | **new** | Unit tests for the producer/PCM helpers. |
| `tests/test_tts_player.py` | **new** | Unit + subprocess-lifecycle tests for the player. |

---

## Phase 0 — Test scaffolding

### Task 0: pytest + test directory

**Files:**
- Create: `tests/conftest.py`
- Create: `tests/__init__.py` (empty)

- [ ] **Step 1: Install pytest into the venv**

Run:
```bash
"$HOME/Library/Application Support/OpenWhisperer/uv" pip install --python "$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" pytest 2>/dev/null \
  || "$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -m pip install pytest
```
Expected: pytest installs (or already satisfied). Note: the bundled `uv` lives in the app Resources at runtime; for local dev either `uv` on PATH or the `pip` fallback works.

- [ ] **Step 2: Verify pytest runs under the venv Python**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -m pytest --version`
Expected: prints a `pytest 8.x` version line.

- [ ] **Step 3: Create the test path shim**

Create `tests/conftest.py`:
```python
import os
import sys

_HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, "..", "servers")))
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, "..", "scripts")))
```

Create empty `tests/__init__.py`:
```python
```

- [ ] **Step 4: Confirm pytest collects an empty suite cleanly**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -m pytest tests/ -q`
Expected: `no tests ran` (exit code 5) — confirms collection works with no errors.

- [ ] **Step 5: Commit**

```bash
git add tests/conftest.py tests/__init__.py
git commit -m "test: add pytest scaffolding for TTS streaming"
```

---

## Phase 1 — Server streaming core (`servers/tts_stream.py`)

### Task 1: PCM conversion + producer loop (TDD)

**Files:**
- Create: `servers/tts_stream.py`
- Test: `tests/test_tts_stream.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_tts_stream.py`:
```python
import queue
import threading
import time

import numpy as np

import tts_stream as ts


class _Res:
    def __init__(self, audio):
        self.audio = audio


def _gen(arrays):
    for a in arrays:
        yield _Res(a)


def test_pcm_bytes_roundtrip():
    a = np.array([0.0, 0.5, -0.5, 1.0], dtype=np.float32)
    b = ts.pcm_bytes(a)
    assert np.frombuffer(b, dtype="<f4").tolist() == [0.0, 0.5, -0.5, 1.0]


def test_pcm_bytes_flattens_and_casts_float64_2d():
    a = np.array([[0.1, 0.2, 0.3]], dtype=np.float64)
    out = np.frombuffer(ts.pcm_bytes(a), dtype="<f4")
    assert out.shape == (3,)
    assert np.allclose(out, [0.1, 0.2, 0.3], atol=1e-6)


def test_produce_orders_segments_then_sentinel():
    q = queue.Queue(maxsize=4)
    ev = threading.Event()
    lock = threading.Lock()
    ts.produce(_gen([np.array([0.1], np.float32), np.array([0.2], np.float32)]), q, ev, lock)
    items = []
    while True:
        x = q.get_nowait()
        if x is ts.SENTINEL:
            break
        items.append(round(float(np.frombuffer(x, dtype="<f4")[0]), 3))
    assert items == [0.1, 0.2]
    assert lock.acquire(timeout=1)   # lock released by producer
    lock.release()


def test_produce_stops_immediately_when_cancelled():
    q = queue.Queue(maxsize=1)
    ev = threading.Event()
    lock = threading.Lock()

    def inf():
        i = 0
        while True:
            yield _Res(np.array([float(i)], np.float32))
            i += 1

    ev.set()
    ts.produce(inf(), q, ev, lock)
    assert q.empty()                 # nothing produced, no sentinel
    assert lock.acquire(timeout=1)
    lock.release()


def test_produce_backpressure_does_not_hold_lock():
    q = queue.Queue(maxsize=1)
    ev = threading.Event()
    lock = threading.Lock()
    segs = [np.array([float(i)], np.float32) for i in range(3)]
    t = threading.Thread(target=ts.produce, args=(_gen(segs), q, ev, lock), daemon=True)
    t.start()
    time.sleep(0.3)                  # producer is now blocked on a full queue
    assert lock.acquire(timeout=1)   # ...but the GPU lock MUST be free
    lock.release()
    out = []
    while True:
        x = q.get(timeout=1)
        if x is ts.SENTINEL:
            break
        out.append(round(float(np.frombuffer(x, dtype="<f4")[0]), 1))
    t.join(timeout=2)
    assert out == [0.0, 1.0, 2.0]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -m pytest tests/test_tts_stream.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'tts_stream'`.

- [ ] **Step 3: Write `servers/tts_stream.py`**

Create `servers/tts_stream.py`:
```python
"""Streaming TTS helpers — deliberately free of MLX imports so they are fast to
unit-test. The producer runs model.generate() one segment at a time, holding the
GPU lock ONLY during each segment's synthesis (never during enqueue), so STT can
interleave between segments. A bounded queue gives backpressure without the lock.
"""
import logging
import queue

import numpy as np

logger = logging.getLogger("tts_stream")

TTS_SAMPLE_RATE = 24000   # Kokoro native output rate (mono)
TTS_QUEUE_MAX = 4         # bounded queue → backpressure without holding the GPU lock
SENTINEL = object()       # end-of-stream marker placed on the queue


def pcm_bytes(audio) -> bytes:
    """Convert one segment's audio (numpy array, any float dtype/shape) to
    contiguous little-endian float32 PCM bytes, mono."""
    arr = np.asarray(audio, dtype=np.float32).reshape(-1)
    return arr.astype("<f4", copy=False).tobytes()


def produce(gen, q, cancel_event, lock, *, gpu_timeout=30, put_timeout=0.2):
    """Drive `gen` (a model.generate() iterator) one segment at a time.

    For each segment: acquire `lock`, pull the next segment (synthesis happens on
    `next()`), release `lock`, then enqueue the segment's PCM bytes (blocking with
    a timeout so we stay responsive to `cancel_event` even when the queue is full).
    Terminates by putting SENTINEL — unless cancelled, in which case it returns
    without a sentinel (the drain side sets cancel_event on disconnect)."""
    try:
        while True:
            if cancel_event.is_set():
                return
            acquired = lock.acquire(timeout=gpu_timeout)
            if not acquired:
                logger.warning("TTS producer could not acquire GPU lock in %ss; proceeding unlocked", gpu_timeout)
            try:
                try:
                    result = next(gen)
                except StopIteration:
                    break
            finally:
                if acquired:
                    lock.release()
            if cancel_event.is_set():
                return
            data = pcm_bytes(result.audio)
            while True:
                try:
                    q.put(data, timeout=put_timeout)
                    break
                except queue.Full:
                    if cancel_event.is_set():
                        return
        q.put(SENTINEL)
    except Exception:
        logger.exception("TTS producer failed")
        try:
            q.put(SENTINEL, timeout=1)
        except queue.Full:
            pass
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -m pytest tests/test_tts_stream.py -v`
Expected: PASS (5 passed).

- [ ] **Step 5: Commit**

```bash
git add servers/tts_stream.py tests/test_tts_stream.py
git commit -m "feat: add streaming TTS producer + PCM helpers"
```

---

## Phase 2 — Server `/v1/audio/stream` endpoint

### Task 2: Wire the streaming endpoint

**Files:**
- Modify: `servers/unified_server.py`

- [ ] **Step 1: Add the `queue` import + tts_stream import**

In `servers/unified_server.py`, find the stdlib import block (currently `import asyncio` … `import time`). Add `import queue` after `import os`. Then, after the existing `from mlx_audio.server import ...` line, add:
```python
from tts_stream import TTS_SAMPLE_RATE, TTS_QUEUE_MAX, SENTINEL, produce
```

- [ ] **Step 2: Add the streaming endpoint**

In `servers/unified_server.py`, immediately after the existing `tts_speech` function (the `@app.post("/v1/audio/speech")` block, ends ~line 383), add:
```python
@app.post("/v1/audio/stream")
async def tts_stream(payload: SpeechRequest):
    """Streaming TTS: synthesize per-segment under the GPU lock and stream raw
    float32 PCM as each segment completes (low time-to-first-audio). The legacy
    /v1/audio/speech (WAV) endpoint is kept for compatibility / fallback."""
    loop = asyncio.get_running_loop()
    try:
        model = await loop.run_in_executor(
            _tts_executor, lambda p=payload: model_provider.load_model(p.model)
        )
    except Exception:
        logger.exception("TTS model load failed")
        return JSONResponse({"error": "TTS model load failed"}, status_code=500)

    q: queue.Queue = queue.Queue(maxsize=TTS_QUEUE_MAX)
    cancel_event = threading.Event()

    def _run():
        gen = model.generate(
            payload.input, voice=payload.voice, speed=payload.speed,
            gender=payload.gender, pitch=payload.pitch, lang_code=payload.lang_code,
            ref_audio=payload.ref_audio, ref_text=payload.ref_text,
            temperature=payload.temperature, top_p=payload.top_p, top_k=payload.top_k,
            repetition_penalty=payload.repetition_penalty,
        )
        produce(gen, q, cancel_event, _mlx_gpu_lock)

    _tts_executor.submit(_run)

    async def _drain():
        try:
            while True:
                item = await loop.run_in_executor(None, q.get)
                if item is SENTINEL:
                    break
                yield item
        finally:
            cancel_event.set()  # client disconnect or completion → stop the producer

    return StreamingResponse(
        _drain(),
        media_type="application/octet-stream",
        headers={
            "X-Sample-Rate": str(TTS_SAMPLE_RATE),
            "X-Channels": "1",
            "X-Sample-Format": "f32le",
            "Cache-Control": "no-store",
        },
    )
```

- [ ] **Step 3: Verify the module imports without error**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -c "import sys; sys.path.insert(0,'servers'); import unified_server; print('import OK')"`
Expected: prints `import OK` (after MLX/mlx_audio load). If it errors, fix the import/indentation before continuing.

- [ ] **Step 4: Manual smoke test — stream returns PCM bytes + headers**

Start the server in one terminal:
```bash
SERVER_PORT=8000 "$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" servers/unified_server.py
```
Wait for `TTS warm-up complete`. In another terminal:
```bash
curl -s -D - -o /tmp/ow_stream.pcm -X POST http://127.0.0.1:8000/v1/audio/stream \
  -H "Content-Type: application/json" \
  -d '{"model":"prince-canuma/Kokoro-82M","input":"This is one. This is two. This is three.","voice":"af_heart"}'
echo "bytes: $(stat -f%z /tmp/ow_stream.pcm)"
```
Expected: response headers include `x-sample-rate: 24000`, `x-sample-format: f32le`; `/tmp/ow_stream.pcm` is non-empty (tens-to-hundreds of KB). Sanity-play it:
```bash
"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" - <<'PY'
import numpy as np, sounddevice as sd
a = np.fromfile("/tmp/ow_stream.pcm", dtype="<f4")
sd.play(a, 24000); sd.wait()
print("played", a.shape)
PY
```
Expected: you hear the three sentences. Stop the server (Ctrl+C).

- [ ] **Step 5: Commit**

```bash
git add servers/unified_server.py
git commit -m "feat: add /v1/audio/stream streaming TTS endpoint"
```

---

## Phase 3 — Client streaming player (`scripts/tts_stream_player.py`)

### Task 3: Pure frame parser (TDD)

**Files:**
- Create: `scripts/tts_stream_player.py`
- Test: `tests/test_tts_player.py`

- [ ] **Step 1: Write the failing pure-function tests**

Create `tests/test_tts_player.py`:
```python
import numpy as np

import tts_stream_player as player


def _reader(data):
    pos = {"i": 0}

    def read_fn(n):
        chunk = data[pos["i"]:pos["i"] + n]
        pos["i"] += len(chunk)
        return chunk

    return read_fn


def test_iter_frames_basic_passthrough():
    data = np.array([0.0, 0.25, -0.25, 0.5], dtype="<f4").tobytes()
    out = np.concatenate(list(player.iter_frames(_reader(data), 1.0, 8)))
    assert np.allclose(out, [0.0, 0.25, -0.25, 0.5])


def test_iter_frames_applies_and_clips_gain():
    data = np.array([0.5, -0.5, 1.0], dtype="<f4").tobytes()
    out = np.concatenate(list(player.iter_frames(_reader(data), 4.0, 4)))
    assert out.tolist() == [1.0, -1.0, 1.0]   # 4x gain, clipped to [-1, 1]


def test_iter_frames_drops_trailing_partial_sample():
    data = np.array([0.1, 0.2], dtype="<f4").tobytes() + b"\x00\x00"  # 2 stray bytes
    out = np.concatenate(list(player.iter_frames(_reader(data), 1.0, 64)))
    assert out.shape == (2,)
```

- [ ] **Step 2: Run to verify failure**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -m pytest tests/test_tts_player.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'tts_stream_player'`.

- [ ] **Step 3: Write `scripts/tts_stream_player.py`**

Create `scripts/tts_stream_player.py`:
```python
#!/usr/bin/env python3
"""OpenWhisperer streaming TTS player.

Reads a JSON SpeechRequest from stdin, POSTs it to the server's /v1/audio/stream
endpoint, and plays the streamed float32 PCM through the default output device via
sounddevice — starting playback as the first bytes arrive (low latency).

Owns the lock file (so the app shows "Speaking…") and the PID file (so barge-in can
SIGTERM us). On SIGTERM/SIGINT it aborts playback and exits fast. On any startup
failure it exits non-zero so the caller can fall back to the afplay path.

Set OW_TTS_PLAYER_SILENT=1 to consume the stream without opening an audio device
(used by tests).
"""
import argparse
import os
import signal
import sys
import urllib.request

import numpy as np

_SILENT = os.environ.get("OW_TTS_PLAYER_SILENT") == "1"


def _safe_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def iter_frames(read_fn, gain, frame_bytes):
    """Yield float32 numpy frames parsed from a byte source.

    read_fn(n) returns up to n bytes (b'' at EOF). `gain` is a volume multiplier;
    when gain != 1.0 the frame is clipped to [-1, 1]. `frame_bytes` is the read
    block size. Trailing bytes that don't complete a 4-byte float are dropped."""
    buf = b""
    while True:
        chunk = read_fn(frame_bytes)
        if not chunk:
            break
        buf += chunk
        n = len(buf) // 4
        if n:
            samples = np.frombuffer(buf[: n * 4], dtype="<f4").astype(np.float32)
            buf = buf[n * 4:]
            if gain != 1.0:
                samples = np.clip(samples * gain, -1.0, 1.0)
            yield samples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--volume", type=float, default=1.0)
    parser.add_argument("--lockfile", required=True)
    parser.add_argument("--pidfile", required=True)
    args = parser.parse_args()

    payload = sys.stdin.read()
    state = {"stream": None}

    def _cleanup_and_exit(code):
        st = state.get("stream")
        if st is not None:
            try:
                st.abort()
            except Exception:
                pass
            try:
                st.close()
            except Exception:
                pass
        _safe_remove(args.lockfile)
        _safe_remove(args.pidfile)
        os._exit(code)

    def _on_signal(*_):
        _cleanup_and_exit(0)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    try:
        with open(args.pidfile, "w") as f:
            f.write(str(os.getpid()))
        open(args.lockfile, "w").close()
    except OSError:
        pass

    gain = max(0.0, min(args.volume, 4.0))

    try:
        req = urllib.request.Request(
            args.url, data=payload.encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="POST",
        )
        resp = urllib.request.urlopen(req, timeout=30)
    except Exception as exc:
        sys.stderr.write("tts_stream_player: connect failed: %s\n" % exc)
        _cleanup_and_exit(2)

    sample_rate = int(resp.headers.get("X-Sample-Rate", "24000"))
    frame_bytes = 2048 * 4  # 2048 samples per read block

    if _SILENT:
        for _ in iter_frames(resp.read, gain, frame_bytes):
            pass
        _cleanup_and_exit(0)

    try:
        import sounddevice as sd
    except Exception as exc:
        sys.stderr.write("tts_stream_player: sounddevice import failed: %s\n" % exc)
        _cleanup_and_exit(3)

    try:
        stream = sd.OutputStream(samplerate=sample_rate, channels=1, dtype="float32")
        state["stream"] = stream
        stream.start()
        for samples in iter_frames(resp.read, gain, frame_bytes):
            stream.write(samples)
        stream.stop()
        stream.close()
    except Exception as exc:
        sys.stderr.write("tts_stream_player: playback failed: %s\n" % exc)
        _cleanup_and_exit(4)

    _cleanup_and_exit(0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the pure-function tests to verify they pass**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -m pytest tests/test_tts_player.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add scripts/tts_stream_player.py tests/test_tts_player.py
git commit -m "feat: add streaming TTS player with PCM frame parser"
```

### Task 4: Player lifecycle tests (subprocess, no audio)

**Files:**
- Modify: `tests/test_tts_player.py`

- [ ] **Step 1: Append the failing lifecycle tests**

Add to the end of `tests/test_tts_player.py`:
```python
import http.server
import os
import signal
import socket
import subprocess
import sys
import threading
import time

_HERE = os.path.dirname(__file__)
_PLAYER = os.path.join(_HERE, "..", "scripts", "tts_stream_player.py")


class _PCMHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("X-Sample-Rate", "24000")
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        block = np.zeros(2400, dtype="<f4").tobytes()  # 0.1s of silence
        for _ in range(20):  # ~2s, slow enough to SIGTERM mid-stream
            try:
                self.wfile.write(block)
                self.wfile.flush()
            except Exception:
                return
            time.sleep(0.1)

    def log_message(self, *a):
        pass


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _run_player(url, tmp_path):
    lock = tmp_path / "lock"
    pid = tmp_path / "pid"
    env = dict(os.environ, OW_TTS_PLAYER_SILENT="1")
    proc = subprocess.Popen(
        [sys.executable, _PLAYER, "--url", url, "--volume", "1.0",
         "--lockfile", str(lock), "--pidfile", str(pid)],
        stdin=subprocess.PIPE, env=env,
    )
    proc.stdin.write(b'{"model":"m","input":"hi","voice":"af_heart"}')
    proc.stdin.close()
    return proc, lock, pid


def test_player_sigterm_stops_fast_and_cleans_up(tmp_path):
    port = _free_port()
    srv = http.server.HTTPServer(("127.0.0.1", port), _PCMHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        proc, lock, pid = _run_player(f"http://127.0.0.1:{port}/v1/audio/stream", tmp_path)
        for _ in range(60):
            if lock.exists() and pid.exists():
                break
            time.sleep(0.05)
        assert lock.exists() and pid.exists()
        t0 = time.time()
        proc.send_signal(signal.SIGTERM)
        rc = proc.wait(timeout=3)
        assert time.time() - t0 < 1.0
        assert rc == 0
        assert not lock.exists() and not pid.exists()
    finally:
        srv.shutdown()


def test_player_connect_failure_exits_2_and_cleans_up(tmp_path):
    proc, lock, pid = _run_player("http://127.0.0.1:1/v1/audio/stream", tmp_path)
    rc = proc.wait(timeout=5)
    assert rc == 2
    assert not lock.exists() and not pid.exists()
```

- [ ] **Step 2: Run the full player suite**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -m pytest tests/test_tts_player.py -v`
Expected: PASS (5 passed total). The lifecycle tests run in SILENT mode (no audio device touched).

- [ ] **Step 3: Commit**

```bash
git add tests/test_tts_player.py
git commit -m "test: add streaming player lifecycle + fallback tests"
```

---

## Phase 4 — Barge-in / kill (server)

### Task 5: Extend `kill_tts()` to target the player

**Files:**
- Modify: `servers/unified_server.py` (the `kill_tts()` function, ~lines 168-202)

- [ ] **Step 1: Allow "python" in the PID-file comm check**

In `kill_tts()`, find:
```python
                    if comm and ("afplay" in comm or "tts" in comm or "bash" in comm):
```
Replace with:
```python
                    if comm and ("afplay" in comm or "tts" in comm or "bash" in comm or "python" in comm):
```

- [ ] **Step 2: Add a pkill pattern for the streaming player**

In `kill_tts()`, find the two existing `subprocess.run([... "pkill" ... "afplay.*tts_"])` calls and add, immediately after them (before the `for path in (TTS_PIDFILE, TTS_LOCKFILE):` cleanup loop):
```python
        subprocess.run(
            ["pkill", "-U", str(os.getuid()), "-f", "tts_stream_player"],
            capture_output=True, timeout=2,
        )
```

- [ ] **Step 3: Verify the module still imports**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -c "import sys; sys.path.insert(0,'servers'); import unified_server; print('import OK')"`
Expected: `import OK`.

- [ ] **Step 4: Commit**

```bash
git add servers/unified_server.py
git commit -m "feat: target streaming player in kill_tts (barge-in)"
```

---

## Phase 5 — Hook + speak.sh integration

### Task 6: `tts-hook.sh` — capability gate, streaming branch, fallback

**Files:**
- Modify: `hooks/tts-hook.sh`

- [ ] **Step 1: Update the prior-playback kill to also match the player**

In `hooks/tts-hook.sh`, find:
```bash
    if [[ "$OLD_COMM" == *"bash"* ]] || [[ "$OLD_COMM" == *"afplay"* ]]; then
      # Send SIGINT to afplay children first (cleaner stop than SIGTERM)
      pkill -INT -P "$OLD_PID" 2>/dev/null
      kill "$OLD_PID" 2>/dev/null
      pkill -P "$OLD_PID" 2>/dev/null
    fi
```
Replace with:
```bash
    if [[ "$OLD_COMM" == *"bash"* ]] || [[ "$OLD_COMM" == *"afplay"* ]] || [[ "$OLD_COMM" == *"python"* ]]; then
      # Send SIGINT to afplay children first (cleaner stop than SIGTERM)
      pkill -INT -P "$OLD_PID" 2>/dev/null
      kill "$OLD_PID" 2>/dev/null
      pkill -P "$OLD_PID" 2>/dev/null
    fi
    pkill -f tts_stream_player 2>/dev/null
```

- [ ] **Step 2: Replace the playback section with streaming + fallback**

In `hooks/tts-hook.sh`, find the entire block that starts at `# Run entire TTS pipeline in background (non-blocking)` and runs through the backgrounded subshell and `echo $! > "$PIDFILE"` (i.e. the `( ... ) &` group followed by `echo $! > "$PIDFILE"`). Replace that whole block with:
```bash
# --- Streaming player (preferred) with afplay fallback ---
VENV_PY="$APP_SUPPORT/venv/bin/python"
PLAYER="$(dirname "$SCRIPT_DIR")/scripts/tts_stream_player.py"
STREAM_URL="${TTS_URL%/audio/speech}/audio/stream"
CAP_OK="$APP_SUPPORT/.tts_stream_ok"
CAP_BAD="$APP_SUPPORT/.tts_stream_unavailable"

# One-time cached capability probe: can the venv python import the audio stack?
if [ ! -f "$CAP_OK" ] && [ ! -f "$CAP_BAD" ]; then
  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import sounddevice, numpy" >/dev/null 2>&1; then
    touch "$CAP_OK"
  else
    touch "$CAP_BAD"
  fi
fi

# Resolve voice + volume (shared by both paths)
VOICE_FILE="$APP_SUPPORT/tts_voice"
if [ -f "$VOICE_FILE" ] && [ ! -L "$VOICE_FILE" ]; then
  VOICE="$(cat "$VOICE_FILE" 2>/dev/null | tr -d '[:space:]')"; VOICE="${VOICE:-${TTS_VOICE:-af_heart}}"
else
  VOICE="${TTS_VOICE:-af_heart}"
fi
MODEL="${TTS_MODEL:-prince-canuma/Kokoro-82M}"
VOLUME_FILE="$APP_SUPPORT/tts_volume"
if [ -f "$VOLUME_FILE" ] && [ ! -L "$VOLUME_FILE" ]; then
  VOLUME="$(cat "$VOLUME_FILE" 2>/dev/null | tr -d '[:space:]')"; VOLUME="${VOLUME:-${TTS_VOLUME:-1}}"
else
  VOLUME="${TTS_VOLUME:-1}"
fi

if [ -f "$CAP_OK" ] && [ -f "$PLAYER" ] && [ -x "$VENV_PY" ]; then
  # Streaming path — the player owns the lock + PID files and plays gaplessly.
  PAYLOAD="$(jq -n --arg t "$SPEECH" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')"
  printf '%s' "$PAYLOAD" | "$VENV_PY" "$PLAYER" \
    --url "$STREAM_URL" --volume "$VOLUME" \
    --lockfile "$LOCKFILE" --pidfile "$PIDFILE" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
else
  # --- Fallback: original curl + afplay path ---
  (
    TMPFILE=$(mktemp "$TTS_TMPDIR/tts_XXXXXXXXXXXX") || { rm -f "$LOCKFILE"; exit 1; }
    TTS_OK=false
    CURL_RC=0
    for attempt in 1 2 3; do
      curl -s -X POST "$TTS_URL" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "$SPEECH" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')" \
        --output "$TMPFILE" --max-time 30 2>/dev/null
      CURL_RC=$?
      if [ "$CURL_RC" -eq 0 ] && [ -s "$TMPFILE" ] && [[ "$(dd if="$TMPFILE" bs=4 count=1 2>/dev/null)" == "RIFF" ]]; then
        TTS_OK=true
        break
      fi
      sleep 1
    done
    if [ "$TTS_OK" = "false" ]; then
      logger -t tts-hook "TTS request failed after 3 attempts (last curl rc=$CURL_RC, url=$TTS_URL)"
    fi
    if [ "$TTS_OK" = "true" ] && [ -s "$TMPFILE" ]; then
      afplay -v "$VOLUME" "$TMPFILE" 2>/dev/null
    fi
    rm -f "$LOCKFILE"
    rm -f "$TMPFILE" 2>/dev/null
    rm -f "$PIDFILE" 2>/dev/null
  ) &
  echo $! > "$PIDFILE"
fi
```

Note: `SCRIPT_DIR` is already computed earlier in the hook (for bundled jq). The fallback block reproduces the existing curl+afplay logic so behavior is unchanged when streaming is unavailable.

- [ ] **Step 3: Syntax-check the hook**

Run: `bash -n hooks/tts-hook.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add hooks/tts-hook.sh
git commit -m "feat: stream TTS via player in tts-hook with afplay fallback"
```

### Task 7: `codex-tts-hook.sh` — same integration

**Files:**
- Modify: `hooks/codex-tts-hook.sh`

- [ ] **Step 1: Update the prior-playback kill**

In `hooks/codex-tts-hook.sh`, find:
```bash
    if [[ "$OLD_COMM" == *"bash"* ]] || [[ "$OLD_COMM" == *"afplay"* ]]; then
      pkill -INT -P "$OLD_PID" 2>/dev/null
      sleep 0.15
      kill "$OLD_PID" 2>/dev/null
      pkill -P "$OLD_PID" 2>/dev/null
    fi
```
Replace with:
```bash
    if [[ "$OLD_COMM" == *"bash"* ]] || [[ "$OLD_COMM" == *"afplay"* ]] || [[ "$OLD_COMM" == *"python"* ]]; then
      pkill -INT -P "$OLD_PID" 2>/dev/null
      sleep 0.15
      kill "$OLD_PID" 2>/dev/null
      pkill -P "$OLD_PID" 2>/dev/null
    fi
    pkill -f tts_stream_player 2>/dev/null
```

- [ ] **Step 2: Replace the playback section with streaming + fallback**

In `hooks/codex-tts-hook.sh`, find the block starting at `# Run entire TTS pipeline in background (non-blocking)` through the `( ... ) &` subshell and the following `echo $! > "$PIDFILE"`. Replace that whole block with:
```bash
# --- Streaming player (preferred) with afplay fallback ---
VENV_PY="$APP_SUPPORT/venv/bin/python"
PLAYER="$(dirname "$SCRIPT_DIR")/scripts/tts_stream_player.py"
STREAM_URL="${TTS_URL%/audio/speech}/audio/stream"
CAP_OK="$APP_SUPPORT/.tts_stream_ok"
CAP_BAD="$APP_SUPPORT/.tts_stream_unavailable"

if [ ! -f "$CAP_OK" ] && [ ! -f "$CAP_BAD" ]; then
  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import sounddevice, numpy" >/dev/null 2>&1; then
    touch "$CAP_OK"
  else
    touch "$CAP_BAD"
  fi
fi

VOICE_FILE="$APP_SUPPORT/tts_voice"
if [ -f "$VOICE_FILE" ] && [ ! -L "$VOICE_FILE" ]; then
  VOICE="$(cat "$VOICE_FILE" 2>/dev/null | tr -d '[:space:]')"; VOICE="${VOICE:-${TTS_VOICE:-af_heart}}"
else
  VOICE="${TTS_VOICE:-af_heart}"
fi
MODEL="${TTS_MODEL:-prince-canuma/Kokoro-82M}"
VOLUME_FILE="$APP_SUPPORT/tts_volume"
if [ -f "$VOLUME_FILE" ] && [ ! -L "$VOLUME_FILE" ]; then
  VOLUME="$(cat "$VOLUME_FILE" 2>/dev/null | tr -d '[:space:]')"; VOLUME="${VOLUME:-${TTS_VOLUME:-1}}"
else
  VOLUME="${TTS_VOLUME:-1}"
fi

if [ -f "$CAP_OK" ] && [ -f "$PLAYER" ] && [ -x "$VENV_PY" ]; then
  PAYLOAD="$(jq -n --arg t "$SPEECH" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')"
  printf '%s' "$PAYLOAD" | "$VENV_PY" "$PLAYER" \
    --url "$STREAM_URL" --volume "$VOLUME" \
    --lockfile "$LOCKFILE" --pidfile "$PIDFILE" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
else
  (
    TMPFILE=$(mktemp "$TTS_TMPDIR/tts_XXXXXXXXXXXX") || { rm -f "$LOCKFILE"; exit 1; }
    TTS_OK=false
    CURL_RC=0
    for attempt in 1 2 3; do
      curl -s -X POST "$TTS_URL" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg t "$SPEECH" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')" \
        --output "$TMPFILE" --max-time 30 2>/dev/null
      CURL_RC=$?
      if [ "$CURL_RC" -eq 0 ] && [ -s "$TMPFILE" ] && head -c 4 "$TMPFILE" | grep -q "RIFF"; then
        TTS_OK=true
        break
      fi
      sleep 1
    done
    if [ "$TTS_OK" = "false" ]; then
      logger -t codex-tts-hook "TTS request failed after 3 attempts (last curl rc=$CURL_RC, url=$TTS_URL)"
    fi
    if [ "$TTS_OK" = "true" ] && [ -s "$TMPFILE" ]; then
      afplay -v "$VOLUME" "$TMPFILE" 2>/dev/null
    fi
    rm -f "$LOCKFILE"
    rm -f "$TMPFILE" 2>/dev/null
    rm -f "$PIDFILE" 2>/dev/null
  ) &
  echo $! > "$PIDFILE"
fi
```

- [ ] **Step 3: Syntax-check**

Run: `bash -n hooks/codex-tts-hook.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add hooks/codex-tts-hook.sh
git commit -m "feat: stream TTS via player in codex-tts-hook with afplay fallback"
```

### Task 8: `speak.sh` — use streaming player when available

**Files:**
- Modify: `scripts/speak.sh`

- [ ] **Step 1: Replace the curl+afplay tail with a streaming branch**

In `scripts/speak.sh`, replace lines 21-27 (the `curl ... --output "$TMPFILE"` block, the `afplay`, and the `rm -f "$TMPFILE"`) with:
```bash
APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
VENV_PY="$APP_SUPPORT/venv/bin/python"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAYER="$SCRIPT_DIR/tts_stream_player.py"
STREAM_URL="${TTS_URL%/audio/speech}/audio/stream"

if [ -x "$VENV_PY" ] && [ -f "$PLAYER" ] && "$VENV_PY" -c "import sounddevice, numpy" >/dev/null 2>&1; then
  # Streaming path (foreground — speak.sh is a synchronous CLI util)
  PAYLOAD="$(jq -n --arg t "$TEXT" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')"
  printf '%s' "$PAYLOAD" | "$VENV_PY" "$PLAYER" \
    --url "$STREAM_URL" --volume "${TTS_VOLUME:-1}" \
    --lockfile "$APP_SUPPORT/tts_playing.lock" --pidfile "$APP_SUPPORT/tts_hook.pid"
else
  # Fallback: curl + afplay
  curl -s -X POST "$TTS_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$TEXT" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')" \
    --output "$TMPFILE" 2>/dev/null
  afplay "$TMPFILE" 2>/dev/null
  rm -f "$TMPFILE"
fi
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n scripts/speak.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/speak.sh
git commit -m "feat: stream TTS via player in speak.sh with afplay fallback"
```

---

## Phase 6 — Bundling

### Task 9: Ship the new files in the app bundle

**Files:**
- Modify: `app/build-dmg.sh`

- [ ] **Step 1: Copy the new server + player into Resources**

In `app/build-dmg.sh`, find:
```bash
cp "$PROJECT_DIR/servers/unified_server.py" "$APP_BUNDLE/Contents/Resources/servers/"
cp "$PROJECT_DIR/scripts/speak.sh" "$APP_BUNDLE/Contents/Resources/scripts/"
```
Replace with:
```bash
cp "$PROJECT_DIR/servers/unified_server.py" "$APP_BUNDLE/Contents/Resources/servers/"
cp "$PROJECT_DIR/servers/tts_stream.py" "$APP_BUNDLE/Contents/Resources/servers/"
cp "$PROJECT_DIR/scripts/speak.sh" "$APP_BUNDLE/Contents/Resources/scripts/"
cp "$PROJECT_DIR/scripts/tts_stream_player.py" "$APP_BUNDLE/Contents/Resources/scripts/"
```

- [ ] **Step 2: Make the player executable + reset the capability marker on (re)install**

In `app/build-dmg.sh`, find the `chmod +x "$APP_BUNDLE/Contents/Resources/scripts/speak.sh"` line and add after it:
```bash
chmod +x "$APP_BUNDLE/Contents/Resources/scripts/tts_stream_player.py"
```

- [ ] **Step 3: Syntax-check the build script**

Run: `bash -n app/build-dmg.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Reset the cached capability markers (so a fresh install re-probes)**

In `app/Sources/OpenWhisperer/SetupManager.swift`, in `resetAndRerun(...)` (which removes `Paths.setupComplete`), also remove the markers. Find:
```swift
        try? FileManager.default.removeItem(at: Paths.setupComplete)
        runFirstLaunchSetup(completion: completion)
```
Replace with:
```swift
        try? FileManager.default.removeItem(at: Paths.setupComplete)
        // Re-probe TTS streaming capability after a reset/reinstall
        try? FileManager.default.removeItem(at: Paths.appSupport.appendingPathComponent(".tts_stream_ok"))
        try? FileManager.default.removeItem(at: Paths.appSupport.appendingPathComponent(".tts_stream_unavailable"))
        runFirstLaunchSetup(completion: completion)
```

- [ ] **Step 5: Build the Swift app to confirm it compiles**

Run: `cd app && swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add app/build-dmg.sh app/Sources/OpenWhisperer/SetupManager.swift
git commit -m "build: bundle streaming player + reset capability markers on reinstall"
```

---

## Phase 7 — Full verification

### Task 10: Run the suite + manual end-to-end checklist

- [ ] **Step 1: Run the full pytest suite**

Run: `"$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" -m pytest tests/ -v`
Expected: all tests pass (8: 5 streaming-core/player-pure + lifecycle, etc.).

- [ ] **Step 2: Start the server**

Run:
```bash
SERVER_PORT=8000 "$HOME/Library/Application Support/OpenWhisperer/venv/bin/python" servers/unified_server.py
```
Wait for `TTS warm-up complete`.

- [ ] **Step 3: Time-to-first-audio — streaming vs fallback**

In another terminal, force the capability marker on, then speak a multi-sentence line:
```bash
APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"; touch "$APP_SUPPORT/.tts_stream_ok"; rm -f "$APP_SUPPORT/.tts_stream_unavailable"
echo "First sentence here. Second sentence follows. And a third to finish." | scripts/speak.sh
```
Expected: speech begins after roughly the first sentence — audibly sooner than the old build, and gapless across sentences.

- [ ] **Step 4: Barge-in stop latency**

While a long line is playing (run the Step 3 command with more sentences), in a third terminal:
```bash
pkill -f tts_stream_player
```
Expected: playback stops within ~100 ms; `~/Library/Application Support/OpenWhisperer/tts_playing.lock` and `tts_hook.pid` are gone afterward.

- [ ] **Step 5: Volume honored**

```bash
echo "2" > "$HOME/Library/Application Support/OpenWhisperer/tts_volume"
echo "Testing louder playback now." | scripts/speak.sh
echo "1" > "$HOME/Library/Application Support/OpenWhisperer/tts_volume"
```
Expected: noticeably louder at volume 2 than at 1.

- [ ] **Step 6: Fallback path works**

Force streaming unavailable and confirm afplay still speaks:
```bash
APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"; rm -f "$APP_SUPPORT/.tts_stream_ok"; touch "$APP_SUPPORT/.tts_stream_unavailable"
echo '{"last_assistant_message":"[VOICE: Fallback path test.]","stop_hook_active":false}' | hooks/tts-hook.sh
# cleanup marker afterwards
rm -f "$APP_SUPPORT/.tts_stream_unavailable"
```
Expected: you hear "Fallback path test." via the afplay path (whole-file), no crash. Stop the server (Ctrl+C).

- [ ] **Step 7: Final commit (verification notes, optional)**

If you kept a scratch verification log, commit it; otherwise this task has no code changes. Confirm `git status` is clean of unintended changes.

---

## Self-Review (completed by plan author)

**1. Spec coverage**
- Goal: low TTFA via per-segment streaming → Tasks 1, 2 (producer + endpoint), 3 (player). ✓
- Gapless sounddevice player → Task 3. ✓
- Per-segment GPU-lock release + bounded-queue backpressure → Task 1 (`produce`), tested in `test_produce_backpressure_does_not_hold_lock`. ✓
- New `/v1/audio/stream` raw float32 PCM + headers; keep `/v1/audio/speech` → Task 2. ✓
- Barge-in / kill targets the player → Task 5 (server `kill_tts`) + Tasks 6/7 (hook prior-kill). ✓
- Volume as gain → Task 3 `iter_frames` (clip), passed via hooks/speak.sh. ✓
- Lock-file ownership by player → Task 3, verified Task 10 Step 4. ✓
- Fallback to afplay → Tasks 6/7/8 capability gate. ✓
- All three entry points → Tasks 6 (Claude), 7 (Codex), 8 (speak.sh). ✓
- Bundling → Task 9. ✓
- pytest setup → Task 0. ✓
- Testing strategy (unit + lifecycle + manual) → Tasks 1, 3, 4, 10. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code; every run step has an exact command + expected output. ✓

**3. Type/name consistency:** `pcm_bytes`, `produce`, `SENTINEL`, `TTS_SAMPLE_RATE`, `TTS_QUEUE_MAX` defined in Task 1 and used identically in Task 2; `iter_frames(read_fn, gain, frame_bytes)` defined in Task 3 and used with the same signature in tests; `--url/--volume/--lockfile/--pidfile` args consistent across player, hooks, speak.sh; capability markers `.tts_stream_ok`/`.tts_stream_unavailable` consistent across hooks and SetupManager. ✓

**Open dependency:** Phase 2/10 manual audio tests require the venv to have a working Kokoro model already downloaded (it is, post-setup) and an output device.
