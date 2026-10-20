// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What a local model file is, as the model itself says (rhemion-transcribe --probe: its GGUF header and the
/// family's capabilities). Lets Rhemion list any family transcribe.cpp runs, with its real languages, without a
/// table of its own.
public struct ModelProfile: Codable, Equatable, Sendable {
    /// transcribe.cpp's architecture: "whisper", "qwen3_asr", "gigaam", "parakeet", "canary", ...
    public let family: String
    /// The variant the file names, e.g. "gigaam-v3-e2e-rnnt"; may be empty.
    public let variant: String
    /// ISO 639-1 codes Rhemion knows, in the model's order.
    public let languages: [String]
    /// Detects the language when not told; otherwise it must be told one of `languages`.
    public let detects: Bool
    /// The longest dictation it is made for, in seconds; nil when it has no practical limit.
    public let maxSeconds: Int?
    /// The model's own name from its file (GGUF `general.name`, e.g. "GigaAM v3 E2E-CTC"); nil if it has none.
    public let name: String?

    public init(family: String, variant: String, languages: [String], detects: Bool, maxSeconds: Int? = nil, name: String? = nil) {
        self.family = family; self.variant = variant; self.languages = languages; self.detects = detects
        self.maxSeconds = maxSeconds; self.name = name
    }

    /// What Rhemion calls it when the catalogue doesn't: its own name, else its variant spelled out
    /// ("whisper-large-v3-turbo" -> "Whisper Large v3 Turbo"). Never a file name.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        let words = (variant.isEmpty ? family : variant).split(whereSeparator: { $0 == "-" || $0 == "_" })
        return words.map { w -> String in
            let s = String(w)
            if s.first?.isNumber == true || (s.hasPrefix("v") && s.dropFirst().allSatisfy(\.isNumber)) { return s }
            return ["asr": "ASR", "ctc": "CTC", "rnnt": "RNNT", "e2e": "E2E", "tdt": "TDT", "gigaam": "GigaAM"][s.lowercased()]
                ?? s.prefix(1).uppercased() + s.dropFirst()
        }.joined(separator: " ")
    }

    /// Parses the helper's probe line: "model\t<family>\t<variant>\t<languages>\t<detects>\t<punctuation>\t<max ms>".
    public init?(probeLine line: String) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5, f[0] == "model", !f[1].isEmpty else { return nil }
        family = f[1]; variant = f[2]
        languages = f[3].split(separator: ",").compactMap { ModelProfile.code(String($0)) }
        detects = f[4] == "1"
        maxSeconds = f.count > 6 ? Int(f[6]).flatMap { $0 > 0 ? Int(($0 + 999) / 1000) : nil } : nil
        name = f.count > 7 && !f[7].isEmpty ? f[7] : nil
    }

    /// Past `maxSeconds` it still writes but makes more errors (transcribe.cpp's soft-window families); every
    /// other family refuses a longer dictation.
    public var softLimit: Bool { ["gigaam", "sensevoice", "medasr", "moonshine", "moonshine_streaming"].contains(family) }

    /// The engine Rhemion files it under: Whisper and Qwen3-ASR keep their names, every other family is
    /// "transcribe". All three run in rhemion-transcribe.
    public var engine: String {
        switch family {
        case "whisper": return "whisper"
        case "qwen3_asr": return "qwen"
        default: return "transcribe"
        }
    }

    public var languageHandling: LanguageHandling { detects ? .hintOrDetect : .oneLanguage }

    /// A model's language code as Rhemion's ISO 639-1 list has it (Filipino "fil" is "tl"); nil for one Rhemion
    /// can't name (Cantonese "yue").
    static func code(_ raw: String) -> String? {
        let base = raw.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        let code = ["fil": "tl", "jv": "jw"][base] ?? base
        return ModelCatalog.allLanguages.contains(code) ? code : nil
    }
}

/// Probe results per file, kept beside the runtime's state so each file is probed once (keyed by path, size and
/// modification date; a replaced file is probed again). The file name carries a version: a probe that learns
/// something new gets a new name, so old answers are never read as complete.
public struct ModelProfileCache {
    private let url: URL
    private struct Entry: Codable { let size: Int64; let modified: Double; let profile: ModelProfile }

    public init(url: URL = RuntimePaths.stateDirectory().appendingPathComponent("model-profiles-v3.json")) { self.url = url }

    public func profile(path: String, probe: (String) -> ModelProfile?) -> ModelProfile? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (a[.size] as? NSNumber)?.int64Value,
              let modified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        var all = load()
        if let e = all[path], e.size == size, e.modified == modified { return e.profile }
        guard let profile = probe(path) else { return nil }
        all[path] = Entry(size: size, modified: modified, profile: profile)
        if let data = try? JSONEncoder().encode(all) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return profile
    }

    private func load() -> [String: Entry] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
}
