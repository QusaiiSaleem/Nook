// Licensed under GPL-3.0. See LICENSE.
//
//  Spaces.swift
//  Nook
//
//  Spaces settings. A space is a login context: it owns its cookies and site data, so this is
//  also where that data is inspected and cleared.
//

import NookTabsCore
import SwiftUI
import UniformTypeIdentifiers
import NookDesign
import NookWeb

public struct SpacesSettingsView: View {
    @Environment(TabsController.self) private var tabs
    @Environment(\.tabActions) private var actions

    /// Cookie and record counts per space, filled in as each store answers.
    @State private var stats: [UUID: String] = [:]
    @State private var showAccentPickerFor: UUID?
    @State private var showMarkPickerFor: UUID?
    /// The space whose mark is being chosen from an SVG file.
    @State private var importingMarkFor: UUID?
    @State private var markProblem = false

    public init() {}

    private var spaces: [SpaceRecord] { tabs.orderedSpaces.filter { !$0.isAgent } }

    public var body: some View {
        Form {
            Section {
                // The Agent space keeps its look and borrows another space's data, so it has no row.
                ForEach(spaces) { space in
                    row(space)
                }
            } header: {
                Text("Spaces")
            } footer: {
                Text("Each space keeps its own cookies and logins. Sites you sign into in one space stay signed out in the others.")
            }

            Section {
                Button("New Space…", systemImage: "plus", action: showCreateDialog)
            }
        }
        .formStyle(.grouped)
        .task(id: tabs.orderedSpaces.count) { await refreshStats() }
        .fileImporter(isPresented: Binding(
            get: { importingMarkFor != nil },
            set: { if !$0 { importingMarkFor = nil } }
        ), allowedContentTypes: [.svg]) { result in
            guard let spaceID = importingMarkFor else { return }
            importingMarkFor = nil
            guard case .success(let url) = result else { return }
            Task { await setMark(fromSVG: url, for: spaceID) }
        }
        .alert("That SVG can't be used", isPresented: $markProblem) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose an SVG of at most 64 KB without filters, linked images or reused shapes.")
        }
    }

    @ViewBuilder
    private func row(_ space: SpaceRecord) -> some View {
        HStack(spacing: NookDesign.Spacing.md) {
            Button {
                showAccentPickerFor = space.id
            } label: {
                Circle()
                    .fill(space.accentColor)
                    .frame(width: NookDesign.Size.iconButton, height: NookDesign.Size.iconButton)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { showAccentPickerFor == space.id },
                set: { if !$0 { showAccentPickerFor = nil } }
            )) {
                SpaceAccentPicker(selectedHex: Binding(
                    get: { space.accentHex },
                    set: { tabs.updateSpace(space.id, name: nil, icon: nil, accentHex: $0) }
                ))
                .padding(NookDesign.Spacing.lg)
            }

            // The mark that replaces this space's dot in the switcher (SpaceMarkPicker).
            Button {
                showMarkPickerFor = space.id
            } label: {
                Group {
                    if let mark = space.mark {
                        SpaceMarkView(mark: mark, size: NookDesign.Size.spaceIcon)
                    } else {
                        Image(systemName: "face.smiling")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: NookDesign.Size.iconButton, height: NookDesign.Size.iconButton)
            }
            .buttonStyle(.plain)
            .help("Mark")
            .popover(isPresented: Binding(
                get: { showMarkPickerFor == space.id },
                set: { if !$0 { showMarkPickerFor = nil } }
            )) {
                SpaceMarkPicker(space: space) {
                    showMarkPickerFor = nil
                    importingMarkFor = space.id
                }
                .padding(NookDesign.Spacing.lg)
            }

            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                TextField("Space name", text: Binding(
                    get: { space.name },
                    set: { tabs.updateSpace(space.id, name: $0, icon: nil, accentHex: nil) }
                ))
                .textFieldStyle(.plain)
                Text(stats[space.id] ?? "Checking…")
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Clear Website Data", systemImage: "trash") {
                    Task { await clearData(space) }
                }
                if spaces.count > 1 {
                    Divider()
                    Button("Delete Space…", systemImage: "trash", role: .destructive) {
                        showDeleteDialog(space)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Mark

    /// Checks the SVG, draws it once into the small PNG the mark keeps, and sets it.
    private func setMark(fromSVG url: URL, for spaceID: UUID) async {
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        #if canImport(AppKit)
        if let data, SpaceMark.acceptsSVG(data),
           let png = await SpaceMarkRenderer.png(fromSVG: data, pixels: SpaceMark.picturePixels) {
            tabs.setSpaceMark(spaceID, mark: .picture(png))
            return
        }
        #endif
        markProblem = true
    }

    // MARK: - Data

    private func refreshStats() async {
        for space in spaces {
            guard let profile = tabs.profile(forSpace: space.id) else { continue }
            await profile.refreshDataStoreStats()
            stats[space.id] = profile.estimatedDataSize
        }
    }

    private func clearData(_ space: SpaceRecord) async {
        guard let profile = tabs.profile(forSpace: space.id) else { return }
        await profile.clearAllData()
        stats[space.id] = profile.estimatedDataSize
    }

    // MARK: - Dialogs

    private func showCreateDialog() {
        actions?.presentSpaceCreation { name, accentHex in
            tabs.createSpace(
                name: name.isEmpty ? "New Space" : name,
                icon: "square.grid.2x2",
                accentHex: accentHex,
                after: tabs.orderedSpaces.last?.id
            )
        }
    }

    private func showDeleteDialog(_ space: SpaceRecord) {
        actions?.confirmSpaceDeletion(
            spaceName: space.name,
            tabCount: tabs.tabCount(inSpace: space.id),
            isLastSpace: spaces.count <= 1,
            onDelete: { tabs.deleteSpace(space.id) }
        )
    }
}
