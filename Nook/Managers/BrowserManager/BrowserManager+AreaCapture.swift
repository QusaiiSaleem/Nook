// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+AreaCapture.swift
//  Nook
//
//  Capture Area: freezes the page the window shows and puts the selection and markup overlay
//  (`AreaCaptureView`) over it. The result is copied, or saved through the downloads list like
//  Capture Full Page.
//

import AppKit
import NookWeb
import SwiftUI
import WebKit

extension BrowserManager {
    func captureArea(in windowState: BrowserWindowState) {
        guard let session = tabs.selectedSession(in: windowState), let webView = session.webView, webView.window != nil,
              !webView.subviews.contains(where: { $0 is AreaCaptureHost }) else { return }
        webView.takeSnapshot(with: WKSnapshotConfiguration()) { [weak self] image, _ in
            guard let image else { return }
            self?.presentAreaCapture(image, over: webView, session: session, windowState: windowState)
        }
    }

    private func presentAreaCapture(_ image: NSImage, over webView: WKWebView, session: PageSession, windowState: BrowserWindowState) {
        guard webView.window != nil, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let size: CGSize = webView.bounds.size
        let capture = AreaCaptureSession(snapshot: cgImage, scale: CGFloat(cgImage.width) / size.width, size: size, webView: webView)
        let host = AreaCaptureHost(rootView: AreaCaptureView(session: capture))
        host.frame = webView.bounds
        host.autoresizingMask = [.width, .height]
        host.onCancel = { [weak host] in host?.removeFromSuperview() }
        // Weak: a capture left open when its tab or window closes must not keep the page alive.
        capture.onFinish = { [weak self, weak host, weak webView, weak session] (result: AreaCaptureSession.Result) in
            host?.cancel()
            guard let self, let webView, let session else { return }
            self.finishAreaCapture(result, session: session, webView: webView, windowState: windowState)
        }
        webView.addSubview(host)
        webView.window?.makeFirstResponder(host)
    }

    private func finishAreaCapture(_ result: AreaCaptureSession.Result, session: PageSession, webView: WKWebView, windowState: BrowserWindowState) {
        switch result {
        case .copy(let png):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        case .save(let png):
            downloadManager.saveCompletedFile(png, suggestedFilename: Self.captureFilename(for: session), originalURL: session.url, from: webView.window)
        case .cancel:
            return
        }
        showCaptureToast("Area captured", in: windowState)
    }
}
