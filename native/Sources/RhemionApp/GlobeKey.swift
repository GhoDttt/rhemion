// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The Globe (Fn) key's own system action (System Settings › Keyboard › "Press 🌐 key to"). When Fn is a dictation
// key that action fires too (Apple Dictation, the input source, Emoji & Symbols), so Settings and Welcome say so
// and link to the setting. Read only; Rhemion never changes a system setting.

import AppKit

enum GlobeKey {
    /// What the Globe key does besides dictating with Rhemion, as a phrase ("starts Apple Dictation"); nil when it
    /// is set to Do Nothing.
    static var conflict: String? {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        switch value {
        case 0: return nil
        case 1: return "changes the input source"
        case 2: return "shows Emoji & Symbols"
        case 3: return "starts Apple Dictation"
        default: return "has a system action"   // not set yet: macOS gives it one by default
        }
    }

    /// System Settings › Keyboard, where "Press 🌐 key to" lives.
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
