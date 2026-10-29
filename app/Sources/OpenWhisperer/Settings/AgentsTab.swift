import SwiftUI
import OpenWhispererKit

/// Which coding agents can speak. All four are listed with their own status and
/// Connect button — you can run several agents, so a single-select picker misled.
struct AgentsTab: View {
    /// Connection state per platform, refreshed on appear and after each connect.
    @State private var connected: [Platform: Bool] = [:]
    /// Result of the most recent connect, kept until the next one (failures must not
    /// vanish on a timer).
    @State private var lastResult: (platform: Platform, ok: Bool, message: String)?
    /// Mirrors the stored voice so "Automatic" can name what it resolves to. Reloaded on
    /// appear, since the voice is changed on a different tab.
    @State private var selectedVoice = TTSVoiceRouter.defaultVoice
    @State private var selectedPersona = VoicePersona.automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OWCard {
                VStack(alignment: .leading, spacing: 10) {
                    OWCardHeader(title: "Coding agents", icon: "wand.and.stars",
                                 help: "Connect an agent so its replies are spoken aloud. Connecting writes that agent's hook and speak tool; you can connect as many as you use.")

                    ForEach(Array(Platform.allCases.enumerated()), id: \.element) { index, platform in
                        if index > 0 { OWInternalDivider() }
                        agentRow(platform)
                    }
                }
            }

            // Persona sits with the agents, not with the voice: it is an instruction to the
            // model about the words it writes, and never reaches the synthesiser. Its own
            // card because it is not per-agent — the hooks never read `selected_platform`,
            // so one persona applies to every connected agent. Per-*project* variation is
            // the only axis there is, via OW_TTS_PERSONA.
            OWCard {
                VStack(alignment: .leading, spacing: 10) {
                    OWCardHeader(title: "Persona", icon: "theatermasks",
                                 help: "A light national character the model is told to adopt when it writes a spoken reply. Tone only — it never changes what gets done, and never changes how the voice sounds. Applies to every connected agent; override per project with OW_TTS_PERSONA.")

                    OWPickerRow(label: "Persona", labelWidth: 74) {
                        OWMenuPicker(selection: $selectedPersona,
                                     options: SettingsData.personaOptions(for: selectedVoice))
                            .frame(maxWidth: .infinity)
                    }
                    .onChange(of: selectedPersona) { _, newValue in
                        try? newValue.write(to: Paths.ttsPersona, atomically: true, encoding: .utf8)
                    }

                    if let line = VoicePersona.disclosure(voiceID: selectedVoice,
                                                          override: selectedPersona) {
                        Text(line)
                            .font(OWFont.caption())
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // The voice lives on another tab, so name the one Automatic is following
                    // — otherwise "Automatic (American)" is a claim with no visible source.
                    Text("Following \(SettingsData.voiceLabel(selectedVoice)), set in Settings → Voice.")
                        .font(OWFont.caption())
                        .foregroundColor(OWColor.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let result = lastResult {
                OWCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(result.ok ? OWColor.live : OWColor.danger)
                            Text(result.message)
                                .font(OWFont.body(11))
                                .foregroundColor(OWColor.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // The post-connect step is a hard blocker, so it stays on screen
                        // instead of living in a tooltip.
                        if result.ok, let step = nextStep(for: result.platform) {
                            Text(step)
                                .font(OWFont.caption())
                                .foregroundColor(OWColor.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .onAppear {
            refreshAll()
            loadPersona()
        }
    }

    private func agentRow(_ platform: Platform) -> some View {
        let isConnected = connected[platform] ?? false
        return HStack(spacing: 8) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundColor(isConnected ? OWColor.live : OWColor.inkFaint)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(platform.label)
                        .font(OWFont.body(12))
                        .foregroundColor(OWColor.ink)
                    // Visible ⓘ: spells out exactly which files connecting touches.
                    OWInfoTip(text: connectHelp(for: platform))
                    // Setup instructions live next to the agent they describe, not beside the
                    // Connect button where a text link competed with the row's primary action.
                    Button { ConfigManager.showHookInstructions(for: platform) } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 11))
                            .foregroundColor(OWColor.inkFaint)
                    }
                    .buttonStyle(.plain)
                    .help("How it works")
                    .accessibilityLabel("How \(platform.label) works")
                }
                Text(isConnected ? "Connected" : "Not connected")
                    .font(OWFont.caption())
                    .foregroundColor(isConnected ? OWColor.inkSoft : OWColor.inkFaint)
            }

            Spacer(minLength: 6)

            Button(isConnected ? "Reconnect" : "Connect") { connect(platform) }
                .buttonStyle(OWRowButtonStyle(tinted: isConnected, urgent: !isConnected))
                .frame(width: 104)
        }
    }

    /// Re-read on every appear: the voice is chosen on another tab, and changing it can
    /// retire the Supertonic-only personas this picker was offering.
    private func loadPersona() {
        if let saved = try? String(contentsOf: Paths.ttsVoice, encoding: .utf8) {
            let voice = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if SettingsData.allVoices.contains(where: { $0.id == voice }) { selectedVoice = voice }
        }
        var persona = VoicePersona.automatic
        if let saved = try? String(contentsOf: Paths.ttsPersona, encoding: .utf8) {
            let stored = saved.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if stored == VoicePersona.automatic || VoicePersona.forID(stored) != nil { persona = stored }
        }
        // A persona no longer offered for this voice falls back rather than sitting in the
        // picker with no matching row while the hook goes on applying it.
        if !SettingsData.personaOptions(for: selectedVoice).contains(where: { $0.id == persona }) {
            persona = VoicePersona.automatic
            try? persona.write(to: Paths.ttsPersona, atomically: true, encoding: .utf8)
        }
        selectedPersona = persona
    }

    private func connect(_ platform: Platform) {
        let result = ConfigManager.applyHook(for: platform)
        lastResult = (platform, result.success, result.message)
        // Keep `selected_platform` pointing at the most recently connected agent —
        // it's what first-run instructions default to.
        if result.success { platform.save() }
        refreshAll()
    }

    private func refreshAll() {
        var next: [Platform: Bool] = [:]
        for platform in Platform.allCases {
            next[platform] = ConfigManager.checkHookConfigured(for: platform)
        }
        connected = next
    }

    /// The manual step each agent needs after being connected.
    private func nextStep(for platform: Platform) -> String? {
        switch platform {
        case .claudeCode:
            return "Start a new Claude Code session to pick up the hook."
        case .codexCLI:
            return "Codex skips untrusted hooks — approve the Open Whisperer hook once when Codex prompts you."
        case .pi:
            return "Run /reload in Pi to load the extension."
        case .antigravity:
            return "Start a new agy session to pick up the hook."
        }
    }

    private func connectHelp(for platform: Platform) -> String {
        switch platform {
        case .claudeCode:
            return "Writes the UserPromptSubmit hook into ~/.claude/settings.json and the speak MCP server into ~/.claude.json. Re-applies cleanly on rebuild."
        case .codexCLI:
            return "Writes the speak MCP server into ~/.codex/config.toml and the UserPromptSubmit hook into ~/.codex/hooks.json. Re-applies cleanly on rebuild."
        case .pi:
            return "Copies the Open Whisperer extension into ~/.pi/agent/extensions/ (Pi is MCP-free)."
        case .antigravity:
            return "Writes the speak MCP server into ~/.gemini/config/mcp_config.json and the PreInvocation hook into ~/.gemini/config/hooks.json."
        }
    }
}
