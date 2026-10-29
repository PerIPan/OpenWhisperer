import OpenWhispererKit

func voiceMigrationFailures() -> [String] {
    var failures: [String] = []

    // 2.0.9: af_heart → Heart on Pocket; nothing else moves.
    for (current, expected) in [("af_heart", "pocket:heart"), ("af_heart\n", "pocket:heart"), (" af_heart ", "pocket:heart")] {
        if VoiceMigration.pocketHeart(current: current) != expected {
            failures.append("VoiceMigration.pocketHeart(\(current.debugDescription)): expected \(expected)")
        }
    }
    for current in [nil, "", "bf_emma", "am_michael", "supertonic:nl:F1", "pocket:jane", "pocket:heart", "AF_HEART"] as [String?] {
        if let got = VoiceMigration.pocketHeart(current: current) {
            failures.append("VoiceMigration.pocketHeart(\(String(describing: current))): should leave alone, got \(got)")
        }
    }

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
