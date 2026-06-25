import Foundation
import SwiftUI

/// First-launch setup. Native STT (WhisperKit) + native TTS (FluidAudio) run fully in-process
/// on the ANE — both download their CoreML models lazily on first use, and load failures surface
/// via `ServerManager` / the standby overlay. So setup has nothing to install; it just marks
/// itself complete. (The former `uv`/venv/pip bootstrap was removed in the Phase-2b port.)
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

    /// First-launch setup: nothing to install (models load on demand), so just persist the
    /// completion marker and report success.
    func runFirstLaunchSetup(completion: @escaping (Bool) -> Void) {
        guard !isSetupComplete else { completion(true); return }
        guard !isSetupRunning else { return }
        isSetupRunning = true

        Paths.ensureDirectories()
        do {
            try "done".write(to: Paths.setupComplete, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Setup: failed to write completion marker (\(Paths.setupComplete.path)): \(error) — will re-run next launch")
        }

        updateState(.complete, progress: 1.0)
        isSetupRunning = false
        completion(true)
    }

    /// Re-run setup (e.g., after an update): clear the marker, then re-run.
    func resetAndRerun(completion: @escaping (Bool) -> Void) {
        guard !isSetupRunning else { return }
        try? FileManager.default.removeItem(at: Paths.setupComplete)
        runFirstLaunchSetup(completion: completion)
    }

    private func updateState(_ state: SetupState, progress: Double) {
        DispatchQueue.main.async {
            self.state = state
            self.progress = progress
        }
    }
}
