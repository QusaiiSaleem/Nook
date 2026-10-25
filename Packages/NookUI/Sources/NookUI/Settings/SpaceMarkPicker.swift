// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceMarkPicker.swift
//  Nook
//
//  Sets a space's mark from Settings > Spaces: an emoji clicked in the grid (`EmojiCatalog`,
//  searchable by name), typed or pasted (the character viewer works too), or an SVG file.
//  Choosing the file is the Settings page's job (`onChooseSVG`): a file panel opened from inside
//  this popover could close the popover before the file came back.
//

import NookDesign
import NookTabsCore
import NookWeb
import SwiftUI

struct SpaceMarkPicker: View {
    @Environment(TabsController.self) private var tabs
    let space: SpaceRecord
    let onChooseSVG: () -> Void
    @State private var query = ""
    private let width: CGFloat = 280
    private let gridHeight: CGFloat = 220
    private let columns = [GridItem(.adaptive(minimum: NookDesign.Size.iconButton, maximum: NookDesign.Size.iconButton),
                                    spacing: NookDesign.Spacing.xxs)]

    var body: some View {
        let current = tabs.space(space.id)?.mark
        let results = EmojiCatalog.matching(query)
        VStack(alignment: .leading, spacing: NookDesign.Spacing.md) {
            TextField("Search Emoji", text: $query)
                .onChange(of: query) { _, text in
                    // A typed or pasted emoji is taken as it is; anything else searches. Cleared
                    // only once taken, so text an input method is still composing stays.
                    if let mark = SpaceMark.emoji(from: text) {
                        tabs.setSpaceMark(space.id, mark: mark)
                        query = ""
                    }
                }
            ScrollView {
                LazyVGrid(columns: columns, spacing: NookDesign.Spacing.xxs) {
                    ForEach(results) { entry in
                        Button {
                            tabs.setSpaceMark(space.id, mark: .emoji(entry.emoji))
                        } label: {
                            Text(entry.emoji)
                                .font(NookDesign.Font.titleLarge)
                        }
                        .nookRowSelection(current == .emoji(entry.emoji))
                        .help(entry.name.capitalized)
                    }
                }
                .nookIconButtons()
            }
            .frame(height: gridHeight)
            .overlay {
                if results.isEmpty {
                    Text("No Emoji Found")
                        .font(NookDesign.Font.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Choose SVG…", systemImage: "square.and.arrow.down", action: onChooseSVG)
            if current != nil {
                Button("Remove Mark", systemImage: "xmark.circle", role: .destructive) {
                    tabs.setSpaceMark(space.id, mark: nil)
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }
}
