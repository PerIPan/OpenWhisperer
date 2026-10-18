import AppKit
import Carbon.HIToolbox
import Combine
import OpenWhispererKit
import os.log

private let hotkeyLog = OSLog(subsystem: "com.openwhisperer", category: "hotkey")

/// Which modifier key triggers push-to-talk.
enum PTTKey: String, CaseIterable {
    case fn = "fn"
    case ctrl = "ctrl"
    case option = "option"
    case cmd = "cmd"
    case rightCtrl = "rightCtrl"
    case rightOption = "rightOption"
    case rightCmd = "rightCmd"

    var label: String {
        switch self {
        case .fn: return "fn"
        case .ctrl: return "Ctrl"
        case .option: return "Option"
        case .cmd: return "Cmd"
        case .rightCtrl: return "Right Ctrl"
        case .rightOption: return "Right Option"
        case .rightCmd: return "Right Cmd"
        }
    }

    /// The device-independent flag for this key's family. Used only by the release poll, which
    /// reads the live modifier state: the left/right device bits are an event detail, and if they
    /// were missing from that state a held right-side key would read as released and cut the
    /// dictation off. Matching the family can only err toward "still held" (both Ctrls down).
    var familyFlag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .ctrl, .rightCtrl: return .control
        case .option, .rightOption: return .option
        case .cmd, .rightCmd: return .command
        }
    }
}

/// Manages a global modifier-key toggle hotkey for push-to-talk dictation.
/// Detects solo modifier taps (press+release without any other key in between)
/// to avoid conflicts with key combos like Ctrl+C.
///
/// The decisions live in `HotkeyStateMachine` (Kit, unit-tested); this class only feeds it
/// AppKit events and a release poll, and maps its events onto the callbacks below.
class HotkeyManager {
    var onToggle: (() -> Void)?

    /// Called the moment the hotkey is pressed down (before release).
    /// Used to capture the frontmost app PID before any focus shifts occur.
    var onKeyDown: (() -> Void)?

    /// Called on key release (separate from onToggle).
    /// Used by hold-to-talk mode to stop recording on release.
    var onKeyUp: (() -> Void)?

    /// Called once when another key goes down while the trigger is held (Ctrl+C): the press was
    /// a shortcut, not dictation. Hold-to-talk cancels the recording it started on key down;
    /// neither `onKeyUp` nor `onToggle` fires for that hold.
    var onCombo: (() -> Void)?

    var pttKey: PTTKey = .ctrl {
        didSet {
            if pttKey != oldValue {
                machine.reset()
                stopReleasePoll()
            }
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Accessed only on main thread — global monitor dispatches to main.
    private var machine = HotkeyStateMachine()
    /// Runs only while the key is held. Global monitors get no events during secure input, so a
    /// release landing then is never delivered; this reads the live modifier state instead.
    private var releasePoll: Timer?
    private static let releasePollInterval: TimeInterval = 0.25

    func start() {
        // Global monitor: catches events when our app is NOT focused.
        // Global monitors deliver on a private AppKit thread, so we dispatch to main.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleEvent(event)
            }
        }

        // Local monitor: catches events when our app IS focused.
        // Dispatch to main for consistency with global monitor (M-5).
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            DispatchQueue.main.async { self?.handleEvent(event) }
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        stopReleasePoll()
    }

    /// Must be called on main thread (global monitor dispatches here).
    private func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let pressed: Bool
            switch pttKey {
            case .fn:
                pressed = event.modifierFlags.contains(.function)
            case .ctrl:
                pressed = event.modifierFlags.contains(.control)
            case .option:
                pressed = event.modifierFlags.contains(.option)
            case .cmd:
                pressed = event.modifierFlags.contains(.command)
            case .rightCtrl:
                pressed = event.modifierFlags.contains(.control) && (event.modifierFlags.rawValue & 0x2000) != 0
            case .rightOption:
                pressed = event.modifierFlags.contains(.option) && (event.modifierFlags.rawValue & 0x0040) != 0
            case .rightCmd:
                pressed = event.modifierFlags.contains(.command) && (event.modifierFlags.rawValue & 0x0010) != 0
            }

            dispatch(machine.keyState(held: pressed))

        case .keyDown:
            dispatch(machine.otherKeyDown())

        default:
            break
        }
    }

    /// Map a state-machine event onto the callbacks. Main thread only.
    private func dispatch(_ event: HotkeyStateMachine.Event?) {
        guard let event else { return }
        switch event {
        case .down:
            startReleasePoll()
            onKeyDown?()
        case .up:
            stopReleasePoll()
            // Fire onKeyUp first (hold-to-talk uses this to stop recording)
            onKeyUp?()
            // onToggle fires second — AppDelegate guards against hold-to-talk (L-3)
            onToggle?()
        case .combo:
            // The key is still held: the poll keeps running until the release, which the
            // machine swallows, so it stops itself once `isDown` clears.
            onCombo?()
        }
    }

    private func startReleasePoll() {
        stopReleasePoll()
        let timer = Timer(timeInterval: Self.releasePollInterval, repeats: true) { [weak self] _ in
            self?.pollRelease()
        }
        // .common, so a menu being tracked (the menubar dropdown) doesn't pause it.
        RunLoop.main.add(timer, forMode: .common)
        releasePoll = timer
    }

    private func stopReleasePoll() {
        releasePoll?.invalidate()
        releasePoll = nil
    }

    private func pollRelease() {
        guard machine.isDown else { stopReleasePoll(); return }
        let live = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        let event = machine.poll(held: live.contains(pttKey.familyFlag))
        if !machine.isDown {
            stopReleasePoll()
            // Only reached when the release EVENT never arrived — worth knowing which cause.
            os_log(.default, log: hotkeyLog,
                   "PTT release missed by the event monitor, recovered by poll (secure input: %{public}@)",
                   IsSecureEventInputEnabled() ? "on" : "off")
        }
        dispatch(event)
    }

    deinit {
        stop()
    }
}
