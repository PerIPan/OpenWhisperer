import OpenWhispererKit

/// Checks for `HotkeyStateMachine` — the decision core behind issue #26 (hold-to-talk sticking).
func hotkeyStateMachineFailures() -> [String] {
    var failures: [String] = []
    typealias M = HotkeyStateMachine

    func expect(_ got: M.Event?, _ want: M.Event?, _ what: String) {
        if got != want { failures.append("HotkeyStateMachine \(what): got \(String(describing: got)), expected \(String(describing: want))") }
    }

    // A clean hold: down, then up.
    do {
        var m = M()
        expect(m.keyState(held: true), .down, "clean hold press")
        expect(m.keyState(held: false), .up, "clean hold release")
        if m.isDown { failures.append("HotkeyStateMachine: still down after a clean release") }
    }

    // THE #26 BUG: Ctrl+C during a hold. The old manager swallowed the release, so a recording
    // started on Ctrl-down never stopped. The combo must be reported — once — so hold-to-talk
    // can cancel, and the release after it must report nothing (no toggle on a shortcut).
    do {
        var m = M()
        expect(m.keyState(held: true), .down, "combo press")
        expect(m.otherKeyDown(), .combo, "Ctrl+C during hold")
        expect(m.otherKeyDown(), nil, "second key in the same combo (reported once)")
        expect(m.keyState(held: false), nil, "release after a combo")
        if m.isDown { failures.append("HotkeyStateMachine: still down after a combo release — next press would be ignored") }
        // The very next hold must work normally: no state leaks from the combo.
        expect(m.keyState(held: true), .down, "press after a combo")
        expect(m.keyState(held: false), .up, "release after a combo-free hold")
    }

    // Typing with the trigger NOT held is not a combo.
    do {
        var m = M()
        expect(m.otherKeyDown(), nil, "key with trigger up")
    }

    // Missed release (secure input swallowed the flagsChanged): the poll recovers it, but only
    // after two consecutive misses, so one stale read can't cut a dictation off.
    do {
        var m = M()
        expect(m.keyState(held: true), .down, "missed-release press")
        expect(m.poll(held: false), nil, "first poll miss (debounced)")
        expect(m.poll(held: false), .up, "second poll miss recovers the release")
        expect(m.keyState(held: false), nil, "late release event after poll recovery (deduped)")
        expect(m.poll(held: false), nil, "poll after release")
    }

    // A held key resets the debounce: miss, held, miss is NOT a release.
    do {
        var m = M()
        _ = m.keyState(held: true)
        expect(m.poll(held: false), nil, "miss 1")
        expect(m.poll(held: true), nil, "held again")
        expect(m.poll(held: false), nil, "miss after a held read (counter reset)")
        if !m.isDown { failures.append("HotkeyStateMachine: a non-consecutive miss released the key") }
    }

    // A poll must never START a recording, even if it reads the key held while we think it's up
    // (a timer tick racing the release event).
    do {
        var m = M()
        expect(m.poll(held: true), nil, "poll held while up")
        if m.isDown { failures.append("HotkeyStateMachine: a poll moved the key down") }
    }

    // A missed release after a combo recovers silently (combo already reported, nothing to stop).
    do {
        var m = M()
        _ = m.keyState(held: true)
        _ = m.otherKeyDown()
        _ = m.poll(held: false)
        expect(m.poll(held: false), nil, "poll release after combo")
        if m.isDown { failures.append("HotkeyStateMachine: combo + missed release left the key down") }
    }

    // Repeated press events while already down (autorepeat-ish noise) don't re-fire .down.
    do {
        var m = M()
        _ = m.keyState(held: true)
        expect(m.keyState(held: true), nil, "duplicate press")
    }

    // reset() (trigger key changed) forgets a hold in progress.
    do {
        var m = M()
        _ = m.keyState(held: true)
        m.reset()
        expect(m.keyState(held: false), nil, "release after reset")
    }

    return failures
}

/// Checks for `TranscriptionBudget` and `RecordingCap`.
func transcriptionBudgetFailures() -> [String] {
    var failures: [String] = []

    // The old flat values are still the floor.
    if TranscriptionBudget.seconds(warm: true, sampleCount: 0) != 35 {
        failures.append("TranscriptionBudget: warm floor changed from 35 s")
    }
    if TranscriptionBudget.seconds(warm: false, sampleCount: 0) != 180 {
        failures.append("TranscriptionBudget: cold floor changed from 180 s")
    }

    // The bug it fixes: a 2-minute translated dictation (~0.3x realtime => ~36-72 s decode
    // depending on the Mac) used to hit the flat 35 s watchdog and lose the audio.
    let twoMinutes = 120 * 16_000
    let budget = TranscriptionBudget.seconds(warm: true, sampleCount: twoMinutes)
    if budget != 155 { failures.append("TranscriptionBudget: 2 min warm = \(budget), expected 155") }
    let slowDecode = 120.0 * 0.6   // translating checkpoint on a slower chip, 2x this Mac
    if budget < slowDecode * 2 {
        failures.append("TranscriptionBudget: 2 min warm budget \(budget) s leaves < 2x headroom over a \(slowDecode) s decode")
    }

    // At the recording cap, the budget still covers a slow translating decode.
    let capSamples = Int(RecordingCap.seconds * TranscriptionBudget.sampleRate)
    let atCap = TranscriptionBudget.seconds(warm: true, sampleCount: capSamples)
    if atCap < RecordingCap.seconds * 0.6 * 1.5 {
        failures.append("TranscriptionBudget: budget at the \(RecordingCap.seconds) s cap (\(atCap) s) can't cover a 0.6x-realtime decode with margin")
    }

    // Negative input can't shrink the budget below the floor.
    if TranscriptionBudget.seconds(warm: true, sampleCount: -5) != 35 {
        failures.append("TranscriptionBudget: negative sampleCount changed the budget")
    }
    return failures
}
