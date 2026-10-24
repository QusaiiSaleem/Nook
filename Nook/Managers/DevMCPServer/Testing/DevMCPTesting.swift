// Licensed under GPL-3.0. See LICENSE.
//
//  DevMCPTesting.swift
//  Nook
//
//  DevMCP's testing tools: `inspect` (one call for a page's facts, speed, errors, findings with
//  fixes and pictures at four widths), `type` and `upload` (real input on the agent's page), and
//  `record_start` / `record_stop` (a GIF of the agent's page). DevMCPServer asks `call` before
//  answering "Unknown tool".
//

import AppKit
import WebKit
import NookWeb

@MainActor
enum DevMCPTesting {
    /// `inspect` may load for 20 s and audit for 30 more, longer than the usual tool deadline.
    nonisolated static let inspectTimeout: Double = 60

    static let definitions: [AIToolDefinition] = [
        AIToolDefinition(
            name: "inspect",
            description: "One call to test a page: loads url (default: the agent's tab) in its own hidden window and returns facts (title, language, direction, redirects, memory), speed (TTFB, FCP, LCP, page weight by type, heaviest and slowest files, third-party share), console errors and failed loads, findings with fixes (contrast with a passing colour, alt text, control names, overflow, clipped text, tap targets, keyboard focus, broken, oversized or unsized images, failed fonts, Arabic and RTL traps, hidden elements shown) at 1280, 390, 820 and 1600 px, a dark-mode picture, and what it could not check. Uses the Agent space's logins; with network (slow3g, fast3g, 4g) the load goes through a throttling proxy in a throwaway store with no logins. report.json and full-page PNGs go to ~/Downloads/Nook MCP/inspect/.",
            parameters: ["type": "object", "properties": [
                "url": ["type": "string"],
                "network": ["type": "string", "enum": ["slow3g", "fast3g", "4g"]],
                "dark": ["type": "boolean", "description": "Take the dark-mode picture (default true)."],
            ] as [String: Any]]
        ),
        AIToolDefinition(
            name: "type",
            description: "Type into the agent's page as a person does (trusted key events, which sites that ignore script-made input accept): focuses selector if given, types text, then presses keys in order (Enter, Tab, Backspace, Escape, ArrowLeft, ArrowRight, ArrowUp, ArrowDown). Returns the focused element's value.",
            parameters: ["type": "object", "properties": [
                "text": ["type": "string"],
                "keys": ["type": "array", "items": ["type": "string"]],
                "selector": ["type": "string"],
            ] as [String: Any]]
        ),
        AIToolDefinition(
            name: "upload",
            description: "Choose files for a file input on the agent's page: clicks selector (the input, or the button that opens the file picker) and answers the picker with paths (absolute, or starting with ~). Returns the chosen file names.",
            parameters: ["type": "object", "properties": [
                "selector": ["type": "string"],
                "paths": ["type": "array", "items": ["type": "string"]],
            ] as [String: Any], "required": ["selector", "paths"]]
        ),
        AIToolDefinition(
            name: "record_start",
            description: "Start recording the agent's page as a GIF, 800 px wide (fps default 4, at most 10; maxSeconds default and at most 60). It stops on its own when full; record_stop writes it.",
            parameters: ["type": "object", "properties": [
                "fps": ["type": "number"],
                "maxSeconds": ["type": "number"],
            ] as [String: Any]]
        ),
        AIToolDefinition(
            name: "record_stop",
            description: "Stop the recording and write the GIF to ~/Downloads/Nook MCP/recordings/. Returns its path and frame count.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        ),
    ]

    /// The answer to a testing tool, or nil when `name` is not one.
    static func call(_ name: String, _ args: [String: Any], browserManager bm: BrowserManager, agentView: WKWebView?,
                     session: PageSession?) async -> [String: Any]? {
        do {
            switch name {
            case "inspect": return try await inspect(args, bm)
            case "type":
                guard let agentView else { return text("No agent tab: open a page first.", error: true) }
                let value = try await AgentInput.type(args["text"] as? String, keys: args["keys"] as? [String] ?? [],
                                                      into: agentView, selector: args["selector"] as? String)
                return text("Value: \(value)")
            case "upload": return try await upload(args, agentView, session)
            case "record_start": return recordStart(args, bm)
            case "record_stop": return try await recordStop(bm)
            default: return nil
            }
        } catch {
            return text("\(name) failed: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: - inspect

    private static func inspect(_ args: [String: Any], _ bm: BrowserManager) async throws -> [String: Any] {
        let target: URL
        if let raw = args["url"] as? String {
            guard let url = URL(string: raw), isWeb(url) else { return text("url must be an http or https address", error: true) }
            target = url
        } else if let current = bm.tabs.agentItem.flatMap({ bm.tabs.session(for: $0)?.url ?? bm.tabs.item($0)?.url }), isWeb(current) {
            target = current
        } else {
            return text("Give a url: the agent's tab has no web page.", error: true)
        }
        var throttle: ThrottleProxy.Profile?
        if let raw = args["network"] as? String {
            guard let profile = ThrottleProxy.Profile(rawValue: raw) else { return text("network must be slow3g, fast3g or 4g", error: true) }
            throttle = profile
        }
        let window = (bm.windowRegistry?.activeWindow).flatMap { $0.isIncognito ? nil : $0 } ?? bm.tabs.regularWindows.first
        guard let space = bm.tabs.agentSpaceID ?? window?.spaceID, let profile = bm.tabs.profile(forSpace: space) else {
            return text("No space to load the page in", error: true)
        }
        guard let folder = DevMCPFiles.resolve("inspect/\(stamp())-\(target.host ?? "page")") else {
            return text("Could not make a folder in \(DevMCPFiles.root.path)", error: true)
        }

        let configuration = BrowserConfiguration.shared.webViewConfiguration(for: profile)
        // As on every agent page: no extensions.
        configuration.webExtensionController = nil
        var proxy: ThrottleProxy?
        defer { proxy?.stop() }
        if let throttle {
            let started = try ThrottleProxy(profile: throttle)
            let port = try await started.start()
            proxy = started
            let store = WKWebsiteDataStore.nonPersistent()
            store.proxyConfigurations = [started.proxyConfiguration(port: port)]
            configuration.websiteDataStore = store
        }
        let label = throttle.map {
            "\($0.rawValue) (\(Int($0.latency * 1000)) ms on each new connection, \($0.bytesPerSecond * 8 / 1000) kbit/s shared)"
        }
        let runner = InspectRunner(configuration: configuration, outputFolder: folder)
        let report = await runner.run(url: target, dark: args["dark"] as? Bool ?? true, network: label)

        var markdown = report.markdown()
        if !runner.screenshots.isEmpty {
            markdown += "\n\nPictures, in order: " + runner.screenshots.map(\.label).joined(separator: ", ")
        }
        var content: [[String: Any]] = [["type": "text", "text": markdown]]
        for shot in runner.screenshots {
            content.append(["type": "image", "data": shot.jpeg.base64EncodedString(), "mimeType": "image/jpeg"])
        }
        return ["content": content, "isError": false]
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    // MARK: - upload

    private static func upload(_ args: [String: Any], _ agentView: WKWebView?, _ session: PageSession?) async throws -> [String: Any] {
        guard let agentView, let session else { return text("No agent tab: open a page first.", error: true) }
        guard let selector = args["selector"] as? String, let paths = args["paths"] as? [String], !paths.isEmpty else {
            return text("selector and paths are required", error: true)
        }
        var files: [URL] = []
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return text("Not a file (give an absolute path or one starting with ~): \(path)", error: true)
            }
            let file = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
            guard !holdsSecrets(file) else {
                return text("\(path) is in a hidden folder or ~/Library, where keys and logins live; copy the file somewhere else first.", error: true)
            }
            files.append(file)
        }

        session.pendingUploadURLs = files
        // DevMCP's evaluation counts as a click, so the page may open its file picker.
        let clicked = try await agentView.callAsyncJavaScript(
            "const el = document.querySelector(selector); if (!el) { return false; } el.click(); return true;",
            arguments: ["selector": selector], in: nil, contentWorld: .defaultClient) as? Bool
        guard clicked == true else {
            session.pendingUploadURLs = nil
            return text("No element matches \(selector)", error: true)
        }
        // The picker takes the files when it opens. ponytail: 100 ms poll bounded by 5 s.
        let deadline = Date().addingTimeInterval(5)
        while session.pendingUploadURLs != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard session.pendingUploadURLs == nil else {
            session.pendingUploadURLs = nil
            return text("\(selector) opened no file picker within 5 s. Point selector at the <input type=file> or the button that opens it.", error: true)
        }
        // Let the page's own change handlers run before reading the input back.
        try await Task.sleep(for: .milliseconds(200))
        let names = try await agentView.callAsyncJavaScript(
            """
            const el = document.querySelector(selector);
            const input = el && el.matches('input[type=file]') ? el
                : Array.from(document.querySelectorAll('input[type=file]')).find((i) => i.files && i.files.length);
            return input && input.files ? Array.from(input.files).map((f) => f.name) : [];
            """,
            arguments: ["selector": selector], in: nil, contentWorld: .defaultClient) as? [String] ?? []
        return text(json(["files": names]))
    }

    /// Any file the agent names may be uploaded, except where keys and logins live: hidden files
    /// and folders (~/.ssh, ~/.aws, .env) and ~/Library (keychains, cookies, this server's token).
    /// Anyone holding the token could otherwise send them to a site of their choosing.
    private static func holdsSecrets(_ file: URL) -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").resolvingSymlinksInPath().path
        return file.pathComponents.contains { $0.hasPrefix(".") } || file.path.hasPrefix(library + "/")
    }

    // MARK: - Recording

    @MainActor private final class Recording {
        let recorder: GIFRecorder
        var task: Task<Void, Never>?
        /// Whether this recording still counts as a call in flight.
        var holdsPage = true

        init(recorder: GIFRecorder) { self.recorder = recorder }
    }

    private static var recording: Recording?

    private static func recordStart(_ args: [String: Any], _ bm: BrowserManager) -> [String: Any] {
        guard recording == nil else { return text("Already recording; call record_stop first.", error: true) }
        guard bm.tabs.agentItem != nil else { return text("No agent tab: open a page first.", error: true) }
        let fps = min(max((args["fps"] as? NSNumber)?.doubleValue ?? 4, 1), 10)
        let seconds = min(max((args["maxSeconds"] as? NSNumber)?.doubleValue ?? 60, 1), 60)
        let item = Recording(recorder: GIFRecorder(fps: fps, maxSeconds: seconds))
        // Counted as a call in flight, so the page stays in its window between the agent's calls
        // and the sidebar shows the agent at work.
        bm.tabs.agentCallsInFlight += 1
        item.task = Task { @MainActor in
            defer { release(item, bm) }
            while !Task.isCancelled {
                let started = ContinuousClock.now
                // The agent's tab at each frame, so a tab it opens mid-recording is followed.
                if let view = bm.tabs.agentItem.flatMap(bm.tabs.session(for:))?.webView,
                   let image = try? await view.takeSnapshot(configuration: nil),
                   let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   !item.recorder.add(frame) {
                    return
                }
                try? await Task.sleep(until: started.advanced(by: .seconds(1 / fps)), clock: .continuous)
            }
        }
        recording = item
        return text("Recording at \(fps.formatted()) frames a second for up to \(Int(seconds)) s.")
    }

    private static func recordStop(_ bm: BrowserManager) async throws -> [String: Any] {
        guard let item = recording else { return text("Not recording.", error: true) }
        recording = nil
        item.task?.cancel()
        await item.task?.value
        release(item, bm)
        guard let file = DevMCPFiles.resolve("recordings/\(stamp()).gif") else {
            return text("Could not make a file in \(DevMCPFiles.root.path)", error: true)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let frames = try item.recorder.write(to: file)
        return text(json(["path": file.path, "frames": frames, "seconds": Double(frames) / item.recorder.fps]))
    }

    /// Gives back the call-in-flight count once, whether the recording filled up or was stopped.
    private static func release(_ item: Recording, _ bm: BrowserManager) {
        guard item.holdsPage else { return }
        item.holdsPage = false
        bm.tabs.agentCallsInFlight -= 1
    }

    // MARK: - Answers

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func text(_ s: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": error]
    }

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
