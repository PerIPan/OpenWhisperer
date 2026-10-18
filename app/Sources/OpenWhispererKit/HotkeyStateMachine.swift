import Foundation

/// The decision core of `HotkeyManager`: turns "is the trigger key held?" observations and
/// other-key presses into hotkey events. Pure, so the stuck-recording paths are unit-tested.
///
/// **Why it exists (issue #26, "hold-to-talk occasionally sticks in recording").** Hold-to-talk
/// starts recording on key *down*. The old manager also suppressed the release callback whenever
/// another key went down during the hold — correct for the toggle modes (Ctrl+C must not toggle
/// recording), fatal for hold-to-talk: Ctrl+C with Ctrl as the trigger started a recording on the
/// Ctrl press and then never delivered the release that stops it. The next Ctrl tap "unstuck" it
/// by stopping and transcribing everything captured since. Terminal users press Ctrl+C
/// constantly. Now a combo is its own event, `.combo`, so hold-to-talk can cancel the recording.
///
/// A second, independent cause stays possible: global event monitors receive nothing while
/// secure input is on (password fields, Secure Keyboard Entry), so a release landing in that
/// window is never seen. `poll(held:)` recovers it from the live modifier state.
public struct HotkeyStateMachine: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// The trigger key went down. Hold-to-talk starts recording here.
        case down
        /// The trigger key was released with no other key pressed during the hold.
        case up
        /// Another key went down while the trigger was held: the press belonged to a shortcut
        /// (Ctrl+C), not to dictation. Reported once per hold; the release that follows reports
        /// nothing, so the toggle modes never fire on it.
        case combo
    }

    /// How many consecutive "not held" polls count as a missed release. Two, so a single stale
    /// read can never cut a dictation off mid-sentence; at the manager's 0.25 s interval a
    /// genuinely missed release is recovered within about half a second.
    public static let pollMissesForRelease = 2

    public private(set) var isDown = false
    public private(set) var wasCombo = false
    private var pollMisses = 0

    public init() {}

    /// A modifier-change event reported whether the trigger key is now held.
    public mutating func keyState(held: Bool) -> Event? {
        if held && !isDown {
            isDown = true
            wasCombo = false
            pollMisses = 0
            return .down
        }
        if !held && isDown {
            return release()
        }
        return nil
    }

    /// A non-modifier key went down.
    public mutating func otherKeyDown() -> Event? {
        guard isDown, !wasCombo else { return nil }
        wasCombo = true
        return .combo
    }

    /// The live modifier state, read while the key is believed held. Only ever *releases*: a
    /// poll that sees the key held, or arrives after the release event already landed, does
    /// nothing — a poll must never start a recording.
    public mutating func poll(held: Bool) -> Event? {
        guard isDown else { return nil }
        if held {
            pollMisses = 0
            return nil
        }
        pollMisses += 1
        guard pollMisses >= Self.pollMissesForRelease else { return nil }
        return release()
    }

    /// Forget any hold in progress (the trigger key changed).
    public mutating func reset() {
        isDown = false
        wasCombo = false
        pollMisses = 0
    }

    private mutating func release() -> Event? {
        let combo = wasCombo
        reset()
        return combo ? nil : .up
    }
}
