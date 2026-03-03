"""Lightweight OpenAI-compatible Whisper STT server using MLX."""

import asyncio
import threading
import mlx_whisper
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import tempfile, os, uvicorn

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:8000", "http://localhost:8100", "http://127.0.0.1:8000", "http://127.0.0.1:8100"],
    allow_methods=["POST", "GET"],
    allow_headers=["Content-Type"],
)

MODEL = os.getenv("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")

_transcribe_lock = threading.Lock()

models_response = {
    "object": "list",
    "data": [{"id": "whisper-1", "object": "model", "owned_by": "local"}]
}

@app.get("/v1/models")
@app.get("/models")
async def list_models():
    return models_response

def _serialize_transcribe(tmp_path, language):
    """Run transcription with mutex to prevent concurrent MLX access."""
    with _transcribe_lock:
        return mlx_whisper.transcribe(tmp_path, path_or_hf_repo=MODEL, language=language)

async def do_transcribe(file, model, language, response_format):
    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name
    try:
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(None, lambda: _serialize_transcribe(tmp_path, language))
        text = result["text"]
    finally:
        os.unlink(tmp_path)
    if response_format == "text":
        return text
    return JSONResponse({"text": text})

@app.post("/v1/audio/transcriptions")
@app.post("/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(default="whisper-1"),
    language: str = Form(default=None),
    response_format: str = Form(default="json"),
):
    return await do_transcribe(file, model, language, response_format)

if __name__ == "__main__":
    port = int(os.getenv("STT_PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port)
