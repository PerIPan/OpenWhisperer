import Foundation
import OpenWhispererKit

/// Checks for the Pocket TTS layer: the voice table and pins, the text pass (every rule a measured
/// misreading), the WAV handling, the run's argv/env/sandbox, and the rest policy.
func pocketFailures() -> [String] {
    var failures: [String] = []
    func check(_ ok: Bool, _ what: String) { if !ok { failures.append("Pocket: \(what)") } }

    // MARK: voice table

    check(PocketTTS.defaultVoiceID == "pocket:heart", "default voice is pocket:heart (owner, 2026-10-29)")
    check(PocketTTS.voices.map(\.name) == ["heart", "jane", "eve", "vera", "alba", "michael"], "voice order")
    check(Set(PocketTTS.voices.map(\.name)).count == PocketTTS.voices.count, "voice names unique")
    check(PocketTTS.voices.filter(\.bundled).map(\.name) == ["heart"], "only Heart ships with the app")
    for v in PocketTTS.voices {
        check(v.file.sha256.count == 64 && v.file.sha256.allSatisfy(\.isHexDigit), "\(v.name): sha256 is 64 hex")
        check(v.bundled == (v.file.url == nil), "\(v.name): bundled ⇔ no download URL")
        check(v.file.bytes > 1_000_000, "\(v.name): size plausible")
        if let url = v.file.url {
            check(url.host == "huggingface.co" && url.path.contains("/kyutai/pocket-tts-without-voice-cloning/resolve/"),
                  "\(v.name): downloads from the non-gated repo, at a commit")
            check(url.path.contains("/languages/english/embeddings/\(v.name).safetensors"), "\(v.name): 100M English embeddings path")
        }
        check(v.id == "pocket:\(v.name)", "\(v.name): id shape")
    }
    check(PocketTTS.voice(named: "heart")?.gainDB == 1.0, "Heart's measured gain")
    check(PocketTTS.voices.filter { $0.gender == "Male" }.map(\.name) == ["alba", "michael"], "alba & michael for males (owner)")
    for v in PocketTTS.voices {
        check(v.kokoroStandIn == (v.gender == "Male" ? "am_michael" : "af_heart"), "\(v.name): stand-in keeps the speaker's sex")
    }
    check(PocketTTS.voice(named: "alba")?.personaKey == nil, "Alba: accent undocumented → no persona")
    check(PocketTTS.voice(named: "vera")?.personaKey == "b", "Vera: VCTK p229, Southern England → British")
    for n in ["heart", "jane", "eve", "michael"] { check(PocketTTS.voice(named: n)?.personaKey == "a", "\(n): American") }
    check(PocketTTS.voice(forID: "pocket:heart")?.name == "heart", "forID")
    check(PocketTTS.voice(forID: " POCKET:Jane ")?.name == "jane", "forID: case + whitespace")
    check(PocketTTS.voice(forID: "pocket:nobody") == nil, "forID: unknown name")
    check(PocketTTS.voice(forID: "af_heart") == nil, "forID: Kokoro id")
    check(PocketTTS.isPocketID("pocket:nobody") && !PocketTTS.isPocketID("af_heart"), "isPocketID")
    for f in [PocketTTS.weights, PocketTTS.tokenizer] {
        check(f.url?.path.contains("/languages/english/") == true, "\(f.name): 100M English model path")
    }
    check(PocketTTS.weights.bytes == 219_029_196, "weights size (verified download 2026-10-29)")

    // MARK: text pass — each rule is a measured misreading (see PocketText)

    func said(_ input: String, _ expected: String, _ why: String) {
        let got = PocketText.spoken(input)
        if got != expected { failures.append("PocketText [\(why)]: \(input.debugDescription) → \(got.debugDescription), expected \(expected.debugDescription)") }
    }
    // Left alone: Pocket reads these right as written (measured).
    for unchanged in ["The API returned an error.", "Open a PR and wait for CI to pass.", "Version 2.0.8 is out.",
                      "It took 4.2 seconds, and 340 tests passed.", "Coverage is up 12% this week.",
                      "We have 1,250 users.", "Remind me at 7:30.", "The build ran at 14:05.", "Call me at 9:05 AM.",
                      "Check the README first.", "Open GitHub in Xcode on macOS and iOS.", "Two APIs and three URLs changed."] {
        said(unchanged, unchanged, "already right")
    }
    said("It costs $5.99 a month.", "It costs 5 dollars and 99 cents a month.", "money: was cut to \"$5.\"")
    said("Only $1 left, then $2,500.", "Only 1 dollar left, then 2,500 dollars.", "money: singular, thousands")
    said("$3.00 flat.", "3 dollars flat.", "money: zero cents dropped")
    said("The meeting is at 2:00 PM.", "The meeting is at 2 PM.", "on the hour: was \"2,000 p.m.\"")
    said("Meet at 9:00 a.m. sharp.", "Meet at 9 a.m. sharp.", "on the hour, a.m.")
    said("It starts at 3:00.", "It starts at 3 o'clock.", "on the hour, 12-hour")
    said("Deploy at 14:00.", "Deploy at 14 hundred.", "on the hour, 24-hour")
    said("Pages 10-20 need review.", "Pages 10 to 20 need review.", "range: was \"1020\"")
    said("Released 2026-10-29.", "Released 2026-10-29.", "a date is not a range")
    said("Built for x86-64 and COVID-19 data.", "Built for x86-64 and COVID-19 data.", "names with digits are not ranges")
    // Review, 2026-10-29: a range at a sentence's end (where SentenceSplitter puts most of them)
    // or before a colon was missed; a comma after an amount was swallowed into it; k/M/B and
    // decimal amounts were mangled; year-months and phone numbers became ranges.
    said("I edited lines 10-20.", "I edited lines 10 to 20.", "range at sentence end")
    said("Ports 8000-8010.", "Ports 8000 to 8010.", "range at sentence end, 4 digits")
    said("See lines 10-20: they changed.", "See lines 10 to 20: they changed.", "range before a colon")
    said("It takes 2–3 days.", "It takes 2 to 3 days.", "en dash range")
    said("Python 3.10-3.12 works.", "Python 3.10-3.12 works.", "version range untouched")
    said("Steps 1-2-3 again.", "Steps 1-2-3 again.", "three-part sequence untouched")
    said("Shipped the 2026-10 build.", "Shipped the 2026-10 build.", "year-month is not a range")
    said("Call 555-1234 now.", "Call 555-1234 now.", "phone number is not a range")
    said("Open 9:00-17:00 daily.", "Open 9 o'clock to 17 hundred daily.", "time range")
    said("It costs $20, billed yearly.", "It costs 20 dollars, billed yearly.", "money: comma after amount")
    said("That is $1,000, give or take.", "That is 1,000 dollars, give or take.", "money: thousands then comma")
    said("Budgets: $5, $10 and $20.", "Budgets: 5 dollars, 10 dollars and 20 dollars.", "money: list")
    said("They raised $1.5M last year.", "They raised 1.5 million dollars last year.", "money: millions")
    said("About $2.5k a month.", "About 2.5 thousand dollars a month.", "money: thousands suffix")
    said("A $3B market.", "A 3 billion dollars market.", "money: billions")
    said("Plans are $10-20 a seat.", "Plans are 10 to 20 dollars a seat.", "money range")
    said("It was $1,000.50 exactly.", "It was 1,000 dollars and 50 cents exactly.", "money: thousands and cents")
    said("WHO is it?", "W-H-O is it?", "WHO: was \"Oh is it?\"")
    said("Ask who did it.", "Ask who did it.", "lowercase who untouched")
    said("Check the TODO list and two TODOs.", "Check the to-do list and two to-dos.", "TODO: was \"total\"")
    said("Line one.\nLine two.", "Line one. Line two.", "one line")
    said("It\u{2019}s done.", "It's done.", "plain apostrophe")

    // Pause guard: ordinary text byte for byte; only an over-long comma-less stretch is cut.
    let ordinary = "I checked the build, the tests and the release notes, and everything is ready to ship."
    check(PocketText.paced(ordinary) == ordinary, "paced: ordinary sentence unchanged")
    let long = Array(repeating: "the tests and the docs", count: 20).joined(separator: " ") + "."
    let paced = PocketText.paced(long)
    check(paced != long && paced.contains(","), "paced: long stretch gets a comma")
    check(paced.replacingOccurrences(of: ",", with: "") == long, "paced: only commas added")
    let stretches = paced.split(whereSeparator: { ",.".contains($0) })
    check(stretches.allSatisfy { $0.count <= PocketText.paceLimit }, "paced: every stretch within the limit")
    check(paced.contains(", and"), "paced: breaks before a conjunction")

    // MARK: WAV

    func header(rate: Int = 24_000, channels: Int = 1, bits: Int = 16, format: Int = 1) -> [UInt8] {
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        // Size fields as the program writes them to a pipe: placeholders.
        return Array("RIFF".utf8) + le32(0xFFFF_FFFF) + Array("WAVEfmt ".utf8) + le32(16) + le16(format)
            + le16(channels) + le32(rate) + le32(rate * 2) + le16(2) + le16(bits) + Array("data".utf8) + le32(0xFFFF_FFFF)
    }
    func pcm(_ values: [Int16]) -> [UInt8] { values.flatMap { [UInt8(UInt16(bitPattern: $0) & 0xFF), UInt8(UInt16(bitPattern: $0) >> 8)] } }

    // 0.5 s of silence, then a tone: the lead is trimmed to 0.1 s.
    let silence = [Int16](repeating: 0, count: 12_000)
    let tone = (0..<4_800).map { Int16(16_000 * sin(Double($0) * 0.2)) }
    if let s = try? PocketWAV.samples(fromWAV: Data(header() + pcm(silence + tone)), gainDB: 0) {
        let lead = s.prefix { abs($0) < 0.001 }.count
        check(abs(lead - 2_400) <= 240, "WAV: leading quiet trimmed to ~0.1 s (got \(lead) samples)")
        check(s.count >= 4_800 && s.count < 12_000 + 4_800, "WAV: tone kept, most silence gone")
    } else { failures.append("Pocket: WAV: valid clip rejected") }
    // Gain: +6 dB doubles, and is clipped.
    if let s = try? PocketWAV.samples(fromWAV: Data(header() + pcm([8_192, 30_000])), gainDB: 6.0206) {
        check(abs(s[0] - 0.5) < 0.001, "WAV: +6 dB doubles")
        check(s[1] == 1, "WAV: gain clipped at full scale")
    } else { failures.append("Pocket: WAV: gain clip rejected") }
    // All-silent: kept as is, not emptied.
    if let s = try? PocketWAV.samples(fromWAV: Data(header() + pcm([0, 0, 0])), gainDB: 0) {
        check(s.count == 3, "WAV: silence stays silence")
    }
    for (name, bad) in [("44.1 kHz", header(rate: 44_100)), ("stereo", header(channels: 2)),
                        ("float", header(format: 3)), ("8-bit", header(bits: 8))] {
        check((try? PocketWAV.samples(fromWAV: Data(bad + pcm([1, 2])), gainDB: 0)) == nil, "WAV: \(name) refused")
    }
    check((try? PocketWAV.samples(fromWAV: Data(header()), gainDB: 0)) == nil, "WAV: no audio refused")
    check((try? PocketWAV.samples(fromWAV: Data("not a wav at all, clearly not".utf8), gainDB: 0)) == nil, "WAV: junk refused")
    // Round trip through the writer.
    let written = PocketWAV.wav([0, 0.5, -0.5, 2, .nan])
    check(written.count == 44 + 10, "WAV writer: size")
    if let back = try? PocketWAV.samples(fromWAV: written, gainDB: 0) {
        // The writer emits a real header; trimming keeps everything here (quiet ≤ 0.1 s).
        check(back.count == 5 && abs(back[1] - 0.5) < 0.001 && back[3] == 1 && back[4] == 0, "WAV writer: round trip, clip, NaN→0")
    } else { failures.append("Pocket: WAV writer output not readable") }

    // MARK: one run

    let argv = PocketTTS.arguments(program: "/A/OW.app/Contents/Helpers/pocket-tts", config: "/P/english.yaml",
                                   voice: "/A/OW.app/Contents/Resources/pocket/heart.safetensors",
                                   pocketFolder: "/P", app: "/A/OW.app", home: "/Users/u")
    check(argv.first == "/usr/bin/sandbox-exec" && argv[1] == "-p" && argv[2] == PocketTTS.sandboxProfile, "argv: sandboxed")
    check(argv.contains("PROGRAM_FILE=/A/OW.app/Contents/Helpers/pocket-tts") && argv.contains("HOME_DIR=/Users/u")
          && argv.contains("POCKET=/P") && argv.contains("APP=/A/OW.app"), "argv: sandbox params")
    let tail = Array(argv.drop { $0 != "/A/OW.app/Contents/Helpers/pocket-tts" })
    check(tail.count > 1 && tail[1] == "generate" && tail.contains("--quantize") && tail.contains("-q"), "argv: generate, int8, quiet")
    check(tail.suffix(4) == ["--text", "-", "--output-path", "-"], "argv: stdin text, stdout WAV")
    check(PocketTTS.sandboxProfile.contains("(deny network*)") && PocketTTS.sandboxProfile.contains("(deny file-write*)")
          && PocketTTS.sandboxProfile.contains("(deny process-exec*)"), "sandbox: no network, no writes, no exec")
    let env = PocketTTS.environment(pocketFolder: "/P")
    check(env == ["PATH": "/usr/bin:/bin", "HOME": "/P", "RAYON_NUM_THREADS": "2", "HF_HUB_OFFLINE": "1"], "env: exactly these")
    check(PocketTTS.runSeconds(for: "") == 2 && abs(PocketTTS.runSeconds(for: String(repeating: "x", count: 1500)) - 17) < 0.001,
          "run budget: 2 s + 10 ms/char")
    let config = PocketTTS.configText(weights: "/P/model.safetensors", tokenizer: "/P/it's/tokenizer.json")
    check(config.contains("weights_path: '/P/model.safetensors'"), "config: weights path quoted")
    check(config.contains("tokenizer_path: '/P/it''s/tokenizer.json'"), "config: quote doubled")
    check(config.contains("sample_rate: 24000") && !config.contains("{weights}") && !config.contains("{tokenizer}"), "config: filled")

    // MARK: rest policy

    var h = PocketHealth()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    h.recordFailure(at: t0); h.recordFailure(at: t0)
    check(!h.isResting(at: t0), "health: two failures don't rest it")
    h.recordFailure(at: t0)
    check(h.isResting(at: t0.addingTimeInterval(59)) && !h.isResting(at: t0.addingTimeInterval(61)), "health: third failure rests 1 min")
    for _ in 0..<3 { h.recordFailure(at: t0) }
    check(h.isResting(at: t0.addingTimeInterval(299)) && !h.isResting(at: t0.addingTimeInterval(301)), "health: next rest 5 min")
    for _ in 0..<3 { h.recordFailure(at: t0) }
    for _ in 0..<3 { h.recordFailure(at: t0) }
    check(h.isResting(at: t0.addingTimeInterval(1799)) && !h.isResting(at: t0.addingTimeInterval(1801)), "health: then 30 min, capped")
    h.recordSuccess()
    check(!h.isResting(at: t0) && h.consecutiveFailures == 0 && h.restsTaken == 0, "health: success clears everything")

    // Downloads wait after a single failure (review: a failed fetch was retried on every sentence).
    var d = PocketHealth(failuresBeforeRest: 1)
    d.recordFailure(at: t0)
    check(d.isResting(at: t0.addingTimeInterval(30)) && !d.isResting(at: t0.addingTimeInterval(61)), "download backoff: one failure waits 1 min")
    d.recordFailure(at: t0)
    check(d.isResting(at: t0.addingTimeInterval(299)), "download backoff: then 5 min")
    check(PocketHealth(failuresBeforeRest: 0).failuresBeforeRest == 1, "health: threshold floors at 1")

    return failures
}
