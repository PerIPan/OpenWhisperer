import Foundation
import OpenWhispererKit

func ttsVoiceRegistryFailures() -> [String] {
    var failures: [String] = []
    let all = TTSVoiceRegistry.allVoices
    if all.count != 54 {
        failures.append("TTSVoiceRegistry.allVoices: expected 54 voices, got \(all.count)")
    }
    if !all.contains(where: { $0.id == "af_heart" && $0.gender == "Female" && $0.region == "US" }) {
        failures.append("TTSVoiceRegistry.allVoices: missing af_heart or properties mismatched")
    }
    return failures
}
