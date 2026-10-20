// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Speech

/// Apple's on-device recognition as Rhemion offers it: one catalogue model ("Apple Speech") over two macOS 26
/// recognizers. SpeechTranscriber, the newer and faster one, serves the languages it knows; DictationTranscriber,
/// the one Apple Dictation uses, serves the rest. Nothing downloads from us: macOS keeps one language pack per
/// language (`AssetInventory`) and fetches it from Apple on request.
public enum AppleSpeech {
    public static let modelID = "apple-speech"

    /// Whether this Mac can run it at all.
    public static var isAvailable: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// The languages (ISO 639-1) it can recognise on this Mac, installed or not.
    public static func languages() async -> [String] {
        guard #available(macOS 26, *) else { return [] }
        var out: [String] = []
        for locale in await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales {
            if let code = locale.language.languageCode?.identifier, !out.contains(code) { out.append(code) }
        }
        return out
    }

    /// The languages of SpeechTranscriber alone, Apple's newer recognizer (about ten languages); the rest of
    /// `languages()` is served only by the recognizer behind ordinary Dictation.
    public static func advancedLanguages() async -> [String] {
        guard #available(macOS 26, *) else { return [] }
        var out: [String] = []
        for locale in await SpeechTranscriber.supportedLocales {
            if let code = locale.language.languageCode?.identifier, !out.contains(code) { out.append(code) }
        }
        return out
    }

    /// The one language Apple Speech listens for, given the user's languages in their order: the first it knows,
    /// else the first, else English.
    public static func language(for mine: [String]) async -> String {
        let known = await languages()
        return mine.first { known.contains($0) } ?? mine.first ?? "en"
    }

    /// The languages macOS holds packs for on this program's behalf (reserved). Uninstall gives them back.
    public static func reservedLanguages() async -> [String] {
        guard #available(macOS 26, *) else { return [] }
        return await AssetInventory.reservedLocales.map(\.identifier)
    }

    /// Give back every pack reservation this program holds, so macOS can remove packs no other app uses.
    public static func releaseReservations() async {
        guard #available(macOS 26, *) else { return }
        for locale in await AssetInventory.reservedLocales { _ = await AssetInventory.release(reservedLocale: locale) }
    }

    /// The languages whose pack is on this Mac now.
    public static func installedLanguages() async -> [String] {
        guard #available(macOS 26, *) else { return [] }
        var out: [String] = []
        for code in await languages() { if await isInstalled(code) { out.append(code) } }
        return out
    }

    public static func isInstalled(_ code: String) async -> Bool {
        guard #available(macOS 26, *), let module = await module(for: code) else { return false }
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    /// Ask macOS for the pack (it downloads it from Apple); returns once it is on this Mac. False if Apple Speech
    /// doesn't know the language. `downloadAndInstall` can return while macOS is still fetching in the background,
    /// so this waits for the pack itself (up to ten minutes).
    @discardableResult
    public static func install(_ code: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Bool {
        guard #available(macOS 26, *), let module = await module(for: code) else { return false }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return true }
        let watch = Task {
            while !Task.isCancelled {
                progress?(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watch.cancel() }
        try await request.downloadAndInstall()
        for _ in 0..<1200 where await AssetInventory.status(forModules: [module]) != .installed {
            try await Task.sleep(for: .milliseconds(500))
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw CancellationError() }
        progress?(1)
        return true
    }

    /// The locale for an ISO 639-1 code among a recognizer's locales: the one macOS calls equivalent ("en" →
    /// en_US, "uk" → uk_UA), else the Mac's own region, else the first by name.
    static func locale(_ code: String, in locales: [Locale], equivalent: Locale?) -> Locale? {
        let matching = locales.filter { $0.language.languageCode?.identifier == code }
        guard !matching.isEmpty else { return nil }
        if let equivalent, let same = matching.first(where: { $0.identifier(.bcp47) == equivalent.identifier(.bcp47) }) { return same }
        if let region = Locale.current.region, let own = matching.first(where: { $0.region == region }) { return own }
        return matching.sorted { $0.identifier < $1.identifier }.first
    }

    /// The recognizer for this language: SpeechTranscriber when it knows the language, else DictationTranscriber.
    @available(macOS 26, *)
    public static func module(for code: String) async -> (any SpeechModule)? {
        let wanted = Locale(identifier: code)
        if let l = locale(code, in: await SpeechTranscriber.supportedLocales,
                          equivalent: await SpeechTranscriber.supportedLocale(equivalentTo: wanted)) {
            return SpeechTranscriber(locale: l, preset: .transcription)
        }
        if let l = locale(code, in: await DictationTranscriber.supportedLocales,
                          equivalent: await DictationTranscriber.supportedLocale(equivalentTo: wanted)) {
            return DictationTranscriber(locale: l, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                        reportingOptions: [], attributeOptions: [])
        }
        return nil
    }
}
