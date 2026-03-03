#!/usr/bin/env python3
"""Voice input bridge: records mic -> Whisper STT -> types into active app.

Usage:
  python voice-input.py              # Speak, text is typed (no Enter)
  python voice-input.py --submit     # Auto-press Enter after typing
  python voice-input.py --loop       # Keep listening continuously

Requires: sounddevice, numpy, requests
Activate the mlx venv before running.
"""

import argparse
import io
import os
import subprocess
import sys
import tempfile
import time

import numpy as np
import sounddevice as sd
import soundfile as sf

STT_URL = os.getenv("STT_URL", "http://localhost:8000/v1/audio/transcriptions")
TTS_LOCKFILE = "/tmp/tts_playing.lock"
SAMPLE_RATE = 16000
SILENCE_THRESHOLD = 0.04
SILENCE_DURATION = 2.0  # seconds of silence before processing


def calibrate_noise(duration=1.0):
    """Record ambient noise and return energy level."""
    chunk_size = int(SAMPLE_RATE * 0.1)
    chunks = int(duration / 0.1)
    stream = sd.InputStream(
        samplerate=SAMPLE_RATE, channels=1, dtype="float32", blocksize=chunk_size,
    )
    stream.start()
    energies = []
    for _ in range(chunks):
        data, _ = stream.read(chunk_size)
        energies.append(np.sqrt(np.mean(data**2)))
    stream.stop()
    stream.close()
    return np.mean(energies)


def record_until_silence(silence_duration=SILENCE_DURATION, max_duration=30):
    """Record audio until silence is detected."""
    print("Listening...", flush=True)

    chunks = []
    silent_chunks = 0
    chunk_duration = 0.1  # 100ms chunks
    chunk_size = int(SAMPLE_RATE * chunk_duration)
    max_chunks = int(max_duration / chunk_duration)
    silence_chunks_needed = int(silence_duration / chunk_duration)
    has_speech = False

    stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        blocksize=chunk_size,
    )
    stream.start()

    try:
        for i in range(max_chunks):
            # Abort recording if TTS starts playing
            if os.path.exists(TTS_LOCKFILE):
                print("(paused for TTS playback)", flush=True)
                break

            data, _ = stream.read(chunk_size)
            energy = np.sqrt(np.mean(data**2))

            if energy > SILENCE_THRESHOLD:
                has_speech = True
                silent_chunks = 0
                chunks.append(data.copy())
            elif has_speech:
                # Only keep silence chunks after speech started
                silent_chunks += 1
                chunks.append(data.copy())
            # else: discard pre-speech silence

            if has_speech and silent_chunks >= silence_chunks_needed:
                break
    finally:
        stream.stop()
        stream.close()

    if not has_speech:
        return None

    audio = np.concatenate(chunks).flatten()
    # Trim trailing silence
    trim_samples = int(silence_duration * SAMPLE_RATE)
    if len(audio) > trim_samples:
        audio = audio[:-trim_samples]

    print(f"Recorded {len(audio)/SAMPLE_RATE:.1f}s of audio", flush=True)
    return audio


def record_while_key_held():
    """Record while any key is held (press Enter to start, Enter to stop)."""
    input("Press Enter to start recording...")
    print("Recording... Press Enter to stop.", flush=True)

    chunks = []
    chunk_size = int(SAMPLE_RATE * 0.1)

    stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        blocksize=chunk_size,
    )
    stream.start()

    import threading

    stop_flag = threading.Event()

    def wait_for_enter():
        input()
        stop_flag.set()

    t = threading.Thread(target=wait_for_enter, daemon=True)
    t.start()

    try:
        while not stop_flag.is_set():
            data, _ = stream.read(chunk_size)
            chunks.append(data.copy())
    finally:
        stream.stop()
        stream.close()

    if not chunks:
        return None

    audio = np.concatenate(chunks).flatten()
    print(f"Recorded {len(audio)/SAMPLE_RATE:.1f}s of audio", flush=True)
    return audio


def transcribe(audio):
    """Send audio to Whisper STT server."""
    import requests

    # Write to temp wav file
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        sf.write(f.name, audio, SAMPLE_RATE)
        tmp_path = f.name

    try:
        with open(tmp_path, "rb") as f:
            resp = requests.post(
                STT_URL,
                files={"file": ("audio.wav", f, "audio/wav")},
                data={"model": "whisper-1", "language": "en"},
                timeout=30,
            )
        resp.raise_for_status()
        result = resp.json()
        return result.get("text", "").strip()
    finally:
        os.unlink(tmp_path)


ALLOWED_APPS = {"Terminal", "iTerm2", "Code", "Code - Insiders", "Electron", "Warp"}


def get_frontmost_app():
    """Get the name of the currently focused application."""
    result = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get name of first application process whose frontmost is true'],
        capture_output=True, text=True,
    )
    return result.stdout.strip()


def check_submit_trigger(text):
    """Check if text ends with a submit trigger phrase. Returns (cleaned_text, should_submit)."""
    import re
    lower = text.lower().rstrip(" .,!?")
    triggers = ["submit", "send it", "go ahead"]
    for trigger in triggers:
        if lower.endswith(trigger):
            # Strip the trigger word and trailing whitespace/punctuation
            pattern = r'\s*\b' + re.escape(trigger) + r'[.!?,]?$'
            cleaned = re.sub(pattern, '', text.strip(), flags=re.IGNORECASE)
            if cleaned:  # don't submit empty text
                return cleaned, True
    return text, False


def type_text(text, submit=True):
    """Type text into the active application using AppleScript."""
    # Verify we're typing into an allowed app
    app = get_frontmost_app()
    if app not in ALLOWED_APPS:
        print(f"Warning: '{app}' is focused, not Claude Code. Skipping input.", flush=True)
        return

    # Escape for AppleScript
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("'", "\\'")

    script = f'tell application "System Events" to keystroke "{escaped}"'
    try:
        subprocess.run(["osascript", "-e", script], check=True)
    except subprocess.CalledProcessError:
        print("Error: osascript denied. Grant Accessibility access to Terminal/VS Code in System Settings → Privacy & Security → Accessibility", flush=True)
        return

    if submit:
        time.sleep(0.1)
        try:
            subprocess.run(
                [
                    "osascript",
                    "-e",
                    'tell application "System Events" to key code 36',  # Enter key
                ],
                check=True,
            )
        except subprocess.CalledProcessError:
            print("Error: could not press Enter", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Voice input via local Whisper")
    parser.add_argument(
        "--auto",
        action="store_true",
        default=True,
        help="Auto-detect silence (default)",
    )
    parser.add_argument(
        "--hold", action="store_true", help="Hold-to-talk mode (Enter to start/stop)"
    )
    parser.add_argument(
        "--submit", action="store_true", help="Press Enter after typing (default: just type, no Enter)"
    )
    parser.add_argument(
        "--loop", action="store_true", help="Keep listening in a loop"
    )
    parser.add_argument(
        "--silence",
        type=float,
        default=SILENCE_DURATION,
        help=f"Silence duration to stop recording (default: {SILENCE_DURATION}s)",
    )
    args = parser.parse_args()

    print("Voice Input (Whisper STT)")
    print(f"Server: {STT_URL}")
    print(f"Mode: {'hold-to-talk' if args.hold else 'auto-silence'}")

    # Calibrate to room noise
    global SILENCE_THRESHOLD
    print("Calibrating ambient noise...", end=" ", flush=True)
    noise_level = calibrate_noise(duration=1.0)
    SILENCE_THRESHOLD = max(SILENCE_THRESHOLD, noise_level * 2.5)
    print(f"noise={noise_level:.4f}, threshold={SILENCE_THRESHOLD:.4f}")
    print("---")

    while True:
        try:
            # Wait while TTS is playing to avoid feedback loop
            if os.path.exists(TTS_LOCKFILE):
                # Wait for TTS to finish
                while os.path.exists(TTS_LOCKFILE):
                    time.sleep(0.2)
                # Cooldown: let room echo/reverb die before recording
                time.sleep(1.5)
                continue

            if args.hold:
                audio = record_while_key_held()
            else:
                audio = record_until_silence(silence_duration=args.silence)

            if audio is None or len(audio) < SAMPLE_RATE * 0.3:
                if not args.loop:
                    break
                continue

            # Discard if TTS started during recording (audio may contain TTS bleed)
            if os.path.exists(TTS_LOCKFILE):
                print("(discarding — TTS started during recording)", flush=True)
                continue

            print("Transcribing...", flush=True)
            text = transcribe(audio)

            if text:
                # Check for spoken submit trigger at the end
                text, triggered = check_submit_trigger(text)
                submit = args.submit or triggered
                print(f">>> {text}{'  [submit]' if submit else ''}")
                type_text(text, submit=submit)
                # Cooldown after typing to avoid echo/reverb re-recording
                time.sleep(1.0)
                # After submit, wait for ALL TTS activity to settle
                if submit:
                    print("(mic off — waiting for TTS)", flush=True)
                    time.sleep(2)  # wait for Claude to respond and hook to fire
                    # Keep waiting while TTS is active, with quiet period check
                    while True:
                        while os.path.exists(TTS_LOCKFILE):
                            time.sleep(0.2)
                        # Wait 2s to see if another TTS starts
                        time.sleep(2)
                        if not os.path.exists(TTS_LOCKFILE):
                            break  # no new TTS, safe to resume
                    print("(mic on)", flush=True)
            else:
                print("(no speech detected)")

            if not args.loop:
                break

        except KeyboardInterrupt:
            print("\nStopped.")
            break


if __name__ == "__main__":
    main()
