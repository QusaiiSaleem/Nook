// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceMarkPicker.swift
//  Nook
//
//  Sets a space's mark from Settings > Spaces: an emoji typed or pasted (the character viewer
//  works too), or an SVG file of at most 64 KB. The mark replaces the space's dot in the switcher.
//

import NookDesign
import NookTabsCore
import NookWeb
import SwiftUI
import UniformTypeIdentifiers

struct SpaceMarkPicker: View {
    @Environment(TabsController.self) private var tabs
    let space: SpaceRecord
    @State private var emojiText = ""
    @State private var importing = false
    @State private var problem: String?
    private let width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.md) {
            TextField("Emoji", text: $emojiText)
                .onChange(of: emojiText) { _, text in
                    guard !text.isEmpty else { return }
                    if let mark = SpaceMark.emoji(from: text) {
                        tabs.setSpaceMark(space.id, mark: mark)
                        problem = nil
                    } else {
                        problem = "Type or paste one emoji."
                    }
                    emojiText = ""
                }
            Button("Choose SVG…", systemImage: "square.and.arrow.down") { importing = true }
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.svg]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let mark = SpaceMark.svg(from: data) else {
                problem = "Choose an SVG of at most 64 KB."
                return
            }
            tabs.setSpaceMark(space.id, mark: mark)
            problem = nil
        }
    }
}
