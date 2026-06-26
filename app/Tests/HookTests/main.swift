import Foundation

/// Plain-executable runner for the bash-hook integration tests (CLT has no XCTest/Testing module).
/// Swift port of the deleted pytest suite. Run with: `swift run HookTests` (exits non-zero on any
/// failure). Aggregates every check group and reports all failures.
var failures: [String] = []
failures += speakableTextFailures()
failures += voiceContextFailures()
failures += ttsHookGateFailures()
failures += codexTtsHookFailures()

if failures.isEmpty {
    print("✅ HookTests: all checks passed")
} else {
    for f in failures {
        FileHandle.standardError.write(Data(("❌ " + f + "\n").utf8))
    }
    FileHandle.standardError.write(Data("\n\(failures.count) check(s) failed\n".utf8))
    exit(1)
}
