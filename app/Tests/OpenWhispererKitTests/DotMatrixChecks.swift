import OpenWhispererKit

/// Checks for `DotMatrix` — text → 5×7 dot-matrix columns for the overlay marquee.
func dotMatrixFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("DotMatrix.\(name): \(detail)") }
    }

    // "L": full-height left stem, bottom-only right edge.
    let l = DotMatrix.columns(for: "L")
    expect(l.count == 5, "glyphWidth", "got \(l.count)")
    expect(l[0] == Array(repeating: true, count: 7), "lStem", "got \(l[0])")
    expect(l[4] == [false, false, false, false, false, false, true], "lFoot", "got \(l[4])")

    // Two glyphs joined by exactly one blank separator column.
    let lo = DotMatrix.columns(for: "LO")
    expect(lo.count == 11, "separatorWidth", "got \(lo.count)")
    expect(lo[5] == Array(repeating: false, count: 7), "separatorBlank", "got \(lo[5])")

    // Case-insensitive; unknown characters render as blank glyphs, not crashes.
    expect(DotMatrix.columns(for: "l") == l, "caseInsensitive", "lowercase differs")
    let unknown = DotMatrix.columns(for: "?")
    expect(unknown.count == 5 && unknown.allSatisfy { $0.allSatisfy { !$0 } }, "unknownBlank", "got \(unknown)")

    // Empty string → no columns.
    expect(DotMatrix.columns(for: "").isEmpty, "empty", "got non-empty")

    // Every status word the overlay marquee scrolls must have full glyph
    // coverage — a missing glyph renders blank and silently truncates the
    // word on screen (the "STANDBY shows as AND" bug). Update this list when
    // TranscriptionOverlay's marquee words change.
    for word in ["STANDBY", "ERROR", "LOADING"] {
        for character in word {
            let glyph = DotMatrix.columns(for: String(character))
            expect(!glyph.allSatisfy { $0.allSatisfy { !$0 } }, "coverage\(character)",
                   "'\(character)' in \"\(word)\" renders blank")
        }
    }

    // Every column is exactly 7 rows.
    expect(DotMatrix.columns(for: "LOADING ERROR").allSatisfy { $0.count == 7 }, "rowCount", "a column isn't 7 rows")

    return failures
}
