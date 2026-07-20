import Foundation

/// Text → 5×7 dot-matrix columns for the overlay's LED marquee. Row-major glyph
/// definitions (legible, verifiable), transposed to columns at lookup. Only the
/// glyphs the status words need are defined; unknown characters render blank.
public enum DotMatrix {
    public static let rows = 7
    private static let glyphWidth = 5

    private static let font: [Character: [String]] = [
        "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
        "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
        "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
        "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
        "G": ["01111", "10000", "10000", "10011", "10001", "10001", "01111"],
        "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
        "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
        "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
        "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
        "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
        " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
    ]

    /// Columns of 7 bools (top → bottom), glyphs joined by one blank column.
    public static func columns(for text: String) -> [[Bool]] {
        var result: [[Bool]] = []
        for (index, character) in text.uppercased().enumerated() {
            if index > 0 { result.append(Array(repeating: false, count: rows)) }
            let glyph = font[character] ?? font[" "]!
            for column in 0..<glyphWidth {
                result.append((0..<rows).map { row in
                    Array(glyph[row])[column] == "1"
                })
            }
        }
        return result
    }
}
