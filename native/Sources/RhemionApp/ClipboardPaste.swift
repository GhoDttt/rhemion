// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

// In-process clipboard paste. All pasteboard and event work is serialized off the main actor; the
// delayed restore is deliberately decoupled from completion so the delivery FIFO can advance.

@preconcurrency import AppKit
import Carbon.HIToolbox
@preconcurrency import CoreGraphics
import Foundation
import Security

enum ClipboardPaste {
    enum PasteStatus: Sendable {
        case pasteSubmitted, targetChanged, pasteNotPosted, pasteAmbiguous, error
    }

    static func paste(
        _ text: String,
        targetPid: Int?,
        settleMS: Int = 0,
        stillTarget: (@Sendable () -> Bool)? = nil,
        completion: @escaping (PasteStatus) -> Void
    ) {
        Engine.shared.paste(text, targetPid: targetPid, settleMS: settleMS, stillTarget: stillTarget, completion: completion)
    }

    /// A clipboard marked by its owner as concealed (passwords) or transient (one-time codes), per the
    /// nspasteboard.org convention.
    /// V for ⌘V, worked out on the main thread (Text Input Sources must not be called from the paste queue:
    /// that traps) at launch and whenever the keyboard layout changes; the paste only reads it.
    static let vKey = Locked<CGKeyCode>(0x09)
    /// The tag of the latest posted paste (read in the completion, which runs right after it is set): lets the
    /// caller hand the user's clipboard back as soon as it sees the text land (`restoreNow`).
    static let lastPostedToken = Locked<String?>(nil)
    /// The text was seen in the field: the app has read the clipboard, so the user's own clipboard can go back
    /// now. Only the restore of THAT paste (by its tag); a newer paste's pending restore is never touched.
    static func restoreNow(token: String) { Engine.shared.restoreNow(token: token) }
    /// ⌘V again for the paste tagged `token`, its text still on the clipboard (see `Engine.repaste`).
    static func repaste(token: String, targetPid: Int?, stillTarget: (@Sendable () -> Bool)? = nil,
                        completion: @escaping (PasteStatus) -> Void) {
        Engine.shared.repaste(token: token, targetPid: targetPid, stillTarget: stillTarget, completion: completion)
    }
    /// When nothing confirms the paste (a field that cannot be read), the user's clipboard goes back after this
    /// long. It used to be 250 ms, but Chrome sometimes reads the clipboard later than that (a busy page),
    /// and then pasted the user's OLD clipboard instead of the dictation (bench: 2 in about 700 pastes).
    static let fallbackRestoreMS = 1_500
    /// Marks the ⌘V events Rhemion posts itself, so `UserPasteWatch` lets them through untouched.
    static let ownEventMarker: Int64 = 0x5248_454D
    private nonisolated(unsafe) static var layoutObserver: NSObjectProtocol?

    @MainActor static func trackKeyboardLayout() {
        vKey.value = vKeyCode()
        guard layoutObserver == nil else { return }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { vKey.value = vKeyCode() } }
    }

    /// The key code that types "v" in the keyboard layout macOS uses for shortcuts (the current ASCII-capable
    /// layout: Dvorak puts V elsewhere; a Russian layout pairs with ABC/US, where it is 0x09). Falls back to 0x09.
    /// Main thread only.
    @MainActor static func vKeyCode() -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return 0x09 }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return 0x09 }
            for code in 0..<UInt16(128) {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) { return CGKeyCode(code) }
            }
            return 0x09
        }
    }

    static func isSensitive(_ snapshot: [[String: Data]]) -> Bool {
        snapshot.contains { item in
            item.keys.contains("org.nspasteboard.ConcealedType") || item.keys.contains("org.nspasteboard.TransientType")
        }
    }

    private final class Callback: @unchecked Sendable {
        let body: (PasteStatus) -> Void
        init(_ body: @escaping (PasteStatus) -> Void) { self.body = body }
    }

    private final class PendingRestore: @unchecked Sendable {
        let savedOriginal: [[String: Data]]
        let changeCount: Int
        let token: String
        var workItem: DispatchWorkItem?
        /// When its ⌘V went out (or went out again, `repaste`): the next paste waits for this one to be read.
        var postedAt = DispatchTime.now()

        init(savedOriginal: [[String: Data]], changeCount: Int, token: String) {
            self.savedOriginal = savedOriginal
            self.changeCount = changeCount
            self.token = token
        }
    }

    final class Engine: @unchecked Sendable {
        static let shared = Engine()
        /// The system clipboard; a test passes a private one, so it never touches the user's.
        private let pasteboard: NSPasteboard
        init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

        private let queue = DispatchQueue(label: "com.sageathor.rhemion.app.clipboard-paste")
        private let sentinelType = NSPasteboard.PasteboardType("com.sageathor.rhemion.paste")
        private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        private let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        private let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        private var pending: PendingRestore? {
            didSet { if self === Engine.shared, (oldValue == nil) != (pending == nil) { UserPasteWatch.shared.set(armed: pending != nil) } }
        }

        func paste(
            _ text: String,
            targetPid: Int?,
            settleMS: Int,
            stillTarget: (@Sendable () -> Bool)?,
            completion: @escaping (PasteStatus) -> Void
        ) {
            let callback = Callback(completion)
            queue.async { self.begin(text, targetPid: targetPid, settleMS: settleMS, stillTarget: stillTarget, callback: callback) }
        }

        /// How long the next paste waits for the previous one to be seen in its field before writing the clipboard.
        /// Overwriting it earlier could hand the previous ⌘V the NEXT text when the app reads the clipboard late
        /// (Chrome, a busy page). Confirmation (`restoreNow`) ends the wait at once; an unreadable field waits it out.
        static let readWaitMS = 800

        private func begin(_ text: String, targetPid: Int?, settleMS: Int, stillTarget: (@Sendable () -> Bool)?, callback: Callback) {
            if let pending, DispatchTime.now() < pending.postedAt + .milliseconds(Self.readWaitMS) {
                queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                    self.begin(text, targetPid: targetPid, settleMS: settleMS, stillTarget: stillTarget, callback: callback)
                }
                return
            }
            guard !text.isEmpty else { callback.body(.pasteNotPosted); return }
            guard targetMatches(targetPid) else { callback.body(.targetChanged); return }
            guard let source = CGEventSource(stateID: .privateState) else {
                callback.body(.pasteNotPosted); return
            }

            // If a prior restore is pending and its tagged write is intact, its saved snapshot is the
            // real original clipboard. Carry that snapshot through instead of snapshotting our text.
            let savedOriginal: [[String: Data]]
            if let pending, stillOwns(changeCount: pending.changeCount, token: pending.token) {
                savedOriginal = pending.savedOriginal
                pending.workItem?.cancel()
                self.pending = nil
            } else {
                pending?.workItem?.cancel()
                pending = nil
                let t0 = DispatchTime.now().uptimeNanoseconds
                savedOriginal = snapshot()
                let snapMS = (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                // The snapshot sits on the paste path; a big clipboard (images) shows up here.
                if snapMS >= 20 { log("paste: clipboard snapshot took \(snapMS) ms (\(savedOriginal.count) item(s))") }
            }

            let (changeCount, token) = writeTagged(text)
            let state = CompletionState(callback: callback)

            let watchdog = DispatchWorkItem { [weak self, state] in
                guard let self, !state.completed else { return }
                if self.stillOwns(changeCount: changeCount, token: token) {
                    self.restore(savedOriginal)
                }
                self.complete(state, state.posted ? .pasteAmbiguous : .error)
            }
            state.watchdog = watchdog
            queue.asyncAfter(deadline: .now() + .milliseconds(1_500), execute: watchdog)

            // ⌘V goes out as soon as the user's own keys are up (a Recall chord, a late push-to-talk release):
            // a held modifier would turn ⌘V into another shortcut. No fixed settle otherwise: the insertion
            // bench (Chrome and Safari, React fields included) found none needed.
            queue.asyncAfter(deadline: .now() + .milliseconds(settleMS)) { [weak self, state] in
              self?.whenKeysUp(until: .now() + .milliseconds(600), state: state) { [weak self, state] in
                guard let self, !state.completed else { return }
                guard self.targetMatches(targetPid) else {
                    self.restoreIfOwned(savedOriginal, changeCount: changeCount, token: token)
                    self.complete(state, .targetChanged)
                    return
                }
                // The field may have changed while the keys were up-waiting: check it again right before ⌘V.
                if let stillTarget, !stillTarget() {
                    self.restoreIfOwned(savedOriginal, changeCount: changeCount, token: token)
                    self.complete(state, .targetChanged)
                    return
                }
                guard !self.modifiersHeld() else {
                    self.restoreIfOwned(savedOriginal, changeCount: changeCount, token: token)
                    self.complete(state, .pasteNotPosted)
                    return
                }

                guard let shortcut = Self.shortcut(source) else {
                    self.restoreIfOwned(savedOriginal, changeCount: changeCount, token: token)
                    self.complete(state, .pasteNotPosted)
                    return
                }

                // Last check before ⌘V: if the user copied something since our write, the clipboard is
                // theirs now. Pasting would insert THEIR content, so do not post, and leave it alone.
                guard self.stillOwns(changeCount: changeCount, token: token) else {
                    self.complete(state, .pasteNotPosted)
                    return
                }

                state.posted = true
                Self.post(shortcut)

                self.scheduleRestore(savedOriginal, changeCount: changeCount, token: token)
                ClipboardPaste.lastPostedToken.value = token
                self.complete(state, .pasteSubmitted)
              }
            }
        }

        /// ⌘V as four events, all built before any is posted (a half-built shortcut would leave Command stuck).
        /// 0x37 is left Command; V comes from the shortcut layout (vKeyCode: Dvorak's V is not QWERTY's).
        private static func shortcut(_ source: CGEventSource) -> [CGEvent]? {
            let vKey = ClipboardPaste.vKey.value
            guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
                  let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
                  let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
                  let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else { return nil }
            for event in [cmdDown, vDown, vUp, cmdUp] {
                event.setIntegerValueField(.eventSourceUserData, value: ClipboardPaste.ownEventMarker)
            }
            cmdDown.flags = .maskCommand
            vDown.flags = .maskCommand
            vUp.flags = .maskCommand
            return [cmdDown, vDown, vUp, cmdUp]
        }

        private static func post(_ shortcut: [CGEvent]) {
            for (i, event) in shortcut.enumerated() {
                if i > 0 { usleep(10_000) }
                event.post(tap: .cghidEventTap)
            }
        }

        /// The same paste once more: the clipboard still holds this paste's text (its tag, untouched), nothing is
        /// written. For an app that showed the paste event and dropped the text (Chromium 155 and later skip the
        /// first ⌘V after another app changed the clipboard; the second lands). The caller decides it was a miss.
        /// The pending restore waits again from now, so the user's clipboard never comes back under this ⌘V.
        func repaste(token: String, targetPid: Int?, stillTarget: (@Sendable () -> Bool)?, completion: @escaping (PasteStatus) -> Void) {
            let callback = Callback(completion)
            queue.async {
                guard let record = self.pending, record.token == token,
                      self.stillOwns(changeCount: record.changeCount, token: token) else { callback.body(.pasteNotPosted); return }
                guard self.targetMatches(targetPid), stillTarget?() ?? true else { callback.body(.targetChanged); return }
                guard !self.modifiersHeld(), let source = CGEventSource(stateID: .privateState),
                      let shortcut = Self.shortcut(source) else { callback.body(.pasteNotPosted); return }
                Self.post(shortcut)
                record.postedAt = DispatchTime.now()
                record.workItem?.cancel()
                let work = DispatchWorkItem { [weak self, weak record] in
                    guard let self, let record, self.pending === record else { return }
                    self.pending = nil
                    self.restoreIfOwned(record.savedOriginal, changeCount: record.changeCount, token: record.token)
                }
                record.workItem = work
                self.queue.asyncAfter(deadline: .now() + .milliseconds(ClipboardPaste.fallbackRestoreMS), execute: work)
                callback.body(.pasteSubmitted)
            }
        }

        /// Runs `body` once no modifier is held, or at `until` (body then sees the key still down and does not paste).
        private func whenKeysUp(until: DispatchTime, state: CompletionState, _ body: @escaping () -> Void) {
            guard !state.completed else { return }
            if !modifiersHeld() || DispatchTime.now() >= until { body(); return }
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self, state] in
                self?.whenKeysUp(until: until, state: state, body)
            }
        }

        private final class CompletionState: @unchecked Sendable {
            let callback: Callback
            var completed = false
            var posted = false
            var watchdog: DispatchWorkItem?
            init(callback: Callback) { self.callback = callback }
        }

        private func complete(_ state: CompletionState, _ status: PasteStatus) {
            guard !state.completed else { return }
            state.completed = true
            state.watchdog?.cancel()
            state.watchdog = nil
            state.callback.body(status)
        }

        private func scheduleRestore(
            _ savedOriginal: [[String: Data]], changeCount: Int, token: String
        ) {
            let record = PendingRestore(
                savedOriginal: savedOriginal, changeCount: changeCount, token: token
            )
            pending = record
            let work = DispatchWorkItem { [weak self, weak record] in
                guard let self, let record, self.pending === record else { return }
                self.pending = nil
                self.restoreIfOwned(
                    record.savedOriginal, changeCount: record.changeCount, token: record.token
                )
            }
            record.workItem = work
            queue.asyncAfter(deadline: .now() + .milliseconds(ClipboardPaste.fallbackRestoreMS), execute: work)
        }

        /// The user pressed ⌘V while the dictation still sits on the clipboard: their own goes back now, before the
        /// keystroke reaches the app. Synchronous (called from the event tap, which holds the keystroke meanwhile).
        func restorePendingNow() {
            queue.sync {
                guard let record = pending else { return }
                record.workItem?.cancel()
                pending = nil
                restoreIfOwned(record.savedOriginal, changeCount: record.changeCount, token: record.token)
                log("paste: clipboard given back at the user's ⌘V")
            }
        }

        func restoreNow(token: String) {
            queue.async { [weak self] in
                guard let self, let record = self.pending, record.token == token else { return }
                record.workItem?.cancel()
                self.pending = nil
                self.restoreIfOwned(record.savedOriginal, changeCount: record.changeCount, token: record.token)
            }
        }

        private func snapshot() -> [[String: Data]] {
            (pasteboard.pasteboardItems ?? []).map { item in
                var entries: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { entries[type.rawValue] = data }
                }
                return entries
            }
        }

        private func restore(_ snapshot: [[String: Data]]) {
            pasteboard.clearContents()
            // A password manager's concealed/transient copy is not put back: it clears its own copy on a
            // timer by watching changeCount, which our paste already moved, so a restored secret would stay.
            guard !ClipboardPaste.isSensitive(snapshot) else { return }
            let items = snapshot.map { entries in
                let item = NSPasteboardItem()
                for (rawType, data) in entries {
                    item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
                }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }

        private func randomToken() -> String {
            var bytes = [UInt8](repeating: 0, count: 16)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                arc4random_buf(&bytes, bytes.count)
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        private func writeTagged(_ text: String) -> (Int, String) {
            let token = randomToken()
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(token.utf8), forType: sentinelType)
            item.setData(Data("1".utf8), forType: concealedType)
            item.setData(Data("1".utf8), forType: transientType)
            item.setData(Data("1".utf8), forType: autoGeneratedType)
            pasteboard.writeObjects([item])
            return (pasteboard.changeCount, token)
        }

        private func stillOwns(changeCount: Int, token: String) -> Bool {
            guard pasteboard.changeCount == changeCount,
                  let top = pasteboard.pasteboardItems?.first,
                  let data = top.data(forType: sentinelType),
                  String(data: data, encoding: .utf8) == token else { return false }
            return true
        }

        private func restoreIfOwned(
            _ snapshot: [[String: Data]], changeCount: Int, token: String
        ) {
            if stillOwns(changeCount: changeCount, token: token) { restore(snapshot) }
        }

        private func targetMatches(_ targetPid: Int?) -> Bool {
            guard let targetPid else { return true }
            guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
            return Int(frontmost.processIdentifier) == targetPid
        }

        private func modifiersHeld() -> Bool {
            let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            return !CGEventSource.flagsState(.combinedSessionState).intersection(relevant).isEmpty
        }
    }
}

extension ClipboardPaste {
    /// While a dictation sits on the clipboard waiting to be given back (up to `fallbackRestoreMS` when the field
    /// cannot confirm the paste), the user's own ⌘V must paste THEIR clipboard. An active event tap sees that
    /// keystroke before the app does, hands the clipboard back, and lets the keystroke through. It is on only
    /// while a restore is pending; when it cannot be made, the timed restore is all there is.
    final class UserPasteWatch: @unchecked Sendable {
        static let shared = UserPasteWatch()
        private let lock = NSLock()
        private var armed = false
        private var tap: CFMachPort?   // main thread only

        func set(armed on: Bool) {
            lock.withLock { armed = on }
            DispatchQueue.main.async { self.apply() }
        }

        private var isArmed: Bool { lock.withLock { armed } }

        private func apply() {
            let on = isArmed
            if on && tap == nil {
                let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
                guard let made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                                   eventsOfInterest: mask, callback: userPasteTapCallback, userInfo: nil) else {
                    log("paste: user ⌘V watch unavailable")
                    return
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, made, 0), .commonModes)
                tap = made
            }
            if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
        }

        fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if isArmed, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return
            }
            guard type == .keyDown, isArmed,
                  event.getIntegerValueField(.eventSourceUserData) != ClipboardPaste.ownEventMarker,
                  event.flags.contains(.maskCommand),
                  CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == ClipboardPaste.vKey.value else { return }
            Engine.shared.restorePendingNow()
        }
    }
}

private func userPasteTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    ClipboardPaste.UserPasteWatch.shared.handle(type, event)
    return Unmanaged.passUnretained(event)
}
