// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FluidAudio

/// How one take is recognised. Automatic (the default) is the native multilingual decode. With Recognition set to
/// limit, Parakeet narrows by alphabet only (FluidAudio's `TokenLanguageFilter`: Latin, Cyrillic, Greek): one
/// language it knows → that language's filter; several sharing one alphabet (Russian and Ukrainian) → that
/// alphabet; alphabets that differ → still multilingual. Whisper takes one language by name, else detects.
public enum LanguagePolicy: Equatable, Sendable {
    case auto
    /// One language (ISO 639-1).
    case only(String)
    /// Several languages written in one alphabet.
    case script([String])

    public static let russian = LanguagePolicy.only("ru")
    public static let english = LanguagePolicy.only("en")

    /// The pre-3.2 setting (`language`: auto | ru | en).
    public init(setting: String) {
        switch setting.lowercased() {
        case "ru": self = .russian
        case "en": self = .english
        default:   self = .auto          // "auto" and any unknown value
        }
    }

    /// From the languages the user dictates in and the Recognition choice (Settings › Models). The languages alone
    /// never narrow recognition: only `limit` does, and only as far as the model honestly can.
    public init(languages: [String], limit: Bool) {
        let codes = languages.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard limit else { self = .auto; return }
        if codes.count == 1 { self = .only(codes[0]); return }
        let known = codes.compactMap(Language.init(rawValue:))
        if known.count == codes.count, let first = known.first, codes.count > 1, known.allSatisfy({ $0.script == first.script }) {
            self = .script(codes)
        } else {
            self = .auto
        }
    }

    /// FluidAudio language filter; nil = native multilingual decode.
    public var parakeet: Language? {
        switch self {
        case .auto: return nil
        case .only(let code): return Language(rawValue: code)
        case .script(let codes): return codes.first.flatMap(Language.init(rawValue:))
        }
    }

    /// whisper `-l` value.
    public var whisperFlag: String {
        if case .only(let code) = self { return code }
        return "auto"
    }
}
