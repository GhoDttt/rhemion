// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

// About Rhemion — the identity window: the mark on the left; name, slogan, what it does, and the version
// (with a quiet Copy for bug reports) on one aligned edge; the links in a footer bar with OK. Opened from the
// menu-bar menu and from Rhemion › About Rhemion. One instance: choosing it again brings it forward.
import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let logoClock = WelcomeLogoClock()
    /// Opens What's New (the first link in the footer).
    var onWhatsNew: (() -> Void)?

    func show() {
        if window == nil {
            let root = AboutView(info: AboutInfo(bundle: .main), logoClock: logoClock,
                                 onClose: { [weak self] in self?.window?.close() },
                                 onWhatsNew: { [weak self] in self?.onWhatsNew?() })
            let hosting = NSHostingController(rootView: root.themedRoot())
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "About Rhemion"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        AppController.shared?.setDockIconVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        if let window, !window.isVisible {
            logoClock.restart()
            centerOnPointerScreen(window)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppController.shared?.setDockIconVisible(false)
    }
}

/// What the About window shows, read from the bundle (the build script writes RhemionVersion = the full
/// VERSION string, which keeps a pre-release suffix that CFBundleShortVersionString can't hold).
struct AboutInfo: Equatable {
    let version: String
    let build: String?

    init(version: String, build: String?) { self.version = version; self.build = build }

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        version = info["RhemionVersion"] as? String ?? info["CFBundleShortVersionString"] as? String ?? "?"
        build = info["CFBundleVersion"] as? String
    }

    /// "3.0.0 (144)", or just "3.0.0" when there is no build number.
    var versionLine: String { version + (build.map { " (\($0))" } ?? "") }
    /// What Copy puts on the clipboard: the line a bug report asks for.
    var copyText: String { "Rhemion " + versionLine }

    static let repository = URL(string: "https://github.com/sageathor/rhemion")!
    static let releaseNotes = repository.appendingPathComponent("releases")
    static let reportIssue = repository.appendingPathComponent("issues/new/choose")
    static let privacy = repository.appendingPathComponent("blob/main/PRIVACY.md")
    static let licensesOnline = repository.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md")
    /// The notices inside the app (Contents/Resources/Licenses, next to every license text), so they open offline;
    /// the web copy only when a build lacks them.
    static var licenses: URL {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("Licenses/THIRD_PARTY_NOTICES.txt") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? licensesOnline
    }
}

struct AboutView: View {
    let info: AboutInfo
    @ObservedObject var logoClock: WelcomeLogoClock
    let onClose: () -> Void
    var onWhatsNew: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false
    private var dark: Bool { scheme == .dark }

    static let width: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 24) {
                WelcomeLogo(clock: logoClock, size: 112)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Rhemion").font(RhemionStyle.font(24, .heavy)).foregroundStyle(RhemionStyle.text(dark))
                    Text("Thought, uninterrupted.").font(RhemionStyle.font(15, .bold))
                        .foregroundStyle(RhemionStyle.text(dark)).padding(.top, 6)
                    Text("Hold a key and speak. Your Mac does the typing.").font(RhemionStyle.font(13))
                        .foregroundStyle(RhemionStyle.secondary(dark)).padding(.top, 3)
                        .fixedSize(horizontal: false, vertical: true)
                    versionRow.padding(.top, 12)
                    HStack(spacing: 0) {
                        Text("© 2026 Sageathor · ").font(RhemionStyle.font(11))
                            .foregroundStyle(RhemionStyle.tertiary(dark))
                        TextLink(title: "Licenses & Notices", size: 11) { open(AboutInfo.licenses) }
                            .accessibilityLabel("Licenses and Notices")
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 18, leading: 28, bottom: 22, trailing: 28))

            HStack(spacing: 16) {
                if let onWhatsNew { TextLink(title: "What's New", action: onWhatsNew) }
                TextLink(title: "Release Notes") { open(AboutInfo.releaseNotes) }
                TextLink(title: "Report an Issue") { open(AboutInfo.reportIssue) }
                TextLink(title: "Privacy") { open(AboutInfo.privacy) }
                TextLink(title: "Source Code") { open(AboutInfo.repository) }
                Spacer(minLength: 8)
                RaisedButton(title: "OK", action: onClose).fixedSize().keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            .background(RhemionStyle.rail(dark))
            .overlay(alignment: .top) { Rectangle().fill(RhemionStyle.line(dark)).frame(height: 1) }
        }
        .frame(minWidth: Self.width)
        .background(RhemionStyle.content(dark))
        .background(Button("", action: onClose).keyboardShortcut(.cancelAction).hidden())
    }

    /// The version and its Copy on one line. The button keeps the width of its widest label ("Copied"), so
    /// the line never shifts when it flips; nothing else shares the line, so a long pre-release version fits.
    private var versionRow: some View {
        HStack(spacing: 6) {
            Text("Version \(info.versionLine)").monospacedDigit()
                .font(RhemionStyle.font(12)).foregroundStyle(RhemionStyle.secondary(dark))
                .fixedSize()
            Button(action: copyVersion) {
                ZStack(alignment: .leading) {
                    copyLabel(copied: true).hidden()
                    copyLabel(copied: copied)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietActionStyle(dark: dark))
            .help("Copy the version and build for a bug report")
            .accessibilityLabel(copied ? "Copied" : "Copy version and build")
        }
    }

    private func copyLabel(copied: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5, weight: .medium))
                .frame(width: 12)
            Text(copied ? "Copied" : "Copy").font(RhemionStyle.font(12, .semibold))
        }
    }

    private func copyVersion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info.copyText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    private func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

