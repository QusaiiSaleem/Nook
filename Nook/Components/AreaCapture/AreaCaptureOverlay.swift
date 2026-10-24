// Licensed under GPL-3.0. See LICENSE.
//
//  AreaCaptureOverlay.swift
//  Nook
//
//  Capture Area: the page freezes as a snapshot; drag a box or click an element, then mark the
//  picture up with arrows and highlights and copy or save it. The overlay is a subview of the
//  page's own web view, so its points are the page's points (the compositor never touches a web
//  view's subviews, and split panes need nothing extra). Wording approved by Qusai (2026-10-24).
//

import AppKit
import NookDesign
import NookUI
import SwiftUI
import WebKit

@MainActor
@Observable
final class AreaCaptureSession {
    enum Stage { case selecting, marking }
    enum Tool { case arrow, highlight }
    enum Result { case copy(Data), save(Data), cancel }

    let snapshot: CGImage
    /// Snapshot pixels per page point.
    let scale: CGFloat
    let size: CGSize
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var onFinish: (Result) -> Void = { _ in }

    var stage = Stage.selecting
    var hover: CGRect?
    var drag: (start: CGPoint, end: CGPoint)?
    var crop: CGRect?
    var marks: [CaptureMark] = []
    var draft: CaptureMark?
    var tool = Tool.arrow
    @ObservationIgnored private var hoverInFlight = false
    /// The latest pointer position while a lookup runs, asked next so the outline never lags.
    @ObservationIgnored private var pendingHover: CGPoint?

    init(snapshot: CGImage, scale: CGFloat, size: CGSize, webView: WKWebView) {
        self.snapshot = snapshot
        self.scale = scale
        self.size = size
        self.webView = webView
    }

    /// The element under `point` on the live page, outlined while the pointer rests there.
    func hover(at point: CGPoint) {
        guard stage == .selecting, drag == nil, let webView else { return }
        guard !hoverInFlight else { return pendingHover = point }
        hoverInFlight = true
        let zoom = webView.pageZoom
        webView.callAsyncJavaScript(
            """
            const el = document.elementFromPoint(x, y);
            if (!el || el === document.documentElement || el === document.body) { return null; }
            const r = el.getBoundingClientRect();
            return [r.left, r.top, r.width, r.height];
            """,
            arguments: ["x": point.x / zoom, "y": point.y / zoom], in: nil,
            in: WKContentWorld.world(name: "NookAreaCapture")
        ) { [weak self] result in
            guard let self else { return }
            self.hoverInFlight = false
            if case .success(let value) = result, let r = value as? [Double], r.count == 4 {
                let rect = CGRect(x: r[0] * zoom, y: r[1] * zoom, width: r[2] * zoom, height: r[3] * zoom)
                    .intersection(CGRect(origin: .zero, size: self.size))
                self.hover = rect.isEmpty ? nil : rect
            } else {
                self.hover = nil
            }
            if let next = self.pendingHover {
                self.pendingHover = nil
                self.hover(at: next)
            }
        }
    }

    func select(_ rect: CGRect) {
        let bounded = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard bounded.width >= 4, bounded.height >= 4 else { return }
        crop = bounded
        drag = nil
        hover = nil
        stage = .marking
    }

    func finish(_ action: (Data) -> Result) {
        guard let crop,
              let image = AreaCaptureRenderer.render(
                snapshot, crop: crop, scale: scale, marks: marks,
                arrowColor: NSColor(NookDesign.Surface.danger).cgColor,
                highlightColor: NSColor(NookDesign.Surface.captureHighlight).cgColor),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return onFinish(.cancel) }
        onFinish(action(png))
    }
}

/// Hosts the overlay over a web view. Input stays out of the live page under the picture, so
/// what the person frames is what they see; the capture ends if the page leaves its window or
/// changes size.
final class AreaCaptureHost: NSHostingView<AreaCaptureView> {
    private static let hosts = NSHashTable<AreaCaptureHost>.weakObjects()
    var onCancel: () -> Void = {}
    private var settledSize: CGSize?
    private var cancelled = false

    /// Ends any capture over a page in `window` (`BrowserManager.escapePressed`). True if one was open.
    static func cancel(in window: NSWindow) -> Bool {
        let open = hosts.allObjects.filter { $0.window === window }
        open.forEach { $0.cancel() }
        return !open.isEmpty
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { return cancel() }
        Self.hosts.add(self)
        settledSize = frame.size
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let settledSize, settledSize != newSize { cancel() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel() }
    }
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
}

struct AreaCaptureView: View {
    @Bindable var session: AreaCaptureSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: session.snapshot, scale: session.scale)
                .resizable()
                .frame(width: session.size.width, height: session.size.height)
            switch session.stage {
            case .selecting: selecting
            case .marking: marking
            }
        }
        .frame(width: session.size.width, height: session.size.height, alignment: .topLeading)
    }

    // MARK: - Selecting

    private var selecting: some View {
        ZStack(alignment: .topLeading) {
            NookDesign.Surface.scrim.opacity(0.5)
            if let rect = session.drag.map({ CGRect(from: $0.start, to: $0.end) }) ?? session.hover {
                outline(rect)
            }
            Text("Drag to select an area, or click an element. Esc to cancel.")
                .font(NookDesign.Font.secondary)
                .padding(.horizontal, NookDesign.Spacing.md)
                .padding(.vertical, NookDesign.Spacing.sm)
                .nookFloatingSurface(in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.top, NookDesign.Spacing.lg)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let point) = phase { session.hover(at: point) }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if value.translation.width.magnitude > 3 || value.translation.height.magnitude > 3 {
                        session.drag = (value.startLocation, value.location)
                    }
                }
                .onEnded { value in
                    if let drag = session.drag {
                        session.select(CGRect(from: drag.start, to: drag.end))
                    } else if let hover = session.hover {
                        session.select(hover)
                    }
                    session.drag = nil
                }
        )
    }

    private func outline(_ rect: CGRect) -> some View {
        Image(decorative: session.snapshot, scale: session.scale)
            .resizable()
            .frame(width: session.size.width, height: session.size.height)
            .mask(alignment: .topLeading) { Rectangle().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY) }
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            .allowsHitTesting(false)
    }

    // MARK: - Marking

    @ViewBuilder
    private var marking: some View {
        if let crop = session.crop {
            ZStack(alignment: .topLeading) {
                NookDesign.Surface.scrim
                    .mask { Rectangle().overlay(alignment: .topLeading) {
                        Rectangle().frame(width: crop.width, height: crop.height).offset(x: crop.minX, y: crop.minY)
                            .blendMode(.destinationOut)
                    } }
                Canvas { context, _ in
                    for mark in session.marks + [session.draft].compactMap({ $0 }) { draw(mark, in: &context) }
                }
                .frame(width: crop.width, height: crop.height)
                .contentShape(Rectangle())
                .gesture(markGesture)
                .offset(x: crop.minX, y: crop.minY)
                toolbar
                    .offset(x: max(NookDesign.Spacing.sm, min(crop.minX, session.size.width - 280)),
                            y: crop.maxY + 52 < session.size.height ? crop.maxY + NookDesign.Spacing.sm
                                                                   : max(NookDesign.Spacing.sm, crop.minY - 44))
            }
        }
    }

    private var markGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                switch session.tool {
                case .arrow:
                    session.draft = .arrow(from: value.startLocation, to: value.location)
                case .highlight:
                    if case .highlight(let points) = session.draft {
                        session.draft = .highlight(points + [value.location])
                    } else {
                        session.draft = .highlight([value.startLocation, value.location])
                    }
                }
            }
            .onEnded { _ in
                if let draft = session.draft { session.marks.append(draft) }
                session.draft = nil
            }
    }

    private func draw(_ mark: CaptureMark, in context: inout GraphicsContext) {
        var path = Path()
        switch mark {
        case .arrow(let from, let to):
            let (left, right) = AreaCaptureRenderer.arrowHead(from: from, to: to, length: CaptureMark.arrowHeadLength)
            path.move(to: from)
            path.addLine(to: to)
            path.move(to: left)
            path.addLine(to: to)
            path.addLine(to: right)
            context.stroke(path, with: .color(NookDesign.Surface.danger),
                           style: StrokeStyle(lineWidth: CaptureMark.arrowWidth, lineCap: .round, lineJoin: .round))
        case .highlight(let points):
            guard let first = points.first else { return }
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
            context.stroke(path, with: .color(NookDesign.Surface.captureHighlight),
                           style: StrokeStyle(lineWidth: CaptureMark.highlightWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private var toolbar: some View {
        HStack(spacing: NookDesign.Spacing.xxs) {
            tool(.arrow, "Arrow", "arrow.up.right")
            tool(.highlight, "Highlight", "highlighter")
            Button("Undo", systemImage: "arrow.uturn.backward") { _ = session.marks.popLast() }
                .help("Undo")
                .disabled(session.marks.isEmpty)
            Divider().frame(height: NookDesign.Size.iconButton / 2)
            Button("Copy", systemImage: "doc.on.doc") { session.finish { .copy($0) } }.help("Copy")
            Button("Save", systemImage: "square.and.arrow.down") { session.finish { .save($0) } }.help("Save")
            Button("Cancel", systemImage: "xmark") { session.onFinish(.cancel) }.help("Cancel")
        }
        .labelStyle(.iconOnly)
        .nookIconButtons()
        .padding(NookDesign.Spacing.xs)
        .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.lg))
    }

    private func tool(_ tool: AreaCaptureSession.Tool, _ name: String, _ icon: String) -> some View {
        Button(name, systemImage: icon) { session.tool = tool }
            .help(name)
            .nookRowSelection(session.tool == tool, radius: NookDesign.Radius.md)
    }
}

private extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
