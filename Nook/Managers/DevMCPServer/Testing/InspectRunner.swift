// Licensed under GPL-3.0. See LICENSE.
//
//  InspectRunner.swift
//  Nook
//
//  One `inspect` call: the page loads in its own off-screen window (never one a person may be
//  watching), the capture script records from document start, and the runner freezes animation,
//  reads facts and speed, presses the real Tab key to see focus, audits and screenshots each width
//  (one load at 1280, the others by resizing), takes a dark-mode picture, and writes the report.
//

import AppKit
import PDFKit
import WebKit

/// Says it is the key window without becoming one, as WebKit's own test runner does: WebKit draws
/// keyboard focus (`:focus-visible`) only in an active window, and really making this one key
/// would take the keyboard from whatever the person is typing in.
private final class InspectWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Whether a bounded call has already answered.
@MainActor
private final class AnswerOnce {
    var done = false
}

@MainActor
final class InspectRunner: NSObject, WKNavigationDelegate {
    static let widths = [390, 820, 1280, 1600]
    static let height: CGFloat = 900

    /// The pictures for the MCP answer, after `run`.
    private(set) var screenshots: [(label: String, jpeg: Data)] = []

    private let configuration: WKWebViewConfiguration
    private let outputFolder: URL
    private var finished = false
    private var status: Int?
    private var redirects: [String] = []

    init(configuration: WKWebViewConfiguration, outputFolder: URL) {
        self.configuration = configuration
        self.outputFolder = outputFolder
        super.init()
    }

    /// `timeout` bounds the load; `workBudget` bounds everything after it, so the MCP call answers
    /// before its own deadline with the widths it did not reach listed, never passed.
    func run(url: URL, dark: Bool = true, timeout: TimeInterval = 20, network: String? = nil,
             workBudget: TimeInterval = 30) async -> InspectReport {
        configuration.userContentController.addUserScript(InspectScripts.capture)
        // Tab reaches links too, so the focus check sees every control.
        if let preferences = configuration.preferences.copy() as? WKPreferences {
            preferences.tabFocusesLinks = true
            configuration.preferences = preferences
        }
        let window = InspectWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1280, height: Self.height),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: Self.height), configuration: configuration)
        webView.navigationDelegate = self
        // An off-screen window counts as occluded, and WebKit then hides the page: no animation
        // frames, throttled timers. Only takes if set before the view enters the window.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusion) { webView.perform(occlusion, with: NSNumber(value: false)) }
        window.contentView = webView
        window.orderBack(nil)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            window.orderOut(nil)
            window.close()
        }

        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        let partial = !finished

        var report = InspectReport(
            url: url.absoluteString, finalURL: webView.url?.absoluteString ?? url.absoluteString, status: status,
            partial: partial, network: network, facts: [:], speed: [:], errors: [], failedLoads: [], findings: [],
            unassessable: [], files: [])
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let workDeadline = Date().addingTimeInterval(workBudget)
        func inTime(_ step: String) -> Bool {
            if Date() < workDeadline { return true }
            report.unassessable.append("\(step): not checked, out of time")
            return false
        }

        // Many pages finish setting up on their first frames, so let them draw before measuring.
        await settle(webView)
        _ = await evaluate(webView, InspectScripts.freeze)
        report.facts = Self.facts(Self.object(await evaluate(webView, InspectScripts.facts)))
        if !redirects.isEmpty { report.facts["redirects"] = redirects.joined(separator: " → ") }
        if let memory = Self.memoryMB(of: webView) { report.facts["memory"] = "\(memory) MB" } else {
            report.unassessable.append("memory: the page's process could not be read")
        }
        report.speed = Self.speed(Self.object(await evaluate(webView, InspectScripts.speed)), facts: report.facts)

        var findings: [InspectFinding] = []
        if inTime("keyboard focus") { findings += await focusFindings(webView, window: window) }
        for width in [1280, 390, 820, 1600] {
            guard inTime("width \(width)") else { continue }
            resize(window, webView, width: width)
            await settle(webView)
            let audit = Self.object(await evaluate(webView, InspectScripts.audit(width: width, phone: width <= 820)))
            findings += Self.findings(audit["findings"])
            for item in (audit["unassessable"] as? [String] ?? []) where !report.unassessable.contains(item) {
                report.unassessable.append(item)
            }
            if let jpeg = await bounded(10, { try? await InspectScripts.shot(webView, maxWidth: 1200) }) {
                screenshots.append(("top-\(width)", jpeg))
                save(jpeg, "top-\(width).jpg", into: &report)
            }
            if let pdf = await bounded(15, { try? await webView.pdf(configuration: WKPDFConfiguration()) }),
               let png = Self.pngImage(fromPDF: pdf, scale: 1) {
                save(png, "full-\(width).png", into: &report)
            }
        }
        if dark, inTime("dark mode") {
            resize(window, webView, width: 1280)
            webView.appearance = NSAppearance(named: .darkAqua)
            await settle(webView)
            if let jpeg = await bounded(10, { try? await InspectScripts.shot(webView, maxWidth: 1200) }) {
                screenshots.append(("dark-1280", jpeg))
                save(jpeg, "dark-1280.jpg", into: &report)
            }
        }
        report.unassessable.append("phone identity: other widths are the same page resized; sites that serve phones different HTML are not covered")

        let captured = Self.object(await evaluate(webView, "JSON.stringify(window.__nookInspect || {})"))
        report.errors = (captured["console"] as? [String] ?? []) + (captured["errors"] as? [String] ?? [])
        report.failedLoads = captured["failed"] as? [String] ?? []
        report.findings = InspectReport.merge(findings)

        let reportFile = outputFolder.appendingPathComponent("report.json")
        report.files.insert(reportFile.path, at: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) { try? data.write(to: reportFile) }
        return report
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finished = true
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString { redirects.append(url) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            status = http.statusCode
        }
        return .allow
    }

    // MARK: - Steps

    /// Real Tab presses (browsers show focus styles only after keyboard use), comparing each
    /// focused control with how it looked unfocused.
    private func focusFindings(_ webView: WKWebView, window: NSWindow) async -> [InspectFinding] {
        guard Int((await evaluate(webView, InspectScripts.focusBaseline)) ?? "0") ?? 0 > 0 else { return [] }
        window.makeFirstResponder(webView)
        var seen = Set<String>()
        var findings: [InspectFinding] = []
        for _ in 0..<40 {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                    isARepeat: false, keyCode: 48) {
                    window.sendEvent(event)
                }
            }
            await settle(webView)
            let state = Self.object(await evaluate(webView, InspectScripts.focusCheck))
            guard let selector = state["selector"] as? String else { continue }
            if seen.contains(selector) { break }
            seen.insert(selector)
            if state["changed"] as? Bool == false {
                findings.append(InspectFinding(
                    severity: "warning", rule: "focus-visible", message: "No visible change when focused with the keyboard",
                    width: nil, selector: selector, fix: "add a :focus-visible outline"))
            }
        }
        return findings
    }

    private func resize(_ window: NSWindow, _ webView: WKWebView, width: Int) {
        window.setContentSize(NSSize(width: CGFloat(width), height: Self.height))
        webView.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: Self.height)
    }

    /// Two animation frames, so layout and paint have caught up.
    private func settle(_ webView: WKWebView) async {
        _ = await bounded(1) {
            try? await webView.callAsyncJavaScript(
                "await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); return 1;",
                arguments: [:], in: nil, contentWorld: .page)
        }
        try? await Task.sleep(for: .milliseconds(60))
    }

    private func evaluate(_ webView: WKWebView, _ js: String) async -> String? {
        await bounded(10) {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(js, in: nil, in: .page) { result in
                    if case .success(let value) = result { continuation.resume(returning: value as? String) }
                    else { continuation.resume(returning: nil) }
                }
            }
        }
    }

    /// WebKit's callbacks cannot be cancelled, so a page that never answers would hold the whole
    /// call: whichever of the work and the timer finishes first answers, and the other is ignored.
    private func bounded<T>(_ seconds: TimeInterval, _ work: @escaping @MainActor () async -> T?) async -> T? {
        let once = AnswerOnce()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let value = await work()
                if !once.done { once.done = true; continuation.resume(returning: value) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if !once.done { once.done = true; continuation.resume(returning: nil) }
            }
        }
    }

    private func save(_ data: Data, _ name: String, into report: inout InspectReport) {
        let file = outputFolder.appendingPathComponent(name)
        if (try? data.write(to: file)) != nil { report.files.append(file.path) }
    }

    // MARK: - Formatting

    private static func object(_ json: String?) -> [String: Any] {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func findings(_ value: Any?) -> [InspectFinding] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let severity = item["severity"] as? String, let rule = item["rule"] as? String,
                  let message = item["message"] as? String else { return nil }
            return InspectFinding(severity: severity, rule: rule, message: message, width: item["width"] as? Int,
                                  selector: item["selector"] as? String, fix: item["fix"] as? String)
        }
    }

    private static func facts(_ raw: [String: Any]) -> [String: String] {
        var facts: [String: String] = [:]
        for key in ["title", "lang", "dir", "viewport"] { if let value = raw[key] as? String, !value.isEmpty { facts[key] = value } }
        if let nodes = raw["domNodes"] as? Int { facts["domNodes"] = "\(nodes)" }
        if let loaded = raw["fontsLoaded"] as? Int { facts["fontsLoaded"] = "\(loaded)" }
        if let failed = raw["fontsFailed"] as? [String], !failed.isEmpty { facts["fontsFailed"] = failed.joined(separator: ", ") }
        if let blocking = raw["headBlocking"] as? [String], !blocking.isEmpty {
            facts["renderBlocking"] = "\(blocking.count): " + blocking.prefix(5).joined(separator: ", ")
        }
        return facts
    }

    private static func speed(_ raw: [String: Any], facts: [String: String]) -> [String: String] {
        var speed: [String: String] = [:]
        for key in ["ttfb", "fcp", "lcp", "domReady", "load"] { if let ms = raw[key] as? Int { speed[key] = "\(ms) ms" } }
        if raw["lcp"] == nil || raw["lcp"] is NSNull { speed["lcp"] = "not reported" }
        if let requests = raw["requests"] as? Int { speed["requests"] = "\(requests)" }
        if let total = raw["totalBytes"] as? Int { speed["pageWeight"] = bytes(total + (raw["documentBytes"] as? Int ?? 0)) }
        if let share = raw["thirdPartyShare"] as? Int { speed["thirdParty"] = "\(share)%" }
        if let byType = raw["bytesByType"] as? [String: Int], !byType.isEmpty {
            speed["byType"] = byType.sorted { $0.value > $1.value }.map { "\($0.key) \(bytes($0.value))" }.joined(separator: ", ")
        }
        func list(_ key: String, _ unit: (Int) -> String, _ field: String) {
            let items = (raw[key] as? [[String: Any]] ?? []).prefix(3).compactMap { item -> String? in
                guard let url = item["url"] as? String, let value = item[field] as? Int, value > 0 else { return nil }
                return "\(url.suffix(80)) (\(unit(value)))"
            }
            if !items.isEmpty { speed[key] = items.joined(separator: "; ") }
        }
        list("heaviest", bytes, "bytes")
        list("slowest", { "\($0) ms" }, "ms")
        return speed
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private static func memoryMB(of webView: WKWebView) -> UInt64? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        var usage = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return ok == 0 ? usage.ri_phys_footprint / 1_048_576 : nil
    }

    /// Every page of the PDF stacked into one PNG (as Capture Full Page draws it).
    static func pngImage(fromPDF data: Data, scale: CGFloat) -> Data? {
        guard let document = PDFDocument(data: data) else { return nil }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        let sizes = pages.map { $0.bounds(for: .mediaBox).size }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.reduce(0) { $0 + $1.height }
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(scale, 32_000 / height, 16_000 / width)
        guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        var top = height
        for (page, size) in zip(pages, sizes) {
            top -= size.height
            context.saveGState()
            context.translateBy(x: 0, y: top)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
