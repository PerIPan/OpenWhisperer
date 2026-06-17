#!/bin/bash
# Enforce UTF-8 for safe string slicing (#15)
export LANG="${LANG:-en_US.UTF-8}"
# Claude Code Stop hook — speaks the last response via mlx_audio TTS
# Claude includes a [VOICE: ...] tag with a spoken summary
# Fully async: TTS generation + playback runs in background
# New responses interrupt previous playback

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
PIDFILE="$APP_SUPPORT/tts_hook.pid"
LOCKFILE="$APP_SUPPORT/tts_playing.lock"
TTS_TMPDIR="${TMPDIR:-/tmp}/claude-tts-$(id -u)"
mkdir -p "$TTS_TMPDIR"

# Find jq: system PATH first, then bundled in app
if ! command -v jq &>/dev/null; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then
    export PATH="$(dirname "$BUNDLED_JQ"):$PATH"
  else
    exit 0  # no jq available, skip TTS
  fi
fi

INPUT=$(cat)

# Prevent loops
if [ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active')" = "true" ]; then
  exit 0
fi

# --- Voice-turn gate (runs BEFORE we kill prior playback, so a typed/non-voice
#     turn never interrupts an in-progress voice reply) ---
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
PENDING_DIR="$APP_SUPPORT/speak_pending"
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_.-' '_')
PENDING="$PENDING_DIR/$SAFE_ID"
# Sweep markers orphaned by sessions that died between prompt and response.
find "$PENDING_DIR" -type f -mmin +5 -delete 2>/dev/null
# Only speak if THIS session was marked a voice turn by the UPS hook.
[ -f "$PENDING" ] || exit 0
rm -f "$PENDING"

# Serialize concurrent hook invocations with mkdir-based lock (atomic on all filesystems)
HOOK_LOCK="$APP_SUPPORT/tts_hook.lockdir"
if [ -d "$HOOK_LOCK" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$HOOK_LOCK" 2>/dev/null || echo 0) ))
  if [ "$LOCK_AGE" -gt 30 ]; then rm -rf "$HOOK_LOCK"; fi
fi
LOCK_ACQUIRED=false
for _try in 1 2 3; do
  if mkdir "$HOOK_LOCK" 2>/dev/null; then LOCK_ACQUIRED=true; break; fi
  sleep 0.1
done
trap 'rm -rf "$HOOK_LOCK"' EXIT
if [ "$LOCK_ACQUIRED" = "false" ]; then exit 0; fi

# Kill any previous TTS playback (validate PID before killing)
if [ -f "$PIDFILE" ] && [ ! -L "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
  if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    OLD_COMM=$(ps -p "$OLD_PID" -o comm= 2>/dev/null)
    if [[ "$OLD_COMM" == *"bash"* ]] || [[ "$OLD_COMM" == *"afplay"* ]] || [[ "$OLD_COMM" == *"python"* ]]; then
      pkill -INT -P "$OLD_PID" 2>/dev/null
      kill "$OLD_PID" 2>/dev/null
      pkill -P "$OLD_PID" 2>/dev/null
    fi
    pkill -f tts_stream_player 2>/dev/null
  fi
  find "$TTS_TMPDIR" -name "tts_*" -mmin +1 -delete 2>/dev/null
  rm -f "$PIDFILE"
fi

# Extract the FIRST PARAGRAPH of the response (markdown-stripped) as the spoken text.
TEXT=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty')
[ -z "$TEXT" ] && exit 0
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/first-paragraph.sh")
[ -z "$SPEECH" ] && exit 0

# Lock AFTER validation — only when we know we'll play audio
touch "$LOCKFILE"

TTS_URL="${TTS_URL:-http://localhost:8000/v1/audio/speech}"
# Validate TTS_URL points to localhost
case "$TTS_URL" in
  http://localhost:*|http://127.0.0.1:*) ;;
  *)
    TTS_URL="http://localhost:8000/v1/audio/speech"
    ;;
esac

# --- Streaming player (preferred) with afplay fallback ---
VENV_PY="$APP_SUPPORT/venv/bin/python"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAYER="$(dirname "$HOOK_DIR")/scripts/tts_stream_player.py"
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

# Release hook lock now that PID is written (trap will also clean up)
rmdir "$HOOK_LOCK" 2>/dev/null

exit 0
