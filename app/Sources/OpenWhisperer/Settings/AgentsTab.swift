import SwiftUI

struct AgentsTab: View {
    @State private var selectedPlatform: Platform = .claudeCode
    @State private var hookApplied = false
    @State private var applyMessage = ""
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
                    ConfigManager.showHookInstructions(for: selectedPlatform)
                }
            } header: {
                Text("Spoken replies for your coding agent")
            } footer: {
                Text(footerText)
            }
        }
        .formStyle(.grouped)
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
