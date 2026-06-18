#!/bin/bash
# Enforce UTF-8 for safe string slicing (#15)
export LANG="${LANG:-en_US.UTF-8}"
# Claude Code Stop hook — speaks the last response via the in-app native TTS player.
# The UserPromptSubmit hook marks a dictated turn (speak_pending marker); this hook extracts the
# response's first paragraph and POSTs it to the app, which synthesizes sentence-by-sentence and
# plays in-process. Barge-in and superseding playback are handled inside the app (no PID/afplay).

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"

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

# --- Voice-turn gate: only speak turns the UserPromptSubmit hook marked as dictated. ---
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
PENDING_DIR="$APP_SUPPORT/speak_pending"
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_.-' '_')
PENDING="$PENDING_DIR/$SAFE_ID"
# Sweep markers orphaned by sessions that died between prompt and response. The 15-minute
# window lets a long agent turn finish without its own marker being swept mid-turn.
find "$PENDING_DIR" -type f -mmin +15 -delete 2>/dev/null
# Only speak if THIS session was marked a voice turn by the UPS hook.
[ -f "$PENDING" ] || exit 0
rm -f "$PENDING"

# Extract the FIRST PARAGRAPH of the response (markdown-stripped) as the spoken text.
TEXT=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty')
[ -z "$TEXT" ] && exit 0
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/first-paragraph.sh")
[ -z "$SPEECH" ] && exit 0

# Resolve voice (volume is applied app-side now).
VOICE_FILE="$APP_SUPPORT/tts_voice"
if [ -f "$VOICE_FILE" ] && [ ! -L "$VOICE_FILE" ]; then
  VOICE="$(cat "$VOICE_FILE" 2>/dev/null | tr -d '[:space:]')"; VOICE="${VOICE:-${TTS_VOICE:-af_heart}}"
else
  VOICE="${TTS_VOICE:-af_heart}"
fi

# POST to the in-app player (loopback only). Fire-and-forget: the app returns 202 immediately,
# then synthesizes + plays in-process and owns tts_playing.lock.
PLAY_URL="${TTS_PLAY_URL:-http://localhost:8000/v1/audio/play}"
case "$PLAY_URL" in
  http://localhost:*|http://127.0.0.1:*) ;;
  *) PLAY_URL="http://localhost:8000/v1/audio/play" ;;
esac

PAYLOAD="$(jq -n --arg t "$SPEECH" --arg v "$VOICE" '{input: $t, voice: $v}')"
curl -s -X POST "$PLAY_URL" -H "Content-Type: application/json" -d "$PAYLOAD" --max-time 5 >/dev/null 2>&1 &

exit 0
