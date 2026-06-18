import Foundation
import OpenWhispererKit

/// Shared harness for the bash-hook integration tests. Each test runs a hook script in an
/// isolated temp `HOME` (so `$HOME/Library/Application Support/OpenWhisperer` is a sandbox) with
/// an optional stubbed `curl` on `PATH`, then asserts on exit code, stdout, marker files, and the
/// recorded curl calls. This is the Swift port of the deleted pytest suite (subprocess + HOME
/// override), kept dependency-free so it builds under Command Line Tools.
enum Hook {
    /// Repo root, derived from this file's compile-time path: app/Tests/HookTests/ → repo.
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // HookTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // app
        .deletingLastPathComponent()   // repo root
    static let hooksDir = repoRoot.appendingPathComponent("hooks")

    struct Result {
        let exit: Int32
        let stdout: String
    }

    /// A throwaway sandbox: a temp HOME with the App Support dir, a stub-bin dir, and a curl log.
    final class Sandbox {
        let home: URL
        let appSupport: URL
        let curlLog: URL
        private let binDir: URL
        private let fm = FileManager.default

        init() {
            let base = fm.temporaryDirectory.appendingPathComponent("owhook-\(UUID().uuidString)")
            home = base
            appSupport = base.appendingPathComponent("Library/Application Support/OpenWhisperer")
            binDir = base.appendingPathComponent("bin")
            curlLog = base.appendingPathComponent("curl_calls.log")
            try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        }

        /// `PATH` with the stub-bin dir first, so a stubbed `curl` shadows the real one.
        var path: String { "\(binDir.path):/usr/bin:/bin:/usr/local/bin" }

        /// Install a fake `curl` that appends its arguments to `curlLog` and exits 0 — lets a test
        /// assert what the hook would have POSTed without touching the network.
        func installCurlStub() {
            let stub = binDir.appendingPathComponent("curl")
            let script = "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"\(curlLog.path)\"\nexit 0\n"
            try? script.write(to: stub, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }

        /// Write the `voice_turn` signal the UserPromptSubmit hook matches against. The hash is
        /// computed with `VoiceSignal.canonicalHash`, which proves Swift/bash hashing parity.
        func writeVoiceTurn(forPrompt prompt: String, timestamp: Int? = nil) {
            let ts = timestamp ?? Int(Date().timeIntervalSince1970)
            let body = VoiceSignal.signalContents(hash: VoiceSignal.canonicalHash(prompt), timestamp: ts)
            try? body.write(to: appSupport.appendingPathComponent("voice_turn"),
                            atomically: true, encoding: .utf8)
        }

        func writeVoiceDetail(_ detail: String) {
            try? detail.write(to: appSupport.appendingPathComponent("voice_detail"),
                              atomically: true, encoding: .utf8)
        }

        /// Create a `speak_pending/<sanitized session id>` marker the Stop hook gate looks for.
        func writeMarker(session: String) {
            let dir = appSupport.appendingPathComponent("speak_pending")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data().write(to: dir.appendingPathComponent(Self.sanitize(session)))
        }

        func markerExists(session: String) -> Bool {
            fm.fileExists(atPath: appSupport.appendingPathComponent("speak_pending")
                .appendingPathComponent(Self.sanitize(session)).path)
        }

        func voiceTurnExists() -> Bool {
            fm.fileExists(atPath: appSupport.appendingPathComponent("voice_turn").path)
        }

        /// Poll the curl log until non-empty (a backgrounded `curl &` may land after the hook exits).
        func curlCalls(waitingUpTo seconds: Double = 2) -> String {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let s = try? String(contentsOf: curlLog, encoding: .utf8), !s.isEmpty { return s }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return (try? String(contentsOf: curlLog, encoding: .utf8)) ?? ""
        }

        /// True if no curl call lands within a short settle window (for "should not POST" cases).
        func noCurlWithin(_ seconds: Double = 0.4) -> Bool {
            Thread.sleep(forTimeInterval: seconds)
            let s = (try? String(contentsOf: curlLog, encoding: .utf8)) ?? ""
            return s.isEmpty
        }

        func cleanup() { try? fm.removeItem(at: home) }

        /// Mirror of the hooks' `tr -c 'A-Za-z0-9_.-' '_'` session-id sanitization.
        static func sanitize(_ s: String) -> String {
            String(s.map { c in
                let ok = c.isASCII && (c.isLetter || c.isNumber || "_.-".contains(c))
                return ok ? c : "_"
            })
        }
    }

    /// Run a hook script with the sandbox's HOME + PATH, feeding `stdin`, returning exit + stdout.
    static func run(_ name: String, stdin: String, sandbox: Sandbox, env extra: [String: String] = [:]) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [hooksDir.appendingPathComponent(name).path]
        var env = ["HOME": sandbox.home.path, "PATH": sandbox.path, "LANG": "en_US.UTF-8"]
        for (k, v) in extra { env[k] = v }
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // discard hook stderr

        do { try proc.run() } catch {
            return Result(exit: -1, stdout: "RUN ERROR: \(error)")
        }
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
        // curl is redirected to /dev/null inside the hooks, so the stdout pipe closes when the
        // hook process exits — no deadlock waiting on a backgrounded child.
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return Result(exit: proc.terminationStatus, stdout: String(data: out, encoding: .utf8) ?? "")
    }
}
