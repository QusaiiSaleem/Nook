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
        await repeat_visit_says_files_came_from_cache()
        await slowest_excludes_time_in_the_queue()
        await inspect_runs_without_the_ad_blocker()
        await hung_page_still_answers_and_stops()
        await focus_check_says_where_it_stopped()
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

extension InspectRunnerCheck {
    /// A second visit through the same store gets the image from the cache; the report must say so
    /// rather than pass the revalidation's header bytes off as the page's weight.
    @MainActor static func repeat_visit_says_files_came_from_cache() async {
        let server = await TinyServer.start()
        // A store of its own, removed afterwards: a non-persistent store keeps no HTTP cache
        // between page processes, so nothing would come from the cache.
        let storeID = UUID()
        let store = WKWebsiteDataStore(forIdentifier: storeID)
        func visit() async -> InspectReport {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = store
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("irun-cache-\(UUID().uuidString)")
            return await InspectRunner(configuration: config, outputFolder: out)
                .run(url: URL(string: "http://127.0.0.1:\(server.port)/cache.html")!, dark: false, timeout: 10, workBudget: 0)
        }
        let first = await visit()
        precondition(first.speed["cache"] == nil, "a first visit claimed the cache: \(first.speed)")
        let second = await visit()
        precondition(server.hits["/pixel.png"] == 1, "the image was fetched \(server.hits["/pixel.png"] ?? 0) times: no cache hit to report")
        precondition(second.speed["cache"]?.contains("1 of 1") == true, "repeat visit not flagged: \(second.speed)")
        server.stop()
        try? await WKWebsiteDataStore.remove(forIdentifier: storeID)
    }

    /// Eight images that each take 300 ms, six connections at a time: the last two wait in line for
    /// 300 ms first. "Slowest" times the request, not the wait.
    @MainActor static func slowest_excludes_time_in_the_queue() async {
        let server = await TinyServer.start()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("irun-queue-\(UUID().uuidString)")
        let report = await InspectRunner(configuration: WKWebViewConfiguration(), outputFolder: out)
            .run(url: URL(string: "http://127.0.0.1:\(server.port)/queue.html")!, dark: false, timeout: 15, workBudget: 0)
        // "…/slow7.png (312 ms from request to last byte); …" → [312, …]
        let times = (report.speed["slowest"] ?? "").components(separatedBy: " ms from request").compactMap {
            $0.components(separatedBy: "(").last.flatMap { Int($0) }
        }
        precondition(!times.isEmpty && times.max()! >= 250, "slow images not timed: \(report.speed)")
        precondition(times.max()! < 450, "queue time counted as slowness: \(report.speed["slowest"] ?? "")")
        server.stop()
    }
}

extension InspectRunnerCheck {
    /// Nook's own blocker must not show up as the site's broken images: inspect shows the page as a
    /// visitor without Nook sees it, and says so.
    @MainActor static func inspect_runs_without_the_ad_blocker() async {
        let server = await TinyServer.start()
        let rules = FileManager.default.temporaryDirectory.appendingPathComponent("irun-rules-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        let list = try! await WKContentRuleListStore(url: rules)!.compileContentRuleList(
            forIdentifier: "test", encodedContentRuleList: #"[{"trigger":{"url-filter":"pixel\\.png"},"action":{"type":"block"}}]"#)!
        let config = WKWebViewConfiguration()
        config.userContentController.add(list)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("irun-blocker-\(UUID().uuidString)")
        let report = await InspectRunner(configuration: config, outputFolder: out)
            .run(url: URL(string: "http://127.0.0.1:\(server.port)/cache.html")!, dark: false, timeout: 10, workBudget: 0)
        precondition(!report.failedLoads.contains { $0.contains("pixel.png") }, "the blocker's work reported as a failed load: \(report.failedLoads)")
        precondition(report.facts["adBlocking"]?.contains("off") == true, "the report does not say the blocker was off: \(report.facts)")
        server.stop()
    }

    /// A page whose scripts stop answering after load: the call still answers within its budget,
    /// says what it could not read, and leaves no page process spinning.
    @MainActor static func hung_page_still_answers_and_stops() async {
        let server = await TinyServer.start()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("irun-hung-\(UUID().uuidString)")
        let pagesBefore = Set(pageProcesses())
        let start = Date()
        let report = await InspectRunner(configuration: WKWebViewConfiguration(), outputFolder: out)
            .run(url: URL(string: "http://127.0.0.1:\(server.port)/hang.html")!, dark: true, timeout: 5, workBudget: 4)
        let took = Date().timeIntervalSince(start)
        precondition(took < 9, "a hung page held the call for \(took) s")
        precondition(report.unassessable.contains { $0.contains("did not answer") }, "the hang is not reported: \(report.unassessable)")
        try? await Task.sleep(for: .seconds(2))
        let busy = busiestCPU(of: pageProcesses().filter { !pagesBefore.contains($0) })
        precondition(busy < 0.5, "a page process is still spinning at \(Int(busy * 100))% CPU after the call")
        server.stop()
    }

    /// The keyboard check presses Tab at most 40 times; past that it must say so, not pass silently.
    @MainActor static func focus_check_says_where_it_stopped() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("irun-links-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("links.html")
        try! ("<html><body>" + (1...60).map { "<p><a href=\"#l\($0)\">Link \($0)</a></p>" }.joined() + "</body></html>")
            .write(to: file, atomically: true, encoding: .utf8)
        let report = await InspectRunner(configuration: WKWebViewConfiguration(), outputFolder: folder.appendingPathComponent("out"))
            .run(url: file, dark: false, timeout: 10, workBudget: 20)
        precondition(report.unassessable.contains { $0.contains("keyboard focus") && $0.contains("40") }, "the focus cap is not reported: \(report.unassessable)")
    }

    /// Every WebKit page process on the Mac. macOS does not tie a page process to a command-line
    /// program, so the check compares the list before and after a run.
    static func pageProcesses() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, n)).filter { pid in
            var path = [CChar](repeating: 0, count: 4096)
            return pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasSuffix("com.apple.WebKit.WebContent")
        }
    }

    /// The highest CPU share, over one second, among `pids`.
    static func busiestCPU(of pids: [pid_t]) -> Double {
        func cpu(_ pid: pid_t) -> UInt64 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
            return ok == 0 ? info.ri_user_time + info.ri_system_time : 0
        }
        let before = pids.map(cpu), t0 = mach_absolute_time()
        Thread.sleep(forTimeInterval: 1)
        let after = pids.map(cpu), t1 = mach_absolute_time()
        return zip(before, after).map { $1 > $0 ? Double($1 - $0) / Double(t1 - t0) : 0 }.max() ?? 0
    }
}

/// A tiny HTTP/1.1 server for the speed checks: a cacheable image, and slow images.
final class TinyServer: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var hits: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
    static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private init(_ listener: NWListener) { self.listener = listener }

    @MainActor static func start() async -> TinyServer {
        let server = TinyServer(try! NWListener(using: .tcp, on: .any))
        server.listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let line = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                server.answer(path, on: connection)
            }
        }
        server.listener.start(queue: .global())
        while server.port == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        return server
    }

    func stop() { listener.cancel() }

    private func answer(_ path: String, on connection: NWConnection) {
        lock.lock(); counts[path, default: 0] += 1; lock.unlock()
        var body = Data("not found".utf8), type = "text/plain", cache = "no-store", delay = 0.0
        switch path {
        case "/cache.html":
            body = Data("<html><body><img src=\"/pixel.png\"></body></html>".utf8); type = "text/html"
        case "/pixel.png":
            body = Self.pixel; type = "image/png"; cache = "max-age=3600"
        case "/queue.html":
            body = Data(("<html><body>" + (1...8).map { "<img src=\"/slow\($0).png\">" }.joined() + "</body></html>").utf8); type = "text/html"
        case "/hang.html":
            body = Data("<html><body><p>Loaded, then stuck</p><script>addEventListener('load', () => setTimeout(() => { for (;;) {} }, 50))</script></body></html>".utf8); type = "text/html"
        case let slow where slow.hasPrefix("/slow"):
            body = Self.pixel; type = "image/png"; delay = 0.3
        default: break
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: \(cache)\r\nConnection: close\r\n\r\n"
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// The silent server's connections, kept open so the image load never ends.
final class Held: @unchecked Sendable {
    var connections: [NWConnection] = []
}
