// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceMarkPicker.swift
//  Nook
//
//  Sets a space's mark from Settings > Spaces: an emoji typed or pasted (the character viewer
//  works too), or an SVG file. Choosing the file is the Settings page's job (`onChooseSVG`): a
//  file panel opened from inside this popover could close the popover before the file came back.
//

import NookDesign
import NookTabsCore
import NookWeb
import SwiftUI

struct SpaceMarkPicker: View {
    @Environment(TabsController.self) private var tabs
    let space: SpaceRecord
    let onChooseSVG: () -> Void
    @State private var emojiText = ""
    @State private var problem: String?
    private let width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.md) {
            TextField("Emoji", text: $emojiText)
                .onChange(of: emojiText) { _, text in
                    guard !text.isEmpty else { problem = nil; return }
                    // Cleared only once taken, so text an input method is still composing stays.
                    if let mark = SpaceMark.emoji(from: text) {
                        tabs.setSpaceMark(space.id, mark: mark)
                        problem = nil
                        emojiText = ""
                    } else {
                        problem = "Type or paste one emoji."
                    }
                }
            Button("Choose SVG…", systemImage: "square.and.arrow.down", action: onChooseSVG)
            if tabs.space(space.id)?.mark != nil {
                Button("Remove Mark", systemImage: "xmark.circle", role: .destructive) {
                    tabs.setSpaceMark(space.id, mark: nil)
                }
            }
            if let problem {
                Text(problem)
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}
