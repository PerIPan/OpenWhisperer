import SwiftUI

struct AgentsTab: View {
    @State private var selectedPlatform: Platform = .claudeCode
    @State private var hookApplied = false
    @State private var applyMessage = ""
    @State private var showingHowItWorks = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Picker("Platform", selection: $selectedPlatform) {
                    ForEach(Platform.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: selectedPlatform) { _, newValue in
                    guard loaded else { return }
                    newValue.save()
                    hookApplied = ConfigManager.checkHookConfigured(for: newValue)
                }

                LabeledContent("Voice hook") {
                    Button {
                        let result = ConfigManager.applyHook(for: selectedPlatform)
                        hookApplied = result.success
                        applyMessage = result.message
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyMessage = "" }
                    } label: {
                        Label(hookApplied ? "Applied" : "Auto-Apply",
                              systemImage: hookApplied ? "checkmark.circle.fill" : "bolt.fill")
                    }
                }

                if !applyMessage.isEmpty {
                    Text(applyMessage)
                        .font(.caption)
                        .foregroundStyle(applyMessage.lowercased().contains("fail") ? .red : .green)
                }

                Button("How it works…") {
                    showingHowItWorks = true
                }
            } header: {
                Text("Spoken replies for your AI agent")
            } footer: {
                Text(footerText)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingHowItWorks) {
            HowItWorksSheet(platform: selectedPlatform)
        }
        .onAppear {
            selectedPlatform = Platform.load()
            hookApplied = ConfigManager.checkHookConfigured(for: selectedPlatform)
            DispatchQueue.main.async { loaded = true }
        }
    }

    private var footerText: String {
        switch selectedPlatform {
        case .claudeCode:
            return "Writes the UserPromptSubmit hook into ~/.claude/settings.json and the speak MCP server into ~/.claude.json. Re-applies cleanly on rebuild."
        case .codexCLI:
            return "Writes the speak MCP server and UserPromptSubmit hook into ~/.codex/config.toml (needs one-time hook trust). Re-applies cleanly on rebuild."
        case .pi:
            return "Copies the OpenWhisperer extension into ~/.pi/agent/extensions/ (no MCP). Run /reload in Pi afterward."
        case .antigravity:
            return "Writes the speak MCP server into ~/.gemini/config/mcp_config.json and the PreInvocation hook into ~/.gemini/config/hooks.json. Start a new agy session afterward."
        }
    }
}

// MARK: - How it works (Tailscale-style sheet)

/// In-window explainer for the per-platform voice wiring. The first-run flow keeps
/// using ConfigManager's standalone InstructionWindow (shown from AppDelegate);
/// this sheet is the Settings-window affordance.
struct HowItWorksSheet: View {
    let platform: Platform
    @Environment(\.dismiss) private var dismiss

    private struct SheetSection {
        let heading: String
        let body: String
        var mono = false
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title)
                        .font(.title3.weight(.semibold))

                    ForEach(sections, id: \.heading) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.heading)
                                .font(.headline)
                            Text(section.body)
                                .font(section.mono
                                    ? .system(.callout, design: .monospaced)
                                    : .callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.quaternary.opacity(0.6),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 500)
    }

    private var title: String {
        switch platform {
        case .claudeCode: return "How voice works with Claude Code"
        case .codexCLI: return "How voice works with Codex CLI"
        case .pi: return "How voice works with Pi"
        case .antigravity: return "How voice works with Antigravity"
        }
    }

    private var sections: [SheetSection] {
        var result: [SheetSection]
        switch platform {
        case .claudeCode:
            result = [
                SheetSection(
                    heading: "What Auto-Apply does",
                    body: "OpenWhisperer adds voice to Claude Code in two pieces: a UserPromptSubmit hook that nudges Claude to speak a summary first on dictated turns, and a speak tool (MCP) that plays it through this app. Restart Claude Code afterward and verify with /mcp."),
                SheetSection(
                    heading: "Do it by hand",
                    body: """
                    # Hook — in ~/.claude/settings.json:
                    {
                      "hooks": {
                        "UserPromptSubmit": [{
                          "hooks": [{ "type": "command",
                            "command": "\(Paths.voiceContextHook.path)" }]
                        }]
                      }
                    }

                    # speak tool:
                    claude mcp add --scope user --transport http \\
                      OpenWhisperer http://localhost:8000/mcp
                    """,
                    mono: true),
            ]
        case .codexCLI:
            result = [
                SheetSection(
                    heading: "What Auto-Apply does",
                    body: "Registers the speak tool and the UserPromptSubmit voice hook in ~/.codex/config.toml. Important: Codex silently ignores untrusted hooks — the first time you run codex afterward, approve trusting the OpenWhisperer hook or spoken summaries won't fire."),
                SheetSection(
                    heading: "Do it by hand",
                    body: """
                    # In ~/.codex/config.toml:
                    [mcp_servers.OpenWhisperer]
                    url = "http://localhost:8000/mcp"

                    [[hooks.UserPromptSubmit]]

                    [[hooks.UserPromptSubmit.hooks]]
                    type = "command"
                    command = "\(Paths.voiceContextHook.path)"
                    timeout = 30
                    """,
                    mono: true),
            ]
        case .pi:
            result = [
                SheetSection(
                    heading: "What Auto-Apply does",
                    body: "Pi has no MCP. Auto-Apply copies one extension into Pi's extensions folder; it registers an openwhisperer_speak tool and a per-turn voice nudge, talking to this app's local server over HTTP. Run /reload in Pi (or restart it) to load it."),
                SheetSection(
                    heading: "Do it by hand",
                    body: """
                    cp "\(Paths.piExtensionSource.path)" \\
                       "\(Paths.piExtensionDest.path)"
                    """,
                    mono: true),
            ]
        case .antigravity:
            result = [
                SheetSection(
                    heading: "What Auto-Apply does",
                    body: "Adds voice to Antigravity (agy) in two pieces: the speak tool in ~/.gemini/config/mcp_config.json (the same endpoint Claude/Codex/Pi use) and a PreInvocation hook in ~/.gemini/config/hooks.json that nudges the model to speak first on dictated turns. Start a new agy session afterward."),
                SheetSection(
                    heading: "Do it by hand",
                    body: """
                    # ~/.gemini/config/mcp_config.json:
                    { "mcpServers": {
                        "openwhisperer": { "serverUrl": "http://localhost:8000/mcp" } } }

                    # ~/.gemini/config/hooks.json:
                    { "openwhisperer": { "PreInvocation": [
                        { "type": "command",
                          "command": "\(Paths.agyPreInvocationHook.path)",
                          "timeout": 10 } ] } }
                    """,
                    mono: true),
            ]
        }
        result.append(SheetSection(
            heading: "When replies are spoken",
            body: "By default only voice-dictated turns are spoken; typed turns stay silent. Change this in the Voice tab under \u{201C}Speak replies\u{201D}."))
        return result
    }
}
