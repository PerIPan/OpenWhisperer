import Foundation

/// Line-based editing of `~/.codex/config.toml`, scoped to the tables we once wrote inline. The
/// hook itself now lives in `~/.codex/hooks.json` (Codex loads both representations but warns
/// when one layer carries both), so the job here is to lift our `[[hooks.UserPromptSubmit]]`
/// tables out while leaving everything else — `[mcp_servers.OpenWhisperer]`, `[features]
/// hooks = true`, `[hooks.state]` trust hashes, foreign hooks — byte-for-byte as found. No TOML
/// parser: the file is split into sections at table headers, and only sections that are
/// unmistakably ours are dropped.
public enum CodexConfigTOML {
    static let groupHeader = "[[hooks.UserPromptSubmit]]"
    static let hookHeader = "[[hooks.UserPromptSubmit.hooks]]"

    /// A table header (or the preamble before the first one) plus the lines under it, blank
    /// lines included, so dropping a section takes its spacing with it.
    private struct Section {
        /// Header with whitespace and any trailing comment removed; nil for the preamble.
        var header: String?
        var lines: [String]

        var body: ArraySlice<String> { header == nil ? lines[...] : lines.dropFirst() }
        var hasContent: Bool {
            body.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        var isOwnHookTable: Bool {
            header == hookHeader && body.contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("command") && HooksJSON.isOwnHook(t)
            }
        }
    }

    private static func sections(_ lines: [String]) -> [Section] {
        var out: [Section] = []
        var current = Section(header: nil, lines: [])
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[") else {
                current.lines.append(line)
                continue
            }
            if current.header != nil || !current.lines.isEmpty { out.append(current) }
            // Cut at the FIRST run of closing brackets, not the last "]": a trailing comment
            // holding a "]" (`[mcp_servers.OpenWhisperer] # speak [tts]`) used to stay in the
            // header, so the table went unrecognised and a duplicate — invalid TOML, which Codex
            // refuses to load at all — was appended.
            var close = t.firstIndex(of: "]") ?? t.endIndex
            while close < t.endIndex, t[close] == "]" { close = t.index(after: close) }
            current = Section(header: String(t[..<close].filter { !$0.isWhitespace }), lines: [line])
        }
        out.append(current)
        return out
    }

    /// True while the pre-hooks.json app's inline `[[hooks.UserPromptSubmit.hooks]]` table is
    /// still there — the cue that an install needs migrating.
    public static func hasOwnInlineHook(_ toml: String) -> Bool {
        sections(toml.components(separatedBy: "\n")).contains { $0.isOwnHookTable }
    }

    /// Remove our inline hook table, the bare `[[hooks.UserPromptSubmit]]` we wrote to hold it
    /// (only if nothing else is left in it), and the legacy `notify = [...]` line of the
    /// pre-MCP Stop-style hook. Returns the input unchanged when none of those are present.
    public static func strippingOwnHooks(from toml: String) -> String {
        let lines = toml.components(separatedBy: "\n").filter { !isOwnNotifyLine($0) }
        var secs = sections(lines)
        secs.removeAll { $0.isOwnHookTable }
        var kept: [Section] = []
        for (i, s) in secs.enumerated() {
            let followedByHookTable = i + 1 < secs.count && secs[i + 1].header == hookHeader
            if s.header == groupHeader && !s.hasContent && !followedByHookTable { continue }
            kept.append(s)
        }
        return kept.flatMap { $0.lines }.joined(separator: "\n")
    }

    static let mcpHeader = "[mcp_servers.OpenWhisperer]"

    /// Whether our `[mcp_servers.OpenWhisperer]` table is present — as a real table header, so a
    /// commented-out `# [mcp_servers.OpenWhisperer]` does not count. The old substring check
    /// said "connected" for exactly that, and a port change would then have appended a live
    /// table the user had deliberately disabled.
    public static func hasOwnMCPServerTable(_ toml: String) -> Bool {
        sections(toml.components(separatedBy: "\n")).contains { $0.header == mcpHeader }
    }

    /// Point our `[mcp_servers.OpenWhisperer]` table at `url`, adding the table when it's
    /// missing. Only that table's `url` line changes — another key in it (a user's
    /// `startup_timeout_sec`) and every other table stay byte-for-byte. Idempotent.
    ///
    /// Connect used to add the table only when absent, so once written, the URL never changed:
    /// moving the TTS server off :8000 silently cost Codex its `speak` tool.
    public static func settingOwnMCPServerURL(_ url: String, in toml: String) -> String {
        let urlLine = "url = \"\(url)\""
        var secs = sections(toml.components(separatedBy: "\n"))
        if let i = secs.firstIndex(where: { $0.header == mcpHeader }) {
            var lines = secs[i].lines
            if let j = lines.indices.dropFirst().first(where: { isURLKey(lines[$0]) }) {
                let indent = lines[j].prefix { $0 == " " || $0 == "\t" }
                lines[j] = indent + urlLine
            } else {
                lines.insert(urlLine, at: 1)
            }
            secs[i].lines = lines
            return secs.flatMap { $0.lines }.joined(separator: "\n")
        }
        var out = toml
        while !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
        return out + mcpHeader + "\n" + urlLine + "\n"
    }

    /// The bare `url` key — not `url_extra`, not a comment.
    private static func isURLKey(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("url") else { return false }
        guard let f = t.dropFirst(3).first else { return false }
        return f == " " || f == "=" || f == "\t"
    }

    /// `notify = [...]` naming our old hook — matched on the bare key so `notify_on_error` and a
    /// user's unrelated notify are left alone.
    private static func isOwnNotifyLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("notify") else { return false }
        let rest = t.dropFirst("notify".count)
        guard let f = rest.first, f == " " || f == "=" || f == "\t" else { return false }
        return t.contains("codex-tts-hook") || t.contains("OpenWhisperer")
    }
}
