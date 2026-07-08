import Foundation

public struct TTSVoice: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let language: String
    public let region: String
    public let gender: String
    public var cached: Bool?

    public init(id: String, name: String, language: String, region: String, gender: String, cached: Bool? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.region = region
        self.gender = gender
        self.cached = cached
    }
}

public struct TTSVoiceGroup: Sendable {
    public let name: String
    public let voices: [TTSVoice]
    
    public init(name: String, voices: [TTSVoice]) {
        self.name = name
        self.voices = voices
    }
}

public enum TTSVoiceRegistry {
    public static let groups: [TTSVoiceGroup] = [
        TTSVoiceGroup(name: "English (US)", voices: [
            TTSVoice(id: "af_heart", name: "Heart", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_bella", name: "Bella", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_alloy", name: "Alloy", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_aoede", name: "Aoede", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_jessica", name: "Jessica", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_kore", name: "Kore", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_nicole", name: "Nicole", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_nova", name: "Nova", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_river", name: "River", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_sarah", name: "Sarah", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_sky", name: "Sky", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "am_adam", name: "Adam", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_echo", name: "Echo", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_eric", name: "Eric", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_fenrir", name: "Fenrir", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_liam", name: "Liam", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_michael", name: "Michael", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_onyx", name: "Onyx", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_puck", name: "Puck", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_santa", name: "Santa", language: "English", region: "US", gender: "Male")
        ]),
        TTSVoiceGroup(name: "English (UK)", voices: [
            TTSVoice(id: "bf_alice", name: "Alice", language: "English", region: "UK", gender: "Female"),
            TTSVoice(id: "bf_emma", name: "Emma", language: "English", region: "UK", gender: "Female"),
            TTSVoice(id: "bf_isabella", name: "Isabella", language: "English", region: "UK", gender: "Female"),
            TTSVoice(id: "bf_lily", name: "Lily", language: "English", region: "UK", gender: "Female"),
            TTSVoice(id: "bm_daniel", name: "Daniel", language: "English", region: "UK", gender: "Male"),
            TTSVoice(id: "bm_fable", name: "Fable", language: "English", region: "UK", gender: "Male"),
            TTSVoice(id: "bm_george", name: "George", language: "English", region: "UK", gender: "Male"),
            TTSVoice(id: "bm_lewis", name: "Lewis", language: "English", region: "UK", gender: "Male")
        ]),
        TTSVoiceGroup(name: "French", voices: [
            TTSVoice(id: "ff_siwis", name: "Siwis", language: "French", region: "FR", gender: "Female")
        ]),
        TTSVoiceGroup(name: "Italian", voices: [
            TTSVoice(id: "if_sara", name: "Sara", language: "Italian", region: "IT", gender: "Female"),
            TTSVoice(id: "im_nicola", name: "Nicola", language: "Italian", region: "IT", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Spanish", voices: [
            TTSVoice(id: "ef_dora", name: "Dora", language: "Spanish", region: "ES", gender: "Female"),
            TTSVoice(id: "em_alex", name: "Alex", language: "Spanish", region: "ES", gender: "Male"),
            TTSVoice(id: "em_santa", name: "Santa", language: "Spanish", region: "ES", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Portuguese (BR)", voices: [
            TTSVoice(id: "pf_dora", name: "Dora", language: "Portuguese", region: "BR", gender: "Female"),
            TTSVoice(id: "pm_alex", name: "Alex", language: "Portuguese", region: "BR", gender: "Male"),
            TTSVoice(id: "pm_santa", name: "Santa", language: "Portuguese", region: "BR", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Hindi", voices: [
            TTSVoice(id: "hf_alpha", name: "Alpha", language: "Hindi", region: "IN", gender: "Female"),
            TTSVoice(id: "hf_beta", name: "Beta", language: "Hindi", region: "IN", gender: "Female"),
            TTSVoice(id: "hm_omega", name: "Omega", language: "Hindi", region: "IN", gender: "Male"),
            TTSVoice(id: "hm_psi", name: "Psi", language: "Hindi", region: "IN", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Japanese", voices: [
            TTSVoice(id: "jf_alpha", name: "Alpha", language: "Japanese", region: "JP", gender: "Female"),
            TTSVoice(id: "jf_gongitsune", name: "Gongitsune", language: "Japanese", region: "JP", gender: "Female"),
            TTSVoice(id: "jf_nezumi", name: "Nezumi", language: "Japanese", region: "JP", gender: "Female"),
            TTSVoice(id: "jf_tebukuro", name: "Tebukuro", language: "Japanese", region: "JP", gender: "Female"),
            TTSVoice(id: "jm_kumo", name: "Kumo", language: "Japanese", region: "JP", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Chinese", voices: [
            TTSVoice(id: "zf_xiaobei", name: "Xiaobei", language: "Chinese", region: "CN", gender: "Female"),
            TTSVoice(id: "zf_xiaoni", name: "Xiaoni", language: "Chinese", region: "CN", gender: "Female"),
            TTSVoice(id: "zf_xiaoxiao", name: "Xiaoxiao", language: "Chinese", region: "CN", gender: "Female"),
            TTSVoice(id: "zf_xiaoyi", name: "Xiaoyi", language: "Chinese", region: "CN", gender: "Female"),
            TTSVoice(id: "zm_yunjian", name: "Yunjian", language: "Chinese", region: "CN", gender: "Male"),
            TTSVoice(id: "zm_yunxi", name: "Yunxi", language: "Chinese", region: "CN", gender: "Male"),
            TTSVoice(id: "zm_yunxia", name: "Yunxia", language: "Chinese", region: "CN", gender: "Male"),
            TTSVoice(id: "zm_yunyang", name: "Yunyang", language: "Chinese", region: "CN", gender: "Male")
        ])
    ]

    public static var allVoices: [TTSVoice] {
        groups.flatMap { $0.voices }
    }
}
