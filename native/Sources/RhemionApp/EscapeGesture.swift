// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

// EscapeGesture — global double-tap Escape, the "nope, get rid of it" gesture. Two Esc presses
// within a short window either cancel a recording in progress (nothing is delivered) or, right after a
// dictation landed, erase the whole delivered take. The single stroke means the same thing at any
// stage; AppController routes it (see main.swift).
//
// Unlike the other global hotkeys (Carbon RegisterEventHotKey, which would swallow EVERY single
// Esc system-wide), this is a CGEventTap on keyDown so a lone Esc always passes through untouched: the
// tap swallows ONLY the Escs of an engaged double-tap. It is an ACTIVE (.defaultTap) tap so it
// can consume that event — kept separate from the listen-only PTT tap (HotkeyTap) so the proven
// PTT-under-Secure-Input behavior is untouched. Being a CGEventTap, it does not fire under Secure
// Keyboard Entry — acceptable, since dictation is never delivered into a secure field, so there is
// nothing to cancel or erase there.
//
// `isEligible` is the cheap first-press gate: the tap only tracks Esc toward the gesture when it
// returns true (a recording is active, or a just-delivered take is still armed). While idle it returns
// false, so ordinary Escapes pass at once. While eligible, the FIRST Esc is held (press and release) for
// the double-tap window: many apps act on a single Esc (Telegram closes the chat, a browser closes a
// panel), and that first Esc used to move the focus before the second one arrived. If a second Esc comes,
// neither reaches the app; if not, the held Esc is given back, marked so this tap lets it through. `onDoubleTap` is called synchronously on the
// SECOND Esc and returns whether it actually claimed an action — the tap swallows that second Esc ONLY
// when it did, so an Esc is never eaten in a context where the gesture would be a no-op (e.g. the armed
// take belongs to a different, now-unfocused app).

import AppKit
import Carbon.HIToolbox

final class EscapeGesture: @unchecked Sendable {
    /// Cheap gate for whether to track an Esc toward the gesture at all (recording OR an armed take).
    /// Called synchronously on the main run loop from the tap callback; must be cheap and non-blocking.
    var isEligible: (@Sendable () -> Bool)?
    /// Called synchronously on the main run loop on a detected double-tap. Returns true if it CLAIMED
    /// an action (cancel a recording / erase a take in the frontmost app), false if there was nothing
    /// to do — the tap swallows the second Esc only when this returns true.
    var onDoubleTap: (@Sendable () -> Bool)?

    private static let escKeyCode: Int64 = 53   // kVK_Escape
    private var window: CFTimeInterval = 0.35    // max seconds between the two Esc presses
    private var lastEscAt: CFTimeInterval = 0
    /// The first Esc of a possible double-tap (press, and its release once it comes), held for `window`.
    private var heldDown: CGEvent?
    private var heldUp: CGEvent?
    private var holdTimer: DispatchWorkItem?
    /// The release of a second Esc that acted: the app saw no press, so it gets no release either.
    private var swallowUp = false
    /// Marks the Esc this tap gives back, so it passes through untouched.
    private static let replayMarker: Int64 = 0x5248_4573   // "RHEs"
    /// Every Esc, eligible or not: two within a second that did nothing get one log line saying why.
    private var lastAnyEscAt: CFTimeInterval = 0
    /// Why a double-tap would not act now ("nothing armed", "armed 12.3 s ago, TTL 8 s"); nil when it would.
    var whyNotEligible: (@Sendable () -> String)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suspended = false
    private var retryTimer: Timer?

    /// Set the double-tap window (milliseconds). Clamped to a sane range. Main run loop only.
    func setWindowMS(_ ms: Int) { window = min(2.0, max(0.15, Double(ms) / 1000.0)) }

    func start() {
        ensureTap()   // no prompt: Welcome asks for Accessibility; the tap appears once it is granted
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil
        retryTimer?.invalidate(); retryTimer = nil
        lastEscAt = 0
        release()
    }

    /// Temporarily stop acting (a settings recorder is capturing a chord and may use Esc). The tap
    /// stays installed but passes everything through and never fires. Main run loop only.
    func suspend() { suspended = true; lastEscAt = 0; release() }
    func resume() { suspended = false; lastEscAt = 0 }

    // MARK: - tap lifecycle (mirrors HotkeyTap: create only once AX is granted, retry until it is)

    private func ensureTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { scheduleRetry(); return }
        if !createTap() { scheduleRetry() } else { retryTimer?.invalidate(); retryTimer = nil }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.tap != nil { timer.invalidate(); self.retryTimer = nil; return }
            if AXIsProcessTrusted(), self.createTap() { timer.invalidate(); self.retryTimer = nil }
        }
    }

    private func createTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()   // self outlives the tap (held by AppController)
        // .defaultTap (NOT listenOnly): an active tap can return nil to swallow the second Esc.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: escapeTapCallback, userInfo: userInfo) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    // MARK: - event handling (main run loop)

    /// Returns true to SWALLOW the event (the second Esc of an engaged double-tap), false to pass it
    /// through. Runs on the main run loop (the tap's source is added there).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }   // re-enable if the system disabled us
            return false
        }
        guard type == .keyDown || type == .keyUp else { return false }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return false }   // our own give-back
        let isEsc = event.getIntegerValueField(.keyboardEventKeycode) == Self.escKeyCode

        if type == .keyUp {
            guard isEsc else { return false }
            if swallowUp { swallowUp = false; return true }
            if heldDown != nil { heldUp = event.copy(); return true }   // keep press and release together
            return false
        }

        guard isEsc else {
            lastEscAt = 0   // any other key breaks a pending first-Esc, so "Esc x Esc" isn't a double-tap
            // Order stays: the held Esc goes first, then this key.
            if heldDown != nil { release(then: event); return true }
            return false
        }
        // Auto-repeat (a HELD Esc) is never a second press: give the held one back and let the repeats pass.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { release(); return false }

        let now = CACurrentMediaTime()
        let previousAny = lastAnyEscAt
        lastAnyEscAt = now
        // A lone Esc is never held while idle: only track when there's something to act on.
        guard !suspended, isEligible?() == true else {
            if !suspended, previousAny > 0, now - previousAny <= 1.0 {
                log("double-Esc: not acted, \(whyNotEligible?() ?? "not eligible")")
            }
            lastEscAt = 0; release(); return false
        }
        if heldDown != nil {
            // Second Esc within the window (the hold timer has not fired). Act; on success the app sees neither
            // Esc. If the gesture had nothing to do (the armed take belongs to another app or field), both go on.
            lastEscAt = 0
            if onDoubleTap?() == true {
                holdTimer?.cancel(); holdTimer = nil
                heldDown = nil; heldUp = nil; swallowUp = true
                return true
            }
            release(); return false
        }
        if lastEscAt > 0, now - lastEscAt <= 1.0 {
            log("double-Esc: second Esc after \(Int((now - lastEscAt) * 1000)) ms, window \(Int(window * 1000)) ms")
        }
        // First Esc: hold it for the window, then give it back if no second one came.
        lastEscAt = now
        heldDown = event.copy(); heldUp = nil
        let timer = DispatchWorkItem { [weak self] in self?.release() }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: timer)
        return true
    }

    /// Give the held Esc (press, and release if it came) back to the app, then `next` if a key interrupted.
    private func release(then next: CGEvent? = nil) {
        holdTimer?.cancel(); holdTimer = nil
        if let down = heldDown { post(down) }
        if let up = heldUp { post(up) }
        heldDown = nil; heldUp = nil
        if let next, let copy = next.copy() { post(copy) }
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        event.post(tap: .cgSessionEventTap)
    }
}

/// C trampoline: recover the EscapeGesture from userInfo, forward, and honor its swallow decision.
/// Runs on the main run loop (the tap's source is added there), so `handle` is effectively
/// single-threaded / main-actor.
private let escapeTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo,
       Unmanaged<EscapeGesture>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event) {
        return nil   // swallow
    }
    return Unmanaged.passUnretained(event)
}
