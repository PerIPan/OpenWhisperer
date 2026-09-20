/**
 * OpenWhisperer voice extension for Pi.
 *
 * Brings OpenWhisperer's voice mode to the Pi coding agent, which has no MCP:
 *   1. Registers a `speak` tool that plays text via OpenWhisperer's local TTS server (:8000).
 *   2. On a voice-dictated turn (prompt hash matches the app's `voice_turn` signal), injects a
 *      hidden per-turn nudge so the model calls `speak` first with a standalone spoken summary.
 *   3. Carries the same persona and reply-language layers as the bash hook: the two maps below
 *      mirror `resolve_flavor()` and `resolve_language_line()` in hooks/voice-shared.sh.
 *
 * Mirrors hooks/voice-context.sh + voice-shared.sh (gating, nudge, persona, language) and the
 * speak MCP tool (in-app playback). Single self-contained file — no MCP server, no bash hook —
 * which is why the maps are copied rather than sourced. The hook stays the source of truth:
 * reword there first. HookTests' piNudgeParityFailures() parses both files and fails on drift.
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
    case "full":
      return "a spoken paragraph of four or five sentences";
    default:
      return "one plain spoken sentence";
  }
}

/// Extra instruction for the longest tier only — mirrors `resolve_depth_line` in
/// hooks/voice-shared.sh. Without it, "full" reads as just a longer summary.
function nudgeDepth(style: string): string {
  if (style !== "full") return "";
  return (
    " Use that paragraph to explain your reasoning and any trade-offs, not just the conclusion" +
    " — but keep it spoken prose, with no lists, headings, code, or file paths."
  );
}

/**
 * Native-tongue flavor — mirrors `resolve_flavor()` in hooks/voice-shared.sh. One table, two
 * kinds of key: the Kokoro voice-id first character for the automatic path, and the persona id
 * for an override (OW_TTS_PERSONA env → tts_persona file → "auto" = follow the voice). Single
 * chars and words cannot collide, so they share entries. Personality only, no vocabulary
 * steering, kept subdued.
 */
const PERSONAS: Array<{ keys: string[]; accent: string; persona: string; desc: string }> = [
  { keys: ["a", "american"], accent: "American English", persona: "American", desc: "quietly self-assured, with a light touch of Silicon Valley hype" },
  { keys: ["b", "british"], accent: "British English", persona: "British", desc: "dry and unflappable, with a streak of deadpan wit and gentle irony" },
  { keys: ["f", "french"], accent: "French", persona: "French", desc: "dry and faintly unimpressed, given to the occasional philosophical shrug" },
  { keys: ["i", "italian"], accent: "Italian", persona: "Italian", desc: "warm and expressive; things are either wonderful or a small catastrophe, rarely in between" },
  { keys: ["e", "spanish"], accent: "Spanish", persona: "Spanish", desc: "relaxed and direct; there's always time, and it'll all be fine" },
  { keys: ["p", "brazilian"], accent: "Brazilian Portuguese", persona: "Brazilian", desc: "sunny and easygoing, unbothered, always a friendly way around things" },
  { keys: ["h", "hindi"], accent: "Hindi", persona: "Hindi", desc: "warm and irrepressibly helpful, the eternal problem-solver, assuring you it's no trouble at all" },
  { keys: ["j", "japanese"], accent: "Japanese", persona: "Japanese", desc: "courteous and understated, meticulous, softening things, quietly prizing care and subtlety" },
  { keys: ["z", "chinese"], accent: "Mandarin Chinese", persona: "Chinese", desc: "pragmatic and modest, understated, fond of a proverb, unfussed by small things" },
  { keys: ["dutch"], accent: "Dutch", persona: "Dutch", desc: "direct to the point of bluntness and considers that a courtesy; says the plain thing and trusts you can take it" },
  { keys: ["german"], accent: "German", persona: "German", desc: "precise and thorough, quietly certain there is a correct way; jokes arrive deadpan and structurally sound" },
  { keys: ["polish"], accent: "Polish", persona: "Polish", desc: "warm underneath a matter-of-fact surface; expects the worst, copes admirably, mentions neither" },
  { keys: ["russian"], accent: "Russian", persona: "Russian", desc: "sombre and unhurried, fond of a bleak aphorism, unimpressed by enthusiasm" },
  { keys: ["turkish"], accent: "Turkish", persona: "Turkish", desc: "hospitable and generous with reassurance; takes personal responsibility for your comfort" },
  { keys: ["finnish"], accent: "Finnish", persona: "Finnish", desc: "sparing with words, comfortable with silence; says the necessary thing and stops" },
  { keys: ["korean"], accent: "Korean", persona: "Korean", desc: "brisk and thorough, quietly competitive about doing it properly" },
  { keys: ["greek"], accent: "Greek", persona: "Greek", desc: "expansive and quick to debate, always warmly; takes the long view, having watched empires come and go" },
];

/**
 * The persona line for the active voice, or "" for an unknown/no voice. Resolved voice:
 * OW_TTS_VOICE env → tts_voice file. An explicit persona wins over the voice's own; the
 * override is tried first and the voice's prefix second, so an unrecognized override degrades
 * to the voice instead of stripping the persona.
 */
function resolveFlavor(): string {
  const voice = readPref("OW_TTS_VOICE", "tts_voice", "").replace(/\s+/g, "");
  const override = readPref("OW_TTS_PERSONA", "tts_persona", "").replace(/\s+/g, "").toLowerCase();
  const prefix = voice.charAt(0);
  let choseOverride = Boolean(override) && override !== "auto";
  for (const key of [choseOverride ? override : prefix, prefix]) {
    const hit = key ? PERSONAS.find((p) => p.keys.includes(key)) : undefined;
    if (hit) {
      // Overridden: say nothing about the accent. It comes from the voice, not this persona,
      // and naming the persona's own accent would describe a voice that isn't speaking.
      return choseOverride
        ? ` Adopt ${article(hit.persona)} ${hit.persona} persona for the voice speaking your reply: ${hit.desc}.`
        : ` The voice speaking your reply has ${article(hit.accent)} ${hit.accent} accent. Adopt ${article(hit.persona)} ${hit.persona} persona: ${hit.desc}.`;
    }
    choseOverride = false;
  }
  return "";
}

/** "a" or "an" for the word that follows — mirrors `article()` in voice-shared.sh. */
function article(word: string): string {
  return /^[aeiou]/i.test(word) ? "an" : "a";
}

/**
 * Reply language — mirrors `resolve_language_line()` in hooks/voice-shared.sh, including the
 * `en` entry. A *pin* (`OW_TTS_LANGUAGE`, else the `tts_language` file) names the language
 * every spoken reply is written in. Without one, a Supertonic voice's own language is only
 * the default: the engine follows the language of the text (TTSLanguageFollow), so the model
 * may switch when asked. Kokoro voices get nothing; an English Supertonic voice gets nothing.
 */
const LANGUAGES: Record<string, string> = {
  en: "English",
  nl: "Dutch", de: "German", pl: "Polish", ru: "Russian", uk: "Ukrainian", fr: "French",
  it: "Italian", es: "Spanish", pt: "Portuguese", hi: "Hindi", ja: "Japanese", ko: "Korean",
  ar: "Arabic", bg: "Bulgarian", cs: "Czech", da: "Danish", el: "Greek", et: "Estonian",
  fi: "Finnish", hr: "Croatian", hu: "Hungarian", id: "Indonesian", lt: "Lithuanian", lv: "Latvian",
  ro: "Romanian", sk: "Slovak", sl: "Slovenian", sv: "Swedish", tr: "Turkish", vi: "Vietnamese",
};

function resolveLanguageLine(): string {
  // Same normalization as the hook: whitespace, case, a BCP-47 subtag (`pt-BR` → `pt`), and
  // the `english` alias the first cut of OW_TTS_LANGUAGE accepted.
  let pin = readPref("OW_TTS_LANGUAGE", "tts_language", "").replace(/\s+/g, "").toLowerCase().split(/[-_]/)[0];
  if (pin === "english") pin = "en";
  const pinned = LANGUAGES[pin];
  // Sentinel phrase kept distinct from resolveFlavor's "voice speaking your reply" so the two
  // layers stay independently assertable.
  if (pinned) {
    return (
      ` Write the text you pass to \`openwhisperer_speak\` in ${pinned}, whatever language the` +
      ` conversation is in. Your on-screen reply stays in the language of the conversation.`
    );
  }
  const voice = readPref("OW_TTS_VOICE", "tts_voice", "").replace(/\s+/g, "");
  if (!/^supertonic:/i.test(voice)) return "";
  const code = (voice.split(":")[1] ?? "").toLowerCase();
  if (code === "en") return "";
  const language = LANGUAGES[code];
  if (!language) return "";
  return (
    ` Write the text you pass to \`openwhisperer_speak\` in ${language} by default — that is the` +
    ` selected voice's language — but switch to whatever language I ask for or the conversation` +
    ` is in; the voice follows the language you write. Your on-screen reply stays in the language` +
    ` of the conversation.`
  );
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
      // Per-project voice/speed: read here (the extension owns the call, so this is
      // deterministic — no dependency on the model echoing args). Precedence: env → file.
      const voice = readPref("OW_TTS_VOICE", "tts_voice", "");
      const speed = Number.parseFloat(readPref("OW_TTS_SPEED", "tts_speed", ""));
      const body: Record<string, unknown> = { input: params.text };
      if (voice) body.voice = voice;
      if (Number.isFinite(speed)) body.speed = speed;
      try {
        await fetch(TTS_PLAY_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
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

    // Response mode: "always" speaks every turn; "needed" makes every turn a candidate but
    // hands the decision to the model; "voice" (default, and any stale "text") speaks only
    // dictated turns. Mirrors the mode table in hooks/voice-shared.sh.
    const speak = mode === "always" || mode === "needed" ? true : isVoice;

    debug(`before_agent_start mode=${mode} isVoice=${isVoice} speak=${speak}`);
    if (!speak) return;

    const style = readPref("OW_TTS_STYLE", "tts_style", "normal");
    const len = nudgeLen(style);
    const depth = nudgeDepth(style);
    // Persona and reply-language layers ride after the tail, in the same order build_nudge()
    // appends them in hooks/voice-shared.sh (no speak-args line: the tool reads voice/speed itself).
    const tail =
      ` Then write your full reply on screen as usual. Do not mention the tool in your written reply.` +
      resolveFlavor() +
      resolveLanguageLine();

    // "Only when I'm needed" cannot be decided here — this runs before the turn exists — so
    // the gate is delegated to the model, exactly as the bash hooks do for the other agents.
    const nudge =
      mode === "needed"
        ? `Speak this reply ONLY if it needs something from me. First decide whether this turn ends on me: ` +
          `you are asking a question, you are blocked, you need my approval for something risky or ` +
          `destructive, or something failed and I have to choose what happens next. If so, your FIRST ` +
          `action must be to call the \`openwhisperer_speak\` tool exactly once, passing ${len} that says ` +
          `plainly what you need from me and stands alone when heard.${depth} If instead the work simply ` +
          `succeeded and needs nothing from me, do NOT call the tool at all — staying silent is the ` +
          `correct outcome, and a spoken "all done" is exactly what this mode exists to avoid.${tail}`
        : `${isVoice ? "This turn was dictated by voice. " : ""}Before writing your on-screen reply, your ` +
          `FIRST action must be to call the \`openwhisperer_speak\` tool exactly once, passing ${len} that ` +
          `summarizes your answer and stands alone when heard.${depth} Do not skip the speak call.${tail}`;

    return {
      message: {
        customType: "openwhisperer-voice-nudge",
        content: nudge,
        display: false,
      },
    };
  });
}
