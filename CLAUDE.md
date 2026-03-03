# Claude Voice Mode - Project Instructions

## Voice Mode
ALWAYS include a `[VOICE: ...]` tag at the END of every response. This tag contains a short, conversational spoken summary (1-3 sentences) that the TTS hook extracts and reads aloud. Write the voice content as natural speech — no code, no file paths, no markdown, no technical jargon unless the user used it first. The user sees the full response on screen; they hear only the VOICE tag content.

Example: `[VOICE: I fixed the bug in the login page. It was a missing null check on the user object.]`

If the response is already short and conversational, the VOICE tag can match the full response.
