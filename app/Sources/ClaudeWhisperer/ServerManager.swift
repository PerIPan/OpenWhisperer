import Foundation
import Combine

class ServerManager: ObservableObject {
    enum ServerStatus: String {
        case stopped = "Stopped"
        case starting = "Starting..."
        case running = "Running"
        case error = "Error"
    }

    @Published var sttStatus: ServerStatus = .stopped
    @Published var ttsStatus: ServerStatus = .stopped
    @Published var sttPort: Int = 8000
    @Published var ttsPort: Int = 8100

    private var sttProcess: Process?
    private var ttsProcess: Process?
    private var sttLogHandle: FileHandle?
    private var ttsLogHandle: FileHandle?
    private var healthCheckTimer: Timer?
    private var pendingRestart: DispatchWorkItem?
    private var pendingInitialCheck: DispatchWorkItem?
    private var sttStartTime: Date?
    private var ttsStartTime: Date?
    private var stoppingSTT = false
    private var stoppingTTS = false

    private static let startupTimeout: TimeInterval = 60
    private static let maxLogSize: UInt64 = 10 * 1024 * 1024  // 10MB

    var isRunning: Bool {
        sttStatus == .running && ttsStatus == .running
    }

    var statusLabel: String {
        if sttStatus == .running && ttsStatus == .running { return "Running" }
        if sttStatus == .starting || ttsStatus == .starting { return "Starting..." }
        if sttStatus == .error || ttsStatus == .error { return "Error" }
        return "Stopped"
    }

    func startAll() {
        // Must run on main thread for timer scheduling (BUG-08)
        let work = { [self] in
            Paths.ensureDirectories()
            startSTT()
            startTTS()
            startHealthChecks()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func stopAll(synchronous: Bool = false) {
        // Cancel any pending restart (BUG-12)
        pendingRestart?.cancel()
        pendingRestart = nil

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        pendingInitialCheck?.cancel()
        pendingInitialCheck = nil

        stoppingSTT = true
        stoppingTTS = true
        stopProcess(&sttProcess, pidFile: Paths.sttPidFile, synchronous: synchronous)
        stopProcess(&ttsProcess, pidFile: Paths.ttsPidFile, synchronous: synchronous)

        sttStatus = .stopped
        ttsStatus = .stopped
    }

    func restartAll() {
        // Cancel any previous pending restart (BUG-12)
        pendingRestart?.cancel()

        sttStatus = .stopped
        ttsStatus = .stopped

        // Capture process refs before nilling them (avoids race)
        let sttProc = sttProcess
        let ttsProc = ttsProcess
        sttProcess = nil
        ttsProcess = nil

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        pendingInitialCheck?.cancel()
        pendingInitialCheck = nil

        let sttPid = Paths.sttPidFile
        let ttsPid = Paths.ttsPidFile

        let restart = DispatchWorkItem { [weak self] in
            // Terminate on background thread (blocking waits)
            Self.terminateProcess(sttProc, pidFile: sttPid)
            Self.terminateProcess(ttsProc, pidFile: ttsPid)
            DispatchQueue.main.async {
                self?.startAll()
            }
        }
        pendingRestart = restart
        DispatchQueue.global(qos: .userInitiated).async(execute: restart)
    }

    /// Terminate a process synchronously (safe to call from any thread, no state mutation)
    private static func terminateProcess(_ process: Process?, pidFile: URL) {
        guard let proc = process, proc.isRunning else {
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        proc.terminate()
        for _ in 0..<30 {
            if !proc.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            proc.interrupt()
            for _ in 0..<10 {
                if !proc.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    // MARK: - STT Server

    private func startSTT() {
        guard sttProcess == nil || sttProcess?.isRunning != true else { return }

        sttStatus = .starting

        let process = Process()
        process.executableURL = Paths.python
        process.arguments = [Paths.whisperServer.path]
        process.currentDirectoryURL = Paths.appSupport
        var env = makeEnv()
        env["STT_PORT"] = "\(sttPort)"
        process.environment = env

        try? sttLogHandle?.close()
        Self.rotateLogIfNeeded(at: Paths.sttLog)
        let logFile = FileHandle.forWritingOrCreate(at: Paths.sttLog)
        logFile.seekToEndOfFile()
        sttLogHandle = logFile
        process.standardOutput = logFile
        process.standardError = logFile

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                try? self.sttLogHandle?.close()
                self.sttLogHandle = nil
                if self.stoppingSTT {
                    self.stoppingSTT = false
                } else {
                    self.sttStatus = .error
                }
            }
        }

        sttProcess = process
        sttStartTime = Date()

        do {
            try process.run()
            stoppingSTT = false
            writePID(process.processIdentifier, to: Paths.sttPidFile)
        } catch {
            sttProcess = nil
            sttStatus = .error
            NSLog("Failed to start STT: \(error)")
        }
    }

    // MARK: - TTS Server

    private func startTTS() {
        guard ttsProcess == nil || ttsProcess?.isRunning != true else { return }

        ttsStatus = .starting

        let process = Process()
        process.executableURL = Paths.python
        process.arguments = ["-m", "mlx_audio.server", "--host", "127.0.0.1", "--port", "\(ttsPort)"]
        process.currentDirectoryURL = Paths.appSupport
        process.environment = makeEnv()

        try? ttsLogHandle?.close()
        Self.rotateLogIfNeeded(at: Paths.ttsLog)
        let logFile = FileHandle.forWritingOrCreate(at: Paths.ttsLog)
        logFile.seekToEndOfFile()
        ttsLogHandle = logFile
        process.standardOutput = logFile
        process.standardError = logFile

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                try? self.ttsLogHandle?.close()
                self.ttsLogHandle = nil
                if self.stoppingTTS {
                    self.stoppingTTS = false
                } else {
                    self.ttsStatus = .error
                }
            }
        }

        ttsProcess = process
        ttsStartTime = Date()

        do {
            try process.run()
            stoppingTTS = false
            writePID(process.processIdentifier, to: Paths.ttsPidFile)
        } catch {
            ttsProcess = nil
            ttsStatus = .error
            NSLog("Failed to start TTS: \(error)")
        }
    }

    // MARK: - Health Checks

    private func startHealthChecks() {
        // Timer must be on main thread RunLoop (BUG-08)
        healthCheckTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
        // Cancellable first check after 3s to give servers time to boot
        let initialCheck = DispatchWorkItem { [weak self] in
            self?.checkHealth()
        }
        pendingInitialCheck = initialCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: initialCheck)
    }

    private func checkHealth() {
        checkEndpoint("http://localhost:\(sttPort)/models") { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.sttStatus == .starting || self.sttStatus == .running else { return }
                if ok {
                    self.sttStatus = .running
                } else if self.sttStatus == .starting,
                          let start = self.sttStartTime,
                          Date().timeIntervalSince(start) > Self.startupTimeout {
                    self.sttStatus = .error
                }
            }
        }
        checkEndpoint("http://localhost:\(ttsPort)/v1/models") { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.ttsStatus == .starting || self.ttsStatus == .running else { return }
                if ok {
                    self.ttsStatus = .running
                } else if self.ttsStatus == .starting,
                          let start = self.ttsStartTime,
                          Date().timeIntervalSince(start) > Self.startupTimeout {
                    self.ttsStatus = .error
                }
            }
        }
    }

    private func checkEndpoint(_ urlString: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(false)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            completion(ok)
        }.resume()
    }

    // MARK: - Process Management

    private func stopProcess(_ process: inout Process?, pidFile: URL, synchronous: Bool = false) {
        guard let proc = process, proc.isRunning else {
            process = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        process = nil
        proc.terminate()
        if synchronous {
            Self.terminateProcess(proc, pidFile: pidFile)
        } else {
            DispatchQueue.global(qos: .utility).async {
                Self.terminateProcess(proc, pidFile: pidFile)
            }
        }
    }

    private func writePID(_ pid: Int32, to url: URL) {
        try? "\(pid)".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func rotateLogIfNeeded(at url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        let backup = url.appendingPathExtension("old")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
    }

    private func makeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let venvBin = Paths.venv.appendingPathComponent("bin").path
        env["PATH"] = "\(venvBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["VIRTUAL_ENV"] = Paths.venv.path
        return env
    }
}

// MARK: - FileHandle Helper

extension FileHandle {
    static func forWritingOrCreate(at url: URL) -> FileHandle {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
    }
}
