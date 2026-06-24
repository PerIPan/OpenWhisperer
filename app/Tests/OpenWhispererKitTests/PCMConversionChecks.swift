import OpenWhispererKit

/// Checks for `PCMConversion.normalizeInt16` (Int16 → Float32 in [-1, 1)).
func pcmConversionFailures() -> [String] {
    var failures: [String] = []

    func expect(_ input: [Int16], _ expected: [Float], _ name: String, tol: Float = 1e-6) {
        let r = PCMConversion.normalizeInt16(input)
        let mismatch = r.count != expected.count
            || zip(r, expected).contains { abs($0 - $1) > tol }
        if mismatch {
            failures.append("PCMConversion.\(name): normalizeInt16(\(input)) -> \(r); expected \(expected)")
        }
    }

    expect([], [], "empty")
    expect([0], [0.0], "zero")
    expect([-32768], [-1.0], "minClipsToNegativeOne")
    expect([16384], [0.5], "half")
    expect([-16384], [-0.5], "negativeHalf")
    expect([32767], [Float(32767.0 / 32768.0)], "maxNearPositiveOne")
    expect([0, 16384, -16384, -32768], [0, 0.5, -0.5, -1.0], "sequence")

    return failures
}
