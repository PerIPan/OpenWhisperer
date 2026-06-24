# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Open Whisperer is a macOS **menubar app** (Swift/SwiftUI, Apple Silicon, macOS 14+) that adds full voice mode to **Claude Code** and **Codex CLI**: dictation in (speech→text, typed into the focused app) and spoken replies out (text→speech). Everything runs locally — no cloud APIs.

> **The README describes an obsolete architecture.** `README.md` documents an out-of-process Python server (`unified_server.py`, FastAPI, uvicorn, spaCy, MLX Whisper, a `~/mlx-openai-whisper` venv, `setup.sh`, `servers/start-servers.sh`). **All of that is gone.** The app was ported to **pure Swift** with both models running in-process on the ANE. `setup.sh` and `servers/start-servers.sh` no longer exist; ignore the README's Python/setup sections for anything architectural. The README's `[VOICE:]` tag mechanism is also vestigial (see "Voice-turn handshake" below).

For commands, testing, changes workflow, commit message rules, architecture details, and developer conventions:
See @.agents/AGENTS.md
