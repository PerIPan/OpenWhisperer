import Foundation

/// Did an accessibility write that *reported* success actually land?
///
/// `AXUIElementSetAttributeValue` returning `.success` means only that the app accepted the
/// message — not that it applied it. iTerm2 accepts a `kAXValue` write and silently discards
/// it (#49): the insertion was reported as successful, so the caller never fell back to
/// CGEvent Unicode typing, which is the path that does work there. Terminal.app only "works"
/// because its write fails honestly and the fallback runs.
///
/// **Deliberately biased toward trusting the write.** A false negative means typing the text a
/// second time, and a user seeing their sentence twice is worse than the bug this fixes — so
/// this reports failure only where nothing *can* have been inserted: the value was readable
/// both before and after, and is byte-identical. Anything else — unreadable at either end, or
/// changed in a way we can't attribute (a terminal repainting, an app normalizing what it
/// stored) — counts as inserted.
public enum AXInsertionCheck {
    /// Whether to believe a successful-looking write of `inserted`.
    ///
    /// - Parameters:
    ///   - before: the element's value read before the write, or nil if it couldn't be read.
    ///   - after: the value read back after, or nil if it couldn't be read.
    ///   - inserted: the text the write was supposed to add.
    public static func didInsert(before: String?, after: String?, inserted: String) -> Bool {
        // An empty insert is vacuously done, and would make "unchanged" the correct outcome.
        guard !inserted.isEmpty else { return true }
        // No baseline or no read-back: nothing to compare, so keep the old behaviour.
        guard let before, let after else { return true }
        // The one provable case — the element is exactly as we found it.
        return after != before
    }
}
