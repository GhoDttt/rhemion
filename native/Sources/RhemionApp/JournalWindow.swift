// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import AVFoundation
import RhemionStorage
import SwiftUI

// The Journal lives inside the hub: HubModel owns a JournalModel and the hub renders JournalView.
// There is no standalone Journal window anymore — the model, view, and its subviews below are what the hub
// uses.

@MainActor
final class JournalModel: ObservableObject {
    @Published var doc = JournalDoc(entries: [], skippedLines: 0, unreadableFiles: 0) { didSet { refilter() } }
    /// What the list shows for the current search and grouping: worked out once per change, off the main thread.
    /// (Filtering and grouping every entry on each redraw, a hover included, froze the window on a long journal.)
    @Published private(set) var shown: [JournalEntry] = []
    @Published private(set) var shownGroups: [JournalGroup] = []
    /// The search `shown` answers (it lags the field while a search is being worked out).
    @Published private(set) var shownQuery = ""
    /// Bumped whenever `shown` changes: cheaper to watch than the list itself.
    @Published private(set) var shownVersion = 0
    private var filterQuery = "", filterGrouping = JournalGrouping.monthWeekDay
    private var filterTask: Task<Void, Never>?
    func show(query: String, grouping: JournalGrouping) {
        guard query != filterQuery || grouping != filterGrouping else { return }
        let typing = query != filterQuery && !query.isEmpty
        filterQuery = query; filterGrouping = grouping
        refilter(after: typing ? 0.12 : 0)
    }
    private func refilter(after delay: Double = 0) {
        filterTask?.cancel()
        let entries = doc.entries, query = filterQuery, grouping = filterGrouping
        filterTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let (hits, groups) = await Task.detached(priority: .userInitiated) {
                let hits = query.isEmpty ? entries : entries.filter { e in
                    [e.transcript, e.clean, e.raw, e.appName ?? ""].contains { $0.localizedStandardContains(query) }
                }
                return (hits, query.isEmpty && grouping != .flat ? JournalDoc.groups(hits, by: grouping) : [])
            }.value
            guard !Task.isCancelled else { return }
            shown = hits; shownGroups = groups; shownQuery = query; shownVersion += 1
        }
    }
    @Published var loading = false
    enum InsertAgainOutcome { case inserted, fieldGone, failed }
    /// 3.1 Insert again, wired by the AppController: whether this entry can be put back (its press-time target
    /// is still known) and the action, which reports how it went.
    var canInsertAgain: (JournalEntry) -> Bool = { _ in false }
    /// How long a canceled entry is kept (Settings › Journal); shown in its status row.
    var keepCanceledHours = 24
    var insertAgain: ((JournalEntry, @escaping @MainActor (InsertAgainOutcome) -> Void) -> Void)?
    /// Entries put back with Insert again: no longer marked (kept across launches in the state folder).
    @Published private(set) var insertedAgain: Set<String> = InsertedAgainStore.load()
    /// Entries whose field could not be found when Insert again was tried (this session).
    @Published private(set) var fieldGone: Set<String> = []
    func status(_ e: JournalEntry) -> JournalEntry.Status? {
        if insertedAgain.contains(e.id) { return nil }
        if e.delivered, let s = e.session, JournalMarks.mark(session: s) == "erased" { return .erased }
        return e.status
    }
    /// Statuses whose text can be put back with Insert again.
    func canPutBack(_ e: JournalEntry) -> Bool {
        guard let s = status(e), s != .failed, s != .noSpeech, e.transcript.contains(where: { !$0.isWhitespace }) else { return false }
        return canInsertAgain(e)
    }
    /// Entries with an Insert again in flight: a second click does nothing until the first one finished.
    @Published private(set) var inserting: Set<String> = []
    func runInsertAgain(_ e: JournalEntry) {
        guard !inserting.contains(e.id) else { return }
        inserting.insert(e.id)
        insertAgain?(e) { [weak self] outcome in
            guard let self else { return }
            self.inserting.remove(e.id)
            switch outcome {
            case .inserted: self.insertedAgain.insert(e.id); InsertedAgainStore.save(self.insertedAgain)
            case .fieldGone: self.fieldGone.insert(e.id)
            case .failed: break
            }
        }
    }
    /// 3.1 Recognize again, wired by the AppController: asks the runtime to recognise a Failed entry's recording
    /// again. The answer arrives as `recognized(id:ok:error:)`.
    var recognizeAgain: ((JournalEntry) -> Void)?
    /// Entries being recognised again right now, and the last failure per entry (this session).
    @Published private(set) var recognizing: Set<String> = []
    @Published private(set) var recognizeErrors: [String: String] = [:]
    /// A Failed entry, or a Canceled one whose recognition failed (no text), with its recording kept.
    func canRecognizeAgain(_ e: JournalEntry) -> Bool {
        guard let s = status(e), s == .failed || s == .noSpeech || s == .canceled, recognizeAgain != nil, e.audioURL != nil else { return false }
        return !e.transcript.contains(where: { !$0.isWhitespace })
    }
    func runRecognizeAgain(_ e: JournalEntry) {
        guard !recognizing.contains(e.id), let recognizeAgain else { return }
        recognizing.insert(e.id); recognizeErrors[e.id] = nil
        recognizeAgain(e)
        // A runtime that went away never answers: give the button back after a generous wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.recognizing.contains(e.id) else { return }
                self.recognized(id: e.id, ok: false, error: "It took too long. Try again.")
            }
        }
    }
    func recognized(id: String, ok: Bool, error: String?) {
        recognizing.remove(id)
        if ok { reload() } else { recognizeErrors[id] = error ?? "It could not be recognised again." }
    }
    private var refresh: Task<Void, Never>?
    private var reloadPending = false
    func reload() {
        guard refresh == nil else { reloadPending = true; return }
        loading = true
        refresh = Task {
            let loaded = await Task.detached(priority: .userInitiated) { JournalDoc.load() }.value
            doc = loaded
            // Marks of entries that are gone (deleted, expired) go too, once every month was read whole.
            if loaded.unreadableFiles == 0 && loaded.skippedLines == 0 {
                let ids = Set(loaded.entries.map(\.id)), sessions = Set(loaded.entries.compactMap(\.session))
                if !insertedAgain.isSubset(of: ids) { insertedAgain.formIntersection(ids); InsertedAgainStore.save(insertedAgain) }
                Task.detached(priority: .utility) { JournalMarks.keep(sessions: sessions) }
            }
            loading = false
            refresh = nil
            if reloadPending { reloadPending = false; reload() }
        }
    }
}

/// Marks the app sets on entries by runtime session (3.1: "erased" when a take is taken back with Esc twice),
/// in `<stateDir>/journal-marks.json`. Written from any thread; small, read-modify-write under a lock.
enum JournalMarks {
    private static let lock = NSLock()
    private static var url: URL { AppPaths.stateDir.appendingPathComponent(StorageLayout.journalMarkFiles[0]) }
    private nonisolated(unsafe) static var cache: [String: String]?
    /// Marked in this run: the runtime may not have journaled that take yet, so it is never pruned.
    private nonisolated(unsafe) static var fresh = Set<String>()
    private static func load() -> [String: String] {
        // Clear Data › Journal removes the file: a cache kept past that would write the old marks back.
        if let cache, cache.isEmpty || FileManager.default.fileExists(atPath: url.path) { return cache }
        let m = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = m; return m
    }
    private static func save(_ m: [String: String]) {
        cache = m
        do { try JSONEncoder().encode(m).write(to: url, options: .atomic) }
        catch { log("journal marks not saved: \(error.localizedDescription)") }
    }
    static func mark(session: String) -> String? { lock.lock(); defer { lock.unlock() }; return load()[session] }
    static func add(session: String, mark: String) {
        lock.lock(); defer { lock.unlock() }
        var m = load(); m[session] = mark; fresh.insert(session); save(m)
    }
    /// Forget the marks of sessions no entry has any more (deleted, expired).
    static func keep(sessions: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let m = load(), kept = m.filter { sessions.contains($0.key) || fresh.contains($0.key) }
        if kept.count != m.count { save(kept) }
    }
}

/// Entry ids put back with Insert again, in `<stateDir>/journal-inserted-again.json`.
enum InsertedAgainStore {
    private static var url: URL { AppPaths.stateDir.appendingPathComponent(StorageLayout.journalMarkFiles[1]) }
    static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: url), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }
    static func save(_ ids: Set<String>) {
        do { try JSONEncoder().encode(ids.sorted()).write(to: url, options: .atomic) }
        catch { log("journal marks not saved: \(error.localizedDescription)") }
    }
}

/// The Journal's status marks (mono): a ring, and what is inside it is what happened.
/// Not inserted = the orb held by its ring (the notch's kept frame), Failed = the empty ring. Drawn in the
/// row's ink; 12-unit geometry scaled to `size`.
struct JournalStatusMark: View {
    let status: JournalEntry.Status
    var size: CGFloat = 11
    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 12, c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r * k, y: c.y - r * k, width: 2 * r * k, height: 2 * r * k)) }
            switch status {
            case .notInserted:
                ctx.stroke(circle(4.9), with: .foreground, lineWidth: 1.3 * k)
                ctx.fill(circle(2.5), with: .foreground)
            case .failed, .noSpeech:   // an empty ring: no text came out
                ctx.stroke(circle(4.4), with: .foreground, lineWidth: 1.3 * k)
            case .canceled, .erased:   // the ring with a cross (you stopped it) or a line (you took it back)
                ctx.stroke(circle(4.9), with: .foreground, lineWidth: 1.3 * k)
                var p = Path()
                if status == .canceled {
                    p.move(to: CGPoint(x: c.x - 1.9 * k, y: c.y - 1.9 * k)); p.addLine(to: CGPoint(x: c.x + 1.9 * k, y: c.y + 1.9 * k))
                    p.move(to: CGPoint(x: c.x + 1.9 * k, y: c.y - 1.9 * k)); p.addLine(to: CGPoint(x: c.x - 1.9 * k, y: c.y + 1.9 * k))
                } else {
                    p.move(to: CGPoint(x: c.x - 2.3 * k, y: c.y)); p.addLine(to: CGPoint(x: c.x + 2.3 * k, y: c.y))
                }
                ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.3 * k, lineCap: .round))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Insert again's icon ("Into the line"): an arrow entering a line of text. 16-unit geometry.
struct InsertAgainIcon: View {
    var size: CGFloat = 13
    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 16
            var p = Path()
            p.move(to: CGPoint(x: 2.5 * k, y: 3.5 * k)); p.addLine(to: CGPoint(x: 13.5 * k, y: 3.5 * k))
            p.move(to: CGPoint(x: 2.5 * k, y: 12.5 * k)); p.addLine(to: CGPoint(x: 13.5 * k, y: 12.5 * k))
            p.move(to: CGPoint(x: 4 * k, y: 8 * k)); p.addLine(to: CGPoint(x: 10.5 * k, y: 8 * k))
            p.move(to: CGPoint(x: 8.5 * k, y: 5.8 * k)); p.addLine(to: CGPoint(x: 10.8 * k, y: 8 * k)); p.addLine(to: CGPoint(x: 8.5 * k, y: 10.2 * k))
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.5 * k, lineCap: .round, lineJoin: .round))
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

extension JournalEntry.Status {
    var label: String {
        switch self { case .notInserted: return "Not inserted"; case .failed: return "Failed"; case .noSpeech: return "No speech"; case .canceled: return "Canceled"; case .erased: return "Erased" }
    }
}

struct JournalView: View {
    @ObservedObject var model: JournalModel
    let client: RuntimeClient
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var grouping = JournalGrouping.monthWeekDay
    @State private var compact = false
    @State private var details = true
    @State private var groupMenu = false
    @State private var opened: String?
    @State private var checked = Set<String>()
    @State private var pendingDelete = Set<String>()
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var collapsed = Set<String>()
    @State private var hovered: String?
    @State private var listWidth: CGFloat = 348
    @State private var dragWidth: CGFloat?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var exportMode = SettingsStore.load().exportMode
    @State private var exporting = false
    @State private var groupAnchor: CGRect = .zero
    private var dark: Bool { scheme == .dark }
    /// The search the list currently answers (see JournalModel.shown).
    private var search: String { model.shownQuery }
    private var entries: [JournalEntry] { model.shown }
    private var selected: JournalEntry? { entries.first { $0.id == opened } }
    // Flatten the tree: only day sections pin, while month/week headers scroll away.
    private func visibleGroups(_ groups: [JournalGroup]) -> [JournalGroup] {
        groups.flatMap { [$0] + (collapsed.contains($0.id) ? [] : visibleGroups($0.children)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !checked.isEmpty { selectionBar; Divider() }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    list.frame(width: details ? min(listWidth, max(280, geometry.size.width - 385)) : nil).frame(maxWidth: details ? nil : .infinity, maxHeight: .infinity)
                    if details {
                        Rectangle().fill(RhemionStyle.line(dark)).frame(width: 5)
                            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture().onChanged { value in
                                if dragWidth == nil { dragWidth = listWidth }
                                // clamp with the SAME bound the render uses, so there is no invisible slack on drag-back
                                listWidth = max(280, min(geometry.size.width - 385, (dragWidth ?? listWidth) + value.translation.width))
                            }.onEnded { _ in dragWidth = nil })
                        Group {
                            if let selected { JournalDetail(entry: selected, model: model, notify: notify, delete: { requestDelete([selected.id]) }, deleting: deleting).id(selected.id) }
                            else { Text("Select an entry").foregroundStyle(RhemionStyle.secondary(dark)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }.frame(minWidth: 290, maxWidth: .infinity, maxHeight: .infinity).background(RhemionStyle.content(dark))
                    }
                }
            }
            if model.doc.skippedLines > 0 || model.doc.unreadableFiles > 0 {
                Text("Skipped malformed lines: \(model.doc.skippedLines) · Unreadable files: \(model.doc.unreadableFiles)")
                    .font(.caption).foregroundStyle(RhemionStyle.secondary(dark)).padding(6)
            }
        }.frame(minWidth: 860, idealWidth: 1000, minHeight: 440, idealHeight: 640)
            .font(RhemionStyle.font(13)).foregroundStyle(RhemionStyle.text(dark))
            .background(RhemionStyle.rail(dark)).tint(RhemionStyle.gold).buttonStyle(.plain)
            .coordinateSpace(name: "journalRoot")
            .onPreferenceChange(MenuAnchorKey.self) { groupAnchor = $0 }
            .overlay { groupingMenu }
            .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { _ in
                exportMode = SettingsStore.load().exportMode
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(RhemionStyle.font(12)).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).padding(20).allowsHitTesting(false)
                }
            }
            .alert("Delete \(pendingDelete.count) entries and their audio permanently?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) { pendingDelete.removeAll() }
                Button("Delete permanently", role: .destructive) { performDelete() }
            } message: {
                Text("This also removes them from the exported note.")
            }
            .onChange(of: model.shownVersion, initial: true) {
                let values = model.shown
                if !values.contains(where: { $0.id == opened }) { opened = values.first?.id }
                checked.formIntersection(Set(values.map(\.id)))
            }
            .onChange(of: query, initial: true) { model.show(query: query.trimmingCharacters(in: .whitespacesAndNewlines), grouping: grouping) }
            .onChange(of: grouping) { model.show(query: query.trimmingCharacters(in: .whitespacesAndNewlines), grouping: grouping) }
    }
    // Custom dropdown drawn at the window root: no popover arrow, hangs directly under the trigger.
    // A full-window catcher dismisses on any outside click; the card sits above it.
    @ViewBuilder private var groupingMenu: some View {
        if groupMenu {
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { groupMenu = false }
                JournalMenuCard {
                    ForEach(JournalGrouping.allCases, id: \.self) { option in
                        MenuRow(title: option.rawValue, checked: grouping == option, dark: dark) { grouping = option; groupMenu = false }
                    }
                }
                .fixedSize()
                .offset(x: groupAnchor.minX, y: groupAnchor.maxY + 5)
            }
        }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            SearchField(text: $query, placeholder: "Search the journal", style: .toolbar)
            Button { groupMenu.toggle() } label: {
                HStack { Text(grouping.rawValue); Image(systemName: "chevron.down").font(.caption2) }.padding(7)
            }.background(RhemionStyle.content(dark), in: RoundedRectangle(cornerRadius: 7))
                // Capture the trigger's frame so the custom dropdown (no arrow, drawn at the window root) hangs under it.
                .background(GeometryReader { g in Color.clear.preference(key: MenuAnchorKey.self, value: g.frame(in: .named("journalRoot"))) })
            ViewModeToggle(compact: $compact)   // choose one of two views (comfortable / compact), not on/off
            Text("\(entries.count) \(search.isEmpty ? "entries" : "found")").font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.tertiary(dark)).fixedSize()
            Spacer(minLength: 0)
            // The export chip + "Export now" action vanish entirely when export is turned Off in settings.
            if exportMode != "off" {
                HStack(spacing: 5) {
                    Circle().fill(RhemionStyle.success).frame(width: 6, height: 6)
                    Text("Export: \(exportMode)")
                }.font(RhemionStyle.font(11)).padding(7).background(RhemionStyle.content(dark), in: RoundedRectangle(cornerRadius: 7))
                    .help("Current export mode")
                JournalToolbarAction(systemImage: "arrow.up.to.line", help: "Export now to the vault note", busy: exporting) {
                    exporting = true
                    Task { @MainActor in
                        defer { exporting = false }
                        do {
                            reportExport(try await client.exportNow())
                        } catch { notify(error.localizedDescription) }
                    }
                }
            }
            JournalToolbarToggle(systemImage: details ? "sidebar.right" : "rectangle", on: details,
                                 help: details ? "Hide details" : "Show details") { details.toggle() }
        }.font(RhemionStyle.font(12, .semibold)).padding(10)
    }
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(checked.count) selected")
            Button("Select all") { checked = Set(entries.map(\.id)) }
            Button("Clear") { checked.removeAll() }
            Spacer()
            Button("Delete") { requestDelete(checked) }.foregroundStyle(RhemionStyle.danger).disabled(deleting)
        }.font(RhemionStyle.font(12, .semibold)).padding(10).background(RhemionStyle.theme(dark).noticeWash)
    }
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.book.closed").font(.title)
                        Text(model.loading || model.shownVersion == 0 ? "Loading…" : search.isEmpty ? "No entries yet" : "No matches")
                    }.foregroundStyle(RhemionStyle.secondary(dark)).padding(.vertical, 70).frame(maxWidth: .infinity)
                } else if model.shownGroups.isEmpty { rows(entries) }   // a search, or No grouping
                else {
                    ForEach(visibleGroups(model.shownGroups)) { group in
                        if group.level == .day {
                            Section { if !collapsed.contains(group.id) { rows(group.entries) } } header: { groupHeader(group) }
                        } else { groupHeader(group) }
                    }
                }
            }.padding(.bottom, 14)
        }.background(RhemionStyle.rail(dark))
    }
    private func groupHeader(_ group: JournalGroup) -> some View {
        HStack(spacing: 8) {
            if !checked.isEmpty {   // group checkboxes appear only once at least one entry is selected
                let ids = Set(group.entries.map(\.id))
                let count = checked.intersection(ids).count
                JournalCheckbox(on: count == ids.count, mixed: count > 0 && count < ids.count)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
                    .onTapGesture { if count == ids.count { checked.subtract(ids) } else { checked.formUnion(ids) } }
            }
            Button {
                if !collapsed.insert(group.id).inserted { collapsed.remove(group.id) }
            } label: {
                HStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(group.title).font(RhemionStyle.font(group.level == .month ? 15 : group.level == .week ? 10 : 12.5, group.level == .month ? .heavy : .semibold))
                        if group.level == .day { Text("\(group.entries.count)").font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.tertiary(dark)) }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").font(.system(size: 10)).foregroundStyle(RhemionStyle.tertiary(dark))
                }.contentShape(Rectangle())
            }
        }.foregroundStyle(group.level == .week ? RhemionStyle.secondary(dark) : RhemionStyle.text(dark))
            .padding(.horizontal, 12).padding(.top, group.level == .month ? 15 : 9).padding(.bottom, 5)
            .background(RhemionStyle.rail(dark)).overlay(alignment: .top) { if group.level == .month { Divider() } }
    }
    private func rows(_ values: [JournalEntry]) -> some View {
        ForEach(Array(values.enumerated()), id: \.element.id) { index, entry in
            JournalRow(entry: entry, status: model.status(entry), canInsertAgain: model.canPutBack(entry),
                       insertAgain: { model.runInsertAgain(entry) }, compact: compact && search.isEmpty, query: search,
                       selected: opened == entry.id, checked: checked.contains(entry.id), selecting: !checked.isEmpty, hovered: hovered == entry.id,
                       separator: index + 1 < values.count && opened != values[index + 1].id && hovered != values[index + 1].id,
                       open: { opened = entry.id }, toggle: { if !checked.insert(entry.id).inserted { checked.remove(entry.id) } }, copy: {
                           NSPasteboard.general.clearContents()
                           NSPasteboard.general.setString(entry.transcript, forType: .string)
                           notify("Copied (Final)")
                       }).onHover { inside in hovered = inside ? entry.id : (hovered == entry.id ? nil : hovered) }
        }
    }
    private func requestDelete(_ ids: Set<String>) {
        guard !deleting, !ids.isEmpty else { return }
        pendingDelete = ids
        confirmDelete = true
    }

    private func performDelete() {
        let ids = pendingDelete.sorted()
        guard !deleting, !ids.isEmpty else { return }
        pendingDelete.removeAll()
        deleting = true
        // If the open entry is among those being deleted, focus its nearest survivor (the next entry
        // below in the flat list, else the one above) instead of jumping to the top of the journal.
        let idSet = Set(ids)
        let flat = entries
        let focus: String? = {
            guard let openedID = opened, idSet.contains(openedID),
                  let i = flat.firstIndex(where: { $0.id == openedID }) else { return opened }
            if let below = flat[(i + 1)...].first(where: { !idSet.contains($0.id) }) { return below.id }
            return flat[..<i].last(where: { !idSet.contains($0.id) })?.id
        }()
        Task { @MainActor in
            do {
                let removed = try await client.historyDelete(ids: ids)
                notify("Deleted \(removed.count) \(removed.count == 1 ? "entry" : "entries") permanently.")
            } catch {
                notify(error.localizedDescription)
            }
            opened = focus
            checked.removeAll()
            model.reload()
            deleting = false
        }
    }

    /// Export status line. Skipped notes (spec 4.5) are named — the user must learn which months
    /// were not written and why.
    static func exportStatus(_ result: RuntimeClient.ExportResult) -> String {
        let done = "Export complete: \(max(0, result.months.count - result.skipped.count)) month(s)"
        guard !result.skipped.isEmpty else { return done }
        return done + ". Not written — file exists and wasn't written by Rhemion: "
            + result.skipped.joined(separator: ", ")
    }

    private func reportExport(_ result: RuntimeClient.ExportResult) {
        notify(Self.exportStatus(result), seconds: result.skipped.isEmpty ? 3 : 8)
    }

    private func notify(_ message: String) { notify(message, seconds: 3) }

    private func notify(_ message: String, seconds: Int) {
        toastTask?.cancel(); toast = message
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { toast = nil }
        }
    }
}

/// A 30×30 toolbar icon toggle: the raised neutral tile (`activeTile`) when on, a faint wash on hover
/// when off; never an accent tint.
private struct JournalToolbarToggle: View {
    let systemImage: String
    let on: Bool
    let help: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    private var dark: Bool { scheme == .dark }
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 30, height: 30)
                .foregroundStyle(on || hover ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            // Active = raised LIGHT surface (--win), the app's "on = neutral-raised" language (same as the
            // Final/Clean/Raw and Theme pills) — not a gray chip. These float on a near-white toolbar (no
            // segmented track), so ON also carries a hairline border for a continuous edge + a restrained
            // shadow for elevation; the border+shadow are reserved for ON so hover can't masquerade as it.
            .background(!on && hover ? RhemionStyle.hover(dark) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .activeTile(on, dark: dark, radius: 8)
            .onHover { hover = $0 }.help(help).accessibilityLabel(help).accessibilityValue(on ? "On" : "Off")
    }
}
/// A two-position VIEW switcher (comfortable / compact) — a choice between two layouts, not an on/off, so
/// it reads as a segmented control: both icons always visible on a track, the current view a raised light
/// pill (the app's selection language, matching the Final/Clean/Raw and Theme segments).
private struct ViewModeToggle: View {
    @Binding var compact: Bool
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        HStack(spacing: 2) {
            segment(icon: "rectangle.grid.1x2", isCompact: false, help: "Comfortable view")
            segment(icon: "list.bullet", isCompact: true, help: "Compact view")
        }
        .padding(2)
        .background(RhemionStyle.rail(dark), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
    }
    private func segment(icon: String, isCompact: Bool, help: String) -> some View {
        let on = compact == isCompact
        return Button { compact = isCompact } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark))
                .frame(width: 30, height: 24)
                .activeTile(on, dark: dark, radius: 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
/// A momentary toolbar ACTION icon (vs `JournalToolbarToggle`, which persists an on/off chip): no sticky
/// fill, just a neutral hover wash, and it swaps to a small spinner while `busy`. Reused by future toolbar
/// actions (e.g. a Share button) so they stay visually consistent.
private struct JournalToolbarAction: View {
    let systemImage: String
    let help: String
    var busy = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    private var dark: Bool { scheme == .dark }
    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                else { Image(systemName: systemImage) }
            }
            .frame(width: 30, height: 30)
            .foregroundStyle(hover ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(hover ? RhemionStyle.hover(dark) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hover = $0 }.help(help).accessibilityLabel(help)
            .disabled(busy)
    }
}
/// Captures a trigger's frame (in the "journalRoot" space) so a root-level dropdown can hang under it.
private struct MenuAnchorKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}
/// Separate key for the detail's ⓘ panel — a shared key would bubble up to JournalView and clobber the
/// grouping anchor (the detail is a descendant of the view that reads MenuAnchorKey).
private struct InfoAnchorKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}

/// The grouping menu, drawn inside the window: the shared menu rows on the shared card, with its own shadow.
private struct JournalMenuCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        VStack(spacing: 2) { content }
            .frame(width: 232 - 12)
            .menuCard(dark: dark, shadow: true)
    }
}
/// raised button — the exact treatment of the Dictionary's "Add replacement": a raised
/// win pill + hairline border + a soft shadow, hover shifts the fill.
private struct JournalActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        RaisedButton(title: title, systemImage: systemImage, action: action)
    }
}
/// A Quiet-tier action: an icon + text link with no border or fill — same treatment as the
/// settings "Restore defaults". `color` sets the accent (e.g. red for a destructive Delete); hover dims it.
private struct JournalQuietAction: View {
    let title: String
    let systemImage: String
    var danger: Bool = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .regular))
                Text(title).font(RhemionStyle.font(12.5, .regular))
            }
        }.buttonStyle(QuietActionStyle(dark: dark, danger: danger))
    }
}
/// Gold checkbox: solid gold fill + white check when on, hairline border when off. Kept
/// internal (not private) so the Clear Data window (ClearData.swift) and the Uninstall window
/// (FarewellWindow.swift) reuse the exact same control rather than a second implementation.
struct JournalCheckbox: View {
    let on: Bool
    var mixed = false
    // Pure visual — the tap is handled by the caller's .onTapGesture so it can't be swallowed by a
    // sibling row Button (the previous nested-Button setup never registered clicks).
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5).fill(on || mixed ? RhemionStyle.gold : .clear)   // unchecked = no fill
            RoundedRectangle(cornerRadius: 3.5).strokeBorder(on || mixed ? RhemionStyle.gold : RhemionStyle.checkboxEdge(dark), lineWidth: 1)
            if on || mixed { Image(systemName: mixed ? "minus" : "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(RhemionStyle.theme(dark).onAccent) }
        }.frame(width: 15, height: 15)
            .accessibilityLabel("Select").accessibilityValue(mixed ? "Mixed" : on ? "Yes" : "No").accessibilityAddTraits(.isButton)
    }
}
private struct JournalRow: View {
    let entry: JournalEntry
    let status: JournalEntry.Status?
    let canInsertAgain: Bool
    let insertAgain: () -> Void
    let compact: Bool
    let query: String
    let selected: Bool
    let checked: Bool
    let selecting: Bool
    let hovered: Bool
    let separator: Bool
    let open: () -> Void
    let toggle: () -> Void
    let copy: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var preview: AttributedString {
        // A search hit in Clean/Raw should be visible even when the final text differs.
        let source = query.isEmpty ? entry.transcript : [entry.transcript, entry.clean, entry.raw].first { $0.localizedStandardContains(query) } ?? entry.transcript
        var value = AttributedString(source)
        if !query.isEmpty {
            var remaining = source.startIndex..<source.endIndex
            while let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
                if let converted = Range(range, in: value) { value[converted].backgroundColor = RhemionStyle.theme(dark).searchHit }
                remaining = range.upperBound..<source.endIndex
            }
        }
        return value
    }
    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 8) {
            JournalCheckbox(on: checked)
                .frame(width: 20, height: 18, alignment: compact ? .center : .top).contentShape(Rectangle())
                .opacity(hovered || selecting || checked ? 1 : 0)   // reveal on hover / in selection; the tap zone stays live so the first click always lands
                .onTapGesture { open(); toggle() }   // also open the ticked entry so the detail (and its Delete) act on THIS record
            Button(action: open) {
                Group {
                    if compact {
                        HStack(spacing: 8) {
                            Text(JournalDoc.label(entry.ts, "HH:mm")).font(RhemionStyle.font(11.5, .medium)).foregroundStyle(RhemionStyle.secondary(dark))
                            if let status {   // compact: the mark alone, the word in the tooltip
                                JournalStatusMark(status: status).foregroundStyle(selected ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark)).help(status.label)
                            }
                            Text(preview).font(RhemionStyle.font(13, .light)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.duration).font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.tertiary(dark))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(preview).font(RhemionStyle.font(13, .light)).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 5) {
                                Text(JournalDoc.label(entry.ts, query.isEmpty ? "HH:mm" : "dd.MM.yyyy · HH:mm"))
                                Text("·")
                                // Where it went: the app, or "Journal only" as plain text in the same place.
                                Text(entry.isJournalOnly ? "Journal only" : (entry.appName ?? "Unknown app")).lineLimit(1)
                                if let status {
                                    HStack(spacing: 4) {
                                        JournalStatusMark(status: status)
                                        Text(status.label).font(RhemionStyle.font(11, .semibold)).lineLimit(1)
                                    }.foregroundStyle(selected ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark)).padding(.leading, 4)
                                }
                                Spacer(minLength: 0)
                                Text(entry.duration)
                            }.font(RhemionStyle.font(11)).foregroundStyle(RhemionStyle.tertiary(dark))
                        }
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if canInsertAgain {
                Button(action: insertAgain) { InsertAgainIcon(size: 13).foregroundStyle(RhemionStyle.tertiary(dark)).frame(width: 18, height: 18) }
                    .buttonStyle(.plain).opacity(hovered ? 1 : 0).allowsHitTesting(hovered).help("Insert again: put it back in the field where you dictated it")
            }
            if status != .failed, status != .noSpeech, entry.transcript.contains(where: { !$0.isWhitespace }) {   // nothing to copy without text
                Button(action: copy) { Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .regular)).foregroundStyle(RhemionStyle.tertiary(dark)).frame(width: 18, height: 18) }
                    .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).help("Copy (Final)")
            }
        }.monospacedDigit().padding(.horizontal, 8).padding(.vertical, compact ? 6 : 8)
            .background(selected ? RhemionStyle.selected(dark) : hovered ? RhemionStyle.theme(dark).rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if !compact && !selected { RoundedRectangle(cornerRadius: 6).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5).allowsHitTesting(false) } }
            .overlay(alignment: .bottom) {
                if compact && separator && !selected && !hovered { RhemionStyle.line(dark).frame(height: 0.5).padding(.leading, 24) }
            }.padding(.horizontal, compact ? 8 : 10).padding(.vertical, compact ? 0 : 4)
    }
}

private struct JournalDetail: View {
    let entry: JournalEntry
    @ObservedObject var model: JournalModel
    let notify: (String) -> Void
    let delete: () -> Void
    let deleting: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var mode = "Final"
    @State private var info = false
    @State private var infoAnchor: CGRect = .zero
    @State private var textHeight: CGFloat = 0
    private var dark: Bool { scheme == .dark }
    private var transcript: String { mode == "Raw" ? entry.raw : mode == "Clean" ? entry.clean : entry.transcript }
    var body: some View {
        VStack(spacing: 0) {
            // PINNED header — stays put while the transcript scrolls, so Copy is always reachable (a long
            // transcript no longer pushes it off the bottom). Order: mode switcher · app · ⓘ · Copy.
            VStack(alignment: .leading, spacing: 12) {
                Text(JournalDoc.label(entry.ts, "d MMMM yyyy · HH:mm")).font(RhemionStyle.font(18, .bold))
                HStack(spacing: 8) {
                    modeSwitcher
                    Spacer(minLength: 8)
                    Text(entry.isJournalOnly ? "Journal only" : (entry.appName ?? "—")).font(RhemionStyle.font(11)).lineLimit(1).foregroundStyle(RhemionStyle.tertiary(dark))
                    Button { info.toggle() } label: { Image(systemName: "info.circle") }.help("How it was recognized")
                        .background(GeometryReader { g in Color.clear.preference(key: InfoAnchorKey.self, value: g.frame(in: .named("detailRoot"))) })
                    JournalActionButton(title: "Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                        notify("Copied (\(mode))")
                    }
                }
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))
            Divider().overlay(RhemionStyle.line(dark))
            // SCROLL body — transcript, player, and the (deliberate, destructive) Delete at the bottom.
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                if let status = model.status(entry) { statusRow(status); Divider().overlay(RhemionStyle.line(dark)) }
                VStack(alignment: .leading, spacing: 20) {
                    // Selectable transcript in a read-only NSTextView so the selection highlight is OUR gold,
                    // not the system blue accent (SwiftUI's .textSelection can't recolor its highlight).
                    GeometryReader { geo in
                        SelectableText(text: transcript.isEmpty ? "No text" : transcript, width: geo.size.width,
                                       dark: dark, height: $textHeight)
                    }
                    .frame(height: max(textHeight, 1)).frame(maxWidth: .infinity, alignment: .leading)
                    JournalPlayer(url: entry.audioURL, durationMS: entry.audioDurationMS, notify: notify)
                    HStack {
                        Spacer()
                        JournalQuietAction(title: "Delete", systemImage: "trash", danger: true, action: delete).disabled(deleting)
                    }
                }.padding(24)
              }
            }
        }
        .coordinateSpace(name: "detailRoot")
        .onPreferenceChange(InfoAnchorKey.self) { infoAnchor = $0 }
        .overlay { infoPanel }
    }

    /// The status row: the mark and the state as a title line, the reason
    /// under it (fixed sentences, nothing filled in), Insert again on the right when the entry can be put back.
    private func statusRow(_ status: JournalEntry.Status) -> some View {
        let gone = model.fieldGone.contains(entry.id)
        let canPutBack = !gone && model.canPutBack(entry) && !model.inserting.contains(entry.id)
        let canRecognize = model.canRecognizeAgain(entry)
        let recognizing = model.recognizing.contains(entry.id)
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    JournalStatusMark(status: status, size: 13)
                    Text(status.label).font(RhemionStyle.font(13, .semibold))
                }.foregroundStyle(RhemionStyle.text(dark))
                Text(reason(status, gone: gone)).font(RhemionStyle.font(12.5)).foregroundStyle(RhemionStyle.secondary(dark))
                    .lineSpacing(3).padding(.leading, 20).fixedSize(horizontal: false, vertical: true)
                if let error = model.recognizeErrors[entry.id], canRecognize {
                    Text(error).font(RhemionStyle.font(12.5)).foregroundStyle(RhemionStyle.text(dark))
                        .lineSpacing(3).padding(.leading, 20).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if canRecognize {
                RaisedButton(title: recognizing ? "Recognizing…" : "Recognize again", systemImage: "waveform") {
                    model.runRecognizeAgain(entry)
                }
                .disabled(recognizing).help("Recognize the kept recording again")
            }
            if canPutBack {
                RaisedButton(title: "Insert again", icon: AnyView(InsertAgainIcon(size: 13))) { model.runInsertAgain(entry) }
                    .help("Put it back in the field where you dictated it")
            }
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func reason(_ status: JournalEntry.Status, gone: Bool) -> String {
        if gone { return "The field it was meant for is no longer there. Copy the text and paste it where it should go." }
        switch status {
        case .notInserted:
            switch entry.deliveryError {
            case "target-lost": return "Focus moved elsewhere before the text was ready."
            case "paste-unchanged": return "The paste was sent, but the text didn’t appear in the field."
            case "paste-elsewhere": return "Focus moved to another field as the text arrived, so it may have landed there."
            case "recovered": return "Rhemion stopped before this dictation finished. It was recognised from the recording afterwards, so it was not inserted."
            case "recognized-again": return "Recognised again from the recording. It has not been inserted anywhere yet."
            default: return "It could not be inserted where you were typing."
            }
        case .failed:
            let kept = entry.audioURL != nil ? " The recording is kept below." : ""
            switch entry.deliveryError {
            case "recovered": return "Rhemion stopped before this dictation finished, and it could not be recognised afterwards.\(kept)"
            case "recognition-failed": return "Recognition failed, so there is no text.\(kept)"
            default: return "Speech wasn’t recognised, so there is no text.\(kept)"
            }
        case .noSpeech:
            return "Nothing was heard in this recording.\(entry.audioURL != nil ? " The recording is kept below." : "")"
        case .canceled:
            let until = entry.ts.addingTimeInterval(Double(max(1, model.keepCanceledHours)) * 3600)
            let f = DateFormatter()   // system wording and translation: "tomorrow at 11:52", "Wednesday at 9:05"
            f.doesRelativeDateFormatting = true; f.dateStyle = .medium; f.timeStyle = .short
            f.formattingContext = .middleOfSentence
            return "Stopped with Esc twice. Kept until \(f.string(from: until))."
        case .erased:
            return "Taken back with Esc twice right after it was inserted."
        }
    }

    // Final / Clean / Raw — a segmented control (active = raised win pill + soft shadow, thin text).
    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(["Final", "Clean", "Raw"], id: \.self) { value in
                let on = mode == value
                Button { mode = value } label: {
                    Text(value).font(RhemionStyle.font(12, .regular))
                        .foregroundStyle(on ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark))
                        .padding(.horizontal, 13).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .activeTile(on, dark: dark, radius: 6)
            }
        }.padding(2).background(RhemionStyle.rail(dark), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
    }
    // Same surface as the grouping menu (opaque card, radius 12, soft shadow, no arrow), hung under the
    // ⓘ button and right-aligned to it so it stays inside the detail pane. Click-away dismisses.
    @ViewBuilder private var infoPanel: some View {
        if info {
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { info = false }
                VStack(alignment: .leading, spacing: 10) {
                    Text("How it was recognized").font(RhemionStyle.font(13, .semibold)).foregroundStyle(RhemionStyle.text(dark))
                    infoRow("Engine", entry.engine)
                    infoRow("Insertion method", entry.deliveryMethod ?? "—")
                    infoRow("Processing", entry.ms.map { "\($0) ms" } ?? "—")
                    infoRow("Duration", entry.duration)
                }
                .padding(14)
                .frame(width: 264, alignment: .leading)
                .background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
                .themeShadow(RhemionStyle.theme(dark).menuShadow)
                .fixedSize()
                .offset(x: max(8, infoAnchor.maxX - 264), y: infoAnchor.maxY + 5)
            }
        }
    }
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(RhemionStyle.secondary(dark)); Spacer(); Text(value).foregroundStyle(RhemionStyle.text(dark)) }.font(RhemionStyle.font(12))
    }
}

/// Real local-WAV transport: AVAudioPlayer play/pause + drag-to-seek on the "thread" progress, and
/// Reveal-in-Finder. When the entry has no audio (never retained / pruned) play + folder are disabled.
private struct JournalPlayer: View {
    let url: URL?
    let durationMS: Int?
    let notify: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var position = 0.0
    @State private var scrubbing = false
    @State private var rate = 1.0
    private let ticker = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()
    private var dark: Bool { scheme == .dark }
    private var available: Bool { url != nil }        // the WAV exists on disk (Reveal-in-Finder)
    private var playable: Bool { player != nil }       // AVAudioPlayer actually loaded it (play / seek / speed)
    private var total: Double { let d = player?.duration ?? 0; return d > 0 ? d : Double(max(0, durationMS ?? 0)) / 1000 }
    var body: some View {
        HStack(spacing: 12) {
            Button { toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold)).offset(x: playing ? 0 : 1)
                    .foregroundStyle(RhemionStyle.text(dark)).frame(width: 30, height: 30)
            }.buttonStyle(JournalPlayStyle()).disabled(!playable)
                .help(playable ? (playing ? "Pause" : "Play") : available ? "Audio couldn't be loaded" : "No audio for this entry").accessibilityLabel(playing ? "Pause" : "Play")
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 12)
                ZStack(alignment: .leading) {
                    Capsule().fill(RhemionStyle.theme(dark).track).frame(height: 2)
                    // Played portion — monochrome INK (text color): near-black on light / near-white on
                    // dark, so it clearly contrasts the grey track (white-on-light barely showed).
                    Capsule().fill(RhemionStyle.text(dark)).frame(width: width * position, height: 2)
                    // Thumb matches the Copy/Play raised style: a raised neutral badge (win + hairline +
                    // shadow) with a contrasting inner dot (dark on light, light on dark).
                    ZStack {
                        Circle().fill(RhemionStyle.win(dark)).frame(width: 13, height: 13)
                            .overlay { Circle().strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
                            .themeShadow(RhemionStyle.theme(dark).knobShadow)
                        Circle().fill(RhemionStyle.text(dark)).frame(width: 5, height: 5)
                    }.offset(x: width * position - 6.5)
                }.padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { if playable { scrubbing = true; position = min(1, max(0, ($0.location.x - 6) / width)) } }
                        .onEnded { _ in if playable { seek(position); scrubbing = false } })
            }.frame(minWidth: 35).frame(height: 28).opacity(playable ? 1 : 0.5)
                .accessibilityLabel("Playback position").accessibilityValue(JournalDoc.duration(position * total))
            Text("\(JournalDoc.duration(position * total)) / \(available || durationMS != nil ? JournalDoc.duration(total) : "—")").font(RhemionStyle.font(11)).monospacedDigit().fixedSize()
            Button { cycleRate() } label: { Text(rateLabel).font(RhemionStyle.font(12, .medium)).fixedSize() }
                .buttonStyle(.plain).disabled(!playable).help("Playback speed")
            Button { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { notify("No audio file for this entry.") } } label: { Image(systemName: "folder") }
                .disabled(!available).help("Reveal in Finder").accessibilityLabel("Reveal in Finder")
        }.foregroundStyle(RhemionStyle.secondary(dark)).padding(13)
            .background(RhemionStyle.rail(dark), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
            .onAppear { if let url { let p = try? AVAudioPlayer(contentsOf: url); p?.enableRate = true; p?.prepareToPlay(); player = p } }
            .onDisappear { player?.stop(); player = nil }
            .onReceive(ticker) { _ in
                guard playing, !scrubbing, let p = player else { return }
                if p.isPlaying { position = p.duration > 0 ? p.currentTime / p.duration : 0 }
                else { playing = false; position = 0 }   // reached the end
            }
    }
    private func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); playing = false }
        else { if position >= 1 { p.currentTime = 0; position = 0 }; p.play(); p.rate = Float(rate); playing = true }
    }
    private func seek(_ fraction: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(p.duration, fraction * p.duration))
    }
    private var rateLabel: String { rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate) }
    private func cycleRate() {
        let rates = [1.0, 1.25, 1.5, 2.0]
        rate = rates[((rates.firstIndex(of: rate) ?? 0) + 1) % rates.count]
        player?.rate = Float(rate)   // live while playing; re-applied after the next play()
    }
}
/// The Play/Pause face: a raised neutral circle with the Raised button's fill, hairline and shadow; hover
/// shifts the fill. Monochrome (no gold, no breathing glow).
private struct JournalPlayStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        JournalPlayFace(label: configuration.label, pressed: configuration.isPressed)
    }
}
private struct JournalPlayFace<Label: View>: View {
    let label: Label
    let pressed: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    private var dark: Bool { scheme == .dark }
    var body: some View {
        label
            .background(hover ? RhemionStyle.hover(dark) : RhemionStyle.win(dark), in: Circle())
            .overlay { Circle().strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
            .themeShadow(RhemionStyle.theme(dark).raisedShadow)
            .scaleEffect(pressed ? 0.95 : 1)
            .onHover { hover = $0 }
    }
}


/// A read-only, selectable transcript rendered with AppKit so the selection highlight is OUR gold instead
/// of the system-accent blue (SwiftUI's `.textSelection` exposes no way to recolor the highlight). Non-
/// scrolling — the parent ScrollView scrolls; it self-sizes by reporting the wrapped height for the given
/// width back through `height`. Native Cmd+C copies the selection.
private struct SelectableText: NSViewRepresentable {
    let text: String
    let width: CGFloat
    let dark: Bool
    @Binding var height: CGFloat

    private var font: NSFont { NSFont(name: "Mulish-Regular", size: 15) ?? .systemFont(ofSize: 15) }
    private var textColor: NSColor { RhemionStyle.nsText(dark) }
    // Same warm-yellow hue as the journal list's selected row (#F6DD84), just slightly translucent so the
    // text keeps breathing through it (the solid fill read too dense). Base hue matches the selected row —
    // the amber gold #E0A42E turned peachy on white.
    private var selectionColor: NSColor {
        RhemionStyle.nsTextSelection(dark)
    }

    private func attributed() -> NSAttributedString {
        let para = NSMutableParagraphStyle(); para.lineSpacing = 7
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: para])
    }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        tv.selectedTextAttributes = [.backgroundColor: selectionColor]
        tv.textStorage?.setAttributedString(attributed())
        guard width > 0 else { return }
        let bounds = attributed().boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        let measured = ceil(bounds.height) + 2   // small buffer so the last line never clips
        if abs(measured - height) > 0.5 {
            DispatchQueue.main.async { height = measured }
        }
    }
}
