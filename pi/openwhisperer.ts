/**
 * OpenWhisperer voice extension for Pi.
 *
 * Brings OpenWhisperer's voice mode to the Pi coding agent, which has no MCP:
 *   1. Registers a `speak` tool that plays text via OpenWhisperer's local TTS server (:8000).
 *   2. On a voice-dictated turn (prompt hash matches the app's `voice_turn` signal), injects a
 *      hidden per-turn nudge so the model calls `speak` first with a standalone spoken summary.
 *
 * Mirrors hooks/voice-context.sh (gating + nudge) and the speak MCP tool (in-app playback).
 * Single self-contained file — no MCP server, no bash hook.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Text } from "@earendil-works/pi-tui";
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const APP_SUPPORT = join(homedir(), "Library", "Application Support", "OpenWhisperer");
const VOICE_TURN = join(APP_SUPPORT, "voice_turn");
const TTS_PLAY_URL = "http://localhost:8000/v1/audio/play";
const FRESHNESS_S = 900; // voice_turn TTL — matches voice-context.sh

function readPref(envVar: string, file: string, fallback: string): string {
  const env = process.env[envVar]?.trim();
  if (env) return env;
  try {
    return readFileSync(join(APP_SUPPORT, file), "utf8").trim() || fallback;
  } catch {
    return fallback;
  }
}

function nudgeLen(style: string): string {
  switch (style) {
    case "terse":
      return "one short, plain spoken sentence";
    case "rich":
      return "a sentence or two of plain spoken summary";
    default:
      return "one plain spoken sentence";
  }
}

function debug(msg: string): void {
  if (!process.env.OW_PI_DEBUG) return;
  try {
    appendFileSync(join(APP_SUPPORT, "pi-voice.log"), `${new Date().toISOString()} ${msg}\n`);
  } catch {
    /* ignore */
  }
}

/**
 * True if `prompt` matches a fresh `voice_turn` signal — i.e. this turn was dictated.
 * Claims (deletes) the signal on a match so a later typed turn isn't also matched.
 * The hash must match VoiceSignal.canonicalHash: sha256 of the whitespace-trimmed text.
 */
function claimVoiceTurn(prompt: string): boolean {
  if (!existsSync(VOICE_TURN)) return false;
  let raw: string;
  try {
    raw = readFileSync(VOICE_TURN, "utf8");
  } catch {
    return false;
  }
  const lines = raw.split("\n");
  const storedHash = (lines[0] ?? "").trim();
  const storedTs = Number.parseInt((lines[1] ?? "").trim(), 10);
  if (!storedHash) return false;

  const now = Math.floor(Date.now() / 1000);
  if (Number.isFinite(storedTs) && now - storedTs > FRESHNESS_S) {
    try {
      rmSync(VOICE_TURN);
    } catch {
      /* ignore */
    }
    return false;
  }

  const promptHash = createHash("sha256").update(prompt.trim()).digest("hex");
  if (promptHash !== storedHash) return false;

  try {
    rmSync(VOICE_TURN); // atomic-enough claim for a single local user
  } catch {
    /* ignore */
  }
  return true;
}

export default function (pi: ExtensionAPI) {
  // 1. The `speak` tool — plays text aloud via OpenWhisperer's local TTS (fire-and-forget).
  pi.registerTool({
    name: "openwhisperer_speak",
    label: "OpenWhisperer",
    description:
      "Speak the given text aloud through OpenWhisperer's local voice (text-to-speech). " +
      "Fire-and-forget: returns immediately while audio plays.",
    promptSnippet: "Speak a short spoken summary aloud via OpenWhisperer TTS",
    parameters: Type.Object({
      text: Type.String({ description: "The text to speak aloud." }),
    }),
    async execute(_toolCallId, params) {
      debug(`speak tool called: ${JSON.stringify(params.text).slice(0, 80)}`);
      try {
        await fetch(TTS_PLAY_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ input: params.text }),
        });
      } catch (e) {
        return {
          content: [{ type: "text", text: `speak failed: ${(e as Error).message}` }],
          isError: true,
        };
      }
      return { content: [{ type: "text", text: "Speaking." }] };
    },
    // Pretty TUI header: show the brand, not the snake_case wire name (openwhisperer_speak).
    renderCall(_args, theme) {
      return new Text(theme.fg("toolTitle", theme.bold("OpenWhisperer")), 0, 0);
    },
  });

  // 2. The gated nudge — on a turn the response mode means to speak, inject a hidden directive
  //    telling the model to call `speak` first. Per-turn, invisible to the on-screen reply.
  pi.on("before_agent_start", async (event) => {
    const prompt = typeof event.prompt === "string" ? event.prompt : "";
    if (!prompt) return;

    const mode = readPref("OW_TTS_RESPONSE", "tts_response_mode", "voice");
    const isVoice = claimVoiceTurn(prompt);

    let speak: boolean;
    if (mode === "always") speak = true;
    else if (mode === "text") speak = !isVoice;
    else speak = isVoice; // "voice" (default)

    debug(`before_agent_start mode=${mode} isVoice=${isVoice} speak=${speak}`);
    if (!speak) return;

    const len = nudgeLen(readPref("OW_TTS_STYLE", "tts_style", "normal"));
    const voiceLine = isVoice ? "This turn was dictated by voice. " : "";
    const nudge =
      `${voiceLine}Before writing your on-screen reply, your FIRST action must be to call the ` +
      `\`openwhisperer_speak\` tool exactly once, passing ${len} that summarizes your answer and stands alone ` +
      `when heard. Then write your full reply on screen as usual. Do not skip the speak call, and ` +
      `do not mention the tool in your written reply.`;

    return {
      message: {
        customType: "openwhisperer-voice-nudge",
        content: nudge,
        display: false,
      },
    };
  });
}
