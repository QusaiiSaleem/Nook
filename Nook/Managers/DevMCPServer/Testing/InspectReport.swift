// Licensed under GPL-3.0. See LICENSE.
//
//  InspectReport.swift
//  Nook
//
//  What the MCP `inspect` tool answers: page facts, speed, errors, findings with fixes, and the
//  checks that could not answer honestly. A check that cannot tell is listed, never counted as a
//  pass (scitter's standards axis rule).
//

import Foundation

struct InspectFinding: Codable, Equatable {
    var severity: String
    var rule: String
    var message: String
    var width: Int?
    var selector: String?
    var fix: String?
}

struct InspectReport: Codable {
    var url: String
    var finalURL: String
    var status: Int?
    var partial: Bool
    var network: String?
    var facts: [String: String]
    var speed: [String: String]
    var errors: [String]
    var failedLoads: [String]
    var findings: [InspectFinding]
    var unassessable: [String]
    var files: [String]

    static let severities = ["error", "warning", "advice"]
    private static let listLimit = 20

    /// One finding per problem: the same rule, selector and message at several widths become one
    /// finding naming the widths.
    static func merge(_ findings: [InspectFinding]) -> [InspectFinding] {
        var order: [String] = []
        var groups: [String: [InspectFinding]] = [:]
        for finding in findings {
            let key = "\(finding.rule)|\(finding.selector ?? "")|\(finding.message)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(finding)
        }
        return order.compactMap { key in
            guard var first = groups[key]?.first, let group = groups[key] else { return nil }
            // Two elements that share a description can report the same width.
            let widths = Set(group.compactMap(\.width)).sorted()
            if widths.count > 1 {
                first.width = nil
                first.message += " (at \(widths.map(String.init).joined(separator: ", ")))"
            }
            return first
        }
    }

    /// Saves the report as JSON (report.json beside its pictures).
    func write(to file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: file) }
    }

    func markdown() -> String {
        var out: [String] = []
        var title = "# \(finalURL)"
        if let status { title += " — \(status)" }
        if partial { title += " — partial (the page did not finish loading)" }
        if let network { title += " — network: \(network)" }
        out.append(title)

        func section(_ name: String, _ values: [String: String]) {
            guard !values.isEmpty else { return }
            out.append("\n## \(name)")
            values.keys.sorted().forEach { out.append("- \($0): \(values[$0] ?? "")") }
        }
        func list(_ name: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            out.append("\n## \(name)")
            items.prefix(Self.listLimit).forEach { out.append("- \($0)") }
            if items.count > Self.listLimit { out.append("- +\(items.count - Self.listLimit) more") }
        }

        section("Facts", facts)
        section("Speed", speed)
        list("Errors", errors)
        list("Failed loads", failedLoads)

        out.append("\n## Findings")
        let counts = Self.severities.map { severity in
            let n = findings.filter { $0.severity == severity }.count
            return "\(n) \(severity)\(n == 1 || severity == "advice" ? "" : "s")"
        }
        out.append(counts.joined(separator: " · "))
        for severity in Self.severities {
            for finding in findings where finding.severity == severity {
                var line = "- [\(finding.rule)] \(finding.message)"
                let place = [finding.width.map { "\($0) px" }, finding.selector].compactMap { $0 }
                if !place.isEmpty { line += " (\(place.joined(separator: ", ")))" }
                if let fix = finding.fix { line += " → \(fix)" }
                out.append(line)
            }
        }
        list("Could not check", unassessable)
        list("Files", files)
        return out.joined(separator: "\n")
    }
}
