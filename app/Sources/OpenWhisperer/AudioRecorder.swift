import AVFoundation
import AppKit
import Combine
import os.log
import OpenWhispererKit

private let audioLog = OSLog(subsystem: "com.openwhisperer.app", category: "audio")

/// Records microphone audio, provides real-time RMS levels for waveform,
/// and exports 16 kHz mono Float32 PCM for in-process Parakeet (FluidAudio) transcription.
class AudioRecorder: ObservableObject {
    enum State {
        case idle, recording, uploading
        /// Hands-free: listening for keyword, mic open but not buffering for STT
        case listening
    }

    // @Published must only be mutated from main thread
    @Published var state: State = .idle
    @Published var audioLevel: Float = 0.0
    @Published var levelHistory: [Float] = Array(repeating: 0, count: 50)
    /// Normalized (0…1) per-band energy of the latest input buffer's channel-0 samples,
    /// for the overlay's segmented spectrum display — see `SpectrumBands`.
    @Published private(set) var spectrumBands: [Float] = []
    @Published var micPermission: Bool = false
    /// Set when the audio engine fails to configure or start, so the UI can surface it (T2.3).
    @Published var engineError: String?
    /// True when audio level is below silence threshold (hands-free mode)
    @Published var isSilent: Bool = true

    /// Called when silence exceeds the configured threshold (hands-free mode).
    /// Fired on the main thread.
    var onSilenceTimeout: (() -> Void)?

    /// Called with raw audio buffers for keyword detection (any thread).
    var onRawAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Ambient noise floor (calibrated on hands-free activation)
    private(set) var ambientNoiseFloor: Float = 0.01
    /// Speech threshold multiplier over ambient noise floor
    var speechThresholdMultiplier: Float = 4.0
    /// Silence duration threshold in seconds (configurable, default 3)
    var silenceThresholdSeconds: TimeInterval = 3.0
    /// Whether silence detection is active (hands-free mode).
    /// Read from audio tap thread, written from main — use lock for thread safety (C-3).
    private var _silenceDetectionEnabled = false
    var silenceDetectionEnabled: Bool {
        get { bufferLock.lock(); defer { bufferLock.unlock() }; return _silenceDetectionEnabled }
        set { bufferLock.lock(); _silenceDetectionEnabled = newValue; bufferLock.unlock() }
    }

    @Published private(set) var silenceStart: Date?
    private var silenceFired = false
    /// Whether we are currently buffering PCM for STT (false in listening stage).
    /// Read from audio tap thread, written from main — use lock for thread safety (C-2).
    private var _bufferingForSTT = false
    private var bufferingForSTT: Bool {
        get { bufferLock.lock(); defer { bufferLock.unlock() }; return _bufferingForSTT }
        set { bufferLock.lock(); _bufferingForSTT = newValue; bufferLock.unlock() }
    }

    private var engine: AVAudioEngine?
    private var pcmBuffers: [AVAudioPCMBuffer] = []
    private let bufferLock = NSLock()
    /// Protected by bufferLock — accessed from audio tap thread and main thread.
    private var converter: AVAudioConverter?
    private let targetSampleRate: Double = 16000
    private let smoothing: Float = 0.25
    // swiftlint:disable:next force_unwrapping — PCM Int16 16kHz mono is always supported
    private let targetFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000,
                                       channels: 1,
                                       interleaved: true) else {
            fatalError("AVAudioFormat failed for PCM Int16 16kHz mono — unsupported platform")
        }
        return fmt
    }()

    init(skipPermissionCheck: Bool = false) {
        if !skipPermissionCheck {
            checkPermission()
        }
    }

    // MARK: - Permissions

    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async { self.micPermission = true }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async { self?.micPermission = granted }
            }
        default:
            DispatchQueue.main.async { self.micPermission = false }
        }
    }

    func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Listening (hands-free keyword stage, mic open but no STT buffering)

    /// Start the audio engine for keyword detection only (no PCM buffering).
    func startListening() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard micPermission, state == .idle || state == .listening else { return }
        bufferingForSTT = false
        if engine == nil {
            setupEngine()
        }
        state = .listening
    }

    /// Transition from listening to active STT recording (start buffering PCM).
    func startBuffering() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .listening || state == .idle else { return }
        bufferingForSTT = true
        silenceFired = false
        silenceStart = nil
        bufferLock.lock()
        pcmBuffers = []
        bufferLock.unlock()
        state = .recording
    }

    /// Flush current PCM buffers as normalized Float32 (16 kHz mono) and continue
    /// recording (hands-free). In-process equivalent of `flushAndContinue()` for the
    /// native STT path — feeds the model directly without a WAV round-trip.
    func flushAndContinueFloat() -> [Float]? {
        dispatchPrecondition(condition: .onQueue(.main))
        bufferLock.lock()
        let snapshot = pcmBuffers
        pcmBuffers = []
        bufferLock.unlock()
        bufferingForSTT = false
        silenceFired = false
        silenceStart = nil
        state = .uploading
        return Self.mergeToFloat(from: snapshot)
    }

    /// Return to listening state after transcription completes (hands-free).
    func resumeListening() {
        dispatchPrecondition(condition: .onQueue(.main))
        bufferingForSTT = false
        silenceFired = false
        silenceStart = nil
        state = .listening
    }

    // MARK: - Ambient Noise Calibration

    /// Calibrate ambient noise floor by sampling RMS for a short duration.
    /// Includes a warmup delay so the engine's audio tap has time to deliver real samples (Mi-7).
    func calibrateAmbient(warmup: TimeInterval = 0.3, duration: TimeInterval = 0.5, completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Wait for engine warmup before sampling (Mi-7: first samples may be 0.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { [weak self] in
            guard let self else { return }
            var samples: [Float] = []
            let startTime = Date()

            let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                samples.append(self.safeRawRMS)
                if Date().timeIntervalSince(startTime) >= duration {
                    t.invalidate()
                    // Filter out zero samples from engine startup
                    let nonZero = samples.filter { $0 > 0 }
                    let avg = nonZero.isEmpty ? Float(0.01) : nonZero.reduce(0, +) / Float(nonZero.count)
                    self.ambientNoiseFloor = max(avg, 0.005)
                    // Ambient calibration logged via os_log in DictationManager
                    completion()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    // MARK: - Recording (must be called from main thread)

    func startRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard micPermission, state == .idle else { return }
        bufferingForSTT = true
        state = .recording
        setupEngine()
    }

    /// Sets up the AVAudioEngine with input tap. Reused by startRecording and startListening.
    private func setupEngine() {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            os_log(.error, log: audioLog, "AVAudioConverter init failed (hwFormat=%{public}@)", "\(hwFormat)")
            self.engine = nil
            engineError = "Could not configure microphone input — unsupported audio format"
            state = .idle
            return
        }
        bufferLock.lock()
        converter = conv
        pcmBuffers = []
        bufferLock.unlock()

        let bufferSize: AVAudioFrameCount = 512
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Feed raw audio to keyword detector (any thread safe)
            self.onRawAudioBuffer?(buffer)

            let rms = self.computeRMS(buffer: buffer)
            let bands = self.spectrumBands(buffer: buffer)
            DispatchQueue.main.async {
                self.audioLevel = self.audioLevel * (1 - self.smoothing) + rms * self.smoothing
                self.levelHistory.removeFirst()
                self.levelHistory.append(self.audioLevel)
                self.spectrumBands = bands

                // Silence detection for hands-free mode
                if self.silenceDetectionEnabled {
                    self.updateSilenceState(rms: rms)
                }
            }

            // Only buffer PCM when actively recording for STT
            guard self.bufferingForSTT else { return }
            if let converted = self.convert(buffer: buffer) {
                self.bufferLock.lock()
                self.pcmBuffers.append(converted)
                self.bufferLock.unlock()
            }
        }

        do {
            try engine.start()
            engineError = nil  // clear any stale failure from a previous attempt (review)
        } catch {
            os_log(.error, log: audioLog, "AVAudioEngine start failed: %{public}@", error.localizedDescription)
            engineError = "Microphone failed to start — check input device and Microphone permission"
            cleanup()
        }
    }

    /// Stop recording and set state to uploading. Must be called from main thread.
    /// Returns immediately — call `exportWAV()` on a background thread to get the data.
    func stopRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .recording else { return }
        state = .uploading

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        bufferLock.lock()
        converter = nil
        bufferLock.unlock()

        audioLevel = 0
        levelHistory = Array(repeating: 0, count: 50)
        spectrumBands = []
    }

    /// Merge accumulated PCM buffers into normalized Float32 samples (16 kHz mono).
    /// Snapshots under lock, then converts outside to avoid blocking the audio tap.
    /// Safe to call from any thread.
    func exportPCMFloat() -> [Float]? {
        bufferLock.lock()
        let snapshot = pcmBuffers
        pcmBuffers = []
        bufferLock.unlock()
        return Self.mergeToFloat(from: snapshot)
    }

    func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        state = .idle
    }

    private func cleanup() {
        dispatchPrecondition(condition: .onQueue(.main))
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        bufferLock.lock()
        converter = nil
        pcmBuffers = []
        bufferLock.unlock()
        state = .idle
    }

    // MARK: - Silence Detection

    /// Called on main thread from audio tap. Tracks silence duration and fires callback.
    /// Uses raw (unscaled) RMS for consistent threshold behavior across microphones (#1).
    private func updateSilenceState(rms: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        let threshold = ambientNoiseFloor * speechThresholdMultiplier
        // Use thread-safe accessor — rawRMS is written on CoreAudio tap thread (C-1 / M-4)
        let nowSilent = safeRawRMS < threshold

        isSilent = nowSilent

        if nowSilent {
            if silenceStart == nil {
                silenceStart = Date()
            }
            // Only fire silence timeout during active recording (not listening stage)
            if !silenceFired, bufferingForSTT,
               let start = silenceStart,
               Date().timeIntervalSince(start) >= silenceThresholdSeconds {
                silenceFired = true
                onSilenceTimeout?()
            }
        } else {
            // Speech detected — reset silence timer
            silenceStart = nil
            silenceFired = false
        }
    }

    /// Stop the audio engine entirely (used when exiting hands-free or app termination).
    func stopEngine() {
        dispatchPrecondition(condition: .onQueue(.main))
        cleanup()
    }

    // MARK: - Audio Processing

    /// Raw RMS (unscaled). Protected by `bufferLock` — written on CoreAudio tap thread,
    /// read on main thread. Use `safeRawRMS` for all cross-thread reads (C-1).
    private var rawRMS: Float = 0

    /// Thread-safe read of `rawRMS` under `bufferLock` (C-1 / M-4).
    var safeRawRMS: Float {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return rawRMS
    }

    private func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let data = UnsafeBufferPointer(start: channelData[0], count: count)
        let sumSq = data.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumSq / Float(count))
        // Protect write: called from CoreAudio tap thread (C-1)
        bufferLock.lock()
        rawRMS = rms
        bufferLock.unlock()
        // Scale for UI display only (0–1 range for waveform)
        return min(rms * 120.0, 1.0)
    }

    /// Reduce `buffer`'s channel-0 samples to `SpectrumBands.bandCount` normalized band
    /// energies for the overlay's segmented spectrum display.
    private func spectrumBands(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return [Float](repeating: 0, count: SpectrumBands.bandCount)
        }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [Float](repeating: 0, count: SpectrumBands.bandCount) }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        return SpectrumBands.bands(samples: samples, sampleRate: Float(buffer.format.sampleRate), gainDb: 14) // raw mic runs well below synthesized playback loudness
    }

    private func convert(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        bufferLock.lock()
        let conv = converter
        bufferLock.unlock()
        guard let conv else { return nil }
        // Guard against partial buffers from Bluetooth route changes (#2)
        guard buffer.frameLength >= 16 else { return nil }
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrames = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio)) + 32

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        conv.convert(to: outputBuffer, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if error != nil {
            return nil
        }
        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    // MARK: - PCM Export

    /// Concatenate Int16 PCM buffers and normalize to Float32 in [-1, 1) via the
    /// unit-tested `PCMConversion`. Returns nil if there are no samples.
    private static func mergeToFloat(from buffers: [AVAudioPCMBuffer]) -> [Float]? {
        guard !buffers.isEmpty else { return nil }
        var int16s: [Int16] = []
        int16s.reserveCapacity(buffers.reduce(0) { $0 + Int($1.frameLength) })
        for buffer in buffers {
            guard let data = buffer.int16ChannelData else { continue }
            let count = Int(buffer.frameLength)
            guard count > 0 else { continue }
            int16s.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
        }
        guard !int16s.isEmpty else { return nil }
        return PCMConversion.normalizeInt16(int16s)
    }
}
