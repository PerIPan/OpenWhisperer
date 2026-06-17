import OpenWhispererKit

func voiceMigrationFailures() -> [String] {
    var failures: [String] = []

    func expect(_ input: String, _ expected: String, _ name: String) {
        let r = VoiceMigration.stripVoiceBlock(from: input)
        if r != expected {
            failures.append("VoiceMigration.\(name): got \(r.debugDescription); expected \(expected.debugDescription)")
        }
    }

    expect("# Project\n\n## Voice Mode\nALWAYS include a [VOICE: ...] tag.\n\nExample: x",
           "# Project",
           "stripsVoiceSectionToEOF")
    expect("# A\n\n## Voice Mode\nblah\n\n## Keep Me\nkept",
           "# A\n\n## Keep Me\nkept",
           "stopsAtNextHeading")
    expect("# No voice here\njust text",
           "# No voice here\njust text",
           "leavesUnrelatedContentUnchanged")

    return failures
}
