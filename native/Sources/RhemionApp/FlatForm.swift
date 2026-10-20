// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Flat Settings: the body is the window colour with no cards. A group is its
// 13 Bold header, its rows and an optional footer; a hairline separates adjacent rows of a group and never
// closes it (none above the first row, none under the last, none in a one-row group). Groups stack 30 apart
// (FlatForm's spacing); a footer sits 8 under the last row; the scrolling body ends 40 below the last block.

import SwiftUI

/// The scrolling page that holds FlatSections.
struct FlatForm<Content: View>: View {
    let dark: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 36 at the sides keeps the row text where the grouped form had it (26 + the card's 10).
                .padding(.horizontal, 36).padding(.top, 20).padding(.bottom, 40)
        }
        .scrollContentBackground(.hidden)
        .background(RhemionStyle.content(dark))
        // Outside a Form a Toggle draws a checkbox; Settings switches stay switches.
        .toggleStyle(.switch)
    }
}

/// One group: header, rows separated by hairlines, optional footer.
struct FlatSection<Content: View, Header: View, Footer: View>: View {
    let content: Content
    let header: Header
    let footer: Footer
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 6)
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { Rectangle().fill(RhemionStyle.line(dark)).frame(height: 1) }
                    rows[index].padding(.vertical, 10)
                }
            }
            footer.padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension FlatSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension FlatSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}
