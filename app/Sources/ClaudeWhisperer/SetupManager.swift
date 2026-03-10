import Foundation
import SwiftUI

class SetupManager: ObservableObject {
    enum SetupState: Equatable {
        case notStarted
        case inProgress(String)
        case complete
        case failed(String)
    }

    @Published var state: SetupState = .notStarted
    @Published var progress: Double = 0
    private var isSetupRunning = false

    var isSetupComplete: Bool {
        FileManager.default.fileExists(atPath: Paths.setupComplete.path)
    }

    /// Run full first-launch setup
    func runFirstLaunchSetup(completion: @escaping (Bool) -> Void) {
        guard !isSetupComplete else {
            completion(true)
            return
        }
        guard !isSetupRunning else { return }
        isSetupRunning = true

        Paths.ensureDirectories()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            updateState(.inProgress("Creating Python environment..."), progress: 0.1)

            // Step 1: Create venv with bundled uv
            guard runCommand(
                Paths.uvBinary.path,
                args: ["venv", Paths.venv.path, "--python", "3.13", "--clear"],
                step: "Creating Python environment..."
            ) else {
                updateState(.failed("Failed to create Python venv"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            // Step 2: Install mlx-audio
            updateState(.inProgress("Installing MLX Audio (TTS)..."), progress: 0.2)
            guard uvPipInstall("mlx-audio") else {
                updateState(.failed("Failed to install mlx-audio"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            // Step 3: Install mlx-whisper
            updateState(.inProgress("Installing MLX Whisper (STT)..."), progress: 0.4)
            guard uvPipInstall("mlx-whisper") else {
                updateState(.failed("Failed to install mlx-whisper"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            // Step 4: Install spaCy model (required by Kokoro TTS)
            updateState(.inProgress("Installing language model..."), progress: 0.6)
            guard uvPipInstall(
                "en_core_web_sm@https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
            ) else {
                updateState(.failed("Failed to install spaCy model"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            // Step 5: Install setuptools
            updateState(.inProgress("Installing dependencies..."), progress: 0.7)
            if !uvPipInstall("setuptools<81") {
                NSLog("Warning: setuptools install failed — TTS server may not work")
            }

            updateState(.inProgress("Finishing up..."), progress: 0.9)

            // Mark setup complete
            try? "done".write(to: Paths.setupComplete, atomically: true, encoding: .utf8)

            updateState(.complete, progress: 1.0)
            DispatchQueue.main.async {
                self.isSetupRunning = false
                completion(true)
            }
        }
    }

    /// Re-run setup (e.g., after update)
    func resetAndRerun(completion: @escaping (Bool) -> Void) {
        guard !isSetupRunning else { return }
        try? FileManager.default.removeItem(at: Paths.setupComplete)
        runFirstLaunchSetup(completion: completion)
    }

    // MARK: - Private

    private func uvPipInstall(_ package: String) -> Bool {
        runCommand(
            Paths.uvBinary.path,
            args: ["pip", "install", "--python", Paths.python.path, package],
            step: "Installing \(package)..."
        )
    }

    private func runCommand(_ executable: String, args: [String], step: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let logFile = FileHandle.forWritingOrCreate(at: Paths.setupLog)
        logFile.seekToEndOfFile()
        if let logData = "=== \(step) ===\n\(executable) \(args.joined(separator: " "))\n".data(using: .utf8) {
            logFile.write(logData)
        }
        process.standardOutput = logFile
        process.standardError = logFile

        do {
            try process.run()
            process.waitUntilExit()
            try? logFile.close()
            let success = process.terminationStatus == 0
            if !success {
                NSLog("Setup step failed: \(step) (exit \(process.terminationStatus))")
            }
            return success
        } catch {
            try? logFile.close()
            NSLog("Setup step error: \(step) — \(error)")
            return false
        }
    }

    private func updateState(_ state: SetupState, progress: Double) {
        DispatchQueue.main.async {
            self.state = state
            self.progress = progress
        }
    }
}
