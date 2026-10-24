// Licensed under GPL-3.0. See LICENSE.
//
// Runs Nook's real Arc parser against this Mac's Arc sidebar and prints what it found.
// swiftc Nook/Managers/ImportManager/Arc.swift Fork/checks/ArcParseCheck.swift -o /tmp/arccheck && /tmp/arccheck
//
import Foundation

@main
struct ArcParseCheck {
    static func main() throws {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
        let result = try parseArcSidebarData(from: file)
        precondition(!result.spaces.isEmpty, "no spaces parsed")
        var splits = 0
        func walk(_ nodes: [ArcNode], _ space: String) -> Int {
            var tabs = 0
            for node in nodes {
                switch node {
                case .tab: tabs += 1
                case .folder(_, let children): tabs += walk(children, space)
                case .split(let halves, let fraction, let focusRight, let vertical):
                    splits += 1
                    let titles = halves.compactMap { if case .tab(_, let page, let custom) = $0 { custom ?? page } else { nil } }
                    print("  split in \(space): \(titles.joined(separator: " | "))  fraction=\(fraction.map { String(format: "%.2f", $0) } ?? "nil") focusRight=\(focusRight) vertical=\(vertical)")
                    precondition(halves.count == 2, "split with \(halves.count) tabs")
                    precondition(fraction.map { $0 > 0 && $0 < 1 } ?? false, "split without a width")
                    tabs += walk(halves, space)
                }
            }
            return tabs
        }
        for space in result.spaces {
            let counts = (walk(space.favorites, space.title), walk(space.pinned, space.title), walk(space.unpinned, space.title))
            print("\(space.title): favorites \(counts.0), pinned \(counts.1), today \(counts.2), accent \(space.accentHex ?? "none")")
        }
        print("splits: \(splits)")
        print("ArcParseCheck passed")
    }
}
