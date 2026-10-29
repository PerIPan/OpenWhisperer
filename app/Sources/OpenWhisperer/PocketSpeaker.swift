import CryptoKit
import Foundation
import OpenWhispererKit
import Security

/// Pocket TTS in the app — see `PocketTTS` (Kit) for what it is and the measurements behind it.
///
/// One run of the bundled program per sentence, under `sandbox-exec`, its text on stdin and its WAV
/// on stdout. What each run reads is checked first:
///
/// - **the program**, against the app bundle's own code seal (`SecStaticCodeCheckValidity` with
///   nested code), before its first run and whenever its stamp changes. Build time checks it
///   against Kyutai's sha256; signing then rewrites its bytes, so at run time the seal is the pin
///   (review, 2026-10-29: "covered by the app signature" had been a claim, not a check);
/// - **every data file** (weights, tokenizer, voice), hashed and stamped through **one** file
///   descriptor — `fstat` before and after the hash, `lstat` of the path to tie them — and
///   re-checked whenever the stamp changes; a changed file is never run;
/// - **the config**, by its **content** before every run, not only its stamp.
///
/// What remains open, deliberately: between those checks and the program's own `open` of the same
/// paths, a process running as the same user could still swap a file. Closing that means handing
/// the program verified descriptors, which it has no option for; and a same-user process can
/// already change far more than this (the user's shell, the agents' configs). The checks are
/// defence in depth against accidents and drive-by tampering, not a boundary against the user.
///
/// **It never makes a reply wait for the model.** The model (~219 MB) is fetched in the background
/// from `prepare()`; until it is ready, or whenever a run fails, `samples` throws and `TTSEngines`
/// has Kokoro say the line (`PocketVoice.kokoroStandIn`). A stock voice's own file (~6–7 MB) is the
/// one thing waited for, briefly (60 s at most), so choosing Jane and pressing ▶ plays Jane.
/// Failed fetches back off — 1, 5, 30 min — so a bad network can't start one on every sentence,
/// and a voice's failed download never rests the engine for the other voices.
actor PocketSpeaker {
    enum Failure: Error, CustomStringConvertible {
        case noProgram, sealBroken, notReady, resting, unknownVoice(String), changed(String), download(String), run(String)

        var description: String {
            switch self {
            case .noProgram: return "no bundled program (not a packaged app)"
            case .sealBroken: return "the app bundle's code seal doesn't hold"
            case .notReady: return "not ready yet (downloading, or waiting before trying again)"
            case .resting: return "resting after repeated failures"
            case .unknownVoice(let v): return "no voice \(v)"
            case .changed(let f): return "\(f) is not the pinned file"
            case .download(let why): return "download failed: \(why)"
            case .run(let why): return "run failed: \(why)"
            }
        }
    }

    /// The program, inside the bundle. nil when not packaged (`swift run`): Kokoro speaks.
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
    /// fetched at launch whichever Pocket voice is chosen, so it doesn't count against a voice.)
    nonisolated static func isCached(_ voice: PocketVoice) -> Bool {
        guard let url = location(of: voice) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return size == voice.file.bytes
    }

    /// Runs: three failures in a row rest Pocket for every voice.
    private var health = PocketHealth()
    /// The model's fetch: one failure waits before the next try.
    private var modelBackoff = PocketHealth(failuresBeforeRest: 1)
    /// Each stock voice's fetch, on its own: Jane failing to download never rests Heart.
    private var voiceBackoff: [String: PocketHealth] = [:]
    /// Files checked against their pin in this process, with the stamp they had then.
    private var checked: [String: FileStamp] = [:]
    /// The program's stamp when the bundle's seal last held.
    private var programStamp: FileStamp?
    /// What english.yaml must say, byte for byte.
    private var expectedConfig: String?
    private var modelReady = false
    private var modelTask: Task<Void, Error>?
    private var voiceTasks: [String: Task<URL, Error>] = [:]

    // MARK: - Model

    /// Fetch (once) and check the model, then write and read back the program's config. Concurrent
    /// callers share one attempt; a failed one is remembered (`modelBackoff`) and forgotten as a
    /// task, so the next call after the wait tries again.
    func prepare() async throws {
        if modelReady { return }
        if let running = modelTask { return try await running.value }
        let task = Task { try await self.loadModel() }
        modelTask = task
        do {
            try await task.value
            modelTask = nil
            modelBackoff.recordSuccess()
        } catch {
            modelTask = nil
            if !(error is CancellationError) { modelBackoff.recordFailure(at: Date()) }
            throw error
        }
    }

    private func loadModel() async throws {
        _ = try await verifiedProgram()
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let weights = try await checkedFile(PocketTTS.weights, at: Self.folder.appendingPathComponent(PocketTTS.weights.name),
                                            session: Self.modelSession)
        let tokenizer = try await checkedFile(PocketTTS.tokenizer, at: Self.folder.appendingPathComponent(PocketTTS.tokenizer.name),
                                              session: Self.modelSession)
        let text = PocketTTS.configText(weights: Self.real(weights).path, tokenizer: Self.real(tokenizer).path)
        try Data(text.utf8).write(to: Self.config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.config.path)
        // Read it back and stamp the bytes read — not whatever is at the path a moment later.
        guard let stamp = Self.stampIfContent(of: Self.config, equals: text) else { throw Failure.changed("english.yaml") }
        checked[Self.config.path] = stamp
        expectedConfig = text
        modelReady = true
        NSLog("Pocket TTS: model ready")
    }

    /// The program, provided the bundle's seal holds — checked again whenever its stamp changes.
    private func verifiedProgram() async throws -> URL {
        guard let program = Self.program else { throw Failure.noProgram }
        let before = FileStamp.of(program)
        if let before, before == programStamp { return program }
        let intact = await Task.detached(priority: .utility) { Self.bundleSealIntact() }.value
        guard intact, let before, FileStamp.of(program) == before else {
            programStamp = nil
            throw Failure.sealBroken
        }
        programStamp = before
        return program
    }

    // MARK: - Voices

    /// The checked file of `voice`, downloading a stock voice's first (60 s at most). Concurrent
    /// callers share the fetch; a failed one waits before the next try, for this voice only.
    private func voiceFile(_ voice: PocketVoice) async throws -> URL {
        guard let url = Self.location(of: voice) else { throw Failure.changed(voice.file.name) }
        if isUnchanged(url) { return url }
        if voiceBackoff[voice.name]?.isResting(at: Date()) == true { throw Failure.notReady }
        if let running = voiceTasks[voice.name] { return try await running.value }
        let task = Task { try await self.checkedFile(voice.file, at: url, canDownload: !voice.bundled, session: Self.voiceSession) }
        voiceTasks[voice.name] = task
        defer { voiceTasks[voice.name] = nil }
        do {
            let checkedURL = try await task.value
            voiceBackoff[voice.name] = nil
            return checkedURL
        } catch {
            if !(error is CancellationError) {
                var backoff = voiceBackoff[voice.name] ?? PocketHealth(failuresBeforeRest: 1)
                backoff.recordFailure(at: Date())
                voiceBackoff[voice.name] = backoff
            }
            throw error
        }
    }

    // MARK: - Speaking

    /// One sentence in `voiceName`, as 24 kHz samples at the voice's gain. Throws whenever Pocket
    /// can't say it — the caller has Kokoro say it instead. `CancellationError` (barge-in) kills
    /// the run and is not counted as a failure. Only a failed *run* counts toward resting Pocket:
    /// a missing model or voice file is a download's business, with its own backoff.
    func samples(_ text: String, voice voiceName: String) async throws -> [Float] {
        guard Self.program != nil else { throw Failure.noProgram }
        guard let voice = PocketTTS.voice(named: voiceName) else { throw Failure.unknownVoice(voiceName) }
        let now = Date()
        guard !health.isResting(at: now) else { throw Failure.resting }
        guard modelReady else {
            // Never wait for the model inside a reply: start (or join) the fetch, let Kokoro speak.
            if modelTask == nil, !modelBackoff.isResting(at: now) { Task { try? await self.prepare() } }
            throw Failure.notReady
        }

        let voiceURL: URL
        do {
            voiceURL = try await voiceFile(voice)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            NSLog("Pocket TTS (\(voice.name)): voice not available (\(error)); Kokoro speaks this line")
            throw error
        }

        do {
            let program = try await verifiedProgram()
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

    /// `file` at `url`, checked against its pin (downloaded first when missing and allowed). A file
    /// already checked and unchanged is not hashed again. One that is present but wrong is set aside
    /// once and fetched fresh; wrong again, refused.
    private func checkedFile(_ file: PocketFile, at url: URL, canDownload: Bool = true, session: URLSession) async throws -> URL {
        if isUnchanged(url) { return url }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            if let stamp = try await Self.verified(url, file) {
                checked[url.path] = stamp
                return url
            }
            guard canDownload else { throw Failure.changed(file.name) }
            NSLog("Pocket TTS: \(file.name) is not the pinned file; fetching it again")
            try? fm.removeItem(at: url)
        }
        guard canDownload, let source = file.url else { throw Failure.changed(file.name) }
        try await Self.download(source, to: url, maxBytes: file.bytes + 1024, session: session)
        guard let stamp = try await Self.verified(url, file) else {
            try? fm.removeItem(at: url)
            throw Failure.changed(file.name)
        }
        checked[url.path] = stamp
        return url
    }

    /// The model's files — weights, tokenizer, config — still exactly as checked, the config by its
    /// content too. Any one touched since makes the whole model un-ready, so the next line starts a
    /// fresh check in the background and Kokoro speaks meanwhile.
    private func modelUnchanged() throws {
        let files = [PocketTTS.weights.name, PocketTTS.tokenizer.name].map { Self.folder.appendingPathComponent($0) }
            + [Self.config]
        let configHolds = expectedConfig.map { Self.stampIfContent(of: Self.config, equals: $0) == checked[Self.config.path] } ?? false
        for url in files where !isUnchanged(url) || (url == Self.config && !configHolds) {
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

    /// The stamp of `url` if its bytes are `file`'s — size and sha256 — read through one descriptor
    /// whose `fstat` is the same before and after the hash and matches the path's `lstat`; nil if
    /// not. Off the actor: hashing 219 MB must not hold up a Heart line.
    private static func verified(_ url: URL, _ file: PocketFile) async throws -> FileStamp? {
        try await Task.detached(priority: .utility) { () throws -> FileStamp? in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let before = FileStamp.of(fd: handle.fileDescriptor), before.size == Int64(file.bytes) else { return nil }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256, FileStamp.of(fd: handle.fileDescriptor) == before, FileStamp.of(url) == before else {
                return nil
            }
            return before
        }.value
    }

    /// The stamp of `url` if it holds exactly `text`, read and stamped through one descriptor.
    private static func stampIfContent(of url: URL, equals text: String) -> FileStamp? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let before = FileStamp.of(fd: handle.fileDescriptor),
              let bytes = try? handle.readToEnd(), bytes == Data(text.utf8),
              FileStamp.of(fd: handle.fileDescriptor) == before, FileStamp.of(url) == before else { return nil }
        return before
    }

    /// Whether the app bundle — program included, as nested code — still matches its signature.
    nonisolated static func bundleSealIntact() -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSStrictValidate))
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        if status != errSecSuccess { NSLog("Pocket TTS: the app bundle's seal check failed (OSStatus \(status)); Kokoro speaks") }
        return status == errSecSuccess
    }

    /// The model: no bytes for 30 s is a failure, the whole file may take 30 minutes on a slow line.
    private static let modelSession = session(resourceTimeout: 1800)
    /// A stock voice (~6–7 MB) is waited for inside a reply, so it gets a minute, not the default week.
    private static let voiceSession = session(resourceTimeout: 60)

    private static func session(resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// https only, at most `maxBytes`, 200 only, into a `.part` beside the destination, then moved.
    private static func download(_ source: URL, to url: URL, maxBytes: Int, session: URLSession) async throws {
        guard source.scheme == "https" else { throw Failure.download("not https") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let (temp, response) = try await session.download(from: source)
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

    /// The path itself (not a link), and only a regular file.
    static func of(_ url: URL) -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return from(info)
    }

    /// An open descriptor — the bytes actually read.
    static func of(fd: Int32) -> FileStamp? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return from(info)
    }

    private static func from(_ info: stat) -> FileStamp? {
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileStamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                         modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                         changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec))
    }
}

/// Runs one program to completion: exactly `environment`, `input` on stdin, stdout read to its end
/// (stderr to /dev/null — the program's log could name the text), SIGKILL after `seconds` or as soon
/// as stdout passes `maxOutput`, and SIGKILL on task cancellation (barge-in). Ported from Estia's
/// `runProgram`; verified 2026-10-29: cancel kills within 20 ms, timeout and cap kill and report.
enum PocketProcess {
    struct Result {
        var status: Int32 = 0
        var signalled = false
        var output = Data()
        var timedOut = false
        var tooLarge = false
    }

    /// The running process's pid, killable from the cancellation handler or the timer on another
    /// thread — and cleared the moment the child is reaped, so a late kill can never reach a
    /// recycled pid (review, 2026-10-29).
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var cancelled = false
        private var late = false

        /// Record the child; false if cancellation already came (the caller kills it at once).
        func started(_ p: pid_t) -> Bool {
            lock.withLock { pid = p; return !cancelled }
        }
        func cancel() { lock.withLock { cancelled = true; if pid > 0 { kill(pid, SIGKILL) } } }
        func timeOut() { lock.withLock { if pid > 0 { late = true; kill(pid, SIGKILL) } } }
        func finished() { lock.withLock { pid = 0 } }
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
                    running.finished()
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
