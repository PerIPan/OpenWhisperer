#!/usr/bin/env python3
"""OpenWhisperer streaming TTS player.

Reads a JSON SpeechRequest from stdin, POSTs it to the server's /v1/audio/stream
endpoint, and plays the streamed float32 PCM through the default output device via
sounddevice — starting playback as the first bytes arrive (low latency).

If streaming fails (server missing the endpoint, 5xx, etc.), it falls back to the
non-streaming /v1/audio/speech (WAV) endpoint so the user still hears the response.

Playback runs on a worker thread so the MAIN thread stays free to handle SIGTERM
instantly: the signal handler just removes the lock/PID files and os._exit()s, which
discards PortAudio's in-process buffer and stops audio immediately (fast barge-in)
without depending on where the audio thread is blocked.

Owns the lock file (so the app shows "Speaking…") — created only AFTER a server
response, so a down/stalled server never shows a stuck "Speaking…" state. Owns the
PID file (written early so a barge-in during connect can target it).

Set OW_TTS_PLAYER_SILENT=1 to consume the stream without opening an audio device
(used by tests).
"""
import argparse
import json
import os
import signal
import sys
import threading
import time
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

    def _exit(code):
        _safe_remove(args.lockfile)
        _safe_remove(args.pidfile)
        os._exit(code)

    def _on_signal(*_):
        # Minimal + instant. Process exit discards PortAudio's in-process buffer, so
        # audio stops immediately — no need to abort the stream from here.
        _exit(0)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    # PID written early so a barge-in during connect can target us. The LOCK is created
    # only after a server response (see _create_lock), so a down/stalled server never
    # leaves a stuck "Speaking…" indicator.
    try:
        with open(args.pidfile, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass

    gain = max(0.0, min(args.volume, 4.0))

    def _post(url, body):
        req = urllib.request.Request(
            url, data=body.encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="POST",
        )
        return urllib.request.urlopen(req, timeout=30)

    def _create_lock():
        try:
            open(args.lockfile, "w").close()
        except OSError:
            pass

    def _play_in_thread(target):
        # Run blocking playback on a worker thread; keep the main thread free (and
        # signal-responsive) so SIGTERM stops playback within ~one poll interval.
        t = threading.Thread(target=target, daemon=True)
        t.start()
        while t.is_alive():
            time.sleep(0.05)
        _exit(0)   # only reached if the worker returns without exiting

    # ----- Primary path: streaming -----
    try:
        resp = _post(args.url, payload)
    except Exception as exc:
        sys.stderr.write("tts_stream_player: stream connect failed: %s\n" % exc)
        resp = None

    if resp is not None:
        _create_lock()
        sample_rate = int(resp.headers.get("X-Sample-Rate", "24000"))
        frame_bytes = 2048 * 4  # 2048 samples per read block
        if _SILENT:
            for _ in iter_frames(resp.read, gain, frame_bytes):
                pass
            _exit(0)

        def _play_stream():
            try:
                import sounddevice as sd
            except Exception as exc:
                sys.stderr.write("tts_stream_player: sounddevice import failed: %s\n" % exc)
                _exit(3)
            try:
                stream = sd.OutputStream(samplerate=sample_rate, channels=1, dtype="float32")
                stream.start()
                for samples in iter_frames(resp.read, gain, frame_bytes):
                    stream.write(samples)
                stream.stop()
                stream.close()
            except Exception as exc:
                sys.stderr.write("tts_stream_player: playback failed: %s\n" % exc)
                _exit(4)
            _exit(0)

        _play_in_thread(_play_stream)

    # ----- Fallback: non-streaming /v1/audio/speech (WAV), play whole -----
    speech_url = args.url.replace("/audio/stream", "/audio/speech")
    try:
        body = json.loads(payload)
    except Exception:
        body = {}
    body["response_format"] = "wav"
    try:
        wav = _post(speech_url, json.dumps(body)).read()
    except Exception as exc:
        sys.stderr.write("tts_stream_player: fallback connect failed: %s\n" % exc)
        _exit(2)

    _create_lock()
    if _SILENT:
        _exit(0)

    def _play_wav():
        try:
            import io
            import soundfile as sf
            import sounddevice as sd
            data, sr = sf.read(io.BytesIO(wav), dtype="float32", always_2d=False)
            if gain != 1.0:
                data = np.clip(data * gain, -1.0, 1.0)
            channels = 1 if data.ndim == 1 else data.shape[1]
            stream = sd.OutputStream(samplerate=int(sr), channels=channels, dtype="float32")
            stream.start()
            stream.write(data)
            stream.stop()
            stream.close()
        except Exception as exc:
            sys.stderr.write("tts_stream_player: fallback playback failed: %s\n" % exc)
            _exit(4)
        _exit(0)

    _play_in_thread(_play_wav)


if __name__ == "__main__":
    main()
