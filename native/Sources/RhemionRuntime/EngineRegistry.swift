// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RhemionASR
import RhemionCore

/// Composition helper: discovers models (Parakeet from FluidAudio's shared cache; whisper by
/// scanning the search path = default dir + snapshot `model_dirs`) and registers each PRESENT one,
/// keyed by model id, so the active model can switch live (the per-take choice selects a different
/// pre-built engine -- see main.swift). Only the whisper CLI binary is a shared advanced override.
///
/// Missing models are intentionally NOT registered (there is nothing to run); they still appear in
/// `rhemion models` as downloadable. Adding a new search dir or file takes a restart (this runs at
/// startup); switching among already-registered models is live.
public func makeModelRegistry(from snapshot: SettingsSnapshot) -> TranscriptionEngineRegistry {
    makeModelRegistry(entries: ModelRegistry.discover(extraDirs: snapshot.modelDirs), snapshot: snapshot)
}

/// Registers the PRESENT entries from an already-computed discovery (so callers that also need the
/// entry list -- e.g. to pick the startup model -- can discover once).
public func makeModelRegistry(entries: [ModelEntry], snapshot: SettingsSnapshot) -> TranscriptionEngineRegistry {
    let registry = TranscriptionEngineRegistry()
    let whisperBinary = snapshot.whisperBinary ?? WhisperEngine.defaultBinary
    // The helper inside Rhemion.app (transcribe.cpp) keeps the model loaded and runs Whisper and Qwen. Only a
    // build without the helper runs Whisper through whisper-cli per take (`whisper_binary`, else Homebrew's).
    let helper = TranscribeHelperEngine.bundledHelper()
    for entry in entries where entry.found {
        let engine: TranscriptionEngine
        switch entry.engine {
        case "apple":
            engine = AppleSpeechEngine()
        case "whisper":
            let model = entry.whisperModel ?? WhisperEngine.defaultModel
            if let helper {
                engine = TranscribeHelperEngine(id: "whisper", helper: helper, model: model)
            } else {
                engine = WhisperEngine(binary: whisperBinary, model: model)
            }
        case "qwen", "transcribe":
            guard let helper, let model = entry.whisperModel else { continue }
            engine = TranscribeHelperEngine(id: entry.engine, helper: helper, model: model)
        default: // parakeet
            engine = ParakeetEngine(version: entry.parakeetVersion ?? .v3)
        }
        registry.register(engine, as: entry.id)
    }
    return registry
}

/// Convenience for tests and callers with no snapshot: discover with the default search path.
public func makeModelRegistry() -> TranscriptionEngineRegistry {
    makeModelRegistry(from: SettingsSnapshot())
}
