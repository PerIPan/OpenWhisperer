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
