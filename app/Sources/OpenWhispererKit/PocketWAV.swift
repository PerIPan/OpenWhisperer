import Foundation

/// The program's WAV as playable samples, and samples back to a WAV for `/v1/audio/speech`.
///
/// The program writes 24 kHz mono 16-bit PCM to a pipe, so the header's size fields are
/// placeholders: the data is whatever follows the 44-byte header. Each clip gets its voice's gain
/// and has its quiet before the first sound cut to `leadSeconds` — Estia measured Pocket's clips
/// opening on 0.45–0.5 s of near silence against af_heart's 0.3 s, putting the first sound
/// 155–280 ms later than it needs to be.
public enum PocketWAV {
    public struct Invalid: Error, Equatable {
        public let reason: String
    }

    public static let sampleRate = 24_000
    static let headerBytes = 44
    /// The quiet kept before the first sound.
    public static let leadSeconds = 0.1
    /// The first sound: the first 10 ms whose RMS reaches −50 dBFS (the program's near silence
    /// and a breath before a word stay under it).
    static let soundLevel: Float = 0.003_16

    /// Samples in −1…1 at `sampleRate`, gain applied (clipped), leading quiet trimmed.
    public static func samples(fromWAV wav: Data, gainDB: Double) throws -> [Float] {
        let bytes = [UInt8](wav.prefix(headerBytes))
        guard bytes.count == headerBytes else { throw Invalid(reason: "short") }
        func ascii(_ at: Int, _ text: String) -> Bool { Array(bytes[at..<at + 4]) == Array(text.utf8) }
        func le16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func le32(_ at: Int) -> Int { le16(at) | le16(at + 2) << 16 }
        guard ascii(0, "RIFF"), ascii(8, "WAVE"), ascii(12, "fmt "), le32(16) == 16, ascii(36, "data") else {
            throw Invalid(reason: "not a WAV")
        }
        guard le16(20) == 1, le16(22) == 1, le32(24) == sampleRate, le16(34) == 16 else {
            throw Invalid(reason: "not 24 kHz mono 16-bit PCM")
        }
        let pcm = wav.dropFirst(headerBytes)
        let count = pcm.count / 2
        guard count > 0 else { throw Invalid(reason: "no audio") }
        let gain = Float(pow(10, gainDB / 20))
        var out = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = max(-1, min(1, Float(v) / 32767 * gain))
            }
        }
        return trimLead(out)
    }

    /// `samples` from `leadSeconds` before the first window that reaches `soundLevel`; all of it
    /// when nothing does (silence stays silence rather than becoming empty).
    static func trimLead(_ samples: [Float]) -> [Float] {
        let window = sampleRate / 100
        var start = 0
        while start + window <= samples.count {
            var sum: Float = 0
            for s in samples[start..<start + window] { sum += s * s }
            if (sum / Float(window)).squareRoot() >= soundLevel {
                let keep = Int(leadSeconds * Double(sampleRate))
                return Array(samples[max(0, start - keep)...])
            }
            start += window
        }
        return samples
    }

    /// A 16-bit mono WAV of `samples` at `sampleRate` (full scale −1…1; louder is clipped,
    /// non-finite is silence).
    public static func wav(_ samples: [Float]) -> Data {
        let dataBytes = samples.count * 2
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var out = Data()
        out.reserveCapacity(headerBytes + dataBytes)
        out += Array("RIFF".utf8) + le32(36 + dataBytes) + Array("WAVEfmt ".utf8)
        out += le32(16) + le16(1) + le16(1) + le32(sampleRate) + le32(sampleRate * 2) + le16(2) + le16(16)
        out += Array("data".utf8) + le32(dataBytes)
        var pcm = [UInt8](repeating: 0, count: dataBytes)
        for (i, s) in samples.enumerated() {
            let clipped = s.isFinite ? max(-1, min(1, s)) : 0
            let v = UInt16(bitPattern: Int16((clipped * 32767).rounded()))
            pcm[i * 2] = UInt8(v & 0xFF)
            pcm[i * 2 + 1] = UInt8(v >> 8)
        }
        out += pcm
        return out
    }
}
