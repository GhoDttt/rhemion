// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The speech models Rhemion offers, with what Settings › Models shows about each before it is on this Mac:
/// size, languages, a speed estimate and published accuracy per language. Shipped in
/// the app; nothing here is fetched. Their order here breaks ties and places models that have no scores yet.
///
/// Accuracy is word errors per 100 words (characters for ja ko th zh). For each language every offered model is
/// scored on the same test, so the numbers compare across models. Russian, Ukrainian, English, German, Spanish,
/// Japanese, Turkish and Kazakh are our own FLEURS stand (`measured`), English our run of eight Open ASR Leaderboard
/// sets; other languages are the publishers' FLEURS numbers. `uncertainty` is the half-width we treat as noise
/// (the 95 % bootstrap half-width for our numbers): at a band edge the more modest band wins, and two models whose
/// ranges overlap count as equally accurate.
public struct CatalogModel: Sendable, Equatable {
    public enum Engine: String, Sendable { case parakeet, apple, whisper, qwen }

    /// Where a model that isn't Parakeet downloads from (Whisper, Qwen): a pinned file and its SHA-256.
    public struct Download: Sendable, Equatable {
        public let url: String
        public let sha256: String
        /// The file name in the local models folder (`~/.local/share/whisper`, where Whisper files live too).
        public let fileName: String
    }

    public struct Accuracy: Sendable, Equatable {
        public init(wer: Double, uncertainty: Double, source: String, date: String) {
            self.wer = wer; self.uncertainty = uncertainty; self.source = source; self.date = date
        }
        public let wer: Double
        public let uncertainty: Double
        public let source: String
        public let date: String
    }

    public let id: String
    public let name: String
    public let engine: Engine
    /// Download size in bytes; nil for a model that ships with macOS.
    public let approxBytes: Int64?
    /// ISO 639-1 codes. Apple Speech's set depends on the Mac, so it is read at runtime instead (empty here).
    public let languages: [String]
    /// Seconds of work after 10 s of speech on Apple Silicon, before this Mac measures it; nil if unknown.
    public let speedEstimate: Double?
    /// Keyed by ISO 639-1 code; a missing language reads "Not tested".
    public let accuracy: [String: Accuracy]
    /// Set for a Whisper model Rhemion downloads itself.
    public var download: Download? = nil
    /// Offered for download. A model that is no longer (Parakeet v3 and v2: Ultra is more accurate in each of their
    /// languages at the same speed) still runs and is listed once it is on this Mac.
    public var offered = true

}

public enum ModelCatalog {
    /// The model a new install downloads and the runtime falls back to (research A2: Ultra is more accurate than
    /// v3 in every language at the same speed).
    public static let defaultID = "parakeet-ultra"
    /// The 25 languages of Parakeet v3 and its retrainings.
    public static let european = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                           "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"]

    private static let openASR = "Open ASR Leaderboard, 7 English sets"
    private static let fleurs = "FLEURS"

    /// FLEURS word errors per 100 words, v3 and Ultra scored together on the Ultra model card
    /// (huggingface.co/moondream/parakeet-ultra, 2026-09).
    private static let fleursV3Ultra: [String: (v3: Double, ultra: Double)] = [
        "bg": (11.90, 10.09), "hr": (10.93, 9.65), "cs": (10.85, 9.97), "da": (16.78, 14.31), "nl": (6.18, 5.46),
        "et": (13.23, 9.69), "fi": (11.05, 9.19), "fr": (4.81, 4.32), "de": (4.13, 3.61), "el": (35.71, 32.25),
        "hu": (13.65, 10.76), "it": (2.61, 2.00), "lv": (21.38, 15.95), "lt": (21.09, 16.36), "mt": (19.13, 14.92),
        "pl": (6.70, 5.54), "pt": (4.65, 3.96), "ro": (11.54, 9.18), "ru": (5.91, 5.21), "sk": (9.46, 7.03),
        "sl": (21.76, 16.64), "es": (3.12, 2.72), "sv": (13.75, 11.57), "uk": (5.94, 4.75),
    ]

    private static func fleursTable(_ pick: ((v3: Double, ultra: Double)) -> Double, english: CatalogModel.Accuracy) -> [String: CatalogModel.Accuracy] {
        var out = fleursV3Ultra.mapValues {
            CatalogModel.Accuracy(wer: pick($0), uncertainty: 0.6, source: fleurs + ", publisher (moondream)", date: "2026-09")
        }
        out["en"] = english
        return out
    }

    /// Our FLEURS stand: the first 150 test recordings per language (about 70 sentences, two or three readers each), 9 to 15 s each, every model
    /// on the same audio, lower case without punctuation before counting (Cyrillic yo counted as ye). Error and uncertainty per language.
    private static let stand = fleurs + ", Rhemion (150 phrases)"
    /// English on our Open ASR suite: 25 recordings from each of eight leaderboard sets (meetings,
    /// earnings calls, podcasts, audiobooks clean and other, finance, Common Voice, parliament), 0.2 to 30 s, Whisper's
    /// English normalizer, the mean of the sets.
    public static let englishStand = "Open ASR Leaderboard, 8 English sets, Rhemion (200 recordings)"
    private static func measured(_ table: [String: (Double, Double)], english: (Double, Double)? = nil,
                                 over base: [String: CatalogModel.Accuracy] = [:]) -> [String: CatalogModel.Accuracy] {
        var out = base.merging(table.mapValues { .init(wer: $0.0, uncertainty: $0.1, source: stand, date: "2026-10-18") }) { $1 }
        if let english { out["en"] = .init(wer: english.0, uncertainty: english.1, source: englishStand, date: "2026-10-18") }
        return out
    }

    public static let models: [CatalogModel] = [
        CatalogModel(
            id: "parakeet-ultra", name: "Parakeet Ultra", engine: .parakeet, approxBytes: 632_000_000,
            languages: european, speedEstimate: 0.16,
            accuracy: measured(["ru": (4.0, 0.9), "uk": (5.8, 1.1), "de": (4.0, 0.8), "es": (2.7, 0.8)], english: (5.9, 1.6),
                over: fleursTable({ $0.ultra }, english: .init(wer: 5.80, uncertainty: 0.3,
                    source: openASR + ", publisher (moondream)", date: "2026-09")))),
        CatalogModel(
            id: "parakeet-v3", name: "Parakeet v3", engine: .parakeet, approxBytes: 461_000_000,
            languages: european, speedEstimate: 0.16,
            accuracy: fleursTable({ $0.v3 }, english: .init(wer: 6.26, uncertainty: 0.3,
                source: openASR + ", publisher (moondream)", date: "2026-09")), offered: false),
        CatalogModel(
            id: "parakeet-v2", name: "Parakeet v2", engine: .parakeet, approxBytes: 443_000_000,
            languages: ["en"], speedEstimate: 0.16,
            accuracy: ["en": .init(wer: 6.05, uncertainty: 0.3, source: openASR + ", publisher (NVIDIA)", date: "2025-05")],
            offered: false),
        // Speeds of Apple Speech and Whisper: measured on an M-series Mac (10 s takes; Whisper told the
        // language and holding its model in rhemion-transcribe; it takes ~2.4 s when it must detect the language).
        CatalogModel(
            id: "apple-speech", name: "Apple Speech", engine: .apple, approxBytes: nil,
            languages: [], speedEstimate: 0.3,
            accuracy: measured(["ru": (10.9, 1.5), "es": (4.3, 0.9), "ja": (5.9, 1.1), "tr": (14.6, 2.3)], english: (6.7, 1.8))),
        CatalogModel(
            id: "whisper-large-v3-turbo-q5_0", name: "Whisper Large v3 Turbo (Q5)", engine: .whisper, approxBytes: 574_041_195,
            languages: allLanguages, speedEstimate: 1.4,
            accuracy: measured(["ru": (3.3, 0.8), "uk": (7.0, 1.3), "de": (4.2, 0.9), "es": (3.0, 0.8),
                                "ja": (6.2, 2.5), "tr": (7.7, 1.8), "kk": (21.8, 2.6)], english: (6.4, 1.7)),
            download: .init(url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin",
                            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
                            fileName: "ggml-large-v3-turbo-q5_0.bin")),
        // Qwen3-ASR 1.7B, Q5_K_M GGUF (handy-computer's conversion for transcribe.cpp): 0.8 to 0.9 s after 10 s of
        // speech on an M1 Pro with the model held (0.25 s for a short phrase), 2.6 GB in memory. Q4_K_M broke Russian, 0.6B is
        // clearly less accurate. FLEURS per language from the Qwen3-ASR report (arXiv
        // 2601.21337, table A.2) for the languages our stand doesn't cover: characters, not words, for ja ko th zh.
        CatalogModel(
            id: "qwen3-asr-1.7b-q5_k_m", name: "Qwen3-ASR 1.7B", engine: .qwen, approxBytes: 1_517_290_464,
            languages: qwen, speedEstimate: 0.9,
            accuracy: measured(["ru": (4.1, 1.0), "de": (2.7, 0.7), "es": (2.4, 0.6), "ja": (6.3, 1.2),
                                "tr": (10.4, 1.9)], english: (6.1, 1.5), over: qwenFleurs),
            download: .init(url: "https://huggingface.co/handy-computer/Qwen3-ASR-1.7B-gguf/resolve/0e0a596e3959c3f3f2ab7d443a5b6f0f4a4bba6f/Qwen3-ASR-1.7B-Q5_K_M.gguf",
                            sha256: "034c557fe92ff8fcd9a9c041cbdaad347be0a86a58d3a348f63cf3f0180879d0",
                            fileName: "Qwen3-ASR-1.7B-Q5_K_M.gguf")),
    ]

    public static func model(id: String) -> CatalogModel? { models.first { $0.id == id } }

    /// Qwen3-ASR's 30 languages (its card; Filipino as "tl", Cantonese has no code in our list).
    /// One line under a model's name in Settings › Models: a checked fact
    /// about how the model is built or where it runs, and what that gives the user, in one natural sentence. Per
    /// engine, so a local file of a known family gets its family's line; any other family gets none.
    public static func summary(engine: String) -> String? {
        [
            "parakeet": "Works on the Neural Engine and leaves your processor almost free.",
            "whisper": "Learned from millions of hours of speech and takes accents in stride.",
            "qwen": "A language model at heart, it hears words through their meaning.",
            "apple": "Apple's own recognition, built into macOS like Dictation.",
        ][engine]
    }

    public static let qwen = ["zh", "en", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja", "tr",
                              "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "tl", "fa", "el", "hu", "mk", "ro"]

    private static let qwenFleurs: [String: CatalogModel.Accuracy] = [
        "ar": 16.98, "cs": 22.42, "da": 21.00, "de": 3.92, "el": 28.08, "es": 3.36, "fa": 29.90, "fi": 25.23,
        "tl": 24.29, "fr": 4.75, "hi": 17.15, "hu": 34.22, "id": 5.16, "it": 2.41, "ja": 5.20, "ko": 2.57, "mk": 19.05,
        "ms": 10.39, "nl": 7.04, "pl": 12.54, "pt": 3.92, "ro": 20.70, "ru": 5.99, "sv": 19.36, "th": 6.32, "tr": 9.47,
        "vi": 5.55, "zh": 2.41,
    ].mapValues { CatalogModel.Accuracy(wer: $0, uncertainty: 0.6, source: fleurs + ", publisher (Qwen)", date: "2026-01") }

    /// Every language a Rhemion user can say they dictate in: Whisper's 99 (ISO 639-1; "haw" has no
    /// two-letter code). Wider than any one model, so a language no model covers can still be chosen and named.
    public static let allLanguages = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "cs", "cy", "da", "de",
        "el", "en", "es", "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht",
        "hu", "hy", "id", "is", "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo", "lt",
        "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc", "pa", "pl",
        "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv", "sw", "ta",
        "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "zh",
    ]

    /// The alphabet Parakeet's filter can narrow a language to (FluidAudio's `TokenLanguageFilter`); nil for a
    /// language it doesn't know. Pinned to FluidAudio by `ModelCatalogTests`.
    public static func alphabet(of code: String) -> String? {
        switch code {
        case "en", "es", "fr", "de", "it", "pt", "ro", "nl", "da", "sv", "fi", "hu", "et", "lv", "lt", "mt",
             "pl", "cs", "sk", "sl", "hr", "bs": return "Latin"
        case "ru", "uk", "be", "bg", "sr": return "Cyrillic"
        case "el": return "Greek"
        default: return nil
        }
    }

    /// The one alphabet all these languages share, if Parakeet's filter knows every one of them.
    public static func sharedAlphabet(_ codes: [String]) -> String? {
        let alphabets = codes.map(alphabet(of:))
        guard let first = alphabets.first ?? nil, alphabets.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// A Whisper model's languages from its file name: ".en" models are English only, the rest all 99.
    public static func whisperLanguages(id: String) -> [String] {
        id.hasSuffix(".en") || id.contains(".en-") || id.contains(".en_") ? ["en"] : allLanguages
    }
}

/// How a model treats the user's languages. Settings › Models speaks of this, never of a model by name, so a
/// new model needs only its handling.
public enum LanguageHandling: String, Codable, Sendable, Equatable, CaseIterable {
    /// Hears every language it knows; can narrow to one alphabet its filter knows (Parakeet).
    case alphabetFilter
    /// Hears one language per dictation: the first of the user's it knows (Apple Speech).
    case oneLanguage
    /// Told the language when the user has one, detects it when they have several (Whisper, Qwen3-ASR).
    case hintOrDetect
}

extension CatalogModel.Engine {
    /// Exhaustive on purpose: a new engine doesn't compile until its language handling is chosen.
    public var languageHandling: LanguageHandling {
        switch self {
        case .parakeet: return .alphabetFilter
        case .apple: return .oneLanguage
        case .whisper, .qwen: return .hintOrDetect
        }
    }
}

/// The Recognition row of Settings › Models for a language handling and the user's languages. Plain text when
/// there is nothing to choose; `limit` names the second choice where one truly narrows.
public enum RecognitionText {
    public struct State: Equatable, Sendable {
        public let value: String
        public let description: String
        public let limit: String?
    }

    public static func state(_ handling: LanguageHandling, languages mine: [String], modelKnows: (String) -> Bool = { _ in true },
                             limited: Bool = false, name: (String) -> String) -> State {
        switch handling {
        case .oneLanguage:
            let code = mine.first(where: modelKnows) ?? mine.first ?? "en"
            return State(value: name(code), description: mine.count > 1
                ? "The model hears one language at a time: the first of yours it knows."
                : "The model hears this language.", limit: nil)
        case .hintOrDetect:
            return mine.count == 1
                ? State(value: "\(name(mine[0])) only", description: "The model listens for this language alone.", limit: nil)
                : State(value: "Automatic", description: "The model detects the language of each dictation.", limit: nil)
        case .alphabetFilter:
            let limit = ModelCatalog.sharedAlphabet(mine).map { "Limit to \($0) writing" }
            let on = limited && limit != nil
            let description: String
            if on { description = "May reduce text in another alphabet. It cannot tell Russian from Ukrainian." }
            else if limit == nil && mine.count > 1 { description = "Your languages use more than one alphabet, so the model hears all of them." }
            else { description = "Hears every language the model knows." }
            return State(value: on ? limit! : "Automatic", description: description, limit: limit)
        }
    }
}
