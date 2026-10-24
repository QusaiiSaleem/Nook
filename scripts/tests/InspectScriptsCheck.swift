// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc -parse-as-library Nook/Managers/DevMCPServer/Testing/InspectScripts.swift \
//         scripts/tests/InspectScriptsCheck.swift -o /tmp/is && /tmp/is
//
//  The in-page checks behind `inspect`, in a real off-screen web view: a page with one of each
//  defect finds each rule; a correct Arabic page finds no Arabic problem; text over a gradient is
//  "could not check", not a pass or a fail; big pages say where they stopped; the capture script
//  sees console errors and failed loads from the start.

import AppKit
import WebKit

@main
struct InspectScriptsCheck {
    @MainActor static var window: NSWindow!
    @MainActor static var web: WKWebView!

    static let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    static let defects = """
        <html lang="ar" dir="ltr"><head><meta name="viewport" content="width=device-width"><style>
        body { margin: 0; font-family: -apple-system, sans-serif; }
        .wide { width: 600px; height: 20px; background: #eee; }
        .faint { color: #999; background: #fff; }
        .clip { display: block; width: 60px; overflow: hidden; white-space: nowrap; }
        .just { text-align: justify; }
        .mono { font-family: Menlo, monospace; }
        .tiny { display: inline-block; width: 20px; height: 20px; }
        </style></head><body>
        <div class="wide" id="wide"></div>
        <p class="faint" id="faint">Faint text here</p>
        <img src="\(pixel)" id="noalt" width="10" height="10">
        <button id="empty"></button>
        <img src="https://127.0.0.1:9/missing.png" alt="missing" id="broken" width="10" height="10">
        <span class="clip" id="clip">This text is far too long to fit</span>
        <p class="just" id="just" dir="rtl">هذا نص عربي مضبوط على الجانبين</p>
        <p class="mono" id="mono" dir="rtl">نص عربي بخط ثابت العرض</p>
        <p id="ltrar">نص عربي بلا اتجاه</p>
        <div hidden style="display: block" id="hid">visible despite hidden</div>
        <div><a href="#" class="tiny" id="tiny">x</a></div>
        <script>console.error('boom')</script>
        </body></html>
        """

    static let cleanArabic = """
        <html lang="ar" dir="rtl"><head><meta name="viewport" content="width=device-width"></head>
        <body style="margin: 16px; font-family: -apple-system, sans-serif; color: #111; background: #fff">
        <h1>مرحبا بكم في الموقع</h1><p>هذا نص عربي سليم يقرأ من اليمين إلى اليسار.</p>
        <button>إرسال</button></body></html>
        """

    static let gradient = """
        <html><body style="margin: 0"><div style="background: linear-gradient(red, blue); padding: 20px">
        <p id="ongrad" style="color: #fff">Text on a gradient</p></div></body></html>
        """

    static var huge: String {
        "<html><body>" + (0..<500).map { "<p>Line \($0)</p>" }.joined() + "</body></html>"
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(InspectScripts.capture)
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1280, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        window.contentView = web
        window.orderBack(nil)

        defects_page_finds_each_rule()
        capture_records_console_and_failed_loads()
        clean_arabic_page_has_no_arabic_findings()
        text_over_a_gradient_is_unassessable()
        big_pages_say_where_they_stopped()
        facts_and_speed_answer()
        print("InspectScriptsCheck passed")
    }

    // MARK: - Checks

    @MainActor static func defects_page_finds_each_rule() {
        load(defects)
        _ = waitUntil(3) { (evaluate("String(document.getElementById('broken').complete)") as? String) == "true" }
        let desktop = audit(width: 1280)
        let desktopRules = Set(desktop.findings.compactMap { $0["rule"] as? String })
        for rule in ["contrast", "image-alt", "control-name", "image-broken", "clipped-text", "arabic-justify",
                     "arabic-monospace", "arabic-ltr", "hidden-shown"] {
            precondition(desktopRules.contains(rule), "missing \(rule) at 1280; got \(desktopRules.sorted())")
        }
        let contrast = desktop.findings.first { $0["rule"] as? String == "contrast" }
        precondition((contrast?["fix"] as? String)?.contains("#") == true, "contrast finding has no colour fix: \(String(describing: contrast))")
        precondition(!desktopRules.contains("overflow"), "no overflow at 1280")
        precondition(!desktopRules.contains("tap-target"), "tap targets are a phone check")

        let phone = audit(width: 390, phone: true)
        let phoneRules = Set(phone.findings.compactMap { $0["rule"] as? String })
        precondition(phoneRules.contains("overflow"), "the 600px box overflows at 390; got \(phoneRules.sorted())")
        precondition(phoneRules.contains("tap-target"), "the 20px link is too small at 390")
        precondition(!phoneRules.contains("contrast"), "width-independent rules run once, at 1280")
        resize(1280)
    }

    @MainActor static func capture_records_console_and_failed_loads() {
        let captured = evaluate("JSON.stringify(window.__nookInspect || null)") as? String ?? ""
        precondition(captured.contains("boom"), "console.error not captured: \(captured.prefix(300))")
        precondition(captured.contains("missing.png"), "failed image load not captured: \(captured.prefix(300))")
    }

    @MainActor static func clean_arabic_page_has_no_arabic_findings() {
        load(cleanArabic)
        let rules = Set((audit(width: 1280).findings + audit(width: 390, phone: true).findings).compactMap { $0["rule"] as? String })
        for rule in ["arabic-justify", "arabic-monospace", "arabic-ltr", "latin-leak", "overflow", "contrast", "control-name"] {
            precondition(!rules.contains(rule), "false alarm \(rule) on a correct Arabic page")
        }
        resize(1280)
    }

    @MainActor static func text_over_a_gradient_is_unassessable() {
        load(gradient)
        let result = audit(width: 1280)
        precondition(result.unassessable.contains { $0.contains("image or gradient") }, "gradient text not listed: \(result.unassessable)")
        precondition(!result.findings.contains { $0["rule"] as? String == "contrast" }, "gradient text was graded")
    }

    @MainActor static func big_pages_say_where_they_stopped() {
        load(huge)
        let result = audit(width: 1280)
        precondition(result.unassessable.contains { $0.contains("first 400 of 500") }, "cap not reported: \(result.unassessable)")
    }

    @MainActor static func facts_and_speed_answer() {
        load(cleanArabic)
        let facts = json(evaluate(InspectScripts.facts) as? String)
        precondition(facts["lang"] as? String == "ar" && facts["dir"] as? String == "rtl", "facts \(facts)")
        precondition((facts["domNodes"] as? Int ?? 0) > 3)
        let speed = json(evaluate(InspectScripts.speed) as? String)
        precondition(speed["bytesByType"] != nil, "speed \(speed)")
    }

    // MARK: - Helpers

    @MainActor static func audit(width: Int, phone: Bool = false) -> (findings: [[String: Any]], unassessable: [String]) {
        resize(width)
        _ = evaluate(InspectScripts.freeze)
        let result = json(evaluate(InspectScripts.audit(width: width, phone: phone)) as? String)
        return (result["findings"] as? [[String: Any]] ?? [], result["unassessable"] as? [String] ?? [])
    }

    @MainActor static func resize(_ width: Int) {
        window.setContentSize(NSSize(width: width, height: 900))
        web.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        _ = waitUntil(0.4) { false }
    }

    @MainActor static func load(_ html: String) {
        resize(1280)
        web.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        precondition(waitUntil { (evaluate("document.readyState") as? String) == "complete" }, "page never loaded")
    }

    static func json(_ string: String?) -> [String: Any] {
        guard let data = string?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    @MainActor @discardableResult
    static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    @MainActor static func evaluate(_ js: String) -> Any? {
        var result: Any?
        var done = false
        web.evaluateJavaScript(js, in: nil, in: .page) { outcome in
            if case .success(let value) = outcome { result = value }
            done = true
        }
        waitUntil(10) { done }
        return result
    }
}
