import Foundation

/// One short spoken sample per language, for the Settings → Voice preview button.
///
/// The sample **must** be in the voice's own language. An English line read by a Greek
/// voice reproduces exactly the unintelligibility Supertonic-3 was added to fix, so a
/// preview in the wrong language would misrepresent the voice it is demonstrating.
///
/// Two clauses rather than one word: prosody — where a voice puts stress and how it
/// handles a sentence boundary — is most of what distinguishes F1 from M1, and a single
/// word reveals none of it.
public enum TTSSampleText {
    /// Used for English and as the fallback for any language without an entry, so a voice
    /// added upstream still previews instead of failing silently.
    public static let fallback = "Hello, this is how I sound. I'll read your replies out loud."

    /// Kokoro fuses language into the voice id's first character (`af_heart` is American
    /// English female). Supertonic carries its language explicitly, so it never needs this.
    ///
    /// Deliberately *not* shared with the persona map in `hooks/voice-shared.sh`: that one
    /// picks a national character for the nudge, this one picks a sentence to synthesize.
    /// Same input, unrelated purposes — coupling them would tie UI copy to model steering.
    private static let kokoroPrefixLanguage: [Character: String] = [
        "a": "en", "b": "en", "f": "fr", "i": "it",
        "e": "es", "p": "pt", "h": "hi", "j": "ja", "z": "zh",
    ]

    /// A wrong translation is audible, so treat corrections as bug fixes.
    ///
    /// **Every sample must be gender-neutral.** Each language ships both a female and a
    /// male voice reading the same string, so a gendered first-person verb is wrong half
    /// the time — and a preview is the one place that is maximally obvious. Where a
    /// language marks gender on the verb (Hindi's future, the Slavic l-participle), the
    /// second clause is phrased passively to avoid it.
    private static let samples: [String: String] = [
        "en": fallback,
        // Kokoro's nine
        "fr": "Bonjour, voici à quoi ressemble ma voix. Je lirai tes réponses à voix haute.",
        "it": "Ciao, questa è la mia voce. Leggerò le tue risposte ad alta voce.",
        "es": "Hola, esta es mi voz. Leeré tus respuestas en voz alta.",
        "pt": "Olá, esta é a minha voz. Vou ler suas respostas em voz alta.",
        "hi": "नमस्ते, मेरी आवाज़ ऐसी है। आपके जवाब ज़ोर से पढ़े जाएँगे।",
        "ja": "こんにちは。これが私の声です。返信を読み上げます。",
        "zh": "你好，这就是我的声音。我会朗读你的回复。",
        // Supertonic's twenty-four
        "ar": "مرحبًا، هكذا يبدو صوتي. سأقرأ ردودك بصوت عالٍ.",
        "bg": "Здравей, така звуча. Ще чета отговорите ти на глас.",
        "cs": "Ahoj, takhle zním. Budu ti číst odpovědi nahlas.",
        "da": "Hej, sådan lyder jeg. Jeg læser dine svar højt.",
        "de": "Hallo, so klinge ich. Ich lese deine Antworten laut vor.",
        "el": "Γεια σου, έτσι ακούγομαι. Θα διαβάζω τις απαντήσεις σου δυνατά.",
        "et": "Tere, nii ma kõlan. Loen sinu vastused ette.",
        "fi": "Hei, tältä kuulostan. Luen vastauksesi ääneen.",
        "hr": "Bok, ovako zvučim. Čitat ću tvoje odgovore naglas.",
        "hu": "Szia, így hangzom. Felolvasom a válaszaidat.",
        "id": "Halo, beginilah suara saya. Saya akan membacakan jawabanmu.",
        "ko": "안녕하세요, 제 목소리는 이렇습니다. 답변을 읽어 드릴게요.",
        "lt": "Sveiki, štai kaip aš skambu. Skaitysiu tavo atsakymus balsu.",
        "lv": "Sveiks, tā es skanu. Es lasīšu tavas atbildes skaļi.",
        "nl": "Hallo, zo klink ik. Ik lees je antwoorden hardop voor.",
        "pl": "Cześć, tak brzmię. Przeczytam twoje odpowiedzi na głos.",
        "ro": "Salut, așa sun. Îți voi citi răspunsurile cu voce tare.",
        "ru": "Привет, вот как я звучу. Я буду читать ответы вслух.",
        "sk": "Ahoj, takto znejem. Budem ti čítať odpovede nahlas.",
        "sl": "Živjo, tako zvenim. Tvoji odgovori bodo prebrani na glas.",
        "sv": "Hej, så här låter jag. Jag läser dina svar högt.",
        "tr": "Merhaba, sesim böyle. Yanıtlarını yüksek sesle okuyacağım.",
        "uk": "Привіт, ось як я звучу. Я читатиму відповіді вголос.",
        "vi": "Xin chào, giọng tôi nghe như thế này. Tôi sẽ đọc to câu trả lời của bạn.",
    ]

    /// The ISO language a voice id speaks, or nil when it can't be determined.
    public static func language(forVoiceID voiceID: String) -> String? {
        let route = TTSVoiceRouter.route(voiceID)
        if let language = route.language { return language }
        // Pocket is English only; its names ("heart") would otherwise read as a Kokoro prefix (h → Hindi).
        if route.engine == .pocket { return "en" }
        guard let first = route.voice.lowercased().first else { return nil }
        return kokoroPrefixLanguage[first]
    }

    /// The sample to synthesize when previewing `voiceID`, always non-empty.
    public static func sample(forVoiceID voiceID: String) -> String {
        guard let language = language(forVoiceID: voiceID) else { return fallback }
        return samples[language] ?? fallback
    }
}
