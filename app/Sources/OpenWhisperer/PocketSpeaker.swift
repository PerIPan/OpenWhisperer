import CryptoKit
import Foundation
import OpenWhispererKit

/// Pocket TTS in the app — see `PocketTTS` (Kit) for what it is and the measurements behind it.
///
/// One run of the bundled program per sentence, under `sandbox-exec`, its text on stdin and its WAV
/// on stdout. Everything it reads is checked against its pin before the first run and whenever the
/// file's size, times or inode change; a changed file is never run. The program itself is checked
/// at build time (signing changes its bytes) and is covered by the app's signature from then on.
///
/// **It never makes a reply wait for a download.** The model (~219 MB) is fetched in the
/// background from `prepare()`; until it is ready, or whenever a run fails, `samples` throws and
/// `TTSEngines` has Kokoro say the line (`PocketVoice.kokoroStandIn`). A stock voice's own file
/// (~6–7 MB) is the one thing waited for, briefly, so choosing Jane and pressing ▶ plays Jane.
actor PocketSpeaker {
    enum Failure: Error, CustomStringConvertible {
        case noProgram, notReady, resting, unknownVoice(String), changed(String), download(String), run(String)

        var description: String {
            switch self {
            case .noProgram: return "no bundled program (not a packaged app)"
            case .notReady: return "model still downloading"
            case .resting: return "resting after repeated failures"
            case .unknownVoice(let v): return "no voice \(v)"
            case .changed(let f): return "\(f) is not the pinned file"
            case .download(let why): return "download failed: \(why)"
            case .run(let why): return "run failed: \(why)"
            }
        }
    }

    /// The program, inside the signed bundle. nil when not packaged (`swift run`): Kokoro speaks.
    static var program: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pocket-tts")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var folder: URL { Paths.pocketFolder }
    static var config: URL { folder.appendingPathComponent("english.yaml") }

    /// Where a voice's file is: Heart in the bundle, the stock voices in Pocket's folder.
    static func location(of voice: PocketVoice) -> URL? {
        if voice.bundled {
            return Bundle.main.resourceURL?.appendingPathComponent("pocket").appendingPathComponent(voice.file.name)
        }
        return folder.appendingPathComponent(voice.file.name)
    }

    /// Whether a voice can speak without a download — the picker's dot and `list_voices`.
    /// Heart ships with the app; a stock voice once its file is on disk. (The shared model is
    /// fetched at launch whichever voice is chosen, so it doesn't count against a voice.)
    nonisolated static func isCached(_ voice: PocketVoice) -> Bool {
        guard let url = location(of: voice) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return size == voice.file.bytes
    }

    private var health = PocketHealth()
    /// Files checked against their sha256 in this process, with the stamp they had then.
    private var checked: [String: FileStamp] = [:]
    private var modelReady = false
    private var modelTask: Task<Void, Error>?
    private var voiceTasks: [String: Task<URL, Error>] = [:]

    // MARK: - Model

    /// Fetch (once) and check the model, then write the program's config. Called at launch when
    /// the chosen voice is a Pocket one; concurrent callers share one attempt; a failed attempt
    /// is forgotten so the next call tries again.
    func prepare() async throws {
        if modelReady { return }
        if let running = modelTask { return try await running.value }
        let task = Task { try await self.loadModel() }
        modelTask = task
        do {
            try await task.value
            modelTask = nil
        } catch {
            modelTask = nil
            throw error
        }
    }

    private func loadModel() async throws {
        guard Self.program != nil else { throw Failure.noProgram }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let weights = try await checkedFile(PocketTTS.weights, at: Self.folder.appendingPathComponent(PocketTTS.weights.name))
        let tokenizer = try await checkedFile(PocketTTS.tokenizer, at: Self.folder.appendingPathComponent(PocketTTS.tokenizer.name))
        let text = PocketTTS.configText(weights: Self.real(weights).path, tokenizer: Self.real(tokenizer).path)
        try Data(text.utf8).write(to: Self.config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.config.path)
        guard let stamp = FileStamp.of(Self.config) else { throw Failure.changed("english.yaml") }
        checked[Self.config.path] = stamp
        modelReady = true
        NSLog("Pocket TTS: model ready")
    }

    // MARK: - Voices

    /// The checked file of `voice`, downloading a stock voice's first. Concurrent callers share it.
    private func voiceFile(_ voice: PocketVoice) async throws -> URL {
        guard let url = Self.location(of: voice) else { throw Failure.changed(voice.file.name) }
        if let stamp = checked[url.path], FileStamp.of(url) == stamp { return url }
        if let running = voiceTasks[voice.name] { return try await running.value }
        let task = Task { try await self.checkedFile(voice.file, at: url, canDownload: !voice.bundled) }
        voiceTasks[voice.name] = task
        defer { voiceTasks[voice.name] = nil }
        return try await task.value
    }

    // MARK: - Speaking

    /// One sentence in `voiceName`, as 24 kHz samples at the voice's gain. Throws whenever Pocket
    /// can't say it — the caller has Kokoro say it instead. `CancellationError` (barge-in) kills
    /// the run and is not counted as a failure.
    func samples(_ text: String, voice voiceName: String) async throws -> [Float] {
        guard let program = Self.program else { throw Failure.noProgram }
        guard let voice = PocketTTS.voice(named: voiceName) else { throw Failure.unknownVoice(voiceName) }
        guard !health.isResting(at: Date()) else { throw Failure.resting }
        guard modelReady else {
            // Never wait for the model inside a reply: start (or join) the fetch, let Kokoro speak.
            if modelTask == nil { Task { try? await self.prepare() } }
            throw Failure.notReady
        }
        do {
            let voiceURL = try await voiceFile(voice)
            try modelUnchanged()
            try unchanged(voiceURL)
            let spoken = PocketText.spoken(text)
            let argv = PocketTTS.arguments(
                program: Self.real(program).path, config: Self.real(Self.config).path, voice: Self.real(voiceURL).path,
                pocketFolder: Self.real(Self.folder).path, app: Self.real(Bundle.main.bundleURL).path,
                home: Self.real(FileManager.default.homeDirectoryForCurrentUser).path)
            let result = try await PocketProcess.run(
                argv, environment: PocketTTS.environment(pocketFolder: Self.real(Self.folder).path),
                input: Data(spoken.utf8), seconds: PocketTTS.runSeconds(for: spoken), maxOutput: PocketTTS.maxOutputBytes)
            if result.timedOut { throw Failure.run("past its \(Int(PocketTTS.runSeconds(for: spoken))) s limit") }
            if result.tooLarge { throw Failure.run("output over its cap") }
            guard result.status == 0, !result.signalled else { throw Failure.run("exit \(result.status)") }
            let samples = try PocketWAV.samples(fromWAV: result.output, gainDB: voice.gainDB)
            health.recordSuccess()
            return samples
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            health.recordFailure(at: Date())
            // Metadata only — the text is the user's conversation and NSLog lands in system logs.
            NSLog("Pocket TTS (\(voice.name)): \(error); Kokoro speaks this line\(health.isResting(at: Date()) ? ", resting" : "")")
            throw error
        }
    }

    // MARK: - Files

    /// `file` at `url`, checked against its pin (downloaded first when missing and allowed). A
    /// file that is present but wrong is set aside once and fetched fresh; wrong again, refused.
    private func checkedFile(_ file: PocketFile, at url: URL, canDownload: Bool = true) async throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            if try Self.matches(url, file) { return record(url) }
            guard canDownload else { throw Failure.changed(file.name) }
            NSLog("Pocket TTS: \(file.name) is not the pinned file; fetching it again")
            try? fm.removeItem(at: url)
        }
        guard canDownload, let source = file.url else { throw Failure.changed(file.name) }
        try await Self.download(source, to: url, maxBytes: file.bytes + 1024)
        guard try Self.matches(url, file) else {
            try? fm.removeItem(at: url)
            throw Failure.changed(file.name)
        }
        return record(url)
    }

    private func record(_ url: URL) -> URL {
        if let stamp = FileStamp.of(url) { checked[url.path] = stamp }
        return url
    }

    /// The model's files — weights, tokenizer, config — still exactly as checked. Any one touched
    /// since (an update, a tamper, a half-finished copy) makes the whole model un-ready, so the
    /// next line starts a fresh check in the background and Kokoro speaks meanwhile.
    private func modelUnchanged() throws {
        let files = [PocketTTS.weights.name, PocketTTS.tokenizer.name].map { Self.folder.appendingPathComponent($0) }
            + [Self.config]
        for url in files where !isUnchanged(url) {
            for f in files { checked[f.path] = nil }
            modelReady = false
            throw Failure.changed(url.lastPathComponent)
        }
    }

    /// A voice file still exactly as checked; if not, it is checked again at its next use.
    private func unchanged(_ url: URL) throws {
        guard isUnchanged(url) else {
            checked[url.path] = nil
            throw Failure.changed(url.lastPathComponent)
        }
    }

    private func isUnchanged(_ url: URL) -> Bool {
        guard let stamp = checked[url.path] else { return false }
        return FileStamp.of(url) == stamp
    }

    private static func matches(_ url: URL, _ file: PocketFile) throws -> Bool {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        guard size == file.bytes else { return false }
        return try sha256(of: url) == file.sha256
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// https only, at most `maxBytes`, 200 only, into a `.part` beside the destination, then moved.
    private static func download(_ source: URL, to url: URL, maxBytes: Int) async throws {
        guard source.scheme == "https" else { throw Failure.download("not https") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let (temp, response) = try await URLSession.shared.download(from: source)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw Failure.download("\(size) bytes, over its cap") }
        let part = url.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        try FileManager.default.moveItem(at: temp, to: part)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: part, to: url)
    }

    /// The real path — the sandbox matches real paths, and `/var` is really `/private/var`.
    /// `realpath`, never `resolvingSymlinksInPath`, which drops `/private`.
    static func real(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

/// A file's identity as `stat` sees it: a checked file whose stamp still matches is the file that
/// was checked.
struct FileStamp: Equatable, Sendable {
    let device: Int64, inode: UInt64, size: Int64, modified: Int64, changed: Int64

    static func of(_ url: URL) -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileStamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                         modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                         changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec))
    }
}

/// Runs one program to completion: exactly `environment`, `input` on stdin, stdout read to its end
/// (stderr to /dev/null — the program's log could name the text), SIGKILL after `seconds` or as soon
/// as stdout passes `maxOutput`, and SIGKILL on task cancellation (barge-in). Ported from Estia's
/// `runProgram`.
enum PocketProcess {
    struct Result {
        var status: Int32 = 0
        var signalled = false
        var output = Data()
        var timedOut = false
        var tooLarge = false
    }

    /// The running process's pid, killable from the cancellation handler on another thread.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var cancelled = false
        private var late = false

        func started(_ p: pid_t) -> Bool {
            lock.withLock { pid = p; return !cancelled }
        }
        func cancel() { lock.withLock { cancelled = true; if pid > 0 { kill(pid, SIGKILL) } } }
        func timeOut() { lock.withLock { late = true; if pid > 0 { kill(pid, SIGKILL) } } }
        var timedOut: Bool { lock.withLock { late } }
    }

    static func run(_ argv: [String], environment: [String: String], input: Data,
                    seconds: TimeInterval, maxOutput: Int) async throws -> Result {
        let running = Running()
        let result: Result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: argv[0])
                    process.arguments = Array(argv.dropFirst())
                    process.environment = environment
                    let stdin = Pipe(), stdout = Pipe()
                    process.standardInput = stdin
                    process.standardOutput = stdout
                    process.standardError = FileHandle.nullDevice
                    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    do { try process.run() } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    if !running.started(process.processIdentifier) { kill(process.processIdentifier, SIGKILL) }
                    let timer = DispatchWorkItem { running.timeOut() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                    var result = Result()
                    let reader = stdout.fileHandleForReading
                    while let piece = try? reader.read(upToCount: 1 << 16), !piece.isEmpty {
                        result.output.append(piece)
                        if result.output.count > maxOutput {
                            result.tooLarge = true
                            kill(process.processIdentifier, SIGKILL)
                            break
                        }
                    }
                    process.waitUntilExit()
                    timer.cancel()
                    try? reader.close()
                    result.status = process.terminationStatus
                    result.signalled = process.terminationReason == .uncaughtSignal
                    result.timedOut = running.timedOut
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            running.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}
