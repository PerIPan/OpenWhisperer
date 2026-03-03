#!/bin/bash
# Start STT + TTS servers for Claude Voice Mode
# Usage: ./start-servers.sh [venv_path]
#
# Voice input is separate: ./scripts/start-input-voice-whisper.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

VENV_PATH="${1:-$HOME/mlx-openai-whisper}"

if [ ! -f "$VENV_PATH/bin/activate" ]; then
  echo "Error: Virtual environment not found at $VENV_PATH"
  echo "Usage: $0 [path/to/venv]"
  exit 1
fi

source "$VENV_PATH/bin/activate"

STT_PORT="${STT_PORT:-8000}"
TTS_PORT="${TTS_PORT:-8100}"

echo "Starting Whisper STT on http://localhost:$STT_PORT"
python "$SCRIPT_DIR/whisper_server.py" &
STT_PID=$!

echo "Starting TTS on http://localhost:$TTS_PORT"
mlx_audio.server --host 0.0.0.0 --port "$TTS_PORT" &
TTS_PID=$!

# Wait for servers to be ready
echo "Waiting for Whisper server..."
for i in $(seq 1 30); do
  curl -s "http://localhost:$STT_PORT/models" > /dev/null 2>&1 && break
  sleep 1
done

echo "Waiting for TTS server..."
for i in $(seq 1 60); do
  curl -s "http://localhost:$TTS_PORT/v1/models" > /dev/null 2>&1 && break
  sleep 1
done

echo ""
echo "Servers ready. For voice input, run in another terminal:"
echo "  ./scripts/start-input-voice-whisper.sh"
echo ""
echo "Press Ctrl+C to stop servers."

cleanup() {
  echo "Shutting down..."
  kill "$STT_PID" "$TTS_PID" 2>/dev/null
  rm -f /tmp/tts_playing.lock /tmp/tts_hook.pid
  wait 2>/dev/null
  echo "Done."
  exit 0
}
trap cleanup INT TERM
wait
