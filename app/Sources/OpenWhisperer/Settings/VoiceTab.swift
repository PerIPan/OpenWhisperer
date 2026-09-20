import SwiftUI
import OpenWhispererKit

/// Spoken replies (TTS output only): which voice, how fast/loud, how much, and when.
struct VoiceTab: View {
    @EnvironmentObject var serverManager: ServerManager
    /// Only for `ttsPlaying` — the same signal that drives the overlay waveform, so the
    /// preview button reflects real playback instead of a guessed duration.
    @EnvironmentObject var dictationManager: DictationManager

    @State private var selectedVoice = "af_heart"
    @State private var selectedSpeed: Double = Double(TTSSpeed.default)
    @State private var selectedVolume: Double = 1.0
    @State private var selectedStyle = "normal"
    @State private var selectedResponse = "voice"
    /// Held in state, not recomputed per redraw: each row's badge stats the filesystem,
    /// and `body` runs far more often than the cache changes.
    @State private var voiceSections: [OWPickerSection] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OWCard {
                VStack(alignment: .leading, spacing: 10) {
                    OWCardHeader(title: "Sound", icon: "speaker.wave.2.fill",
                                 help: "The voice that reads replies aloud, and how fast and loud it speaks. Non-default voices download on first use.")

                    OWPickerRow(label: "Voice", labelWidth: 74) {
                        HStack(spacing: 6) {
                            OWSearchablePicker(
                                selection: $selectedVoice,
                                sections: voiceSections,
                                placeholder: "Search voices…",
                                emptyLabel: "Select voice…",
                                currentLabelOverride: SettingsData.voiceLabel(selectedVoice)
                            )
                            .frame(maxWidth: .infinity)

                            Button {
                                preview()
                            } label: {
                                Image(systemName: dictationManager.ttsPlaying ? "speaker.wave.2.fill" : "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(OWColor.accent)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Hear this voice read a fixed sample in its own language. It previews the voice, not the persona — a persona changes the words the model writes, not how the voice sounds.")
                        }
                    }
                    .onChange(of: selectedVoice) { _, newValue in
                        try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
                        // Cache state changes as soon as a preview or reply downloads a
                        // pack, and the section list bakes it into each row's badge.
                        voiceSections = SettingsData.voiceSections
                        }

                    // The genuinely surprising half of picking a non-English voice: the
                    // model is told to write the spoken text in that language by default
                    // (resolve_language_line in voice-shared.sh), and the engine follows
                    // whatever language it actually writes (TTSLanguageFollow), so replies
                    // switch with the conversation unless tts_language pins one.
                    if let language = SettingsData.voiceLanguageName(selectedVoice) {
                        Text("Replies are spoken in \(language) by default and follow the language you write in. Your on-screen reply stays in the language of the conversation.")
                            .font(OWFont.caption())
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // The persona a voice carries lives on the Agents tab, not here: it
                    // instructs the model about the words it writes, not the synthesiser
                    // about how they sound. The picker's group headers still name each
                    // language's persona, so the choice is informed from this side too.
                    OWInternalDivider()

                    OWPickerRow(label: "Speed", labelWidth: 74) {
                        HStack(spacing: 8) {
                            // Bounds MUST equal TTSSpeed.min/max (see TTSSpeed.swift).
                            // Writes once on release, not on every 0.05 step.
                            OWSlider(value: $selectedSpeed, range: 0.7...1.5) {
                                try? String(format: "%.2f", selectedSpeed)
                                    .write(to: Paths.ttsSpeed, atomically: true, encoding: .utf8)
                            }
                            .help("How fast replies are read aloud. 1× is the default Kokoro rate.")
                            Text(SettingsData.multiplierLabel(selectedSpeed))
                                .font(OWFont.body(11))
                                .foregroundColor(OWColor.inkSoft)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    OWPickerRow(label: "Volume", labelWidth: 74) {
                        HStack(spacing: 8) {
                            // Bounds MUST equal TTSVolume.min/max (see TTSVolume.swift).
                            OWSlider(value: $selectedVolume, range: 0.3...2.0) {
                                try? String(format: "%.2f", selectedVolume)
                                    .write(to: Paths.ttsVolume, atomically: true, encoding: .utf8)
                            }
                            .help("How loud replies are read aloud. 1× is normal; higher may clip.")
                            Text(SettingsData.multiplierLabel(selectedVolume))
                                .font(OWFont.body(11))
                                .foregroundColor(OWColor.inkSoft)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            OWCard {
                VStack(alignment: .leading, spacing: 10) {
                    OWCardHeader(title: "Response", icon: "text.bubble",
                                 help: """
                                 How much of a reply is spoken, and on which turns.

                                 Length — Terse: one short sentence. Normal: one sentence. \
                                 Rich: a sentence or two. Full: a spoken paragraph that \
                                 explains the reasoning, not just the outcome.

                                 Speak — Only when I dictate: typed turns stay silent. \
                                 On every turn: every reply is spoken. Only when I'm needed: \
                                 speaks only when the turn ends on you — a question, a blocked \
                                 step, an approval, or a failure — and stays silent when work \
                                 simply succeeded.
                                 """)

                    OWPickerRow(label: "Length", labelWidth: 74) {
                        OWMenuPicker(selection: $selectedStyle, options: SettingsData.styleLevels)
                            .frame(maxWidth: .infinity)
                    }
                    .onChange(of: selectedStyle) { _, newValue in
                        try? newValue.write(to: Paths.ttsStyle, atomically: true, encoding: .utf8)
                    }

                    // Self-describing options — the explanatory caption is no longer needed.
                    OWPickerRow(label: "Speak", labelWidth: 74) {
                        OWMenuPicker(selection: $selectedResponse, options: SettingsData.responseModes)
                            .frame(maxWidth: .infinity)
                    }
                    .onChange(of: selectedResponse) { _, newValue in
                        try? newValue.write(to: Paths.ttsResponseMode, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    /// Speak a sample **in the selected voice's own language** — an English line read by a
    /// Greek voice would demonstrate the exact unintelligibility Supertonic-3 exists to fix.
    ///
    /// Goes through the same controller replies use, so it honors the current speed and
    /// volume and shares its barge-in: starting a preview stops whatever is already
    /// playing rather than overlapping it. On an uncached voice this triggers the normal
    /// on-demand download, which the row's "downloads" badge has already disclosed.
    private func preview() {
        let voice = selectedVoice
        let speed = Float(selectedSpeed)
        // One actor hop, not two: `bargeIn()` then `play()` as separate awaits lets a second
        // click interleave between them, and both previews end up playing in sequence
        // instead of the second replacing the first.
        Task {
            await serverManager.playback.replaceNow(
                text: TTSSampleText.sample(forVoiceID: voice), voice: voice, speed: speed)
        }
    }

    private func load() {
        voiceSections = SettingsData.voiceSections
        selectedVolume = Double(TTSVolume.parse(try? String(contentsOf: Paths.ttsVolume, encoding: .utf8)))
        selectedSpeed = Double(TTSSpeed.parse(try? String(contentsOf: Paths.ttsSpeed, encoding: .utf8)))
        if let savedVoice = try? String(contentsOf: Paths.ttsVoice, encoding: .utf8),
           !savedVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let voice = savedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
            if SettingsData.allVoices.contains(where: { $0.id == voice }) { selectedVoice = voice }
        }
        if let savedStyle = try? String(contentsOf: Paths.ttsStyle, encoding: .utf8) {
            let style = savedStyle.trimmingCharacters(in: .whitespacesAndNewlines)
            // "full" is a real tier again (2.0.0), so it no longer maps onto "rich" —
            // a stored legacy value now selects the tier it always named.
            if SettingsData.styleLevels.contains(where: { $0.id == style }) {
                selectedStyle = style
            }
        }
        if let savedMode = try? String(contentsOf: Paths.ttsResponseMode, encoding: .utf8) {
            let mode = savedMode.trimmingCharacters(in: .whitespacesAndNewlines)
            if SettingsData.responseModes.contains(where: { $0.id == mode }) { selectedResponse = mode }
        }
    }
}
