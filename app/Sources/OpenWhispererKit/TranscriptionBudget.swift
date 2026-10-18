import Foundation

/// How long a transcription may run before the watchdog gives up on it.
///
/// **The budget grows with the audio.** It used to be a flat 35 s warm / 180 s cold. Decode time
/// scales with clip length, so a long enough dictation always lost: measured 2026-09-29, the
/// translating checkpoint decodes at ~0.3x realtime on an M-series Mac (2.0–2.3 s for a 7.7 s
/// clip), which put the ceiling at roughly 1–2 minutes of speech — exactly the "follow a meeting
/// in another language" case translation exists for. The watchdog cancels the task and the
/// audio is already drained (`exportPCMFloat()` empties the recorder), so a timeout loses
/// everything the user said. One second of budget per second of audio leaves well over 2x
/// headroom on both checkpoints, and the watchdog's real job — catching a hung decode — is
/// unaffected by being generous.
public enum TranscriptionBudget {
    /// The fixed part once the model is resident.
    public static let warmBase: TimeInterval = 35
    /// The fixed part when the model must load inside the task (first dictation, or right after a
    /// Translate switch, when the newly selected checkpoint has never been loaded).
    public static let coldBase: TimeInterval = 180
    /// Recorder output rate: 16 kHz mono.
    public static let sampleRate: Double = 16_000

    public static func seconds(warm: Bool, sampleCount: Int) -> TimeInterval {
        let audio = Double(max(0, sampleCount)) / sampleRate
        return (warm ? warmBase : coldBase) + audio
    }
}

/// The longest a hold- or press-to-talk recording may run before it is stopped and transcribed.
///
/// A forgotten press-to-talk (or a release no layer ever saw) would otherwise record without end
/// and then type the whole of it into whatever app is focused. Ten minutes is far beyond any
/// dictation; hitting it stops and transcribes — it never discards what was said. Hands-free is
/// exempt: it segments on silence by itself.
public enum RecordingCap {
    public static let seconds: TimeInterval = 600
}
