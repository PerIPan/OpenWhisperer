#!/bin/bash
# Setup script for Claude Voice Mode
# Creates a uv venv with all dependencies for STT + TTS on Apple Silicon

set -e
# pipefail: a failing `curl ... | sh` (e.g. uv install) must abort, not pass silently (QW.4)
set -o pipefail

VENV_PATH="${1:-$HOME/mlx-openai-whisper}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Claude Voice Mode Setup ==="
echo ""

# Check for Apple Silicon
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Warning: This setup is optimized for Apple Silicon (M-series) Macs."
  echo "MLX may not work on your architecture."
  read -p "Continue anyway? (y/n) " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check for uv
if ! command -v uv &> /dev/null; then
  echo "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  source "$HOME/.local/bin/env" 2>/dev/null || true
fi

# Create venv
echo "Creating virtual environment at $VENV_PATH..."
uv venv "$VENV_PATH" --python 3.13

source "$VENV_PATH/bin/activate"

# Install dependencies
# Pin mlx-audio==0.4.1: 0.4.4 broke Kokoro TTS — SineGen's interpolate round-trip
# is not length-preserving, so sine_waves drift one hop (×300) vs the uv/noise mask
# and synthesis 500s on most text. Upstream bug (Blaizzy/mlx-audio #784/#786, fix PR
# #785 unmerged). 0.4.1 predates the regression. Remove the pin once #785 ships.
echo "Installing mlx_audio (TTS + STT)..."
uv pip install 'mlx-audio==0.4.1'

echo "Installing mlx_whisper..."
uv pip install mlx-whisper

echo "Installing spaCy English model (required by Kokoro TTS)..."
uv pip install en_core_web_sm@https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl

echo "Installing setuptools (required by webrtcvad)..."
uv pip install "setuptools<81"

# unified_server.py imports these DIRECTLY; mlx-audio does not guarantee them
# transitively, so the server crashes on startup without them.
echo "Installing server dependencies (soundfile, FastAPI/uvicorn, webrtcvad, misaki)..."
uv pip install soundfile fastapi uvicorn python-multipart webrtcvad "misaki[en]"

# Make scripts executable
chmod +x "$SCRIPT_DIR/hooks/tts-hook.sh"
chmod +x "$SCRIPT_DIR/servers/start-servers.sh"
chmod +x "$SCRIPT_DIR/scripts/speak.sh"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Start servers:  ./servers/start-servers.sh $VENV_PATH"
echo "2. Copy CLAUDE.md to your project root"
echo "3. Configure the hook in your project's .claude/settings.json:"
echo ""
echo '   {'
echo '     "hooks": {'
echo '       "Stop": [{'
echo '         "hooks": [{'
echo '           "type": "command",'
echo "           \"command\": \"$SCRIPT_DIR/hooks/tts-hook.sh\","
echo '           "timeout": 60'
echo '         }]'
echo '       }]'
echo '     }'
echo '   }'
echo ""
echo "4. Voice input (uses your local Whisper for high-accuracy STT):"
echo "   python $SCRIPT_DIR/scripts/voice-input.py --loop"
echo "   (Focus the Claude Code input field first, then run in a separate terminal)"
echo ""
echo "5. (Optional) Test TTS:  echo 'Hello world' | ./scripts/speak.sh"
