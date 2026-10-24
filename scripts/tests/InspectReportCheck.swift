// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc Nook/Managers/DevMCPServer/Testing/InspectReport.swift scripts/tests/InspectReportCheck.swift \
//         -o /tmp/ir && /tmp/ir
//
//  What `inspect` answers: findings grouped by severity with their fixes, honest "could not
//  check" items, long lists cut short, and one finding per problem however many widths show it.

import Foundation

@main
struct InspectReportCheck {
    static func report() -> InspectReport {
        InspectReport(
            url: "https://example.com", finalURL: "https://example.com/", status: 200, partial: false, network: nil,
            facts: ["title": "Example"], speed: ["lcp": "1200 ms"], errors: [], failedLoads: [],
            findings: [
                InspectFinding(severity: "error", rule: "contrast", message: "Text contrast 2.8:1, needs 4.5:1",
                               width: nil, selector: "p.note", fix: "use #595959"),
                InspectFinding(severity: "advice", rule: "latin-leak", message: "Latin run in RTL text", width: nil,
                               selector: "h1", fix: nil)
            ],
            unassessable: ["text over an image or gradient: .hero h2"], files: ["/tmp/report.json"])
    }

    static func main() {
        let markdown = report().markdown()
        for part in ["## Findings", "1 error", "[contrast]", "→ use #595959", "## Could not check", "text over an image"] {
            precondition(markdown.contains(part), "markdown lacks \(part):\n\(markdown)")
        }

        let merged = InspectReport.merge([
            InspectFinding(severity: "error", rule: "overflow", message: "Wider than the screen", width: 390, selector: ".hero", fix: nil),
            InspectFinding(severity: "error", rule: "overflow", message: "Wider than the screen", width: 820, selector: ".hero", fix: nil)
        ])
        precondition(merged.count == 1, "merged into \(merged.count)")
        precondition(merged[0].message.contains("390, 820"), "widths missing: \(merged[0].message)")

        // Two links that share a description, both at 390: one width, not "at 390, 390".
        let twins = InspectReport.merge([
            InspectFinding(severity: "warning", rule: "tap-target", message: "Tap target 28 × 19 px", width: 390, selector: "td > a", fix: nil),
            InspectFinding(severity: "warning", rule: "tap-target", message: "Tap target 28 × 19 px", width: 390, selector: "td > a", fix: nil)
        ])
        precondition(twins.count == 1 && twins[0].width == 390 && !twins[0].message.contains("390, 390"), "twins: \(twins)")

        var noisy = report()
        noisy.errors = (1...25).map { "error \($0)" }
        let lines = noisy.markdown().components(separatedBy: "\n").filter { $0.hasPrefix("- error ") }
        precondition(lines.count == 20, "showed \(lines.count) errors")
        precondition(noisy.markdown().contains("+5 more"))
        print("InspectReportCheck passed")
    }
}
