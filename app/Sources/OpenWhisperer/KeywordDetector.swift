import Foundation
import Speech
import AVFoundation

/// Lightweight on-device keyword detection using Apple SFSpeechRecognizer.
/// Used in hands-free mode to detect "initiate" (start recording) and "hold on" (barge-in).
class KeywordDetector: ObservableObject {
    enum DetectedKeyword {
        case initiate
        case holdOn
    }

    @Published var isRunning = false
    @Published var permissionGranted = false

    /// Called on main thread when a keyword is detected.
    var onKeywordDetected: ((DetectedKeyword) -> Void)?

    /// Configurable trigger word for starting recording (default: "initiate")
    var triggerWord: String = "initiate"

    /// Barge-in keyword (always "hold on")
    private let bargeInKeyword = "hold on"

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastProcessedText = ""

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        checkPermission()
    }

    // MARK: - Permission

    func checkPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.permissionGranted = status == .authorized
            }
        }
    }

    // MARK: - Start/Stop

    /// Start listening for keywords. Feed audio buffers via `appendAudioBuffer(_:)`.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard permissionGranted, !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            print("[KeywordDetector] SFSpeechRecognizer not available")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        // We only need keyword detection, not full transcription
        if #available(macOS 15.0, *) {
            request.addsPunctuation = false
        }

        recognitionRequest = request
        lastProcessedText = ""

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString.lowercased()
                // Only check new text since last processing
                let newText = String(text.dropFirst(self.lastProcessedText.count))
                if !newText.isEmpty {
                    self.lastProcessedText = text
                    DispatchQueue.main.async {
                        self.checkForKeywords(in: newText)
                    }
                }
            }

            if let error {
                print("[KeywordDetector] Recognition error: \(error.localizedDescription)")
                // Auto-restart on transient errors
                DispatchQueue.main.async {
                    if self.isRunning {
                        self.restart()
                    }
                }
            }
        }

        isRunning = true
        print("[KeywordDetector] Started listening for keywords")
    }

    /// Stop keyword detection.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        isRunning = false
        lastProcessedText = ""
        print("[KeywordDetector] Stopped")
    }

    /// Restart recognition (e.g. after timeout or error).
    private func restart() {
        stop()
        // Brief delay before restarting to avoid rapid cycling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start()
        }
    }

    // MARK: - Audio Feed

    /// Feed an audio buffer from the shared AVAudioEngine tap.
    /// Call from any thread — SFSpeechAudioBufferRecognitionRequest is thread-safe.
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    // MARK: - Keyword Matching

    private func checkForKeywords(in text: String) {
        let lower = text.lowercased()
        if lower.contains(triggerWord.lowercased()) {
            print("[KeywordDetector] Detected trigger: '\(triggerWord)'")
            onKeywordDetected?(.initiate)
            // Reset to avoid re-triggering on the same utterance
            restart()
        } else if lower.contains(bargeInKeyword) {
            print("[KeywordDetector] Detected barge-in: 'hold on'")
            onKeywordDetected?(.holdOn)
            restart()
        }
    }
}
