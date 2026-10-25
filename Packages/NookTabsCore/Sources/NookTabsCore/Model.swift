// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// A space: one login context (its own website data store), one favorites grid, one pinned
/// section and one tabs section. There is no separate profile record.
public struct SpaceRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var icon: String
    public var accentHex: String
    public var order: OrderKey
    public var modifiedAt: Date
    public var deletedAt: Date?
    /// Shown in place of the space's dot in the switcher; nil keeps the dot. Not `icon`, which
    /// carries the Agent space's marker. Files from before it existed decode with none; a build
    /// from before it drops it on its next save.
    public var mark: SpaceMark?

    public init(id: UUID = UUID(), name: String, icon: String, accentHex: String, order: OrderKey, modifiedAt: Date = Date(),
                deletedAt: Date? = nil, mark: SpaceMark? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accentHex = accentHex
        self.order = order
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
        self.mark = mark
    }
}

/// A space's mark: an emoji, or a small picture made from an SVG the person chose. The SVG is
/// drawn once, when chosen, into a `picturePixels`-wide PNG; only the PNG is kept and shown, so
/// a costly SVG can never slow every redraw (measured: a 141-byte SVG took 1 GB per draw).
public enum SpaceMark: Codable, Hashable, Sendable {
    case emoji(String)
    case picture(Data)

    /// Larger SVGs are refused before they are drawn.
    public static let svgLimit = 64 * 1024
    /// The width and height of a picture mark, in pixels (2x the switcher's icon).
    public static let picturePixels = 64

    /// The first character of `text` when it is an emoji, else nil.
    public static func emoji(from text: String) -> SpaceMark? {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let scalars = first.unicodeScalars
        // Digits, # and * carry the emoji property for keycaps, so a scalar counts when it shows
        // as emoji by default, sits past the plain-text symbols, or is asked for in emoji style
        // (U+FE0F) or as a keycap (U+20E3): ©️ ⌨️ 1️⃣.
        let styled = scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
        let isEmoji = scalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && ($0.value > 0x238C || styled)) }
        return isEmoji ? .emoji(String(first)) : nil
    }

    /// Whether `data` is an SVG worth drawing: at most `svgLimit` bytes, and none of the features
    /// that let a small file take seconds or gigabytes to draw or reach outside itself (measured
    /// 2026-10-24: nested <use> 6.7 s and 1.8 GB; a blur filter never finished).
    public static func acceptsSVG(_ data: Data) -> Bool {
        guard data.count <= svgLimit else { return false }
        let text = String(decoding: data, as: UTF8.self).lowercased()
        guard text.contains("<svg") else { return false }
        return !["<use", "<filter", "<image", "<foreignobject", "<!entity", "<!doctype"].contains { text.contains($0) }
    }
}

extension SpaceRecord {
    /// A mark kind from a newer build reads as none: failing here would fail the whole tab file,
    /// and the person would be left with a read-only session.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        accentHex = try c.decode(String.self, forKey: .accentHex)
        order = try c.decode(OrderKey.self, forKey: .order)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        mark = (try? c.decodeIfPresent(SpaceMark.self, forKey: .mark)) ?? nil
    }
}

/// Where an item sits. Sections (favorites, pinned, tabs) are parent values with no record.
public enum Parent: Codable, Hashable, Sendable {
    case favorites(spaceID: UUID)
    case pinned(spaceID: UUID)
    case tabs(spaceID: UUID)
    case folder(itemID: UUID)

    public var isSection: Bool {
        if case .folder = self { return false }
        return true
    }

    /// The space a section belongs to; nil for a folder.
    public var spaceID: UUID? {
        switch self {
        case .favorites(let id), .pinned(let id), .tabs(let id): return id
        case .folder: return nil
        }
    }
}

public enum ItemKind: Codable, Hashable, Sendable {
    /// `url` is the home URL in the synced scope and the last committed URL in the device scope.
    case tab(url: URL, pageTitle: String)
    case folder
}

/// What fills a live folder. A struct, so a source a newer build adds still decodes here.
public struct LiveSource: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The person's open pull requests on github.com.
    public static let githubPulls = LiveSource(rawValue: "githubPulls")
    /// Open issues assigned to the person on github.com.
    public static let githubIssues = LiveSource(rawValue: "githubIssues")
    /// Unread github.com notification threads.
    public static let githubNotifications = LiveSource(rawValue: "githubNotifications")
    /// The person's incomplete Asana tasks.
    public static let asanaTasks = LiveSource(rawValue: "asanaTasks")

    /// An RSS or Atom feed, stored as "feed:<absolute url>".
    public static func feed(_ url: URL) -> LiveSource { LiveSource(rawValue: "feed:" + url.absoluteString) }

    public var feedURL: URL? {
        guard rawValue.hasPrefix("feed:"), let url = URL(string: String(rawValue.dropFirst(5))),
              url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// Marks a folder as a saved split: two tabs shown side by side (`TabTree+Splits.swift`).
/// An optional field, so a build without splits reads the split as a plain folder.
public struct SplitInfo: Codable, Hashable, Sendable {
    /// The left pane's share of the width.
    public var fraction: Double
    /// Whether the right pane was the one in use.
    public var focusRight: Bool

    public static let minFraction = 0.25

    public init(fraction: Double = 0.5, focusRight: Bool = false) {
        self.fraction = fraction
        self.focusRight = focusRight
    }

    /// Keeps each pane at least `minFraction` of the width.
    public func clamped() -> SplitInfo {
        SplitInfo(fraction: min(max(fraction, Self.minFraction), 1 - Self.minFraction), focusRight: focusRight)
    }
}

public struct Item: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var parent: Parent
    public var order: OrderKey
    public var kind: ItemKind
    public var customTitle: String?
    public var modifiedAt: Date
    public var deletedAt: Date?
    /// Set on a folder whose tabs follow a source (`reconcileLive`).
    public var live: LiveSource?
    /// Set on a folder that is a saved split of its two tabs.
    public var split: SplitInfo?

    public init(id: UUID = UUID(), parent: Parent, order: OrderKey, kind: ItemKind, customTitle: String? = nil, modifiedAt: Date = Date(), deletedAt: Date? = nil, live: LiveSource? = nil, split: SplitInfo? = nil) {
        self.id = id
        self.parent = parent
        self.order = order
        self.kind = kind
        self.customTitle = customTitle
        self.live = live
        self.split = split
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }

    public var isSplit: Bool { isFolder && split != nil }

    public var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    public var url: URL? {
        if case .tab(let url, _) = kind { return url }
        return nil
    }

    public var pageTitle: String? {
        if case .tab(_, let title) = kind { return title }
        return nil
    }

    /// Custom title when set, else the page title (tabs) or empty (folders).
    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return pageTitle ?? ""
    }
}

/// Synced items travel with the space's data; device items stay on this Mac.
public enum Scope: Hashable, Sendable {
    case synced
    case device
}

/// The two sidebar sections of a space.
public enum SidebarSection: String, Codable, Hashable, Sendable {
    case pinned
    case tabs

    public func parent(in spaceID: UUID) -> Parent {
        switch self {
        case .pinned: return .pinned(spaceID: spaceID)
        case .tabs: return .tabs(spaceID: spaceID)
        }
    }
}

public struct Row: Hashable, Sendable, Identifiable {
    public let item: Item
    /// Number of folders and parent tabs the item sits inside.
    public let depth: Int
    public let section: SidebarSection
    /// A tab with children, which the sidebar draws with a disclosure chevron.
    public let hasChildren: Bool
    public var id: UUID { item.id }
}

public enum TreeError: Error, Equatable, Sendable {
    case missingItem
    case missingParent
    case missingSpace
    case cycle
    case tooDeep
    case folderInFavorites
    /// A tab's children are tabs.
    case folderInTab
    /// Only a tab in the Tabs section holds children.
    case childOutsideTabs
    case notATab
    case lastSpace
    /// A split holds two tabs and nothing else.
    case splitHoldsTabsOnly
    case splitFull
    /// A tab in a split holds no children.
    case childInSplit
}
