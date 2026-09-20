# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Open Whisperer is a macOS **menubar app** (Swift/SwiftUI, Apple Silicon, macOS 14+) that adds full voice mode to **Claude Code**, **Codex CLI**, and **Pi**: dictation in (speech→text, typed into the focused app) and spoken replies out (text→speech). Everything runs locally — no cloud APIs.

> **README scope.** `README.md` is the user-facing document: what the app does, how to install it, the configuration reference, and the release notes. It was rewritten for the Swift architecture and is accurate — the only Python mentions left are historical prose saying the Python server, virtualenv and `setup.sh` are *gone*. (An earlier version of this note warned the README still documented that stack; it no longer does.) The README's `[VOICE:]` tag mechanism is vestigial — see "Voice-turn handshake" in AGENTS.md for what actually runs.

For commands, testing, changes workflow, commit message rules, architecture details, and developer conventions:
See @AGENTS.md
