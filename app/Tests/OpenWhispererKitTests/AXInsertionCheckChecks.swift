import Foundation
import OpenWhispererKit

/// Checks for `AXInsertionCheck` — whether a successful-looking AX write actually landed (#49).
func axInsertionCheckFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("AXInsertionCheck.\(name): \(detail)") }
    }

    // The bug: iTerm2 accepts the write, discards it, and the value is untouched. That is the
    // only case this is allowed to call a failure — and it must, or the CGEvent fallback that
    // works there never runs.
    expect(!AXInsertionCheck.didInsert(before: "$ ", after: "$ ", inserted: "This is a test."),
           "unchangedIsFailure", "an untouched value was reported as inserted")
    expect(!AXInsertionCheck.didInsert(before: "", after: "", inserted: "hello"),
           "unchangedEmptyIsFailure", "an untouched empty value was reported as inserted")

    // The normal path: the text landed.
    expect(AXInsertionCheck.didInsert(before: "$ ", after: "$ This is a test.", inserted: "This is a test."),
           "appendedIsSuccess", "a real insertion was reported as failed")
    expect(AXInsertionCheck.didInsert(before: "", after: "hello", inserted: "hello"),
           "intoEmptyIsSuccess", "an insertion into an empty field was reported as failed")

    // Everything unverifiable must be trusted — a false negative types the text twice, which is
    // worse than the bug. These are the cases where we cannot prove anything.
    expect(AXInsertionCheck.didInsert(before: nil, after: "anything", inserted: "x"),
           "unreadableBeforeTrusted", "an unreadable baseline was treated as failure")
    expect(AXInsertionCheck.didInsert(before: "anything", after: nil, inserted: "x"),
           "unreadableAfterTrusted", "an unreadable read-back was treated as failure")
    expect(AXInsertionCheck.didInsert(before: nil, after: nil, inserted: "x"),
           "bothUnreadableTrusted", "no readable value was treated as failure")
    // Changed, but not in a way we can attribute — a terminal repainting, an app normalizing.
    // Trust it: if our text really is absent the next dictation still works, but a double
    // insertion is visible damage.
    expect(AXInsertionCheck.didInsert(before: "$ ", after: "$ \nuser@host:~$ ", inserted: "This is a test."),
           "changedButUnattributableTrusted", "an unattributable change was treated as failure")

    // An empty insert can't be distinguished from "unchanged", so it is vacuously done.
    expect(AXInsertionCheck.didInsert(before: "$ ", after: "$ ", inserted: ""),
           "emptyInsertTrusted", "an empty insert was treated as failure")

    return failures
}
