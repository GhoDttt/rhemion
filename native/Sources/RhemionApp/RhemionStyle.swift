// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

/// The design tokens: the one palette every window draws from (gold #E0A42E, layered neutral surfaces,
/// Mulish). A colour or an appearance recipe lives here and nowhere else, so a theme can change it in one
/// place.
/// One appearance's tokens: every colour and appearance recipe the app draws with.
/// Light and dark are two instances; another theme is another instance, with no change to any screen.
struct RhemionTheme {
    /// A shadow as one value: colour (with its opacity), blur radius, vertical offset.
    struct Shadow { let color: Color; let radius: CGFloat; let y: CGFloat }

    // Ink
    let text, secondary, tertiary: Color
    /// Ink on a gold fill (a ticked checkbox's check, the menu row under the pointer).
    let onAccent: Color
    // Grounds
    let rail, content, win, line, hover, activeSurface: Color
    // Accent and status
    let gold, selected, danger, success: Color
    /// Gold washes: a progress fill (Download), a notice band, search hits.
    let goldWash, noticeWash, searchHit: Color
    /// A row under the pointer in a list (Journal).
    let rowHover: Color
    /// A slider's played track.
    let track: Color
    /// The hairline that lifts a raised surface off the page (active tile, pop-up card).
    let edge: Color
    let checkboxEdge: Color
    // Shadows
    let raisedShadow, tileShadow, knobShadow, menuShadow, tooltipShadow: Shadow
    // Primary button (the one next step of a screen)
    let primaryFill, primaryInk, primaryEdge: Color
    let primaryShadow: Shadow
    // AppKit text views
    let nsText, nsTextSelection: NSColor

    static let gold = Color(rhemionHex: 0xE0A42E)
    static let danger = Color(nsColor: .systemRed)
    static let success = Color(rhemionHex: 0x2E9E5B)

    static let light = RhemionTheme(
        text: Color(rhemionHex: 0x1D1D1F), secondary: Color(rhemionHex: 0x5F5F66), tertiary: Color(rhemionHex: 0x9A9AA1),
        onAccent: .white,
        rail: Color(rhemionHex: 0xF5F5F7), content: Color(rhemionHex: 0xFFFFFF), win: Color(rhemionHex: 0xFFFFFF),
        line: Color(rhemionHex: 0xE5E5E9), hover: Color(rhemionHex: 0xEFEFF2), activeSurface: Color(rhemionHex: 0xFFFFFF),
        gold: gold, selected: Color(rhemionHex: 0xF6DD84), danger: danger, success: success,
        goldWash: gold.opacity(0.22), noticeWash: gold.opacity(0.12), searchHit: gold.opacity(0.35),
        rowHover: Color(rhemionHex: 0xE5E5E9).opacity(0.6), track: Color(rhemionHex: 0x9A9AA1).opacity(0.55),
        edge: Color.black.opacity(0.12), checkboxEdge: Color.black.opacity(0.42),
        raisedShadow: Shadow(color: .black.opacity(0.06), radius: 1.5, y: 1),
        tileShadow: Shadow(color: .black.opacity(0.14), radius: 2, y: 1),
        knobShadow: Shadow(color: .black.opacity(0.14), radius: 1.5, y: 1),
        menuShadow: Shadow(color: .black.opacity(0.22), radius: 17, y: 12),
        tooltipShadow: Shadow(color: .black.opacity(0.12), radius: 6, y: 2),
        primaryFill: Color(rhemionHex: 0xF6DD84), primaryInk: Color(rhemionHex: 0x5A4410), primaryEdge: gold.opacity(0.35),
        primaryShadow: Shadow(color: .black.opacity(0.05), radius: 1.5, y: 1),
        nsText: NSColor(rhemionHex: 0x1D1D1F), nsTextSelection: NSColor(rhemionHex: 0xF6DD84).withAlphaComponent(0.70))

    static let dark = RhemionTheme(
        text: Color(rhemionHex: 0xE8E8EC), secondary: Color(rhemionHex: 0xA8A8AE), tertiary: Color(rhemionHex: 0x909098),
        onAccent: .white,
        rail: Color(rhemionHex: 0x242426), content: Color(rhemionHex: 0x1E1E20), win: Color(rhemionHex: 0x232326),
        line: Color(rhemionHex: 0x37373B), hover: Color(rhemionHex: 0x2C2C30), activeSurface: Color(rhemionHex: 0x343438),
        gold: gold, selected: gold.opacity(0.20), danger: danger, success: success,
        goldWash: gold.opacity(0.22), noticeWash: gold.opacity(0.12), searchHit: gold.opacity(0.35),
        rowHover: Color(rhemionHex: 0x37373B).opacity(0.6), track: Color(rhemionHex: 0x909098).opacity(0.55),
        edge: Color.white.opacity(0.16), checkboxEdge: Color.white.opacity(0.42),
        raisedShadow: Shadow(color: .black.opacity(0.22), radius: 1.5, y: 1),
        tileShadow: Shadow(color: .black.opacity(0.28), radius: 2, y: 1),
        knobShadow: Shadow(color: .black.opacity(0.30), radius: 1.5, y: 1),
        menuShadow: Shadow(color: .black.opacity(0.44), radius: 17, y: 12),
        tooltipShadow: Shadow(color: .black.opacity(0.35), radius: 6, y: 2),
        primaryFill: gold.opacity(0.20), primaryInk: Color(rhemionHex: 0xE8D9A8), primaryEdge: gold.opacity(0.42),
        primaryShadow: Shadow(color: .black.opacity(0.20), radius: 1.5, y: 1),
        nsText: NSColor(rhemionHex: 0xE8E8EC), nsTextSelection: NSColor(rhemionHex: 0xF6DD84).withAlphaComponent(0.32))

    /// The theme for an appearance, from the chosen family (Settings › General › Theme).
    static func resolve(_ dark: Bool) -> RhemionTheme { ThemeStore.shared.family.theme(dark: dark) }
}

/// A theme as the user picks it: a name and its light and dark token sets. System / Light / Dark (the
/// appearance) chooses between the two; the family chooses the look.
struct ThemeFamily: Identifiable {
    let id: String
    let name: String
    let light: RhemionTheme
    let dark: RhemionTheme
    func theme(dark: Bool) -> RhemionTheme { dark ? self.dark : light }

    static let rhemion = ThemeFamily(id: "rhemion", name: "Rhemion", light: .light, dark: .dark)
    /// Every theme Settings offers, in its order. A new theme is one more entry here.
    static let all: [ThemeFamily] = [.rhemion]
    static func named(_ id: String) -> ThemeFamily { all.first { $0.id == id } ?? .rhemion }
}

/// The chosen theme family. Every window root observes it (`themedRoot()`) and redraws when it changes, so
/// a switch reaches every open window and panel at once.
final class ThemeStore: ObservableObject, @unchecked Sendable {
    static let shared = ThemeStore()
    private let lock = NSLock()
    private var current = ThemeFamily.rhemion
    var family: ThemeFamily {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set {
            guard newValue.id != family.id else { return }
            objectWillChange.send()
            lock.lock(); current = newValue; lock.unlock()
        }
    }
}

private struct RhemionThemeKey: EnvironmentKey {
    static let defaultValue = RhemionTheme.light
}

extension EnvironmentValues {
    /// The theme for this view's appearance, set at every window root by `themedRoot()`.
    var rhemionTheme: RhemionTheme {
        get { self[RhemionThemeKey.self] }
        set { self[RhemionThemeKey.self] = newValue }
    }
}

/// A window or panel root: follows the chosen theme family and the appearance, and hands the resolved theme
/// down the environment.
private struct ThemedRoot: ViewModifier {
    @ObservedObject private var store = ThemeStore.shared
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .environment(\.rhemionTheme, store.family.theme(dark: scheme == .dark))
            .id(store.family.id)   // a new family redraws the whole tree with its tokens
    }
}

extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }
}

extension View {
    func themeShadow(_ s: RhemionTheme.Shadow) -> some View { shadow(color: s.color, radius: s.radius, y: s.y) }
}

/// The tokens by appearance, as every view reads them today (`RhemionStyle.text(dark)`): a thin adapter over
/// `RhemionTheme`, so screens never hold a colour of their own.
enum RhemionStyle {
    static let gold = RhemionTheme.gold
    /// THE one danger red for every destructive action and warning (Delete, Uninstall, "can't be undone"):
    /// the system red, so it adapts to light/dark (#FF3B30 / #FF453A) and matches native destructive UI.
    static let danger = RhemionTheme.danger
    /// The one green: something is ready or granted (Welcome, Speech model, the Journal's export dot). Never decoration.
    static let success = RhemionTheme.success

    static func theme(_ dark: Bool) -> RhemionTheme { RhemionTheme.resolve(dark) }
    static func text(_ dark: Bool) -> Color { theme(dark).text }
    static func secondary(_ dark: Bool) -> Color { theme(dark).secondary }
    static func tertiary(_ dark: Bool) -> Color { theme(dark).tertiary }
    /// The rail / sidebar ground (recessed relative to content).
    static func rail(_ dark: Bool) -> Color { theme(dark).rail }
    /// The main content ground.
    static func content(_ dark: Bool) -> Color { theme(dark).content }
    /// A raised neutral surface — the "on/active" language (never an accent fill).
    static func win(_ dark: Bool) -> Color { theme(dark).win }
    static func line(_ dark: Bool) -> Color { theme(dark).line }
    static func hover(_ dark: Bool) -> Color { theme(dark).hover }
    /// The surface of an "on" control (segment, rail item, toolbar toggle), lifted above the track in dark.
    static func activeSurface(_ dark: Bool) -> Color { theme(dark).activeSurface }
    /// A selected destination in the rail (gold-tinted, matching the Journal list selection).
    static func selected(_ dark: Bool) -> Color { theme(dark).selected }
    /// An empty checkbox's edge: 3:1 against the page.
    static func checkboxEdge(_ dark: Bool) -> Color { theme(dark).checkboxEdge }
    // AppKit text views (the Journal transcript) take NSColor.
    static func nsText(_ dark: Bool) -> NSColor { theme(dark).nsText }
    static func nsTextSelection(_ dark: Bool) -> NSColor { theme(dark).nsTextSelection }

    /// The exact bundled Mulish face per weight (no SwiftUI weight synthesis, which renders heavier than
    /// the design). Falls back to the native system font if the face isn't registered.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .heavy, .black: face = "Mulish-ExtraBold"
        case .bold: face = "Mulish-Bold"
        case .semibold: face = "Mulish-SemiBold"
        case .medium: face = "Mulish-Medium"
        case .light, .ultraLight, .thin: face = "Mulish-Light"
        default: face = "Mulish-Regular"
        }
        return NSFont(name: face, size: size) == nil ? .system(size: size, weight: weight) : .custom(face, size: size)
    }
}

extension View {
    /// The app-wide "on" state of a control family — segmented pills, the hub rail, toolbar toggles: a raised
    /// neutral tile (never gold) with a hairline edge and a soft shadow, drawn BEHIND the content so the shadow
    /// falls on the tile, not on the glyph. One recipe: light #FFFFFF,
    /// edge black 12%, shadow 14% r2 y1; dark #343438, edge white 16%, shadow 28% r2 y1.
    func activeTile(_ on: Bool, dark: Bool, radius: CGFloat) -> some View {
        background {
            if on {
                RoundedRectangle(cornerRadius: radius)
                    .fill(RhemionStyle.activeSurface(dark))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(RhemionStyle.theme(dark).edge, lineWidth: 0.5)
                    }
                    .themeShadow(RhemionStyle.theme(dark).tileShadow)
            }
        }
    }
}

extension NSColor {
    convenience init(rhemionHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

extension Color {
    init(rhemionHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

/// THE text link — one style app-wide: gold text like "Restore defaults" (Mulish 12.5
/// regular), an optional SF icon, no background, border or underline; hover dims it (0.75); disabled
/// reads tertiary. `danger: true` swaps the ink to `RhemionStyle.danger` (Uninstall, Delete exported
/// transcripts…).
struct TextLink: View {
    let title: String
    var systemImage: String? = nil
    var danger = false
    /// 12.5 on its own; inside a caption it takes the caption's size (11), so it sits on the same line.
    var size: CGFloat = 12.5
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .regular)) }
                Text(title).font(RhemionStyle.font(size, .regular))
            }
            .foregroundStyle(!isEnabled ? RhemionStyle.tertiary(scheme == .dark) : danger ? RhemionStyle.danger : RhemionStyle.gold)
            .opacity(isEnabled && hover ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
    }
}

// MARK: - Quiet action

/// The one Quiet action rule (design: no surface in any state, state carried by ink). Rest `secondary` (or
/// `danger`), hover `text` (danger: 75 %), pressed 60 % at once; 0.12 s ease-out on hover, none under Reduce
/// Motion. Used by About › Copy, Journal › Delete and the table's Manage / Download.
struct QuietActionStyle: ButtonStyle {
    let dark: Bool
    var danger: Bool = false
    /// The status trigger ("✓ In use ⌄"): `success` ink at rest and under the pointer (75 %), pressed 60 %.
    var status: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        QuietActionBody(configuration: configuration, dark: dark, danger: danger, status: status)
    }
}

private struct QuietActionBody: View {
    let configuration: ButtonStyleConfiguration
    let dark: Bool
    let danger: Bool
    let status: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false
    private var ink: Color {
        if !isEnabled { return RhemionStyle.tertiary(dark) }
        if danger { return RhemionStyle.danger }
        if status { return RhemionStyle.success }
        return hover ? RhemionStyle.text(dark) : RhemionStyle.secondary(dark)
    }
    var body: some View {
        configuration.label
            .foregroundStyle(ink)
            .opacity(configuration.isPressed ? 0.6 : ((danger || status) && hover ? 0.75 : 1))
            .contentShape(Rectangle())
            .animation(reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.12), value: hover)
            .onHover { hover = $0 }
    }
}

/// Primary: the one recommended next step of a screen. Mulish 13 SemiBold, padding 18 × 9,
/// radius 9, the theme's primary fill, ink, edge and shadow. Hugs its label.
struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = RhemionStyle.theme(scheme == .dark)
        Button(action: action) {
            Text(title).font(RhemionStyle.font(13, .semibold))
                .foregroundStyle(theme.primaryInk)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(theme.primaryFill, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.primaryEdge, lineWidth: 1) }
                .themeShadow(theme.primaryShadow)
        }
        .buttonStyle(.plain)
    }
}

/// The search field, in two places with two jobs:
/// `.toolbar`: a window's toolbar (the Journal) on the `rail` ground: `content` fill, no edge, system type,
///   130–250 wide; the clear button follows the text.
/// `.card`: inside a card or popover (Models): `win` fill, a 1 pt `line` edge, 30 tall, Mulish 13, a quiet
///   clear button; it takes the focus when the card opens.
struct SearchField: View {
    enum Style { case toolbar, card }
    @Binding var text: String
    let placeholder: String
    let style: Style
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        let theme = RhemionStyle.theme(scheme == .dark)
        switch style {
        case .toolbar:
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondary)
                TextField(placeholder, text: $text).textFieldStyle(.plain)
                if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.help("Clear search") }
            }.padding(7).frame(minWidth: 130, maxWidth: 250).background(theme.content, in: RoundedRectangle(cornerRadius: 7))
        case .card:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(theme.secondary)
                TextField(placeholder, text: $text).textFieldStyle(.plain).font(RhemionStyle.font(13)).focused($focused)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.tertiary)
                    }
                    .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(theme.win, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line, lineWidth: 1) }
            .onAppear { focused = true }
        }
    }
}

extension View {
    /// A card's surface (popovers, the language list, the Models cards): `win`, radius 12, a 0.5 pt `line` edge.
    /// Menus add their 6 pt inset on top (`menuCard`); the operation pop-up has its own (`OperationPopupCard`).
    func cardSurface(dark: Bool) -> some View {
        background(RhemionStyle.win(dark), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(RhemionStyle.line(dark), lineWidth: 0.5) }
    }
}

// MARK: - Menus

/// A row of our dropdown menus (Settings pickers, the Journal grouping menu): a 20 pt checkmark column marks
/// the current value; the row under the pointer is solid gold with white text. `dark` is passed in because a
/// menu hosted in its own panel does not inherit the window's appearance.
struct MenuRow: View {
    let title: String
    let checked: Bool
    let dark: Bool
    /// A row that cannot be picked here (e.g. a dictation key another row already uses): `tertiary`, no hover,
    /// with `note` ("In use") on the right.
    var note: String? = nil
    var enabled: Bool = true
    /// A destructive item (Remove): `danger` ink; under the pointer it turns gold with white text like any row.
    var danger: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(checked ? 1 : 0).frame(width: 20)
                Text(title).font(RhemionStyle.font(13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                // Under the pointer the whole row turns white on gold, the note too (a grey note vanishes on gold).
                if let note {
                    Text(note).font(RhemionStyle.font(11))
                        .foregroundStyle(hover && enabled ? RhemionStyle.theme(dark).onAccent : RhemionStyle.tertiary(dark))
                }
            }
            .padding(.vertical, 5).padding(.trailing, 8).frame(minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(!enabled ? RhemionStyle.tertiary(dark) : hover ? RhemionStyle.theme(dark).onAccent : danger ? RhemionStyle.danger : RhemionStyle.text(dark))
        .background(hover && enabled ? RhemionStyle.gold : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
        .help(note.map { "\(title): \($0)" } ?? title)
    }
}

extension View {
    /// The menu card: opaque `win`, radius 12 around 6 pt of inset (so the row radius 6 nests), a 0.5 pt edge.
    /// `shadow`: false when the hosting panel draws the native window shadow, true when drawn inside a window.
    func menuCard(dark: Bool, shadow: Bool) -> some View {
        self.padding(6)
            .cardSurface(dark: dark)
            .themeShadow(shadow ? RhemionStyle.theme(dark).menuShadow : .init(color: .clear, radius: 17, y: 12))
    }
}

// MARK: - Window layout

/// THE layout standard of every two-column app window: taken from the
/// Uninstall (farewell) window and reused by Clear Data — a recessed side column (logo, title, subtitle,
/// optional figures, a quiet hint pinned to the bottom) and a main column with the same margins on every
/// screen. Welcome is the hero exception (bigger logo and title). Plain sheets (export deletion)
/// use the main-column margins only.
enum WindowLayout {
    /// Side column width.
    static let sideWidth: CGFloat = 236
    /// Side column padding: top / sides / bottom.
    static let sidePadding = EdgeInsets(top: 26, leading: 22, bottom: 22, trailing: 22)
    /// The logo's size, and its optical shift left (its outer ring is soft, so it reads aligned with the title).
    static let logoSize: CGFloat = 104
    static let logoInset: CGFloat = -4
    /// The side column's vertical rhythm: logo → title → subtitle → figures.
    static let sideSpacing: CGFloat = 12
    /// The minimum room between the side column's content and its bottom hint.
    static let sideHintGap: CGFloat = 12
    static var titleFont: Font { RhemionStyle.font(20, .heavy) }
    static var subtitleFont: Font { RhemionStyle.font(13) }
    static let subtitleLineSpacing: CGFloat = 3
    static var hintFont: Font { RhemionStyle.font(11) }
    /// Main column padding: top / sides / bottom (the bottom is the button row's bottom margin, the
    /// trailing side its right margin).
    static let mainPadding = EdgeInsets(top: 26, leading: 26, bottom: 22, trailing: 26)
    /// Between the blocks of a choosing screen (options → notes → button row).
    static let blockGap: CGFloat = 18
    /// Between the pieces of a step / result screen (title → text → list → button row).
    static let stepGap: CGFloat = 12
    /// Title of a step / result screen in the main column.
    static var stepTitleFont: Font { RhemionStyle.font(15, .semibold) }
    /// Between the buttons of a button row (right-aligned; raised buttons are 30 pt tall).
    static let buttonSpacing: CGFloat = 8
    /// The window is never shorter than this — the side column always has room for its content.
    static let minHeight: CGFloat = 330

    // The operation pop-up: a compact borderless panel over its window.
    /// Pop-up width; its height is its content.
    static let popupWidth: CGFloat = 400
    /// Pop-up padding: top / sides / bottom (the button row's bottom and right margins).
    static let popupPadding = EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24)
    /// Between the pop-up's pieces (title → rows → notes → button row).
    static let popupGap: CGFloat = 14
    /// The pop-up card's corner radius.
    static let popupRadius: CGFloat = 12
}

/// The two columns of a standard window: the side column sized to `WindowLayout.sideWidth`, the main column
/// filling the rest with the standard padding, both as tall as the taller of them (never below
/// `minHeight`). The window's height is exactly that — no empty field, and the side column can never be cut.
struct StandardWindow<Side: View, Main: View>: View {
    let width: CGFloat
    var minHeight: CGFloat = WindowLayout.minHeight
    @ViewBuilder let side: () -> Side
    @ViewBuilder let main: () -> Main
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        StandardWindowLayout(sideWidth: WindowLayout.sideWidth, minHeight: minHeight) {
            side()
            main()
                .padding(WindowLayout.mainPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width)
        .background(RhemionStyle.content(dark))
        .foregroundStyle(RhemionStyle.text(dark))
    }
}

/// Measures both columns at their widths with no height limit, takes the taller (or `minHeight`), and
/// places both at that height.
private struct StandardWindowLayout: Layout {
    let sideWidth: CGFloat
    let minHeight: CGFloat

    private func height(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        guard subviews.count == 2 else { return minHeight }
        let side = subviews[0].sizeThatFits(ProposedViewSize(width: sideWidth, height: nil)).height
        let main = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, width - sideWidth), height: nil)).height
        return max(minHeight, side, main).rounded(.up)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (sideWidth + 500)
        return CGSize(width: width, height: height(width, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: sideWidth, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + sideWidth, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width - sideWidth, height: bounds.height))
    }
}

/// The standard side column: the logo, the title, an optional subtitle, optional figures (`extra`), and a
/// quiet hint pinned to the bottom — on the `rail` ground with a hairline edge.
struct WindowSideColumn<Extra: View>: View {
    @ObservedObject var clock: WelcomeLogoClock
    var farewell = false
    let title: String
    var subtitle: String? = nil
    var hint: String? = nil
    /// The longest subtitle this window can show: its height is kept, so a changing subtitle never resizes the window.
    var subtitleReserve: String? = nil
    @ViewBuilder var extra: () -> Extra
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: WindowLayout.sideSpacing) {
            WelcomeLogo(clock: clock, size: WindowLayout.logoSize, farewell: farewell)
                .padding(.leading, WindowLayout.logoInset)
            Text(title).font(WindowLayout.titleFont)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                ZStack(alignment: .topLeading) {
                    if let subtitleReserve { Text(subtitleReserve).hidden().accessibilityHidden(true) }
                    Text(subtitle)
                }
                .font(WindowLayout.subtitleFont).lineSpacing(WindowLayout.subtitleLineSpacing)
                .foregroundStyle(RhemionStyle.secondary(dark))
                .fixedSize(horizontal: false, vertical: true)
            }
            extra()
            Spacer(minLength: WindowLayout.sideHintGap)
            if let hint {
                Text(hint)
                    .font(WindowLayout.hintFont).foregroundStyle(RhemionStyle.tertiary(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(WindowLayout.sidePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RhemionStyle.rail(dark))
        .overlay(alignment: .trailing) { Rectangle().fill(RhemionStyle.line(dark)).frame(width: 1) }
    }
}

extension WindowSideColumn where Extra == EmptyView {
    init(clock: WelcomeLogoClock, farewell: Bool = false, title: String, subtitle: String? = nil, hint: String? = nil) {
        self.init(clock: clock, farewell: farewell, title: title, subtitle: subtitle, hint: hint) { EmptyView() }
    }
}

/// A right-aligned button row with the standard spacing; `leading` holds notes on the left (optional).
struct WindowButtonRow<Leading: View, Buttons: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var buttons: () -> Buttons
    var body: some View {
        HStack(spacing: WindowLayout.buttonSpacing) {
            leading()
            Spacer(minLength: 8)
            buttons()
        }
    }
}

extension WindowButtonRow where Leading == EmptyView {
    init(@ViewBuilder buttons: @escaping () -> Buttons) {
        self.init(leading: { EmptyView() }, buttons: buttons)
    }
}

/// Every window opens in the true middle of the screen under the pointer, after its SwiftUI content has
/// settled the size (NSWindow.center() sits deliberately above the middle). `fitContent: false` for a resizable
/// window that keeps its own size (the hub): it is only placed.
@MainActor
func centerOnPointerScreen(_ window: NSWindow, fitContent: Bool = true) {
    if fitContent, let view = window.contentViewController?.view {
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        if fit.width > 0, fit.height > 0 { window.setContentSize(fit) }
    }
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
        window.center(); return
    }
    let area = screen.visibleFrame, size = window.frame.size
    window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                  y: (area.midY - size.height / 2).rounded()))
}
