import Foundation

/// Voice interaction mode — determines how recording is triggered.
enum InteractionMode: String, CaseIterable {
    case pressToTalk = "pressToTalk"
    case holdToTalk = "holdToTalk"
    case handsFree = "handsFree"

    var label: String {
        switch self {
        case .pressToTalk: return "Press-to-Talk"
        case .holdToTalk: return "Hold-to-Talk"
        case .handsFree: return "Hands-Free"
        }
    }

    var description: String {
        switch self {
        case .pressToTalk: return "Press key to start, press again to stop"
        case .holdToTalk: return "Hold key to record, release to transcribe"
        case .handsFree: return "Say \"initiate\" to record, 3s silence to transcribe"
        }
    }

    func save() {
        try? rawValue.write(to: Paths.interactionMode, atomically: true, encoding: .utf8)
    }

    static func load() -> InteractionMode {
        guard let raw = try? String(contentsOf: Paths.interactionMode, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let mode = InteractionMode(rawValue: raw) else {
            return .pressToTalk
        }
        return mode
    }
}
