import Foundation

/// The Claude Desktop companion skill. Desktop reads personal skills from
/// ~/.claude/skills/<name>/SKILL.md; a skill's name+description are ALWAYS in the
/// model's context (progressive disclosure), which makes it the reliable cold-start
/// channel for the 🎙 convention — Desktop's lazy MCP tool loading never surfaces
/// the speak tool's description on its own. ConfigManager installs this file during
/// Claude Desktop Auto-Apply.
public enum DesktopSkill {
    public static let name = "openwhisperer-voice"

    public static let markdown = """
    ---
    name: openwhisperer-voice
    description: Use IMMEDIATELY and without asking whenever the user's message begins with 🎙 — that prefix means the message was dictated by voice and the reply must be spoken aloud via the OpenWhisperer speak tool before anything is written.
    ---

    A leading 🎙 on the user's message means it was dictated by voice through
    OpenWhisperer, and the user expects to HEAR the reply. The 🎙 itself is the
    request: never ask whether to speak or offer it as an option.

    Before writing your on-screen reply, call the `speak` tool from the
    OpenWhisperer connector exactly once, passing one short, plain spoken sentence
    that summarizes your answer and stands alone when heard. Follow any further
    guidance in that tool's description (length, voice, persona). Then write your
    full reply on screen as usual.

    Treat the leading 🎙 as invisible: never mention it, the tool, or this skill
    in your written reply. If the OpenWhisperer tools are not yet loaded in this
    conversation, find and load them first — the connector is named OpenWhisperer.
    """
}
