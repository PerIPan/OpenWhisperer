import Foundation

/// A file Pocket TTS needs, pinned by sha256: where it comes from and its name in Pocket's folder.
public struct PocketFile: Sendable, Equatable {
    /// Path under Pocket's folder (`models/pocket-tts/`), e.g. `voices/jane.safetensors`.
    public let name: String
    /// Where it is downloaded from — nil for a file that ships inside the app (Heart).
    public let url: URL?
    public let sha256: String
    public let bytes: Int

    public init(name: String, url: URL?, sha256: String, bytes: Int) {
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
    }
}

/// One Pocket TTS voice: a precomputed voice state the program loads with `--voice`.
public struct PocketVoice: Sendable, Equatable {
    /// The name inside the id (`pocket:<name>`), lowercase.
    public let name: String
    public let displayName: String
    public let gender: String
    /// "US" / "UK", or "" where the speaker's accent is not documented (Alba).
    public let region: String
    /// The persona key the hook's `voice_persona_key()` gives this voice: `a` (American English)
    /// or `b` (British English), nil for none. **Mirrors the hook** — `HookTests` holds them equal.
    public let personaKey: Character?
    /// Loudness correction applied to the program's output, measured by Estia to sit at af_heart's
    /// level (Heart +1.0 dB; the stock voices are hotter and come down).
    public let gainDB: Double
    public let file: PocketFile
    /// Ships inside the app (Resources/pocket) — never downloaded.
    public let bundled: Bool
    /// The Kokoro voice that says a line when Pocket can't: af_heart for the female voices (Heart
    /// *is* af_heart), am_michael for alba and michael — so a stand-in never changes the speaker's
    /// sex mid-reply (Estia's rule).
    public var kokoroStandIn: String { gender == "Male" ? "am_michael" : "af_heart" }

    public var id: String { PocketTTS.prefix + name }
}

/// Pocket TTS (Kyutai Labs): the default English engine since 2.1, replacing Kokoro as the voice
/// people hear, with Kokoro kept as the stand-in for any line Pocket can't say.
///
/// **What it is and how it runs — taken from Estia (local-assistant 0.9.8, `tools/voice/`), which
/// measured all of it; don't re-derive.** The pinned Rust program `pocket-tts` 3.3.0 (release
/// v4.0.1, MIT) is run **once per sentence**: text on stdin, a 24 kHz mono 16-bit WAV on stdout —
/// the format `AudioPlaybackEngine` already plays, so nothing is resampled. There is no resident
/// mode: the program's `serve` mode is a web server (CORS for kyutai.org, voices fetched from the
/// web), and the resident Python package measured slower on 4 of 5 lines. It runs on the **CPU**,
/// int8, under `sandbox-exec` (no network, no other program, no file written), so it never
/// queues behind WhisperKit on the Neural Engine.
///
/// Measured on an M3 MacBook Air, 16 GB, 2026-10-29 (Heart, warm page cache, process start and
/// model load included): a typical 80-character sentence (4.2 s of speech) in **360 ms on 1
/// thread, 305 ms on 2, 285 ms on 4**; Kokoro on the Neural Engine, warm and resident, 250–270 ms
/// for the same line. Two threads: near parity with Kokoro for the first sound, and the rest of a
/// reply is synthesized while the first sentence plays. Peak RSS 505 MB, transient per run.
///
/// **Heart** is Kokoro-82M's af_heart (hexgrad, Apache 2.0) cloned once onto Pocket TTS with
/// Kyutai's gated cloning model (`kyutai/pocket-tts` @ db04f0e6, CC BY 4.0) and written out by the
/// pinned program's `export-voice` — Estia's file, byte for byte. The **100M** model only: on the
/// 18M its questions lose their rise (−0.1 semitones against +3.2). The model files come from the
/// non-gated `kyutai/pocket-tts-without-voice-cloning`, which cannot clone a voice.
public enum PocketTTS {
    public static let prefix = "pocket:"
    public static let defaultVoiceName = "heart"
    public static var defaultVoiceID: String { prefix + defaultVoiceName }

    // MARK: - The program (bundled into the app by build-dmg.sh; HookTests holds the script's pins equal to these)

    public static let releaseURL = URL(string:
        "https://github.com/kyutai-labs/pocket-tts/releases/download/v4.0.1/pocket-tts-3.3.0-aarch64-apple-darwin.tar.gz")!
    public static let releaseTarballSHA256 = "ee9ca6c7c000ee72c5846e3a8ba01d08f56636d94a614d2259c3f12b8fd69afa"
    public static let programSHA256 = "447d95181e133b3fda268d248126041722cf1bdf767093f44f2a0d047ab192be"
    public static let licenseSHA256 = "23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3"

    // MARK: - The model (downloaded on first run, each file at a pinned commit)

    static let hub = "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve"
    static func hubURL(_ revision: String, _ path: String) -> URL { URL(string: "\(hub)/\(revision)/\(path)")! }
    static let modelRevision = "a7056f505a4a8ca72d8b5fb1440071d6f1a35739"

    public static let weights = PocketFile(
        name: "model.safetensors",
        url: hubURL(modelRevision, "languages/english/model.safetensors"),
        sha256: "4c56cbd171c63e8a26ea61f5d48b8a0cd8f3c51f4652c0ab9a19bfcced8c931d", bytes: 219_029_196)
    public static let tokenizer = PocketFile(
        name: "tokenizer.json",
        url: hubURL("00eac05ed3d16bdc3f6b5d598874019c34a89214", "languages/english/tokenizer.json"),
        sha256: "f498428e1eafee50492f7be13dc9bfafcfc12e508cd0eb1b01c92ecd5d8c6687", bytes: 245_020)

    static func stockVoice(_ name: String, _ display: String, _ gender: String, _ region: String,
                           persona: Character?, gain: Double, revision: String = modelRevision,
                           sha256: String, bytes: Int) -> PocketVoice {
        PocketVoice(
            name: name, displayName: display, gender: gender, region: region, personaKey: persona, gainDB: gain,
            file: PocketFile(name: "voices/\(name).safetensors",
                             url: hubURL(revision, "languages/english/embeddings/\(name).safetensors"),
                             sha256: sha256, bytes: bytes),
            bundled: false)
    }

    /// Every voice, in picker order: Heart (ships with the app, the default), then the stock voices,
    /// downloaded the first time they are used (~6–7 MB each). Accents, for the personas: Jane is
    /// VCTK p339 (American, Pennsylvania), Eve p361 and Michael p360 (American, New Jersey), Vera
    /// p229 (English, Southern England); Alba MacKenna's accent is not documented, so she gets no
    /// persona — the same rule as any voice the hook can't place. Alba is listed as male: the
    /// owner's ear (Estia, 26 Oct: "alba & michael for males").
    public static let voices: [PocketVoice] = [
        PocketVoice(
            name: "heart", displayName: "Heart", gender: "Female", region: "US", personaKey: "a", gainDB: 1.0,
            file: PocketFile(name: "heart.safetensors", url: nil,
                             sha256: "60e5e6cbcac2f61554adcfc1ffd9830308802a3685db49489f5a14e8e65b5425",
                             bytes: 8_652_024),
            bundled: true),
        stockVoice("jane", "Jane", "Female", "US", persona: "a", gain: -4.0,
                   sha256: "f802b7b0ce91578dc5448e1cdf4827695e64a34cc6b2f95989dc335082522887", bytes: 7_325_496),
        stockVoice("eve", "Eve", "Female", "US", persona: "a", gain: -3.5,
                   revision: "a3055dcb533cf2ec90458008a01e7cef550bae2a",
                   sha256: "d31289743fdf306517925afb91e99c27b4d336c127013d2c4d1212791a41cf37", bytes: 6_145_848),
        stockVoice("vera", "Vera", "Female", "UK", persona: "b", gain: -5.5,
                   sha256: "fe136ebb9c88b65803e73ab8fc04fcc7faaa5aa790559bdab3d2382826eea44a", bytes: 6_686_520),
        stockVoice("alba", "Alba", "Male", "", persona: nil, gain: -7.0,
                   sha256: "5850f417028fb2bf6de31e5e395e56ee7a21ac0e52ef31aebd4a6a2847d72e9c", bytes: 6_244_152),
        stockVoice("michael", "Michael", "Male", "US", persona: "a", gain: -4.5,
                   sha256: "9f6538650ed3b664ab847d05244f51f04db22ce7ea00e2b285f51d91d6308ce0", bytes: 7_128_888),
    ]

    public static func voice(named name: String) -> PocketVoice? {
        let key = name.lowercased()
        return voices.first { $0.name == key }
    }

    /// The voice a `pocket:<name>` id names, nil for anything else (an unknown name included).
    public static func voice(forID id: String) -> PocketVoice? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        return voice(named: String(trimmed.dropFirst(prefix.count)))
    }

    /// Whether `id` carries the Pocket prefix at all (known name or not).
    public static func isPocketID(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(prefix)
    }

    // MARK: - One run

    /// CPU threads per run (`RAYON_NUM_THREADS`). Two: ~55 ms off the first sound against one,
    /// within ~20 ms of four (measured above); Estia uses one because Gemma owns that Mac's cores.
    public static let threads = 2

    /// The longest one run may take: a measured base and a few ms a character (Estia, 24–26 Oct: a
    /// 1,500-character text under 5 s; 10 ms a character survived a busy Mac where 5 ms did not).
    /// Past it the run is killed and Kokoro says the line.
    public static func runSeconds(for text: String) -> TimeInterval { 2 + 0.01 * Double(text.count) }

    /// The most WAV bytes a run may write — two minutes of speech is 5.8 MB.
    public static let maxOutputBytes = 16 << 20

    public static let sandboxExec = "/usr/bin/sandbox-exec"

    /// Estia's profile, with the user's home in place of hers: no network, no other program, no
    /// file written, no signal to another process, no macOS service; the home is closed except
    /// Pocket's own folder, and the app bundle (program + Heart) is readable wherever it lives.
    /// SBPL takes the last matching rule, so the allows after the home deny reopen exactly those.
    public static let sandboxProfile = """
        (version 1)
        (allow default)
        (deny network*)
        (deny process-fork)
        (deny process-exec*)
        (allow process-exec (literal (param "PROGRAM_FILE")))
        (deny file-write*)
        (allow file-write* (literal "/dev/null"))
        (deny file-read* (subpath (param "HOME_DIR")))
        (allow file-read* (subpath (param "POCKET")))
        (allow file-read* (subpath (param "APP")))
        (deny signal)
        (allow signal (target self))
        (deny mach-lookup)
        """

    /// argv for one run: the sandbox wrapping the program, which reads its text from stdin and
    /// writes the WAV to stdout. Paths must already be resolved (`realpath`): the sandbox matches
    /// the real path, and `/var` → `/private/var` style links would otherwise slip past it.
    public static func arguments(program: String, config: String, voice: String,
                                 pocketFolder: String, app: String, home: String) -> [String] {
        [
            sandboxExec, "-p", sandboxProfile,
            "-D", "HOME_DIR=\(home)", "-D", "POCKET=\(pocketFolder)", "-D", "APP=\(app)",
            "-D", "PROGRAM_FILE=\(program)",
            program, "generate", "-q", "--quantize", "--config", config, "--voice", voice,
            "--text", "-", "--output-path", "-",
        ]
    }

    /// The run's whole environment — nothing of the app's own. `HF_HUB_OFFLINE` keeps the program
    /// from ever reaching for the network (the sandbox would refuse anyway).
    public static func environment(pocketFolder: String) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": pocketFolder,
         "RAYON_NUM_THREADS": String(threads), "HF_HUB_OFFLINE": "1"]
    }

    /// The program's config for the checked weights and tokenizer. Paths in single quotes (YAML's
    /// plain scalars would end at " #"), a quote inside doubled.
    public static func configText(weights: String, tokenizer: String) -> String {
        func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "''") + "'" }
        return englishConfig
            .replacingOccurrences(of: "{weights}", with: quoted(weights))
            .replacingOccurrences(of: "{tokenizer}", with: quoted(tokenizer))
    }

    /// The 100M English model's config, as Estia's (the program's own `english_2026-10.yaml`
    /// with the two paths left open).
    static let englishConfig = """
        # Default English model: identical weights to english_2026-10.yaml.

        weights_path: {weights}
        # Human evals preferred this model at 0.3 (equal WER/similarity/speech rate).
        default_temperature: 0.3


        # Replace characters that are absent from the training data.
        replace_characters:
          '’': "'"
          '‘': "'"

        flow_lm:
          insert_bos_before_voice: true
          dtype: float32
          flow:
            depth: 6
            dim: 512
          transformer:
            d_model: 1024
            hidden_scale: 4
            max_period: 10000
            num_heads: 16
            num_layers: 6
          lookup_table:
            dim: 1024
            n_bins: 4000
            tokenizer: tokenizers
            tokenizer_path: {tokenizer}

        mimi:
          dtype: float32
          sample_rate: 24000
          inner_dim: 32
          outer_dim: 512
          channels: 1
          frame_rate: 12.5
          seanet:
            dimension: 512
            channels: 1
            n_filters: 64
            n_residual_layers: 1
            ratios:
            - 6
            - 5
            - 4
            kernel_size: 7
            residual_kernel_size: 3
            last_kernel_size: 3
            dilation_base: 2
            pad_mode: constant
            compress: 2
          transformer:
            d_model: 512
            num_heads: 8
            num_layers: 2
            layer_scale: 0.01
            context: 250
            dim_feedforward: 2048
            input_dimension: 512
            output_dimensions:
            - 512
          quantizer:
            dimension: 32
            output_dimension: 512

        """
}

/// When to stop trying Pocket for a while. Three failed runs in a row rest it — 1, 5, then 30
/// minutes, every 30 after — so a broken install costs one slow line, not every line (Estia's
/// `SpeakingRetry`). Any success clears it. While resting, Kokoro speaks.
public struct PocketHealth: Sendable, Equatable {
    public static let failuresBeforeRest = 3
    public static let rests: [TimeInterval] = [60, 300, 1800]

    public private(set) var consecutiveFailures = 0
    public private(set) var restsTaken = 0
    public private(set) var restingUntil: Date?

    public init() {}

    public func isResting(at now: Date) -> Bool {
        guard let until = restingUntil else { return false }
        return now < until
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        restsTaken = 0
        restingUntil = nil
    }

    public mutating func recordFailure(at now: Date) {
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.failuresBeforeRest else { return }
        let rest = Self.rests[min(restsTaken, Self.rests.count - 1)]
        restsTaken += 1
        restingUntil = now.addingTimeInterval(rest)
        consecutiveFailures = 0
    }
}
