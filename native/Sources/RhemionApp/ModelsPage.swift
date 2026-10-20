// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Settings › Models: the languages you dictate in, then the models in two tables,
// those that cover every one of your languages and those that miss some, with speed and accuracy as scores out of 10,
// a Download / Manage / In use action per row, and the footer. Whisper's own settings follow in SettingsPane.
//
// The rows come from the catalogue (`ModelCatalog`, shipped data) plus what the runtime reports on this Mac
// (`HubModel.models`). Downloads run in the runtime; Remove deletes the model's files here, through
// `SafeRemover` under the models folder (the same guard as Clear Data).

import AppKit
import SwiftUI
import RhemionCore
import RhemionIPC
import RhemionStorage

// MARK: - Rows

/// One model as the table shows it.
struct ModelsRow: Identifiable, Equatable {
    let id: String
    let name: String
    let engine: String
    let languages: [String]
    /// How it treats the user's languages: the catalogue's engine, or what a local file says.
    let handling: LanguageHandling
    /// The longest dictation it is made for (nil: no practical limit); soft = more errors past it, else refused.
    var maxSeconds: Int? = nil
    var softLimit = false
    let bytes: Int64?
    /// Seconds of work after 10 s of speech; nil = not measured.
    let speed: Double?
    /// Per language, from the catalogue; empty = not tested.
    let accuracy: [String: CatalogModel.Accuracy]
    let found: Bool
    let warm: Bool
    let order: Int
    /// The line under the name (ModelCatalog.summary); nil for a family without one.
    var summary: String? { ModelCatalog.summary(engine: engine) }
}

/// The language names the screen writes: English name, and the language's own name.
enum LanguageNames {
    private static let english = Locale(identifier: "en_US")
    static func name(_ code: String) -> String {
        english.localizedString(forLanguageCode: code) ?? code
    }
    static func native(_ code: String) -> String {
        let own = Locale(identifier: code)
        return own.localizedString(forLanguageCode: code)?.capitalized(with: own) ?? ""
    }
    /// "Russian", "Russian and English", "Russian, Ukrainian and English".
    static func and(_ codes: [String]) -> String {
        let names = codes.map(name)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
    /// "Ukrainian", "Japanese or Korean", "French, German or Italian".
    static func or(_ codes: [String]) -> String {
        let names = codes.map(name)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + names.last!
    }
    /// Up to three by name, then "Russian, Ukrainian and 7 more".
    static func summary(_ codes: [String]) -> String {
        codes.count <= 3 ? and(codes) : "\(codes.prefix(2).map(name).joined(separator: ", ")) and \(codes.count - 2) more"
    }
}

/// The scores' yardstick: the best model Rhemion offers sets the scale, so a score says
/// how close a model comes to the best we have, not to an abstract ideal. The best fills 9 tenths (10 waits for a
/// model that is right every time, at once); each doubling of time costs 1.5 tenths, each doubling of errors 4.
/// Accuracy goes language by language over the user's languages the model knows, and a model whose range overlaps
/// the best one's in a language counts as the best there: same accuracy within the noise, same score.
struct ScoreScale: Equatable {
    let fastest: Double?
    /// Per language: the best centre and the best upper bound (errors plus uncertainty) any model has.
    let best: [String: (centre: Double, upper: Double)]

    static func == (a: ScoreScale, b: ScoreScale) -> Bool {
        a.fastest == b.fastest && a.best.mapValues { [$0.centre, $0.upper] } == b.best.mapValues { [$0.centre, $0.upper] }
    }

    init(rows: [ModelsRow], mine: [String]) {
        fastest = rows.compactMap(\.speed).min()
        var best: [String: (centre: Double, upper: Double)] = [:]
        for r in rows {
            for code in mine {
                guard let a = r.accuracy[code] else { continue }
                let old = best[code] ?? (.infinity, .infinity)
                best[code] = (min(old.centre, a.wer), min(old.upper, a.wer + a.uncertainty))
            }
        }
        self.best = best
    }

    /// How many times slower than the fastest (1 = the fastest).
    func slower(_ seconds: Double) -> Double? { fastest.map { max(1, seconds / max($0, 0.01)) } }
    /// How many times the errors of the best, language by language (geometric mean); 1 where its range meets the best.
    func moreErrors(_ row: ModelsRow, mine: [String]) -> Double? {
        let logs = mine.compactMap { code -> Double? in
            guard let a = row.accuracy[code], let b = best[code], b.centre > 0 else { return nil }
            return a.wer - a.uncertainty <= b.upper ? 0 : log2(a.wer / b.centre)
        }
        return logs.isEmpty ? nil : pow(2, logs.reduce(0, +) / Double(logs.count))
    }
    func speedTenths(_ seconds: Double) -> Int? { slower(seconds).map { Self.tenths(9 - 1.5 * log2($0)) } }
    func accuracyTenths(_ row: ModelsRow, mine: [String]) -> Int? { moreErrors(row, mine: mine).map { Self.tenths(9 - 4 * log2($0)) } }
    static func tenths(_ x: Double) -> Int { min(9, max(1, Int(x.rounded()))) }
}

/// The default order of each table: from the best model for the user's languages to the
/// weakest by quality, the balance of accuracy and speed as the table shows them: twice the accuracy score plus the
/// speed score (an error costs the user more than a second). The recommended model first; equal quality goes
/// Parakeet, Qwen3-ASR, Whisper, any other local model, Apple Speech (the model-choice ties); a model without both
/// scores after every measured one, in catalogue order.
enum ModelsRanking {
    static func quality(accuracy: Int, speed: Int) -> Int { 2 * accuracy + speed }

    static func order(_ rows: [ModelsRow], all: [ModelsRow], mine: [String], recommended: String?) -> [ModelsRow] {
        let scale = ScoreScale(rows: all, mine: mine)
        let engines = ["parakeet", "qwen", "whisper", "transcribe", "apple"]
        func key(_ r: ModelsRow) -> [Int] {
            let accuracy = scale.accuracyTenths(r, mine: mine), speed = r.speed.flatMap(scale.speedTenths)
            let q = accuracy.flatMap { a in speed.map { quality(accuracy: a, speed: $0) } }
            return [r.id == recommended ? 0 : 1, q == nil ? 1 : 0, -(q ?? 0),
                    engines.firstIndex(of: r.engine) ?? engines.count, r.order]
        }
        return rows.sorted { key($0).lexicographicallyPrecedes(key($1)) }
    }
}

/// The model Rhemion recommends for the user's languages, in Settings › Models and in Welcome alike: the most
/// effective model that covers them, by the same quality as the table's order (2 × accuracy + speed scores; equal
/// quality goes Parakeet, Qwen3-ASR, Whisper, Apple Speech). Only models Rhemion offers count, never an unmeasured
/// local file. Apple Speech hears one language at a time, so it counts only for a single language served by
/// Apple's newer recognizer (SpeechTranscriber). When no model covers every language: the one covering the main
/// (first) language and the most of the others; when none covers the main language, the same over the rest.
enum ModelRecommendation {
    static func pick(_ rows: [ModelsRow], mine: [String], appleAdvanced: [String]) -> String? {
        guard !mine.isEmpty else { return nil }
        let candidates = rows.filter { r in
            if r.engine == "apple" { return mine.count == 1 && appleAdvanced.contains(mine[0]) && r.languages.contains(mine[0]) }
            return ModelCatalog.model(id: r.id)?.offered == true
        }
        let scale = ScoreScale(rows: rows, mine: mine)
        let engines = ["parakeet", "qwen", "whisper", "apple"]
        func key(_ r: ModelsRow, _ langs: [String]) -> [Int] {
            let accuracy = scale.accuracyTenths(r, mine: langs), speed = r.speed.flatMap(scale.speedTenths)
            let q = accuracy.flatMap { a in speed.map { ModelsRanking.quality(accuracy: a, speed: $0) } }
            return [q == nil ? 1 : 0, -(q ?? 0), engines.firstIndex(of: r.engine) ?? engines.count, r.order]
        }
        func best(_ pool: [ModelsRow], over langs: [String]) -> String? {
            pool.min { key($0, langs).lexicographicallyPrecedes(key($1, langs)) }?.id
        }
        let full = candidates.filter { r in mine.allSatisfy(r.languages.contains) }
        if !full.isEmpty { return best(full, over: mine) }
        for (index, main) in mine.enumerated() {
            let pool = candidates.filter { $0.languages.contains(main) }
            guard !pool.isEmpty else { continue }
            let rest = Array(mine[index...])
            let most = pool.map { r in rest.filter(r.languages.contains).count }.max() ?? 0
            return best(pool.filter { r in rest.filter(r.languages.contains).count == most }, over: rest)
        }
        return nil
    }
}

/// What the speed and accuracy popovers say about one model: the test behind its numbers.
enum ModelMetrics {
    /// The accuracy card's second line: the recordings it was tested on, and for our own tests their length,
    /// so a long dictation isn't read against it.
    static func accuracySource(_ row: ModelsRow, covered: [String]) -> String {
        let ours = covered.filter { row.accuracy[$0]?.source.contains("Rhemion") == true }.count
        let langs = LanguageNames.and(covered)
        let english = covered.contains { row.accuracy[$0]?.source == ModelCatalog.englishStand }
        if ours == covered.count && english {
            return covered == ["en"] ? "In English recordings up to 30 seconds, from meetings to audiobooks."
                : "In \(langs) recordings up to 30 seconds."
        }
        if ours == covered.count { return "In \(langs) recordings of 9 to 15 seconds." }
        if ours > 0 { return "In \(langs) recordings of about 10 seconds, tested by Rhemion and the publisher." }
        return "In the publisher's tests in \(langs)."
    }

    /// The user's languages the model knows but nobody has tested it in: "Not tested in Ukrainian."
    static func untested(_ row: ModelsRow, mine: [String]) -> String? {
        let gap = mine.filter { row.languages.contains($0) && row.accuracy[$0] == nil }
        return gap.isEmpty ? nil : "Not tested in \(LanguageNames.and(gap))."
    }

    /// The model's own limit on one dictation, when it has one worth saying (a refusal only under ten minutes).
    static func lengthLimit(_ row: ModelsRow) -> String? {
        guard let s = row.maxSeconds else { return nil }
        let length = s < 120 ? "\(s) seconds" : "\(s / 60) minutes"
        if row.softLimit { return "Made for dictations up to \(length). Longer ones get more errors." }
        return s < 600 ? "Takes dictations up to \(length)." : nil
    }

    /// The model's accuracy over the user's languages it covers: mean errors and mean uncertainty; nil if untested.
    static func accuracy(_ row: ModelsRow, for languages: [String]) -> (wer: Double, uncertainty: Double, covered: [String])? {
        let tested = languages.filter { row.accuracy[$0] != nil }
        guard !tested.isEmpty else { return nil }
        let values = tested.compactMap { row.accuracy[$0] }
        let n = Double(values.count)
        return (values.map(\.wer).reduce(0, +) / n, values.map(\.uncertainty).reduce(0, +) / n, tested)
    }
}

// MARK: - Rows from the catalogue and the runtime's report

/// Apple Speech's languages on this Mac, read once at launch (macOS answers asynchronously).
@MainActor enum AppleSpeechLanguages {
    static var all: [String] = []
    /// Served by SpeechTranscriber, Apple's newer recognizer; only these can make Apple Speech the recommendation.
    static var advanced: [String] = []
    static func load() { Task { all = await AppleSpeech.languages(); advanced = await AppleSpeech.advancedLanguages() } }
    /// Where macOS lists its speech languages (Keyboard › Dictation).
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

/// The models as Settings shows them (Models table, General's Speech model row): the catalogue (Apple Speech when
/// this Mac runs it), then each Whisper model on this Mac, with what the runtime reports for each.
@MainActor enum ModelsCatalog {
    static func rows(models: [ModelOption], settings: AppSettings) -> [ModelsRow] {
        let reported = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ModelsRow] = []
        for (i, m) in ModelCatalog.models.enumerated() where m.engine != .apple {
            let r = reported[m.id]
            guard m.offered || r?.found == true else { continue }
            out.append(ModelsRow(id: m.id, name: m.name, engine: m.engine.rawValue, languages: m.languages,
                                 handling: m.engine.languageHandling,
                                 bytes: m.approxBytes, speed: m.speedEstimate, accuracy: m.accuracy,
                                 found: r?.found ?? false, warm: r?.warm ?? true, order: i))
        }
        if let apple = ModelCatalog.model(id: AppleSpeech.modelID), let r = reported[apple.id], r.found {
            out.append(ModelsRow(id: apple.id, name: apple.name, engine: apple.engine.rawValue, languages: AppleSpeechLanguages.all,
                                 handling: .oneLanguage,
                                 bytes: nil, speed: apple.speedEstimate, accuracy: apple.accuracy,
                                 found: true, warm: r.warm, order: ModelCatalog.models.firstIndex(of: apple) ?? 50))
        }
        let whisperFiles = Dictionary(AppPaths.storageLayout(settings: settings).discoveredLocalModels().map { ($0.id, $0.file) },
                                      uniquingKeysWith: { a, _ in a })
        for (i, m) in models.enumerated() where ["whisper", "qwen", "transcribe"].contains(m.engine) && m.found
            && ModelCatalog.model(id: m.id) == nil {
            let size = (try? whisperFiles[m.id]?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
            let qwen = m.engine == "qwen"
            out.append(ModelsRow(id: m.id, name: m.label, engine: m.engine,
                                 languages: m.languages ?? (qwen ? ModelCatalog.qwen : ModelCatalog.whisperLanguages(id: m.id)),
                                 handling: m.handling.flatMap(LanguageHandling.init(rawValue:)) ?? .hintOrDetect,
                                 maxSeconds: m.maxSeconds, softLimit: m.softLimit, bytes: size,
                                 speed: nil, accuracy: [:],
                                 found: true, warm: m.warm, order: 100 + i))
        }
        return out
    }

    /// The model dictation runs on: the selected one when it is on this Mac, else what the runtime falls back to.
    static func inUseID(_ rows: [ModelsRow], selected: String) -> String? {
        if rows.contains(where: { $0.id == selected && $0.found }) { return selected }
        return rows.first { $0.id == ModelCatalog.defaultID && $0.found }?.id ?? rows.first { $0.found }?.id
    }

    /// General's caption under Speech model: a language no model covers, else what the model in use
    /// misses, else your languages.
    static func caption(languages mine: [String], rows: [ModelsRow], inUse: ModelsRow?) -> String {
        let anyModel = Set(rows.flatMap(\.languages))
        let uncovered = mine.filter { !anyModel.contains($0) }
        if !uncovered.isEmpty {
            return uncovered.count == 1 ? "No model for \(LanguageNames.name(uncovered[0]))"
                : "No model for \(LanguageNames.and(uncovered))"
        }
        if let inUse {
            let missing = mine.filter { !inUse.languages.contains($0) }
            if !missing.isEmpty {
                return missing.count <= 2 ? "Missing \(LanguageNames.and(missing))" : "Missing \(missing.count) of your languages"
            }
        }
        return LanguageNames.summary(mine)
    }
}

// MARK: - The page

struct ModelsPage: View {
    @Binding var settings: AppSettings
    @ObservedObject var hub: HubModel
    @ObservedObject private var download: ModelDownloadModel
    @Environment(\.colorScheme) private var scheme
    @State private var sort: (key: SortKey, reversed: Bool)?
    @State private var languagesAnchor: NSView?
    private var dark: Bool { scheme == .dark }

    init(settings: Binding<AppSettings>, hub: HubModel) {
        _settings = settings
        self.hub = hub
        _download = ObservedObject(wrappedValue: hub.modelDownload)
    }

    enum SortKey: String, CaseIterable { case model = "Model", languages = "Languages", speed = "Speed", accuracy = "Accuracy", size = "Size" }

    private var mine: [String] { settings.dictationLanguages }

    private var rows: [ModelsRow] { ModelsCatalog.rows(models: hub.models, settings: settings) }

    private func covers(_ r: ModelsRow) -> Bool { mine.allSatisfy(r.languages.contains) }

    private func recommendedID(_ rows: [ModelsRow]) -> String? {
        ModelRecommendation.pick(rows, mine: mine, appleAdvanced: AppleSpeechLanguages.advanced)
    }

    private func inUseID(_ rows: [ModelsRow]) -> String? { ModelsCatalog.inUseID(rows, selected: settings.model) }

    private func sorted(_ rows: [ModelsRow]) -> [ModelsRow] {
        guard let sort else { return ModelsRanking.order(rows, all: self.rows, mine: mine, recommended: recommendedID(self.rows)) }
        func value(_ r: ModelsRow) -> Double {
            switch sort.key {
            case .model: return 0
            case .languages: return -Double(r.languages.filter(mine.contains).count * 1000 + r.languages.count)
            case .speed: return r.speed ?? .infinity
            case .accuracy: return ModelMetrics.accuracy(r, for: mine)?.wer ?? .infinity
            case .size: return r.bytes.map(Double.init) ?? .infinity
            }
        }
        let best: [ModelsRow] = sort.key == .model
            ? rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            : rows.sorted { value($0) != value($1) ? value($0) < value($1) : $0.order < $1.order }
        return sort.reversed ? best.reversed() : best
    }

    var body: some View {
        let all = rows
        let using = inUseID(all)
        let recommended = recommendedID(all)
        let covering = sorted(all.filter(covers)), missing = sorted(all.filter { !covers($0) })

        FlatSection {
            SettingRow(title: "Languages you dictate in", description: "Finds and ranks models for these languages.", field: true) {
                languagesField
            }
            recognitionRow(rows: all, using: using)
        } header: { header("Languages") }

        table(covering.isEmpty ? "No model covers all your languages yet" : "Covers your languages",
              rows: covering, using: using, recommended: recommended, footer: missing.isEmpty)
        if !missing.isEmpty {
            table("Missing some languages", rows: missing, using: using, recommended: recommended, footer: true)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(RhemionStyle.font(13, .bold)).foregroundStyle(RhemionStyle.text(dark))
    }

    // MARK: recognition

    /// Recognition: what the model in use does with your languages, by its language handling
    /// and never by its name. Only a handling with a real second choice gets a picker.
    private func recognitionRow(rows: [ModelsRow], using: String?) -> some View {
        let row = rows.first { $0.id == using }
        let known = row?.languages ?? ModelCatalog.european
        let state = RecognitionText.state(row?.handling ?? .alphabetFilter, languages: mine, modelKnows: known.contains,
                                          limited: settings.recognitionLimit, name: LanguageNames.name)
        guard let limit = state.limit else { return AnyView(fixedRecognition(value: state.value, description: state.description)) }
        let limited = settings.recognitionLimit
        return AnyView(SettingRow(title: "Recognition", description: state.description, field: true) {
            BoxedPicker(selection: Binding(get: { limited ? "limit" : "auto" }, set: { settings.recognitionLimit = $0 == "limit" }),
                        options: [SettingsChoice(id: "auto", label: "Automatic"), SettingsChoice(id: "limit", label: limit)])
        })
    }

    /// Nothing to choose: the state as plain text, not a one-item menu.
    private func fixedRecognition(value: String, description: String) -> some View {
        SettingRow(title: "Recognition", description: description, field: true) {
            Text(value).font(RhemionStyle.font(13)).foregroundStyle(RhemionStyle.text(dark))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: languages field

    /// Opened from General ("Change in Models ›"): the languages list opens once the field is on screen.
    private func openPickerIfAsked() {
        guard hub.openLanguagesPicker else { return }
        hub.openLanguagesPicker = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { openLanguagePicker() }
    }

    private var languagesField: some View {
        Button { openLanguagePicker() } label: {
            HStack(spacing: 7) {
                Text(LanguageNames.summary(mine)).font(RhemionStyle.font(12, .medium))
                    .foregroundStyle(RhemionStyle.text(dark)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RhemionStyle.secondary(dark))
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: hubFieldHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(RhemionStyle.line(dark), lineWidth: 1) }
        .background(FieldAnchor { languagesAnchor = $0 })
        .onAppear(perform: openPickerIfAsked)
        .onChange(of: hub.openLanguagesPicker) { _, _ in openPickerIfAsked() }
        .accessibilityLabel("Languages you dictate in, \(LanguageNames.and(mine))")
    }

    private func openLanguagePicker() {
        guard let anchor = languagesAnchor else { return }
        HubMenuPanel.shared.showCard(anchor: anchor, dark: dark, width: hubFieldColumn, key: true) {
            LanguagePickerCard(selected: settings.dictationLanguages, dark: dark) { settings.dictationLanguages = $0 }
        }
    }

    // MARK: a table

    @ViewBuilder
    private func table(_ title: String, rows: [ModelsRow], using: String?, recommended: String?, footer: Bool) -> some View {
        FlatSection {
            ForEach(rows) { r in
                ModelsTableRow(row: r, mine: mine, scale: ScoreScale(rows: self.rows, mine: mine), inUse: r.id == using, recommended: r.id == recommended && r.id != using,
                               transfer: download.transfer?.id == r.id ? download.transfer : nil,
                               downloadBusy: download.transfer != nil && download.transfer?.id != r.id,
                               actions: actions, dark: dark)
            }
        } header: {
            VStack(alignment: .leading, spacing: 8) {
                header(title)
                columnRow
            }
        } footer: {
            if footer {
                Text("Models run on this Mac, and audio never leaves it. A model you switch to applies from your next dictation.")
                    .font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
            }
        }
    }

    private var columnRow: some View {
        HStack(spacing: ModelsGrid.gap) {
            column(.model).frame(maxWidth: .infinity, alignment: .leading)
            column(.languages).frame(width: ModelsGrid.languages, alignment: .leading)
            column(.speed).frame(width: ModelsGrid.speed, alignment: .center)
            column(.accuracy).frame(width: ModelsGrid.accuracy, alignment: .center)
            column(.size).frame(width: ModelsGrid.size, alignment: .trailing)
            Color.clear.frame(width: ModelsGrid.action, height: 1)
        }
        .frame(height: 24)
    }

    /// A column title sorts its table: best first, then reversed, then back to the default order (ModelsRanking).
    private func column(_ key: SortKey) -> some View {
        let on = sort?.key == key
        return Button {
            if !on { sort = (key, false) } else if sort?.reversed == false { sort = (key, true) } else { sort = nil }
        } label: {
            HStack(spacing: 3) {
                Text(key.rawValue.uppercased()).font(RhemionStyle.font(10, .semibold)).tracking(0.8)
                if on {
                    Image(systemName: sort?.reversed == true ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ColumnHeaderStyle(on: on, dark: dark))
        .accessibilityLabel("Sort by \(key.rawValue)")
    }

    // MARK: actions

    private var actions: ModelsRowActions {
        ModelsRowActions(
            download: { id in
                download.transfer = .init(id: id)
                hub.client.send(.downloadModel(id: id))
            },
            stop: { hub.client.send(.cancelModelDownload) },
            use: { id in
                guard id == AppleSpeech.modelID else { settings.model = id; return }
                // Apple Speech: the runtime gets macOS's pack for your language first, then dictation switches to it.
                download.onAppleReady = { settings.model = id }
                download.transfer = .init(id: id)
                hub.client.send(.downloadModel(id: id))
            },
            showInFinder: { id in
                if let url = location(of: id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            remove: { row, anchor in askRemove(row, anchor: anchor) })
    }

    private func location(of id: String) -> URL? {
        let layout = AppPaths.storageLayout(settings: settings)
        if let folder = StorageLayout.parakeetFolder(forModel: id) { return layout.fluidModelsRoot.appendingPathComponent(folder) }
        return layout.discoveredLocalModels().first { $0.id == id }?.file
    }

    private func askRemove(_ row: ModelsRow, anchor: NSView) {
        guard let window = anchor.window else { return }
        let all = rows
        let inUse = inUseID(all) == row.id
        // What dictation switches to: the best other model on this Mac, one covering your languages first.
        let others = all.filter { $0.found && $0.id != row.id }
        let next = others.first(where: covers) ?? others.first
        let popup = OperationPopupHost()
        let size = ModelsFormat.size(row.bytes)
        popup.show(RemoveModelPopup(name: row.name, size: size, inUse: inUse, next: next?.name, dark: dark,
                                    onCancel: { popup.close() },
                                    onRemove: { () -> String? in
                                        if inUse, let next { settings.model = next.id }
                                        return removeFiles(of: row.id)
                                    },
                                    onDone: {
                                        popup.close()
                                        hub.client.send(.listDevices)
                                    }),
                   over: window, onCancel: { popup.close() })
    }

    /// Delete a model's files; nil on success, else what went wrong.
    private func removeFiles(of id: String) -> String? {
        let layout = AppPaths.storageLayout(settings: settings)
        do {
            if let folder = StorageLayout.parakeetFolder(forModel: id) {
                try SafeRemover.remove([folder], under: layout.fluidModelsRoot)
            } else if let file = layout.discoveredLocalModels().first(where: { $0.id == id })?.file {
                try SafeRemover.remove([file.lastPathComponent], under: file.deletingLastPathComponent())
            }
            return nil
        } catch {
            log("models: remove \(id) failed: \(error)")
            return "\(error)"
        }
    }
}

/// The grid: name flexible · 84 · 52 · 64 · 64 · 100, gap 12.
enum ModelsGrid {
    static let gap: CGFloat = 12
    static let languages: CGFloat = 84, speed: CGFloat = 52, accuracy: CGFloat = 64, size: CGFloat = 64, action: CGFloat = 100
}

enum ModelsFormat {
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "In macOS" }
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : "\(Int(mb.rounded())) MB"
    }
}

struct ModelsRowActions {
    let download: (String) -> Void
    let stop: () -> Void
    let use: (String) -> Void
    let showInFinder: (String) -> Void
    let remove: (ModelsRow, NSView) -> Void
}

/// Column titles: `tertiary` at rest, `text` when active or under the pointer.
private struct ColumnHeaderStyle: ButtonStyle {
    let on: Bool
    let dark: Bool
    func makeBody(configuration: Configuration) -> some View { HeaderLabel(configuration: configuration, on: on, dark: dark) }
    private struct HeaderLabel: View {
        let configuration: ButtonStyleConfiguration
        let on: Bool
        let dark: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(on || hover ? RhemionStyle.text(dark) : RhemionStyle.tertiary(dark))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hover = $0 }
        }
    }
}

// MARK: - A row

private struct ModelsTableRow: View {
    let row: ModelsRow
    let mine: [String]
    let scale: ScoreScale
    let inUse: Bool
    let recommended: Bool
    let transfer: ModelDownloadModel.Transfer?
    let downloadBusy: Bool
    let actions: ModelsRowActions
    let dark: Bool
    @State private var speedAnchor: NSView?
    @State private var languagesAnchor: NSView?
    @State private var accuracyAnchor: NSView?
    @State private var actionAnchor: NSView?

    var body: some View {
        HStack(spacing: ModelsGrid.gap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(row.name).font(RhemionStyle.font(13, .medium)).foregroundStyle(RhemionStyle.text(dark)).lineLimit(1)
                    if recommended {
                        Text("Recommended").font(RhemionStyle.font(11, .bold)).foregroundStyle(RhemionStyle.gold)
                    }
                }
                if let summary = row.summary {
                    Text(summary).font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { openLanguages() } label: {
                Text(row.languages.count == 1 ? LanguageNames.name(row.languages[0]) : "Multilingual")
                    .font(RhemionStyle.font(12)).lineLimit(1)
            }
            .buttonStyle(QuietActionStyle(dark: dark))
            .frame(width: ModelsGrid.languages, alignment: .leading)
            .background(FieldAnchor { languagesAnchor = $0 })
            .accessibilityLabel("Languages of \(row.name)")

            scoreButton(speed: true).frame(width: ModelsGrid.speed)
                .background(FieldAnchor { speedAnchor = $0 })
            scoreButton(speed: false).frame(width: ModelsGrid.accuracy)
                .background(FieldAnchor { accuracyAnchor = $0 })

            Text(ModelsFormat.size(row.bytes)).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
                .monospacedDigit().frame(width: ModelsGrid.size, alignment: .trailing)

            action.frame(width: ModelsGrid.action, alignment: .trailing)
                .background(FieldAnchor { actionAnchor = $0 })
        }
        .frame(minHeight: 28)   // + the section's 10 above and below = 48; taller with the summary's one or two lines
    }

    // Scores

    private var accuracy: (wer: Double, uncertainty: Double, covered: [String])? { ModelMetrics.accuracy(row, for: mine) }

    private func scoreButton(speed: Bool) -> some View {
        let tenths = speed ? row.speed.flatMap(scale.speedTenths) : scale.accuracyTenths(row, mine: mine)
        return Button { openMetric(speed: speed) } label: {
            MetricScore(tenths: tenths, dark: dark).frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(speed ? "Speed" : "Accuracy"): \(tenths.map { "\($0) of 10" } ?? (speed ? "not measured" : "not tested"))")
    }

    private func openMetric(speed: Bool) {
        guard let anchor = speed ? speedAnchor : accuracyAnchor else { return }
        HubMenuPanel.shared.showCard(anchor: anchor, dark: dark, width: 290, align: .center) {
            MetricCard(speed: speed, row: row, mine: mine, dark: dark)
        }
    }

    private func openLanguages() {
        guard let anchor = languagesAnchor else { return }
        HubMenuPanel.shared.showCard(anchor: anchor, dark: dark, width: 290, align: .center) {
            ModelLanguagesCard(row: row, mine: mine, dark: dark)
        }
    }

    // The action column

    @ViewBuilder private var action: some View {
        if let transfer, !transfer.finished, !transfer.failed {
            DownloadProgressButton(fraction: transfer.fraction, name: row.name, dark: dark, stop: actions.stop)
        } else if let transfer, transfer.failed {
            RaisedButton(title: "Retry") { row.engine == "apple" ? actions.use(row.id) : actions.download(row.id) }
        } else if transfer?.finished == true || (inUse && !row.warm) {
            Text("Preparing…").font(RhemionStyle.font(12, .medium)).foregroundStyle(RhemionStyle.secondary(dark))
        } else if !row.found {
            RaisedButton(title: "Download") { actions.download(row.id) }
                .frame(width: 88).disabled(downloadBusy)
                .help(downloadBusy ? "One download at a time" : "Download \(ModelsFormat.size(row.bytes))")
        } else {
            Button { openMenu() } label: {
                HStack(spacing: 3) {
                    if inUse { Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)) }
                    Text(inUse ? "In use" : "Manage").font(RhemionStyle.font(12, inUse ? .semibold : .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 6).frame(height: 28)
            }
            .buttonStyle(QuietActionStyle(dark: dark, status: inUse))
            .accessibilityLabel(inUse ? "\(row.name), in use. Actions" : "Manage \(row.name)")
        }
    }

    private func openMenu() {
        guard let anchor = actionAnchor else { return }
        let id = row.id, current = row
        // One separator only, before the destructive Remove… (two in a three-item menu were too many).
        HubMenuPanel.shared.showCard(anchor: anchor, dark: dark, align: .trailing) {
            VStack(alignment: .leading, spacing: 2) {
                if !inUse {
                    MenuRow(title: "Use this model", checked: false, dark: dark) { HubMenuPanel.shared.dismiss(); actions.use(id) }
                }
                if current.engine == "apple" {
                    MenuRow(title: "Open Speech settings", checked: false, dark: dark) {
                        HubMenuPanel.shared.dismiss(); AppleSpeechLanguages.openSettings()
                    }
                } else {
                    MenuRow(title: "Show in Finder", checked: false, dark: dark) { HubMenuPanel.shared.dismiss(); actions.showInFinder(id) }
                    MenuSeparator(dark: dark)
                    MenuRow(title: "Remove…", checked: false, dark: dark, danger: true) {
                        HubMenuPanel.shared.dismiss(); actions.remove(current, anchor)
                    }
                }
            }
            .frame(minWidth: 168, alignment: .leading).fixedSize()
            .menuCard(dark: dark, shadow: false)
        }
    }
}

private struct MenuSeparator: View {
    let dark: Bool
    var body: some View {
        Rectangle().fill(RhemionStyle.line(dark)).frame(height: 1).padding(.vertical, 3).padding(.horizontal, 8)
    }
}

/// Download in progress: the Download button filled with gold at 22 % to the percentage, the percentage as its
/// label; under the pointer (or focus) it offers Stop.
private struct DownloadProgressButton: View {
    let fraction: Double
    let name: String
    let dark: Bool
    let stop: () -> Void
    @State private var hover = false
    var body: some View {
        let f = max(0, min(1, fraction))
        Button(action: stop) {
            Text(hover ? "Stop" : "\(Int(f * 100))%").font(RhemionStyle.font(12, .medium)).monospacedDigit()
                .foregroundStyle(RhemionStyle.text(dark))
                .frame(width: 88, height: 30)
                .background(alignment: .leading) {
                    GeometryReader { g in Rectangle().fill(RhemionStyle.theme(dark).goldWash).frame(width: g.size.width * f) }
                }
                .background(RhemionStyle.win(dark))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
                .themeShadow(RhemionStyle.theme(dark).raisedShadow)
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help("Stop download")
        .accessibilityLabel("Downloading \(name), \(Int(f * 100)) percent. Stop")
    }
}

// MARK: - Score

/// The speed or accuracy score as a number, "9 / 10": the score 13 SemiBold
/// `text`, " / 10" 11 `secondary`. Not measured: a `tertiary` dash.
struct MetricScore: View {
    /// 1…10; nil = not measured.
    let tenths: Int?
    let dark: Bool
    var body: some View {
        if let tenths {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(tenths)").font(RhemionStyle.font(13, .semibold)).foregroundStyle(RhemionStyle.text(dark))
                Text(" / 10").font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.secondary(dark))
            }
            .monospacedDigit()
        } else {
            Text("–").font(RhemionStyle.font(13)).foregroundStyle(RhemionStyle.tertiary(dark))
        }
    }
}

// MARK: - Cards

/// The speed or accuracy popover: one line in 15 SemiBold, the result; below it in 12 `secondary`,
/// briefly, how it was measured. Only this model's facts: no words judging it, no other models.
private struct MetricCard: View {
    let speed: Bool
    let row: ModelsRow
    let mine: [String]
    let dark: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if speed, let s = row.speed {
                result(String(format: s < 1 ? "Text in %.2f seconds" : "Text in %.1f seconds", s))
                detail("After a 10\u{2011}second phrase, on a Mac with Apple Silicon.")
            } else if !speed, let a = ModelMetrics.accuracy(row, for: mine) {
                result("About \(Int(a.wer.rounded())) errors per 100 words")
                detail(ModelMetrics.accuracySource(row, covered: a.covered))
                if let gap = ModelMetrics.untested(row, mine: mine) { detail(gap) }
                if let limit = ModelMetrics.lengthLimit(row) { detail(limit) }
            } else if speed {
                result("Speed not measured yet")
            } else {
                result("Accuracy not tested yet")
                detail("No test of this model in your languages yet.")
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(dark: dark)
    }
    private func result(_ s: String) -> some View {
        Text(s).font(RhemionStyle.font(15, .semibold)).foregroundStyle(RhemionStyle.text(dark))
            .fixedSize(horizontal: false, vertical: true)
    }
    private func detail(_ s: String) -> some View {
        Text(s).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark)).padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The model's languages, shaped as the speed and accuracy popovers: one line in
/// 15 SemiBold, how many languages it knows; below it in 12 `secondary`, what that means for the user's languages.
/// No list: adding a language under "Languages you dictate in" answers "does it know X" better.
enum ModelLanguagesText {
    static func heading(_ languages: [String]) -> String {
        languages.count == 1 ? "Knows \(LanguageNames.name(languages[0]))" : "Knows \(languages.count) languages"
    }
    static func detail(_ languages: [String], mine: [String]) -> String {
        let has = mine.filter(languages.contains), missing = mine.filter { !languages.contains($0) }
        if missing.isEmpty {
            if mine.count == 1 { return languages.count == 1 ? "The language you dictate in." : "Including \(LanguageNames.name(mine[0]))." }
            return "Including all \(mine.count) of yours."
        }
        if has.isEmpty { return mine.count == 1 ? "Not \(LanguageNames.name(mine[0]))." : "None of your languages." }
        if missing.count <= 2 {
            return has.count <= 2 ? "Including \(LanguageNames.and(has)), not \(LanguageNames.or(missing))."
                : "Including \(has.count) of yours, not \(LanguageNames.or(missing))."
        }
        return "Including \(has.count) of your \(mine.count) languages."
    }
}

private struct ModelLanguagesCard: View {
    let row: ModelsRow
    let mine: [String]
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ModelLanguagesText.heading(row.languages)).font(RhemionStyle.font(15, .semibold)).foregroundStyle(RhemionStyle.text(dark))
                .fixedSize(horizontal: false, vertical: true)
            Text(ModelLanguagesText.detail(row.languages, mine: mine)).font(RhemionStyle.font(12))
                .foregroundStyle(RhemionStyle.secondary(dark)).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(dark: dark)
    }
}

/// Languages you dictate in: search, then "Selected · N" with your languages first, then all
/// languages; a checkbox row each, English name with the language's own name in `secondary`. At least one stays.
private struct LanguagePickerCard: View {
    @State var selected: [String]
    let dark: Bool
    let commit: ([String]) -> Void
    @State private var query = ""

    init(selected: [String], dark: Bool, commit: @escaping ([String]) -> Void) {
        _selected = State(initialValue: selected)
        self.dark = dark
        self.commit = commit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchField(text: $query, placeholder: "Search languages", style: .card).padding(6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let hits = matches
                    let mineHits = selected.filter(hits.contains)
                    if !mineHits.isEmpty {
                        group("Selected · \(selected.count)")
                        ForEach(mineHits, id: \.self) { row($0) }
                    }
                    let rest = hits.filter { !selected.contains($0) }
                    if !rest.isEmpty {
                        group("All languages")
                        ForEach(rest, id: \.self) { row($0) }
                    }
                    if hits.isEmpty {
                        Text("No language “\(query)”.").font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
                            .padding(12)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
            .frame(height: 300)
        }
        .cardSurface(dark: dark)
    }

    private var matches: [String] {
        let all = ModelCatalog.allLanguages.sorted { LanguageNames.name($0) < LanguageNames.name($1) }
        let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return all }
        return all.filter {
            (LanguageNames.name($0) + " " + LanguageNames.native($0) + " " + $0)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
        }
    }

    private func group(_ title: String) -> some View {
        Text(title).font(RhemionStyle.font(11, .semibold)).foregroundStyle(RhemionStyle.secondary(dark))
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8))
    }

    private func row(_ code: String) -> some View {
        let on = selected.contains(code)
        let last = on && selected.count == 1
        return LanguageRow(name: LanguageNames.name(code), native: LanguageNames.native(code), on: on, enabled: !last, dark: dark) {
            if on { selected.removeAll { $0 == code } } else { selected.append(code) }
            commit(selected)
        }
        .help(last ? "At least one language stays selected" : "")
    }
}

private struct LanguageRow: View {
    let name: String
    let native: String
    let on: Bool
    let enabled: Bool
    let dark: Bool
    let toggle: () -> Void
    @State private var hover = false
    var body: some View {
        let lit = hover && enabled
        let theme = RhemionStyle.theme(dark)
        Button(action: toggle) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5).fill(on ? (lit ? theme.onAccent : theme.gold) : .clear)
                    if !on {
                        RoundedRectangle(cornerRadius: 3.5)
                            .strokeBorder(lit ? theme.onAccent.opacity(0.9) : theme.checkboxEdge, lineWidth: 1)
                    }
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(lit ? theme.gold : theme.onAccent)
                    }
                }
                .frame(width: 15, height: 15)
                Text(name).font(RhemionStyle.font(13)).foregroundStyle(lit ? theme.onAccent : theme.text)
                if native != name, !native.isEmpty {
                    Text(native).font(RhemionStyle.font(11)).foregroundStyle(lit ? theme.onAccent : theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(lit ? theme.gold : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .accessibilityLabel(name).accessibilityValue(on ? "Selected" : "Not selected")
    }
}

// MARK: - Remove

/// Remove…: the question, what happens to dictation, what it frees; then the result.
private struct RemoveModelPopup: View {
    let name: String
    let size: String
    let inUse: Bool
    let next: String?
    let dark: Bool
    let onCancel: () -> Void
    let onRemove: () -> String?
    let onDone: () -> Void
    @State private var result: String??   // nil = asking; .some(nil) = removed; .some(error) = failed

    var body: some View {
        OperationPopupCard {
            switch result {
            case .none:
                OperationPopupTitle(text: "Remove \(name)?")
                if inUse {
                    if let next {
                        line("This is the model in use. Rhemion switches to \(next) for your next dictation.")
                    } else {
                        Text("This is the model in use. Dictation stops until a model is downloaded again.")
                            .font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
                line("Frees \(size). You can download it again any time.")
                WindowButtonRow {
                    RaisedButton(title: "Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    RaisedButton(title: "Remove", danger: true) { result = .some(onRemove()) }
                }
            case .some(nil):
                OperationPopupTitle(text: "\(size) freed")
                line("\(name) is removed from this Mac." + (inUse && next != nil ? " Dictation now uses \(next!)." : ""))
                WindowButtonRow { RaisedButton(title: "Done", action: onDone).keyboardShortcut(.defaultAction) }
            case .some(.some(let error)):
                OperationPopupTitle(text: "\(name) wasn't removed")
                line(error)
                WindowButtonRow { RaisedButton(title: "Done", action: onDone).keyboardShortcut(.defaultAction) }
            }
        }
    }

    private func line(_ s: String) -> some View {
        Text(s).font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark)).fixedSize(horizontal: false, vertical: true)
    }
}
