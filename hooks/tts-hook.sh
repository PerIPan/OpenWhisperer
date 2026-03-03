#!/bin/bash
# Claude Code Stop hook — speaks the last response via mlx_audio TTS
# Claude includes a [VOICE: ...] tag with a spoken summary
# Fully async: TTS generation + playback runs in background
# New responses interrupt previous playback

PIDFILE="/tmp/tts_hook.pid"

# Kill any previous TTS playback
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE")
  kill "$OLD_PID" 2>/dev/null
  pkill -P "$OLD_PID" 2>/dev/null
  rm -f "$PIDFILE"
fi

INPUT=$(cat)

# Prevent loops
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active')" = "true" ]; then
  exit 0
fi

TEXT=$(echo "$INPUT" | jq -r '.last_assistant_message // empty')
[ -z "$TEXT" ] && exit 0

# Extract [VOICE: ...] tag if present (Claude generates the spoken summary)
# Use tail -1 to grab the LAST [VOICE:] tag (avoids matching literal mentions of the tag)
SPEECH=$(echo "$TEXT" | sed -n -E 's/.*\[VOICE: (.*)\].*/\1/p' | tail -1)

# Fallback: clean up raw text if no VOICE tag
if [ -z "$SPEECH" ]; then
  SPEECH=$(echo "$TEXT" | \
    sed 's/```[^`]*```//g' | \
    sed 's/`[^`]*`//g' | \
    sed 's/\*\*//g; s/\*//g' | \
    sed -E 's/^#+ *//g' | \
    sed 's/|[^|]*|//g' | \
    sed -E 's/^- +//g; s/^[0-9]+\. //g' | \
    sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | \
    sed -E 's|https?://[^ ]*||g' | \
    sed 's/  */ /g' | \
    tr '\n' ' ' | \
    sed 's/  */ /g; s/^ *//; s/ *$//')
  # Truncate fallback at sentence boundary around 600 chars
  if [ ${#SPEECH} -gt 600 ]; then
    SPEECH="${SPEECH:0:700}"
    SPEECH=$(echo "$SPEECH" | sed 's/\([.!?]\)[^.!?]*$/\1/')
  fi
fi

[ -z "$SPEECH" ] && exit 0

# Run entire TTS pipeline in background (non-blocking)
(
  TTS_URL="${TTS_URL:-http://localhost:8100/v1/audio/speech}"
  VOICE="${TTS_VOICE:-af_heart}"
  MODEL="${TTS_MODEL:-prince-canuma/Kokoro-82M}"
  TMPFILE=$(mktemp /tmp/tts_XXXXXX.wav)

  curl -s -X POST "$TTS_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$SPEECH" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')" \
    --output "$TMPFILE" 2>/dev/null

  if [ -s "$TMPFILE" ]; then
    afplay "$TMPFILE" 2>/dev/null
  fi
  rm -f "$TMPFILE" 2>/dev/null
  rm -f "$PIDFILE" 2>/dev/null
) &

# Save background PID so next invocation can interrupt it
echo $! > "$PIDFILE"

exit 0
