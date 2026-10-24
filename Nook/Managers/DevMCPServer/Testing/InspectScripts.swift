// Licensed under GPL-3.0. See LICENSE.
//
//  InspectScripts.swift
//  Nook
//
//  The in-page half of the MCP `inspect` tool. `capture` runs at document start and records
//  console errors, uncaught errors and failed loads; the rest run after load and answer as JSON
//  strings. The audit follows scitter's standards axis: WCAG contrast with a passing colour,
//  names, RTL correctness, overflow at each width, plus Qusai's house rules (Arabic traps, the
//  hidden-element trap). A check that cannot answer says so in `unassessable`; caps say where
//  they stopped.
//

import AppKit
import WebKit

enum InspectScripts {
    /// Page world, document start, main frame.
    static var capture: WKUserScript {
        WKUserScript(source: captureSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Stops animations and transitions so screenshots and layout checks do not depend on timing.
    static let freeze = #"""
    (function () {
        if (document.getElementById('__nook-inspect-freeze')) { return 'ok'; }
        const style = document.createElement('style');
        style.id = '__nook-inspect-freeze';
        style.textContent = '*, *::before, *::after { animation-play-state: paused !important; animation-delay: -1ms !important; transition: none !important; caret-color: transparent !important; scroll-behavior: auto !important; }';
        (document.head || document.documentElement).appendChild(style);
        return 'ok';
    })()
    """#

    static let facts = #"""
    (function () {
        const meta = document.querySelector('meta[name="viewport"]');
        const fonts = document.fonts ? Array.from(document.fonts) : [];
        const head = document.head ? Array.from(document.head.children) : [];
        const blocking = head.filter((el) =>
            (el.tagName === 'SCRIPT' && el.src && !el.async && !el.defer && el.type !== 'module') ||
            (el.tagName === 'LINK' && el.rel === 'stylesheet' && (!el.media || el.media === 'all'))
        ).map((el) => el.src || el.href).slice(0, 20);
        return JSON.stringify({
            title: document.title,
            lang: document.documentElement.getAttribute('lang') || '',
            dir: document.documentElement.getAttribute('dir') || getComputedStyle(document.documentElement).direction,
            viewport: meta ? meta.getAttribute('content') : '',
            domNodes: document.getElementsByTagName('*').length,
            fontsLoaded: fonts.filter((f) => f.status === 'loaded').length,
            fontsFailed: fonts.filter((f) => f.status === 'error').map((f) => f.family),
            headBlocking: blocking
        });
    })()
    """#

    static let speed = #"""
    (function () {
        const nav = performance.getEntriesByType('navigation')[0];
        const paint = performance.getEntriesByType('paint').find((p) => p.name === 'first-contentful-paint');
        const inspect = window.__nookInspect || {};
        const resources = performance.getEntriesByType('resource');
        const host = location.host;
        const bytesByType = {};
        let total = 0, third = 0;
        const sized = resources.map((r) => {
            const bytes = r.transferSize || r.encodedBodySize || 0;
            bytesByType[r.initiatorType] = (bytesByType[r.initiatorType] || 0) + bytes;
            total += bytes;
            try { if (new URL(r.name).host !== host) { third += bytes; } } catch (e) {}
            return { url: r.name, bytes: bytes, ms: Math.round(r.duration) };
        });
        const round = (v) => (v == null ? null : Math.round(v));
        return JSON.stringify({
            ttfb: nav ? round(nav.responseStart) : null,
            fcp: paint ? round(paint.startTime) : null,
            lcp: inspect.lcp != null ? round(inspect.lcp) : null,
            domReady: nav ? round(nav.domContentLoadedEventEnd) : null,
            load: nav ? round(nav.loadEventEnd) : null,
            documentBytes: nav ? (nav.transferSize || nav.encodedBodySize || 0) : 0,
            requests: resources.length,
            bytesByType: bytesByType,
            totalBytes: total,
            thirdPartyShare: total ? Math.round(third / total * 100) : 0,
            heaviest: sized.slice().sort((a, b) => b.bytes - a.bytes).slice(0, 5),
            slowest: sized.slice().sort((a, b) => b.ms - a.ms).slice(0, 5)
        });
    })()
    """#

    /// The audit for one width. Width-independent rules run once, at 1280.
    static func audit(width: Int, phone: Bool) -> String {
        "(\(auditSource))(\(width), \(phone ? "true" : "false"))"
    }

    /// A JPEG of the visible page, at most `maxWidth` pixels wide.
    @MainActor static func shot(_ webView: WKWebView, maxWidth: CGFloat) async throws -> Data {
        let config = WKSnapshotConfiguration()
        let scale = webView.window?.backingScaleFactor ?? 2
        config.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, maxWidth / scale)))
        let image = try await webView.takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            throw NSError(domain: "InspectScripts", code: 1, userInfo: [NSLocalizedDescriptionKey: "snapshot encoding failed"])
        }
        return jpeg
    }

    // MARK: - Sources

    private static let captureSource = #"""
    // Nook Inspect Capture
    (function () {
        if (window.__nookInspect) { return; }
        const state = { console: [], errors: [], failed: [], lcp: null };
        Object.defineProperty(window, '__nookInspect', { value: state });
        const keep = (list, value) => { if (list.length < 200) { list.push(String(value).slice(0, 500)); } };
        for (const level of ['error', 'warn']) {
            const original = console[level];
            console[level] = function () {
                keep(state.console, level + ': ' + Array.from(arguments).map((a) => {
                    try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); }
                }).join(' '));
                return original.apply(this, arguments);
            };
        }
        window.addEventListener('error', (event) => {
            const target = event.target;
            if (target && target !== window && (target.src || target.href)) {
                keep(state.failed, (target.tagName || 'resource').toLowerCase() + ' ' + (target.src || target.href));
            } else {
                keep(state.errors, (event.message || 'error') + (event.filename ? ' @ ' + event.filename + ':' + event.lineno : ''));
            }
        }, true);
        window.addEventListener('unhandledrejection', (event) => {
            const reason = event.reason;
            keep(state.errors, 'unhandled rejection: ' + (reason && reason.message ? reason.message : String(reason)));
        });
        const fetchOriginal = window.fetch;
        if (fetchOriginal) {
            window.fetch = function () {
                const url = String(arguments[0] && arguments[0].url ? arguments[0].url : arguments[0]);
                return fetchOriginal.apply(this, arguments).then((response) => {
                    if (response.status >= 400) { keep(state.failed, 'fetch ' + response.status + ' ' + url); }
                    return response;
                }, (error) => { keep(state.failed, 'fetch failed ' + url); throw error; });
            };
        }
        const open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
            this.addEventListener('loadend', () => {
                if (this.status >= 400 || this.status === 0) { keep(state.failed, 'xhr ' + (this.status || 'failed') + ' ' + url); }
            });
            return open.apply(this, arguments);
        };
        try {
            new PerformanceObserver((list) => {
                const entries = list.getEntries();
                if (entries.length) { state.lcp = entries[entries.length - 1].startTime; }
            }).observe({ type: 'largest-contentful-paint', buffered: true });
        } catch (e) {}
    })();
    """#

    private static let auditSource = #"""
    function (width, phone) {
        const findings = [];
        const unassessable = [];
        const ARABIC = /[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]/;
        const ARABIC_ALL = /[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]/g;
        const LATIN_RUN = /[A-Za-z][A-Za-z .\-]{2,}/;
        const add = (severity, rule, el, message, fix, perWidth) => {
            const finding = { severity: severity, rule: rule, message: message };
            if (el) { finding.selector = sel(el); }
            if (fix) { finding.fix = fix; }
            if (perWidth) { finding.width = width; }
            findings.push(finding);
        };
        function sel(el) {
            if (!el || el.nodeType !== 1) { return ''; }
            if (el.id) { return el.tagName.toLowerCase() + '#' + el.id; }
            const cls = Array.from(el.classList).slice(0, 2).map((c) => '.' + c).join('');
            const own = el.tagName.toLowerCase() + cls;
            const parent = el.parentElement;
            if (!parent || parent === document.body || parent === document.documentElement) { return own; }
            return sel(parent).split(' > ').slice(-1)[0] + ' > ' + own;
        }
        function visible(el) {
            const style = getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) { return false; }
            const rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
        }
        function ownText(el) {
            let text = '';
            for (const node of el.childNodes) { if (node.nodeType === 3) { text += node.textContent; } }
            return text.trim();
        }
        const all = Array.from(document.body ? document.body.getElementsByTagName('*') : []);

        // Per width: overflow, clipped text, tap targets.
        const doc = document.scrollingElement || document.documentElement;
        if (doc.scrollWidth > doc.clientWidth + 1) {
            add('error', 'overflow', null, 'Page is wider than the screen (' + doc.scrollWidth + ' px > ' + doc.clientWidth + ' px)', 'find the element that is too wide; see the following lines', true);
            let shown = 0;
            for (const el of all) {
                if (shown >= 10) { break; }
                const style = getComputedStyle(el);
                if (style.position === 'fixed') { continue; }
                const rect = el.getBoundingClientRect();
                if (rect.width > 0 && (rect.right > doc.clientWidth + 1) && rect.left < doc.clientWidth && visible(el)) {
                    const parentRect = el.parentElement ? el.parentElement.getBoundingClientRect() : null;
                    if (parentRect && parentRect.right > doc.clientWidth + 1 && el.parentElement !== document.body) { continue; }
                    add('error', 'overflow', el, 'Reaches past the right edge (' + Math.round(rect.right) + ' px)', 'max-width: 100% or allow it to wrap', true);
                    shown++;
                }
            }
        }
        let clipped = 0;
        for (const el of all) {
            if (clipped >= 10) { break; }
            const style = getComputedStyle(el);
            if (!(style.overflowX === 'hidden' || style.overflowX === 'clip') || style.textOverflow === 'ellipsis') { continue; }
            if (el.scrollWidth > el.clientWidth + 1 && (el.textContent || '').trim() && visible(el)) {
                add('warning', 'clipped-text', el, 'Text is cut off (' + el.scrollWidth + ' px of text in ' + el.clientWidth + ' px)', 'let it wrap, or add text-overflow: ellipsis', true);
                clipped++;
            }
        }
        if (phone) {
            let small = 0;
            const controls = Array.from(document.querySelectorAll('a[href], button, input:not([type=hidden]), select, textarea, [role=button]'));
            for (const el of controls) {
                if (small >= 10) { break; }
                if (!visible(el)) { continue; }
                if (el.tagName === 'A' && el.parentElement && ownText(el.parentElement)) { continue; }
                const rect = el.getBoundingClientRect();
                if (rect.width < 44 || rect.height < 44) {
                    add('warning', 'tap-target', el, 'Tap target ' + Math.round(rect.width) + ' × ' + Math.round(rect.height) + ' px, under 44 × 44', 'give it at least 44 × 44 px of tappable area', true);
                    small++;
                }
            }
        }
        if (width !== 1280) { return JSON.stringify({ findings: findings, unassessable: unassessable }); }

        // Once, at 1280.
        function rgba(value) {
            const m = value.match(/rgba?\(([^)]+)\)/);
            if (!m) { return null; }
            const p = m[1].split(/[\s,\/]+/).filter(Boolean).map(Number);
            return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
        }
        function over(top, bottom) {
            const a = top.a + bottom.a * (1 - top.a);
            if (a === 0) { return { r: 255, g: 255, b: 255, a: 1 }; }
            return {
                r: (top.r * top.a + bottom.r * bottom.a * (1 - top.a)) / a,
                g: (top.g * top.a + bottom.g * bottom.a * (1 - top.a)) / a,
                b: (top.b * top.a + bottom.b * bottom.a * (1 - top.a)) / a, a: a
            };
        }
        function background(el) {
            const layers = [];
            for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
                const style = getComputedStyle(node);
                if (style.backgroundImage && style.backgroundImage !== 'none') { return null; }
                const color = rgba(style.backgroundColor);
                if (color && color.a > 0) { layers.push(color); if (color.a >= 1) { break; } }
            }
            let result = { r: 255, g: 255, b: 255, a: 1 };
            for (let i = layers.length - 1; i >= 0; i--) { result = over(layers[i], result); }
            return result;
        }
        function lum(c) {
            const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
            return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
        }
        function ratio(a, b) { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }
        function hex(c) { return '#' + [c.r, c.g, c.b].map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join(''); }
        function passing(fg, bg, needed) {
            const toward = lum(bg) > 0.5 ? 0 : 255;
            for (let step = 1; step <= 40; step++) {
                const t = step / 40;
                const c = { r: fg.r + (toward - fg.r) * t, g: fg.g + (toward - fg.g) * t, b: fg.b + (toward - fg.b) * t, a: 1 };
                if (ratio(c, bg) >= needed) { return hex(c); }
            }
            return hex({ r: toward, g: toward, b: toward });
        }
        const texts = all.filter((el) => ownText(el) && !['SCRIPT', 'STYLE', 'NOSCRIPT'].includes(el.tagName) && visible(el));
        const textCap = 400;
        if (texts.length > textCap) { unassessable.push('contrast: checked the first ' + textCap + ' of ' + texts.length + ' text elements'); }
        let overImage = 0;
        for (const el of texts.slice(0, textCap)) {
            const style = getComputedStyle(el);
            const fg = rgba(style.color);
            const bg = background(el);
            if (!fg) { continue; }
            if (!bg) { if (overImage < 10) { unassessable.push('contrast: text over an image or gradient: ' + sel(el)); } overImage++; continue; }
            const size = parseFloat(style.fontSize);
            const large = size >= 24 || (size >= 18.66 && Number(style.fontWeight) >= 700);
            const needed = large ? 3 : 4.5;
            const value = ratio(over(fg, bg), bg);
            if (value < needed) {
                add('error', 'contrast', el, 'Text contrast ' + value.toFixed(2) + ':1, needs ' + needed + ':1', 'use ' + passing(fg, bg, needed) + ' on ' + hex(bg));
            }
        }
        if (overImage > 10) { unassessable.push('contrast: ' + (overImage - 10) + ' more text elements over images or gradients'); }

        for (const img of Array.from(document.images)) {
            const hiddenFromAT = img.getAttribute('aria-hidden') === 'true' || img.getAttribute('role') === 'presentation';
            if (!img.hasAttribute('alt') && !hiddenFromAT) { add('error', 'image-alt', img, 'Image has no alt text', 'add alt="…" (or alt="" if decorative)'); }
            if (img.complete && img.currentSrc && img.naturalWidth === 0) { add('error', 'image-broken', img, 'Image failed to load: ' + img.currentSrc.slice(0, 200)); continue; }
            const rect = img.getBoundingClientRect();
            if (rect.width > 0 && img.naturalWidth > rect.width * devicePixelRatio * 2) {
                add('advice', 'image-oversized', img, 'Image is ' + img.naturalWidth + ' px wide but shown at ' + Math.round(rect.width) + ' px', 'serve about ' + Math.round(rect.width * devicePixelRatio) + ' px wide');
            }
            if (!img.getAttribute('width') && !img.getAttribute('height') && getComputedStyle(img).aspectRatio === 'auto' && visible(img)) {
                add('advice', 'image-unsized', img, 'Image has no size, so the page may jump while it loads', 'add width and height attributes');
            }
        }

        const controls = Array.from(document.querySelectorAll('button, a[href], input:not([type=hidden]), select, textarea, [role=button]'));
        const controlCap = 200;
        if (controls.length > controlCap) { unassessable.push('control names: checked the first ' + controlCap + ' of ' + controls.length + ' controls'); }
        function accessibleName(el) {
            const label = el.getAttribute('aria-label');
            if (label && label.trim()) { return label.trim(); }
            const by = el.getAttribute('aria-labelledby');
            if (by) { const text = by.split(/\s+/).map((id) => (document.getElementById(id) || {}).textContent || '').join(' ').trim(); if (text) { return text; } }
            if (el.labels && el.labels.length) { const text = Array.from(el.labels).map((l) => l.textContent).join(' ').trim(); if (text) { return text; } }
            if (el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type) && el.value) { return el.value; }
            const text = (el.textContent || '').trim();
            if (text) { return text; }
            const img = el.querySelector && el.querySelector('img[alt]');
            if (img && img.getAttribute('alt').trim()) { return img.getAttribute('alt'); }
            return (el.getAttribute('title') || el.getAttribute('placeholder') || '').trim();
        }
        for (const el of controls.slice(0, controlCap)) {
            if (!visible(el) && el.tagName !== 'BUTTON') { continue; }
            if (!accessibleName(el)) { add('error', 'control-name', el, el.tagName.toLowerCase() + ' has no accessible name', 'add visible text or aria-label'); }
        }

        if (document.fonts) {
            for (const face of Array.from(document.fonts)) {
                if (face.status === 'error') { add('warning', 'font-failed', null, 'Font failed to load: ' + face.family, 'check the font URL and its CORS headers'); }
            }
        }

        // Arabic traps and right-to-left text.
        const MONO = /monospace|mono\b|menlo|courier|consolas|monaco/i;
        for (const el of texts) {
            const text = ownText(el);
            if (!ARABIC.test(text)) { continue; }
            const style = getComputedStyle(el);
            const letters = text.replace(/[^\p{L}]/gu, '').length || 1;
            const arabicShare = (text.match(ARABIC_ALL) || []).length / letters;
            if (style.textAlign === 'justify') { add('warning', 'arabic-justify', el, 'Justified Arabic text: stretching breaks the joins between letters', 'text-align: start'); }
            if (MONO.test(style.fontFamily)) { add('warning', 'arabic-monospace', el, 'Arabic in a monospace font (' + style.fontFamily.split(',')[0] + ') renders badly', 'use a proportional font for Arabic'); }
            if (arabicShare >= 0.5 && style.direction === 'ltr') { add('warning', 'arabic-ltr', el, 'Arabic text laid out left to right', 'dir="rtl" on it or an ancestor'); }
            if (style.direction === 'rtl' && LATIN_RUN.test(text)) {
                add('advice', 'latin-leak', el, 'A Latin run sits bare inside right-to-left text: punctuation may jump sides', 'wrap the Latin run in <bdi> or <span dir="ltr">');
            }
        }

        for (const el of Array.from(document.querySelectorAll('[hidden]'))) {
            if (getComputedStyle(el).display !== 'none') { add('warning', 'hidden-shown', el, 'Marked hidden but still shown: CSS overrides the hidden attribute', '[hidden] { display: none !important; }'); }
        }

        for (const frame of Array.from(document.querySelectorAll('iframe'))) {
            let reachable = false;
            try { reachable = !!frame.contentDocument; } catch (e) {}
            if (!reachable) { unassessable.push('cross-origin frame: ' + (frame.src || '(no src)').slice(0, 200)); }
        }
        unassessable.push('layout shift: WebKit reports no layout-shift entries');
        unassessable.push('Lighthouse score: Lighthouse runs only in Chrome');
        return JSON.stringify({ findings: findings, unassessable: unassessable });
    }
    """#
}
