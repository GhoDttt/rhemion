// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import RhemionStorage

/// A read-only projection of the runtime's JSONL record; no runtime dependency.
struct JournalEntry: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let ts: Date
    let engine: String
    let ms: Int?
    let audioDurationMS: Int?
    let raw: String
    let clean: String
    let enhanced: String?
    let delivered: Bool
    let deliveryMethod: String?
    let appName: String?
    let appBundleID: String?
    let audio: String?
    let audioRetained: Bool?
    let preDictionary: String?
    /// The runtime session (3.1 entries only): the key of the press-time target for Insert again.
    var session: String? = nil
    var deliveryError: String? = nil

    /// What the Journal marks on this entry (3.1). Not inserted: the text exists but never landed; Failed: recognition
    /// itself failed (an engine error, or a take cut short by a stop); No speech: recognition ran and heard nothing.
    /// Canceled: stopped with Esc twice and kept (the runtime journals it with the error `canceled`).
    /// Erased: inserted, then taken back with Esc twice (marked by the app, see JournalMarks).
    /// Journal only (Shift with the dictation key) is not delivered on purpose and carries no mark.
    enum Status: Sendable, Equatable { case notInserted, failed, noSpeech, canceled, erased }
    var status: Status? {
        if delivered { return nil }
        if deliveryError == "journal-only" { return nil }   // dictated to the journal on purpose (Shift): nothing to flag
        if deliveryError == "canceled" { return .canceled }
        if transcript.contains(where: { !$0.isWhitespace }) { return .notInserted }
        return deliveryError == "recognition-failed" || deliveryError == "recovered" ? .failed : .noSpeech
    }

    /// Dictated with Shift to the journal only (3.1): never inserted, so no app goes with it.
    var isJournalOnly: Bool { deliveryError == "journal-only" }

    // enhanced wins only when it has real non-whitespace text (empty/blank enhanced falls back to clean,
    // matching RecallStore) — else Final would show/copy an empty string.
    var transcript: String {
        if let enhanced, enhanced.contains(where: { !$0.isWhitespace }) { return enhanced }
        return clean
    }
    /// The local WAV for this entry, or nil when there is no audio (never retained, or pruned by
    /// retention). Mirrors where the runtime files retained takes: the app's own data dir
    /// (`RHEMION_DATA_DIR = <stateDir>/data`), month-foldered, under `Audio/`.
    var audioURL: URL? {
        guard let audio, !audio.isEmpty else { return nil }
        let url = AppPaths.dataDir
            .appendingPathComponent("history/\(JournalDoc.monthFolder(ts))/Audio/\(audio)", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    var duration: String { audioDurationMS.map { JournalDoc.duration(Double($0) / 1000) } ?? "—" }
}

enum JournalGrouping: String, CaseIterable {
    case monthWeekDay = "Month · Week · Day"
    case monthDay = "Month · Day"
    case day = "By day"
    case flat = "No grouping"
}

struct JournalGroup: Identifiable, Sendable {
    enum Level { case month, week, day }
    let id: String
    let level: Level
    let title: String
    let entries: [JournalEntry]
    let children: [JournalGroup]
}

struct JournalDoc: Sendable {
    let entries: [JournalEntry]
    let skippedLines: Int
    let unreadableFiles: Int

    static func load(directory: URL = AppPaths.stateDir.appendingPathComponent("log", isDirectory: true),
                     saveInBackground: Bool = true) -> JournalDoc {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch {
            let missing = (error as NSError).code == NSFileReadNoSuchFileError
            return JournalDoc(entries: [], skippedLines: 0, unreadableFiles: missing ? 0 : 1)
        }
        var entries: [JournalEntry] = [], skipped = 0, unreadable = 0
        var seen = Set<String>(), parsed: [String: MonthCache.Month] = [:], fresh: [String: MonthCache.Month] = [:]
        let saved = MonthCache.savedDirectory(forLog: directory)
        for name in names.sorted(by: >) where name.range(of: #"^dictate-\d{4}-(0[1-9]|1[0-2])\.jsonl$"#, options: .regularExpression) != nil {
            let url = directory.appendingPathComponent(name)
            // A month whose file is as it was last time is not read again (only the current one usually changes).
            guard let key = MonthCache.key(url) else { unreadable += 1; continue }
            let month: MonthCache.Month
            if let cached = MonthCache.month(url.path, key: key) { month = cached }
            else if let stored = MonthCache.saved(name, in: saved, key: key) { month = stored }
            else {
                guard let data = try? Data(contentsOf: url) else { unreadable += 1; continue }
                month = MonthCache.Month(key: key, data: data)
                fresh[name] = month
            }
            parsed[url.path] = month
            skipped += month.skipped
            for entry in month.entries where seen.insert(entry.id).inserted { entries.append(entry) }
        }
        MonthCache.keep(parsed)
        // Months read from their logs are saved for the next launch; saved months whose log is gone go.
        let kept = Set(parsed.keys.map { URL(fileURLWithPath: $0).lastPathComponent })
        if saveInBackground { Task.detached(priority: .utility) { MonthCache.save(fresh, keeping: kept, in: saved) } }
        else { MonthCache.save(fresh, keeping: kept, in: saved) }
        entries.sort { $0.ts == $1.ts ? $0.id > $1.id : $0.ts > $1.ts }
        return JournalDoc(entries: entries, skippedLines: skipped, unreadableFiles: unreadable)
    }

    /// The months read last time, by path: a file is read again only when its size, modification time or
    /// identity changed. In memory, for this run of the app.
    /// The months are also saved, as parsed, in `<stateDir>/journal-cache/` (one file per month, with the key of
    /// the log it was read from): the next launch opens the Journal without parsing the logs again. A copy of the
    /// journal text, so it goes with the Journal (StorageLayout `.transcripts`); any saved month that doesn't match
    /// its log is simply read again.
    enum MonthCache {
        struct Key: Equatable, Sendable, Codable { let size: Int, modified: Date, inode: Int }
        struct Month: Sendable, Codable {
            static let format = 1   // bump when JournalEntry or the parse changes: saved months are then read again
            var format = Month.format
            let key: Key, entries: [JournalEntry], skipped: Int
            init(key: Key, data: Data) {
                // Date.ISO8601FormatStyle: ISO8601DateFormatter took two thirds of the parse.
                let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true), seconds = Date.ISO8601FormatStyle()
                var entries: [JournalEntry] = [], skipped = 0
                // Split bytes first: invalid UTF-8 in one line must not discard an entire month.
                for line in data.split(separator: 0x0A) {
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let id = object["id"] as? String, !id.isEmpty,
                          let timestamp = object["ts"] as? String,
                          let date = (try? fractional.parse(timestamp)) ?? (try? seconds.parse(timestamp)),
                          let raw = object["raw"] as? String, let clean = object["clean"] as? String
                    else { skipped += 1; continue }
                    entries.append(JournalEntry(
                        id: id, ts: date, engine: object["engine"] as? String ?? "—",
                        ms: object["ms"] as? Int, audioDurationMS: object["audio_duration_ms"] as? Int,
                        raw: raw, clean: clean, enhanced: object["enhanced"] as? String,
                        delivered: object["delivered"] as? Bool ?? false,
                        deliveryMethod: object["delivery_method"] as? String,
                        appName: object["app_name"] as? String, appBundleID: object["app_bundle_id"] as? String,
                        audio: object["audio"] as? String, audioRetained: object["audio_retained"] as? Bool,
                        preDictionary: object["pre_dictionary"] as? String,
                        session: object["session"] as? String, deliveryError: object["delivery_error"] as? String))
                }
                self.key = key; self.entries = entries; self.skipped = skipped
            }
        }
        private static let lock = NSLock()
        private nonisolated(unsafe) static var months: [String: Month] = [:]
        static func key(_ url: URL) -> Key? {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (a[.size] as? NSNumber)?.intValue, let modified = a[.modificationDate] as? Date,
                  let inode = (a[.systemFileNumber] as? NSNumber)?.intValue else { return nil }
            return Key(size: size, modified: modified, inode: inode)
        }
        static func month(_ path: String, key: Key) -> Month? {
            lock.lock(); defer { lock.unlock() }
            return months[path].flatMap { $0.key == key ? $0 : nil }
        }
        /// What the last load read: months gone from the folder are forgotten.
        static func keep(_ read: [String: Month]) { lock.lock(); months = read; lock.unlock() }
        /// Forget what this run read (tests).
        static func forgetRead() { keep([:]) }

        static func savedDirectory(forLog log: URL) -> URL {
            log.deletingLastPathComponent().appendingPathComponent(StorageLayout.journalCacheFolder, isDirectory: true)
        }
        static func saved(_ name: String, in directory: URL, key: Key) -> Month? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let month = try? JSONDecoder().decode(Month.self, from: data),
                  month.format == Month.format, month.key == key else { return nil }
            return month
        }
        static func save(_ fresh: [String: Month], keeping names: Set<String>, in directory: URL) {
            let fm = FileManager.default
            if !fresh.isEmpty {
                do {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    for (name, month) in fresh {
                        let url = directory.appendingPathComponent(name)
                        try JSONEncoder().encode(month).write(to: url, options: .atomic)
                        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }
                } catch { log("journal cache not saved: \(error.localizedDescription)") }
            }
            for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !names.contains(name) {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// ISO weeks use the local time zone, including ISO week-years at the December boundary.
    static func groups(_ entries: [JournalEntry], by grouping: JournalGrouping,
                       timeZone: TimeZone = .current) -> [JournalGroup] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        func partition(_ values: [JournalEntry], level: JournalGroup.Level, parent: String) -> [JournalGroup] {
            let component: Calendar.Component = level == .month ? .month : level == .week ? .weekOfYear : .day
            let buckets = Dictionary(grouping: values) { calendar.dateInterval(of: component, for: $0.ts)!.start }
            return buckets.keys.sorted(by: >).map { start in
                let members = buckets[start]!.sorted { $0.ts > $1.ts }
                let id = "\(parent)/\(level)/\(start.timeIntervalSince1970)"
                let title: String
                let children: [JournalGroup]
                switch level {
                case .month:
                    title = label(start, "LLLL yyyy", timeZone: timeZone).capitalized
                    children = partition(members, level: grouping == .monthWeekDay ? .week : .day, parent: id)
                case .week:
                    let end = calendar.date(byAdding: .day, value: 6, to: start)!
                    title = "WEEK \(calendar.component(.weekOfYear, from: start)) · \(label(start, "dd.MM", timeZone: timeZone))–\(label(end, "dd.MM", timeZone: timeZone))"
                    children = partition(members, level: .day, parent: id)
                case .day:
                    title = label(start, "d MMMM · EEE", timeZone: timeZone)
                    children = []
                }
                return JournalGroup(id: id, level: level, title: title, entries: members, children: children)
            }
        }
        guard grouping != .flat else { return [] }
        return partition(entries, level: grouping == .day ? .day : .month, parent: "")
    }

    // Reused, lock-guarded formatters keyed by format+time zone — building a DateFormatter per group
    // title on every render is expensive on large journals. English locale is the default chrome;
    // localization (incl. Russian date names) comes later.
    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    static func label(_ date: Date, _ format: String, timeZone: TimeZone = .current) -> String {
        let key = "\(format)|\(timeZone.identifier)"
        formatterLock.lock(); defer { formatterLock.unlock() }
        let formatter: DateFormatter
        if let cached = formatters[key] { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            formatters[key] = formatter
        }
        return formatter.string(from: date)
    }

    /// "yyyy-MM" for the audio month folder — uses Calendar.current to match the runtime's
    /// `HistoryStore.month` / `WAVSinkFactory` exactly (same calendar identifier and time zone).
    static func monthFolder(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func duration(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
