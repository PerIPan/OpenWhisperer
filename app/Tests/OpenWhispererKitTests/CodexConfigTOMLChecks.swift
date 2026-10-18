import OpenWhispererKit

/// Checks for `CodexConfigTOML` — the migration that moves our Codex hook out of the inline
/// `[[hooks.UserPromptSubmit]]` tables in `~/.codex/config.toml` (Codex warns when a layer has
/// both `hooks.json` and inline `[hooks]`). Only our own tables may go: the `speak` MCP server,
/// `[features] hooks = true`, `[hooks.state]` trust hashes, and any foreign hook must survive.
func codexConfigTOMLFailures() -> [String] {
    var failures: [String] = []
    func expect(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !cond {
            let d = detail()
            failures.append("CodexConfigTOML.\(name)" + (d.isEmpty ? "" : ": \(d)"))
        }
    }

    let ourPath = "/Applications/OpenWhisperer.app/Contents/Resources/hooks/voice-context.sh"
    let inline = """
    [[hooks.UserPromptSubmit]]

    [[hooks.UserPromptSubmit.hooks]]
    type = "command"
    command = "\(ourPath)"
    timeout = 30
    """

    // The shape a real install has after the pre-hooks.json app wrote it.
    let real = """
    model = "gpt-5.6-sol"

    [mcp_servers.OpenWhisperer]
    url = "http://localhost:8000/mcp"

    [mcp_servers.OpenWhisperer.tools.speak]
    approval_mode = "approve"

    \(inline)

    [hooks.state]

    [hooks.state."/Users/x/.codex/config.toml:user_prompt_submit:0:0"]
    trusted_hash = "sha256:7f2f"

    [features]
    hooks = true

    """
    let stripped = CodexConfigTOML.strippingOwnHooks(from: real)
    expect(!stripped.contains("voice-context.sh"), "stripRemovesOwnHook", stripped)
    expect(!stripped.contains("[[hooks.UserPromptSubmit]]"), "stripRemovesOwnGroupHeader", stripped)
    expect(stripped.contains("[mcp_servers.OpenWhisperer]\nurl = \"http://localhost:8000/mcp\""), "stripKeepsMCPServer", stripped)
    expect(stripped.contains("[mcp_servers.OpenWhisperer.tools.speak]\napproval_mode = \"approve\""), "stripKeepsMCPSubtable", stripped)
    expect(stripped.contains("[hooks.state]"), "stripKeepsHookState", stripped)
    expect(stripped.contains("trusted_hash = \"sha256:7f2f\""), "stripKeepsTrustedHash", stripped)
    expect(stripped.contains("[features]\nhooks = true"), "stripKeepsFeaturesFlag", stripped)
    expect(stripped.hasPrefix("model = \"gpt-5.6-sol\"\n"), "stripKeepsPreamble", stripped)
    expect(stripped.contains("approval_mode = \"approve\"\n\n[hooks.state]"), "stripLeavesSingleBlankLine", stripped.debugDescription)
    expect(CodexConfigTOML.strippingOwnHooks(from: stripped) == stripped, "stripIdempotent")
    expect(CodexConfigTOML.hasOwnInlineHook(real), "hasOwnInlineHookTrue")
    expect(!CodexConfigTOML.hasOwnInlineHook(stripped), "hasOwnInlineHookFalse")

    // A config without our hook comes back byte-identical, foreign UserPromptSubmit hook and all.
    let foreign = """
    model = "gpt-5.6-sol"

    [[hooks.UserPromptSubmit]]
    matcher = ".*"

    [[hooks.UserPromptSubmit.hooks]]
    type = "command"
    command = "/Users/x/bin/lint-prompt.sh"

    [features]
    hooks = true
    """
    expect(CodexConfigTOML.strippingOwnHooks(from: foreign) == foreign, "stripNoOpOnForeign")
    expect(!CodexConfigTOML.hasOwnInlineHook(foreign), "hasOwnInlineHookFalseForeign")
    expect(CodexConfigTOML.strippingOwnHooks(from: "") == "", "stripNoOpOnEmpty")

    // Our group after a foreign one: only ours goes.
    let both = foreign + "\n\n" + inline + "\n"
    let bothStripped = CodexConfigTOML.strippingOwnHooks(from: both)
    expect(bothStripped.contains("lint-prompt.sh"), "stripKeepsForeignGroup", bothStripped)
    expect(bothStripped.contains("matcher = \".*\""), "stripKeepsForeignMatcher", bothStripped)
    expect(!bothStripped.contains("voice-context.sh"), "stripDropsOwnAmongForeign", bothStripped)
    expect(bothStripped.components(separatedBy: "[[hooks.UserPromptSubmit]]").count == 2, "stripLeavesOneGroupHeader", bothStripped)

    // Our hook sharing a group with a foreign one: the group header and the foreign hook stay.
    let sharedGroup = """
    [[hooks.UserPromptSubmit]]

    [[hooks.UserPromptSubmit.hooks]]
    type = "command"
    command = "/Users/x/bin/lint-prompt.sh"

    [[hooks.UserPromptSubmit.hooks]]
    type = "command"
    command = "\(ourPath)"
    timeout = 30
    """
    let sharedStripped = CodexConfigTOML.strippingOwnHooks(from: sharedGroup)
    expect(sharedStripped.contains("[[hooks.UserPromptSubmit]]"), "sharedGroupKeepsHeader", sharedStripped)
    expect(sharedStripped.contains("lint-prompt.sh"), "sharedGroupKeepsForeign", sharedStripped)
    expect(!sharedStripped.contains("voice-context.sh"), "sharedGroupDropsOurs", sharedStripped)

    // Headers with inner whitespace are still ours.
    let spaced = "[[ hooks.UserPromptSubmit ]]\n\n[[ hooks.UserPromptSubmit.hooks ]]\ntype = \"command\"\ncommand = \"\(ourPath)\"\n"
    expect(CodexConfigTOML.strippingOwnHooks(from: spaced) == "", "stripHandlesSpacedHeaders", CodexConfigTOML.strippingOwnHooks(from: spaced).debugDescription)

    // Legacy `notify = [...]` pointing at our old Stop-style hook goes; a foreign notify stays.
    let legacy = "notify = [\"/Applications/OpenWhisperer.app/Contents/Resources/hooks/codex-tts-hook.sh\"]\nnotify_on_error = true\n"
    expect(CodexConfigTOML.strippingOwnHooks(from: legacy) == "notify_on_error = true\n", "stripsLegacyNotify", CodexConfigTOML.strippingOwnHooks(from: legacy).debugDescription)
    let foreignNotify = "notify = [\"/usr/local/bin/ding\"]\n"
    expect(CodexConfigTOML.strippingOwnHooks(from: foreignNotify) == foreignNotify, "keepsForeignNotify")
    expect(!CodexConfigTOML.hasOwnInlineHook(legacy), "legacyNotifyIsNotAnInlineHook")

    // settingOwnMCPServerURL — a changed TTS port must reach Codex. Before this, Connect only
    // ADDED the table when missing, so an existing `url = "http://localhost:8000/mcp"` stayed
    // forever and Codex lost `speak` the moment the port changed.
    do {
        let url = "http://localhost:8123/mcp"
        // Missing table → appended, separated by a blank line.
        let added = CodexConfigTOML.settingOwnMCPServerURL(url, in: "model = \"o3\"\n")
        if !added.contains("[mcp_servers.OpenWhisperer]\nurl = \"\(url)\"") {
            failures.append("settingOwnMCPServerURL(missing): table not appended: \(added.debugDescription)")
        }
        if !added.hasPrefix("model = \"o3\"\n\n") { failures.append("settingOwnMCPServerURL(missing): preamble changed or no blank line") }

        // Existing table → only our url line changes; other keys in it and other tables stay.
        let existing = """
            model = "o3"

            [mcp_servers.OpenWhisperer]
            url = "http://localhost:8000/mcp"
            startup_timeout_sec = 20

            [mcp_servers.other]
            url = "http://localhost:9000/mcp"
            """
        let updated = CodexConfigTOML.settingOwnMCPServerURL(url, in: existing)
        let want = existing.replacingOccurrences(of: "url = \"http://localhost:8000/mcp\"", with: "url = \"\(url)\"")
        if updated != want { failures.append("settingOwnMCPServerURL(existing): got \(updated.debugDescription)") }
        if !updated.contains("url = \"http://localhost:9000/mcp\"") { failures.append("settingOwnMCPServerURL: touched a foreign table's url") }

        // Already right → byte-identical (Connect reports "Already configured").
        if CodexConfigTOML.settingOwnMCPServerURL(url, in: updated) != updated {
            failures.append("settingOwnMCPServerURL: not idempotent")
        }

        // Table present without a url line (hand-edited) → url inserted under the header.
        let bare = "[mcp_servers.OpenWhisperer]\nstartup_timeout_sec = 20\n"
        let fixed = CodexConfigTOML.settingOwnMCPServerURL(url, in: bare)
        if fixed != "[mcp_servers.OpenWhisperer]\nurl = \"\(url)\"\nstartup_timeout_sec = 20\n" {
            failures.append("settingOwnMCPServerURL(no url line): got \(fixed.debugDescription)")
        }

        // Trailing comment holding a "]" (review): the header must still be recognised, or a
        // duplicate table — invalid TOML, Codex refuses the whole file — gets appended.
        let commented = "[mcp_servers.OpenWhisperer] # speak [tts]\nurl = \"http://localhost:8000/mcp\"\n"
        let cm = CodexConfigTOML.settingOwnMCPServerURL(url, in: commented)
        if cm.components(separatedBy: "[mcp_servers.OpenWhisperer]").count != 2 {
            failures.append("settingOwnMCPServerURL(header with trailing comment): duplicate table appended: \(cm.debugDescription)")
        }
        if !cm.contains("url = \"\(url)\"") || !cm.contains("# speak [tts]") {
            failures.append("settingOwnMCPServerURL(header with trailing comment): url not updated or comment lost: \(cm.debugDescription)")
        }

        // hasOwnMCPServerTable: a real header counts; a commented-out one does not.
        if !CodexConfigTOML.hasOwnMCPServerTable(existing) { failures.append("hasOwnMCPServerTable: missed a real table") }
        if !CodexConfigTOML.hasOwnMCPServerTable("[ mcp_servers.OpenWhisperer ]  # x\n") { failures.append("hasOwnMCPServerTable: missed a spaced/commented header") }
        if CodexConfigTOML.hasOwnMCPServerTable("# [mcp_servers.OpenWhisperer]\n# url = \"http://localhost:8000/mcp\"\n") {
            failures.append("hasOwnMCPServerTable: a commented-out table counted as connected — a port change would re-enable it")
        }
        if CodexConfigTOML.hasOwnMCPServerTable("[mcp_servers.OpenWhispererX]\n") { failures.append("hasOwnMCPServerTable: prefix match") }

        // `url_extra = ...` is a different key and must not be rewritten.
        let lookalike = "[mcp_servers.OpenWhisperer]\nurl_extra = 1\nurl = \"http://localhost:8000/mcp\"\n"
        let la = CodexConfigTOML.settingOwnMCPServerURL(url, in: lookalike)
        if !la.contains("url_extra = 1") || !la.contains("url = \"\(url)\"") {
            failures.append("settingOwnMCPServerURL(lookalike key): got \(la.debugDescription)")
        }
    }

    return failures
}

/// Checks for `TTSPort` — the port every agent config points at.
func ttsPortFailures() -> [String] {
    var failures: [String] = []
    if TTSPort.parse(nil) != 8000 { failures.append("TTSPort.parse(nil): expected 8000") }
    if TTSPort.parse("8123\n") != 8123 { failures.append("TTSPort.parse: whitespace not trimmed") }
    for bad in ["", "abc", "80", "1023", "65536", "-1", "8000.5"] where TTSPort.parse(bad) != 8000 {
        failures.append("TTSPort.parse(\(bad.debugDescription)): expected the 8000 fallback, got \(TTSPort.parse(bad))")
    }
    if TTSPort.parse("1024") != 1024 || TTSPort.parse("65535") != 65535 { failures.append("TTSPort.parse: range ends rejected") }
    if TTSPort.mcpURL(port: 8123) != "http://localhost:8123/mcp" { failures.append("TTSPort.mcpURL: wrong shape") }
    // The default must stay what every pre-2.0.8 config already says, or every existing
    // install would read as stale and get rewritten on first launch.
    if TTSPort.mcpURL(port: TTSPort.defaultPort) != "http://localhost:8000/mcp" {
        failures.append("TTSPort: default URL changed from http://localhost:8000/mcp")
    }
    return failures
}
