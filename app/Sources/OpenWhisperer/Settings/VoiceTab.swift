import SwiftUI
import OpenWhispererKit

struct VoiceTab: View {
    @State private var selectedVoice = "af_heart"
    @State private var selectedSpeed = Double(TTSSpeed.default)
    @State private var selectedVolume = 1.0
    @State private var selectedStyle = "normal"
    @State private var selectedResponse = "voice"
    @State private var loaded = false

    private static let styleLevels: [(id: String, label: String)] = [
        ("terse", "Terse"), ("normal", "Normal"), ("rich", "Rich"), ("full", "Full"),
    ]
    // Display labels only — the written values stay `voice`/`always`
    // (the tts_response_mode values read by voice-context.sh).
    private static let responseModes: [(id: String, label: String)] = [
        ("voice", "Only dictated turns"), ("always", "Every turn"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Voice", selection: $selectedVoice) {
                    ForEach(TTSVoiceRegistry.groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.voices, id: \.id) { v in
                                Text("\(v.name) (\(v.gender.prefix(1)))").tag(v.id)
                            }
                        }
                    }
                }
                .onChange(of: selectedVoice) { _, newValue in
                    guard loaded else { return }
                    try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
                }

                // Continuous sliders — a step: would draw tick marks. The write rounds
                // to 2 decimals and TTSSpeed/TTSVolume clamp on read, so no snapping
                // is needed. Bounds MUST equal TTSSpeed.min/max (see TTSSpeed.swift).
                LabeledContent("Speed") {
                    HStack(spacing: 8) {
                        Slider(value: $selectedSpeed, in: 0.7...1.5)
                        Text(multiplierLabel(selectedSpeed))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .onChange(of: selectedSpeed) { _, newValue in
                    guard loaded else { return }
                    try? String(format: "%.2f", newValue)
                        .write(to: Paths.ttsSpeed, atomically: true, encoding: .utf8)
                }

                // Bounds MUST equal TTSVolume.min/max (see TTSVolume.swift).
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Slider(value: $selectedVolume, in: 0.3...2.0)
                        Text(multiplierLabel(selectedVolume))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .onChange(of: selectedVolume) { _, newValue in
                    guard loaded else { return }
                    try? String(format: "%.2f", newValue)
                        .write(to: Paths.ttsVolume, atomically: true, encoding: .utf8)
                }
            }

            Section {
                Picker("Reply detail", selection: $selectedStyle) {
                    ForEach(Self.styleLevels, id: \.id) { Text($0.label).tag($0.id) }
                }
                .onChange(of: selectedStyle) { _, newValue in
                    guard loaded else { return }
                    try? newValue.write(to: Paths.ttsStyle, atomically: true, encoding: .utf8)
                }
                Picker("Speak replies", selection: $selectedResponse) {
                    ForEach(Self.responseModes, id: \.id) { Text($0.label).tag($0.id) }
                }
                .onChange(of: selectedResponse) { _, newValue in
                    guard loaded else { return }
                    try? newValue.write(to: Paths.ttsResponseMode, atomically: true, encoding: .utf8)
                }
            } header: {
                Text("Response")
            } footer: {
                Text("\"Only dictated turns\" speaks replies to voice input; \"Every turn\" speaks typed turns too.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    /// Formats a playback multiplier (speed or volume) as a trimmed "1.5×" / "1×".
    private func multiplierLabel(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s + "×"
    }

    private func load() {
        if let savedVoice = try? String(contentsOf: Paths.ttsVoice, encoding: .utf8),
           !savedVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let voice = savedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
            if TTSVoiceRegistry.allVoices.contains(where: { $0.id == voice }) {
                selectedVoice = voice
            }
        }
        selectedSpeed = Double(TTSSpeed.parse(try? String(contentsOf: Paths.ttsSpeed, encoding: .utf8)))
        selectedVolume = Double(TTSVolume.parse(try? String(contentsOf: Paths.ttsVolume, encoding: .utf8)))
        if let savedStyle = try? String(contentsOf: Paths.ttsStyle, encoding: .utf8),
           !savedStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let style = savedStyle.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.styleLevels.contains(where: { $0.id == style }) { selectedStyle = style }
        }
        if let savedResponse = try? String(contentsOf: Paths.ttsResponseMode, encoding: .utf8),
           !savedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mode = savedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.responseModes.contains(where: { $0.id == mode }) { selectedResponse = mode }
        }
        DispatchQueue.main.async { loaded = true }
    }
}
