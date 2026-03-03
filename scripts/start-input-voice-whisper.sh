#!/bin/bash
# Start Whisper voice input for Claude Code
# Usage: ./start-voice.sh [options]
#        ./start-voice.sh --submit    (auto-press Enter after typing)
#        ./start-voice.sh --silence 2.5

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PATH="${VENV_PATH:-$HOME/mlx-openai-whisper}"

if [ ! -f "$VENV_PATH/bin/activate" ]; then
  echo "Error: Virtual environment not found at $VENV_PATH"
  echo "Set VENV_PATH or run setup.sh first."
  exit 1
fi

source "$VENV_PATH/bin/activate"

# Check STT server is running
if ! curl -s "http://localhost:${STT_PORT:-8000}/models" > /dev/null 2>&1; then
  echo "Error: Whisper STT server not running on port ${STT_PORT:-8000}"
  echo "Start it first: ./servers/start-servers.sh --no-voice"
  exit 1
fi

echo "Starting voice input (Whisper-powered, loop mode)"
echo "Say 'submit', 'send it', or 'go ahead' at the end to press Enter."
echo "Press Ctrl+C to stop."
echo "---"

python "$SCRIPT_DIR/voice-input.py" --loop "$@"
