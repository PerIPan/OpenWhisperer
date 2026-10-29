#!/bin/bash
# Speaks text via the local native TTS server (synchronous CLI utility).
# Usage: echo "text" | ./speak.sh  OR  ./speak.sh "text to speak"
#
# This blocks until playback finishes: it synthesizes the whole clip (POST /v1/audio/speech → WAV)
# then plays it with afplay. The Stop / notify hooks instead POST /v1/audio/play for low-latency,
# sentence-streamed in-app playback; speak.sh stays a simple blocking helper.

# The port the app's server last bound (Settings → Advanced), else 8000.
TTS_PORT=$(tr -d '[:space:]' 2>/dev/null < "$HOME/Library/Application Support/OpenWhisperer/tts_port")
case "$TTS_PORT" in ''|*[!0-9]*) TTS_PORT=8000 ;; esac
TTS_URL="${TTS_URL:-http://localhost:$TTS_PORT/v1/audio/speech}"
# Unset: no voice in the request, so the app uses the one chosen in Settings (Heart by default).
# It used to default to af_heart here, which kept speak.sh on Kokoro after the app moved to Heart.
VOICE="${TTS_VOICE:-}"
TMPFILE=$(mktemp /tmp/tts_XXXXXX.wav)

if [ -n "$1" ]; then
  TEXT="$*"
else
  TEXT=$(cat)
fi

[ -z "$TEXT" ] && exit 0

# Truncate very long text to avoid timeout
TEXT="${TEXT:0:2000}"

curl -s -X POST "$TTS_URL" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg t "$TEXT" --arg v "$VOICE" 'if $v == "" then {input: $t} else {input: $t, voice: $v} end')" \
  --output "$TMPFILE" 2>/dev/null
afplay -v "${TTS_VOLUME:-1}" "$TMPFILE" 2>/dev/null
rm -f "$TMPFILE"
