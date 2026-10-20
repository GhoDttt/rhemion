// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FluidAudio
import Foundation
import RhemionCore

/// A recognition model the user can select. Discovered by scanning, not hardcoded: whisper models
/// come from scanning a search path of directories (so a `.bin` dropped in -- or one already
/// downloaded by another tool -- is picked up, no per-file config and no duplicate download);
/// Parakeet models come from FluidAudio's SHARED cache (`~/Library/Application Support/FluidAudio/
/// Models`), which every FluidAudio app reuses, so they are de-duplicated across apps for free. A
/// small known-models table supplies nice labels; anything else still shows up.
///
/// NOTE: discovery runs at runtime START. A newly added file/dir appears in `rhemion models`
/// immediately (that CLI rescans) but is only RUNNABLE after a runtime restart, and only PRESENT
/// models are registered to run (missing ones list as downloadable).
public struct ModelEntry: Sendable {
    public let id: String            // stable settings value, e.g. "parakeet-v3" / "whisper-large-v3-turbo"
    public let label: String         // human name for the listing
    public let engine: String        // "parakeet" | "whisper" | "qwen" | "transcribe" | "apple"
    public let detail: String        // one-line description
    public let location: String      // parakeet: cache dir; whisper: weights file (tilde-expanded)
    public let found: Bool           // present on disk right now
    public let parakeetVersion: AsrModelVersion?   // set for parakeet models (to build the engine)
    public let whisperModel: String?               // resolved .bin path (to build the engine)
    /// What a local file says it is (rhemion-transcribe --probe); nil for Parakeet, Apple, or an unprobed file.
    public let profile: ModelProfile?

    public init(id: String, label: String, engine: String, detail: String, location: String,
                found: Bool, parakeetVersion: AsrModelVersion?, whisperModel: String?, profile: ModelProfile? = nil) {
        self.id = id; self.label = label; self.engine = engine; self.detail = detail
        self.location = location; self.found = found
        self.parakeetVersion = parakeetVersion; self.whisperModel = whisperModel; self.profile = profile
    }
}

public enum ModelRegistry {
    public static let defaultID = ModelCatalog.defaultID

    /// Built-in whisper search directory. Extra dirs (setting `model_dirs`) are scanned in addition,
    /// letting the user reuse whisper models already downloaded elsewhere instead of duplicating them.
    public static let defaultWhisperDir = "~/.local/share/whisper"

    /// Known parakeet models, from the catalogue (`ModelCatalog`), in its order. (These live in FluidAudio's
    /// shared cache; presence is checked there.)
    private static let knownParakeet: [(id: String, version: AsrModelVersion, label: String, detail: String)] =
        ModelCatalog.models.compactMap { m in
            m.parakeetVersion.map { (m.id, $0, m.name, m.languages.count == 1 ? "English only" : "\(m.languages.count) languages") }
        }

    /// Resolve downloadable models from the same table used by discovery, without scanning disk.
    public static func parakeetVersion(id: String) -> AsrModelVersion? {
        knownParakeet.first { $0.id == id }?.version
    }

    /// Nice labels/details for known whisper weight filenames; unknown `.bin` files still appear
    /// (labeled by filename). Keyed by the on-disk filename.
    private static let knownWhisper: [String: (label: String, detail: String)] = [
        "ggml-large-v3-turbo.bin": ("Whisper Large v3 Turbo", "whisper.cpp large-v3-turbo — multilingual, full precision"),
        "ggml-large-v3-turbo-q5_0.bin": ("Whisper Large v3 Turbo (Q5)", "whisper.cpp large-v3-turbo, Q5 quantized — smaller/faster"),
        "Qwen3-ASR-1.7B-Q5_K_M.gguf": ("Qwen3-ASR 1.7B", "Qwen3-ASR 1.7B, Q5_K_M GGUF for transcribe.cpp"),
    ]

    /// Discover every model: Parakeet from the shared FluidAudio cache, whisper by scanning
    /// `defaultWhisperDir` + `extraDirs`. Parakeet and known-whisper models are always listed (as
    /// missing if absent, so the catalog shows what could be added); scanned unknown `.bin` files are
    /// added too. Whisper de-dups by model id (search-path order: earlier dirs win).
    public static func discover(extraDirs: [String] = [], probe: ((String) -> ModelProfile?)? = nil) -> [ModelEntry] {
        var out: [ModelEntry] = []
        let probe = probe ?? defaultProbe

        for p in knownParakeet {
            let dir = AsrModels.defaultCacheDirectory(for: p.version)
            out.append(ModelEntry(id: p.id, label: p.label, engine: "parakeet", detail: p.detail,
                                  location: dir.path, found: AsrModels.modelsExist(at: dir, version: p.version),
                                  parakeetVersion: p.version, whisperModel: nil))
        }

        // Apple Speech ships with macOS 26: present when the Mac can run it. Its language packs come from macOS on
        // request (the app asks when the model is chosen), so a missing pack is a per-take error, not absence.
        out.append(ModelEntry(id: AppleSpeech.modelID, label: "Apple Speech", engine: "apple",
                              detail: "Built into macOS", location: "", found: AppleSpeech.isAvailable,
                              parakeetVersion: nil, whisperModel: nil))

        // Whisper: scan the search path for *.bin (excluding VAD helpers), de-dup by id.
        var seen = Set<String>()
        let dirs = ([defaultWhisperDir] + extraDirs).map(expandTilde)
        for dir in dirs {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in names.sorted() where (hasBinSuffix(name) && !isVADName(name)) || isGGUF(name) {
                let id = localID(for: name)
                guard !seen.contains(id) else { continue }
                let path = (dir as NSString).appendingPathComponent(name)
                // A model must be a readable regular file: a directory named "x.bin", a broken
                // symlink, or a FIFO is not a model. (fileExists follows symlinks, so a symlink to a
                // real weights file still qualifies.)
                guard isUsableModelFile(path) else { continue }
                seen.insert(id)
                let known = knownWhisper[name]
                // The file says what it is. A GGUF that can't be probed is listed only when its name says Qwen3-ASR
                // (a build without the helper); any other is left out rather than mislabelled.
                let profile = probe(path)
                if isGGUF(name) && profile == nil && engine(for: name) != "qwen" { continue }
                out.append(ModelEntry(id: id, label: known?.label ?? label(for: name, profile: profile),
                                      engine: profile?.engine ?? engine(for: name),
                                      detail: known?.detail ?? "local model (\(name))",
                                      location: path, found: true, parakeetVersion: nil, whisperModel: path, profile: profile))
            }
        }
        // Two files of one model (two quantizations) would read the same: those, and only those, add the quantization.
        let names = Dictionary(grouping: out.indices.filter { out[$0].profile != nil }, by: { out[$0].label })
        for (_, idx) in names where idx.count > 1 {
            for i in idx {
                let stem = ((out[i].location as NSString).lastPathComponent as NSString).deletingPathExtension
                guard let q = quantization(of: stem) else { continue }
                let e = out[i]
                out[i] = ModelEntry(id: e.id, label: "\(e.label) (\(q.uppercased()))", engine: e.engine, detail: e.detail,
                                    location: e.location, found: e.found, parakeetVersion: e.parakeetVersion,
                                    whisperModel: e.whisperModel, profile: e.profile)
            }
        }
        // Known whisper models not found anywhere in the search path -> list as missing.
        for (name, meta) in knownWhisper.sorted(by: { $0.key < $1.key }) {
            let id = localID(for: name)
            guard !seen.contains(id) else { continue }
            let expected = (expandTilde(defaultWhisperDir) as NSString).appendingPathComponent(name)
            out.append(ModelEntry(id: id, label: meta.label, engine: engine(for: name), detail: meta.detail,
                                  location: expected, found: false, parakeetVersion: nil, whisperModel: expected))
        }
        return out
    }

    /// The discovered entry with this id (nil if none), for a given search path.
    public static func entry(id: String?, extraDirs: [String] = []) -> ModelEntry? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return discover(extraDirs: extraDirs).first { $0.id == id }
    }

    /// Pick the model id to start on: the desired one if present, else the default if present, else
    /// the first present model, else the default id (nothing found -- the runtime will surface that).
    public static func startupID(desired: String?, entries: [ModelEntry]) -> String {
        let present = entries.filter { $0.found }
        if let d = desired?.trimmingCharacters(in: .whitespacesAndNewlines),
           present.contains(where: { $0.id == d }) { return d }
        if present.contains(where: { $0.id == defaultID }) { return defaultID }
        return present.first?.id ?? defaultID
    }

    // whisper filename -> stable id: "ggml-large-v3-turbo-q5_0.bin" -> "whisper-large-v3-turbo-q5_0".
    // Extension stripping is case-insensitive (handles ".BIN"); the "ggml-" prefix too.
    private static func whisperID(for filename: String) -> String {
        var stem = (filename as NSString).deletingPathExtension
        if stem.lowercased().hasPrefix("ggml-") { stem = String(stem.dropFirst(5)) }
        return "whisper-\(stem)"
    }

    private static func hasBinSuffix(_ name: String) -> Bool { name.lowercased().hasSuffix(".bin") }
    private static func isGGUF(_ name: String) -> Bool { name.lowercased().hasSuffix(".gguf") }

    /// A local file's id: Whisper `.bin` as `whisperID`, a `.gguf` by its name in lower case ("qwen3-asr-1.7b-q5_k_m");
    /// the same rule as `StorageLayout.localModelID`.
    private static func localID(for name: String) -> String {
        isGGUF(name) ? String(name.lowercased().dropLast(5)) : whisperID(for: name)
    }

    /// Probes with rhemion-transcribe (the bundled one, or `RHEMION_TRANSCRIBE_HELPER`), once per file.
    public static let defaultProbe: @Sendable (String) -> ModelProfile? = { path in
        guard let helper = TranscribeHelperEngine.bundledHelper()
                ?? ProcessInfo.processInfo.environment["RHEMION_TRANSCRIBE_HELPER"] else { return nil }
        return ModelProfileCache().profile(path: path) { probeFile($0, helper: helper) }
    }

    /// Runs `helper --probe file` (a few seconds at most: CPU load, nothing compiled).
    /// The file is untrusted (anything in a models folder), so the helper must be a trusted executable and runs in
    /// its sandbox.
    public static func probeFile(_ path: String, helper: String) -> ModelProfile? {
        guard (try? validateTrustedExecutable(helper)) != nil else { return nil }
        let command = HelperSandbox.command(helper: helper, arguments: ["--probe", path], model: path, takes: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command.executable)
        p.arguments = command.arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.split(separator: "\n").lazy.compactMap { ModelProfile(probeLine: String($0)) }.first
    }

    /// A file's name in the list: the catalogue's label, else what the file says it is (`ModelProfile.displayName`),
    /// else its stem spelled out. Never the file name with its extension or quantization.
    static func label(for name: String, profile: ModelProfile?) -> String {
        if let profile { return profile.displayName }
        var stem = (name as NSString).deletingPathExtension
        if stem.lowercased().hasPrefix("ggml-") { stem = String(stem.dropFirst(5)) }
        if hasBinSuffix(name) && !stem.lowercased().hasPrefix("whisper") { stem = "whisper-" + stem }   // a .bin is Whisper
        return ModelProfile(family: stem, variant: quantization(of: stem).map { String(stem.dropLast($0.count + 1)) } ?? stem,
                            languages: [], detects: true).displayName
    }

    /// The quantization a file name ends in ("Q8_0", "Q5_K_M", "F16"), if any.
    static func quantization(of stem: String) -> String? {
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let tail = String(stem[stem.index(after: dash)...])
        return tail.range(of: #"^(?i)(q\d.*|f16|f32|bf16)$"#, options: .regularExpression) != nil ? tail : nil
    }

    /// The engine a local file runs on when it can't be probed: "qwen" for a Qwen3-ASR GGUF, else "whisper".
    private static func engine(for name: String) -> String {
        isGGUF(name) && name.lowercased().hasPrefix("qwen3-asr") ? "qwen" : "whisper"
    }

    // Exclude VAD helper models (e.g. ggml-silero-*.bin). Token-based, not a naive substring, so a
    // legitimate name like "invader-model.bin" is NOT excluded by containing "vad".
    private static func isVADName(_ name: String) -> Bool {
        let tokens = Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return tokens.contains("silero") || tokens.contains("vad")
    }

    private static func isUsableModelFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && fm.isReadableFile(atPath: path)
    }

    private static func expandTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}
