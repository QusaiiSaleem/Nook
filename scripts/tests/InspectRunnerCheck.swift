// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc -parse-as-library Nook/Managers/DevMCPServer/Testing/InspectReport.swift \
//         Nook/Managers/DevMCPServer/Testing/InspectScripts.swift Nook/Managers/DevMCPServer/Testing/InspectRunner.swift \
//         scripts/tests/InspectRunnerCheck.swift -o /tmp/irun && /tmp/irun
//
//  One `inspect` run against a local page, drawn as a visible page: facts, errors, findings at the right widths, focus
//  checked with the real Tab key, five screenshots, files on disk; and a page that never finishes
//  loading is reported as partial instead of hanging the call.

import AppKit
import Network
import WebKit

@main
struct InspectRunnerCheck {
    static let page = """
        <html lang="en"><head><style>
        body { margin: 0; font-family: -apple-system, sans-serif; }
        .wide { width: 600px; height: 20px; background: #eee; }
        a.quiet:focus, a.quiet:focus-visible { outline: none; box-shadow: none; }
        </style></head><body>
        <div class="wide"></div>
        <p><a class="quiet" href="#one">Quiet link</a></p>
        <p><button id="normal">Normal button</button></p>
        <script>console.error('boom')</script>
        <script>requestAnimationFrame(() => { document.title = 'Runner fixture'; })</script>
        <script>addEventListener('resize', () => {
            if (!window.__logged) { window.__logged = true; console.warn('focused-at-resize ' + document.activeElement.tagName); }
        })</script>
        </body></html>
        """

    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        await runner_reports_one_call()
        await runner_gives_up_after_timeout()
        await runner_stops_at_its_budget()
        print("InspectRunnerCheck passed")
    }

    @MainActor static func runner_reports_one_call() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("irun-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("page.html")
        try! page.write(to: file, atomically: true, encoding: .utf8)
        let out = folder.appendingPathComponent("out")
        let runner = InspectRunner(configuration: WKWebViewConfiguration(), outputFolder: out)
        let report = await runner.run(url: file, dark: true, timeout: 20)

        precondition(!report.partial, "a local page finished loading")
        precondition(report.status == nil || report.status == 200, "status \(String(describing: report.status))")
        // The title is written in an animation frame, which a page WebKit counts as hidden never gets.
        precondition(report.facts["title"] == "Runner fixture", "the page never drew a frame: facts \(report.facts)")
        precondition(report.errors.contains { $0.contains("boom") }, "errors \(report.errors)")
        let overflow = report.findings.filter { $0.rule == "overflow" }
        precondition(overflow.contains { ($0.width == 390) || $0.message.contains("390") }, "overflow at 390: \(overflow)")
        precondition(!overflow.contains { $0.width == 1280 || $0.message.contains("1280") }, "no overflow at 1280: \(overflow)")
        let focus = report.findings.filter { $0.rule == "focus-visible" }
        precondition(focus.contains { $0.selector?.contains("quiet") == true }, "the outline-less link has no visible focus: \(report.findings)")
        precondition(!focus.contains { $0.selector?.contains("normal") == true }, "the default button focus ring was flagged")
        // The focus check must not leave a focus ring in the pictures taken after it.
        precondition(report.errors.contains { $0.contains("focused-at-resize BODY") }, "a control kept focus after the focus check: \(report.errors)")
        precondition(runner.screenshots.count == 5, "screenshots \(runner.screenshots.map(\.label))")
        precondition(runner.screenshots.allSatisfy { $0.jpeg.count > 1000 }, "empty screenshots")
        for name in ["report.json", "full-390.png", "full-1280.png", "top-1600.jpg", "dark-1280.jpg"] {
            precondition(FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path), "missing \(name)")
        }
        precondition(report.files.contains { $0.hasSuffix("report.json") })
    }

    /// A server that accepts and never answers: the page never finishes loading.
    @MainActor static func runner_gives_up_after_timeout() async {
        let listener = try! NWListener(using: .tcp, on: .any)
        let held = Held()
        listener.newConnectionHandler = { connection in
            held.connections.append(connection)
            connection.start(queue: .main)
        }
        listener.start(queue: .main)
        // The port reads 0 until the listener is ready.
        while (listener.port?.rawValue ?? 0) == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        let port = listener.port!.rawValue

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("irun-hang-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("hang.html")
        try! "<html><body><img src=\"https://127.0.0.1:\(port)/never.png\"></body></html>".write(to: file, atomically: true, encoding: .utf8)
        let runner = InspectRunner(configuration: WKWebViewConfiguration(), outputFolder: folder.appendingPathComponent("out"))
        let start = Date()
        let report = await runner.run(url: file, dark: false, timeout: 2)
        let took = Date().timeIntervalSince(start)
        precondition(!held.connections.isEmpty, "the page never reached the silent server")
        precondition(report.partial, "a page that never finishes is partial")
        precondition(took < 6, "the call returned after \(took) s")
        listener.cancel()
    }
}

extension InspectRunnerCheck {
    /// A call out of time still answers: the widths it did not reach are listed, never passed.
    @MainActor static func runner_stops_at_its_budget() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("irun-budget-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("page.html")
        try! page.write(to: file, atomically: true, encoding: .utf8)
        let out = folder.appendingPathComponent("out")
        let runner = InspectRunner(configuration: WKWebViewConfiguration(), outputFolder: out)
        let report = await runner.run(url: file, dark: true, timeout: 10, network: "slow3g", workBudget: 0)
        precondition(report.network == "slow3g", "network \(String(describing: report.network))")
        precondition(runner.screenshots.isEmpty, "screenshots taken after the budget: \(runner.screenshots.map(\.label))")
        let skipped = report.unassessable.filter { $0.contains("out of time") }
        precondition(skipped.contains { $0.contains("1280") } && skipped.contains { $0.contains("390") }, "skipped widths not listed: \(report.unassessable)")
        precondition(FileManager.default.fileExists(atPath: out.appendingPathComponent("report.json").path), "no report.json")
    }
}

/// The silent server's connections, kept open so the image load never ends.
final class Held: @unchecked Sendable {
    var connections: [NWConnection] = []
}
