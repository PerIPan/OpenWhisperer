import OpenWhispererKit

/// Checks for `NumberNormalizer.normalize` — numerics → spoken words before g2p.
/// Returns a list of human-readable failures (empty = all passed).
func numberNormalizerFailures() -> [String] {
    var failures: [String] = []

    func expect(_ input: String, _ expected: String, _ name: String) {
        let r = NumberNormalizer.normalize(input)
        if r != expected {
            failures.append(
                "NumberNormalizer.\(name): normalize(\(input.debugDescription)) -> "
                + "\(r.debugDescription); expected \(expected.debugDescription)"
            )
        }
    }

    expect("It costs $5.99 today.", "It costs five dollars and ninety nine cents today.", "moneyDollarsCents")
    expect("that's $1 even", "that's one dollar even", "moneySingular")
    expect("price $5.00 flat", "price five dollars flat", "moneyZeroCents")
    expect("$1,250.00 total", "one thousand two hundred fifty dollars total", "moneyCommasZeroCents")
    expect("15% off", "fifteen percent off", "percent")
    expect("pi is 3.14", "pi is three point one four", "decimal")
    expect("room 101", "room one hundred one", "integer")
    expect("we met in 2026", "we met in two thousand twenty six", "year")
    expect("no numbers here", "no numbers here", "passthrough")

    return failures
}
