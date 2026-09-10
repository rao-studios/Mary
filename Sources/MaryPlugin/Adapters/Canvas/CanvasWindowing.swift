//
//  CanvasWindowing.swift
//  MaryPlugin
//
//  WHAT: The windows behind the canvas — the seam, and the live WebKit one.
//  IN:   CanvasService
//  OUT:  CanvasWindowing / LiveCanvasWindows
//  PIN:  MARY'S OWN WINDOWS, NOT A BROWSER'S. A borderless window that never
//        becomes key, ordered front without activating Mary, so the person's
//        application keeps the keyboard. The page talks (one message handler)
//        and Mary listens; nothing here evaluates a script in the page.
//        THE CLICK IS THE ESCAPE HATCH. A full-screen page with no keyboard
//        focus must always be dismissable by hand, and a WKWebView swallows
//        mouse events — so a transparent view sits above it and takes the click.
//

import AppKit
import Foundation
import WebKit

/// Every window act the canvas performs, so a test can stand in for the screen.
public protocol CanvasWindowing: Sendable {
    /// The screen a page would go on, or nil when there is none.
    func screenFrame() async -> CGRect?
    /// Load the page into a hidden window and wait — up to `readyBound` — for
    /// it to report. `onDismiss` fires when the person closes it by hand.
    func prepare(
        _ page: CanvasPage, id: CanvasWindowID, placement: CanvasPlacement,
        readyBound: Duration, onDismiss: @escaping @Sendable (CanvasWindowID) -> Void
    ) async -> CanvasReceipt
    /// Put a prepared window on screen at `placement`. False when it is gone.
    func show(_ id: CanvasWindowID, placement: CanvasPlacement) async -> Bool
    /// Take a window off screen, keeping its page.
    func hide(_ id: CanvasWindowID) async
    /// Close a window for good.
    func close(_ id: CanvasWindowID) async
    func closeAll() async
}

// MARK: - Live

/// The real thing: one `NSWindow` per page, WebKit inside, on one process pool.
public final class LiveCanvasWindows: CanvasWindowing, @unchecked Sendable {

    public init() {}

    public func screenFrame() async -> CGRect? {
        await MainActor.run { NSScreen.main?.frame }
    }

    public func prepare(
        _ page: CanvasPage, id: CanvasWindowID, placement: CanvasPlacement,
        readyBound: Duration, onDismiss: @escaping @Sendable (CanvasWindowID) -> Void
    ) async -> CanvasReceipt {
        await CanvasWindowHost.shared.prepare(
            page, id: id, placement: placement, readyBound: readyBound, onDismiss: onDismiss)
    }

    public func show(_ id: CanvasWindowID, placement: CanvasPlacement) async -> Bool {
        await CanvasWindowHost.shared.show(id, placement: placement)
    }

    public func hide(_ id: CanvasWindowID) async {
        await CanvasWindowHost.shared.hide(id)
    }

    public func close(_ id: CanvasWindowID) async {
        await CanvasWindowHost.shared.close(id)
    }

    public func closeAll() async {
        await CanvasWindowHost.shared.closeAll()
    }
}

/// The main-actor owner of every canvas window.
@MainActor
final class CanvasWindowHost {

    static let shared = CanvasWindowHost()

    // ONE WEB-CONTENT PROCESS FOR ALL OF THEM is WebKit's own doing now —
    // `WKProcessPool` stopped meaning anything in macOS 12 — so a beat is an
    // `orderFront`, and the page was loaded while the window was still hidden.
    private var windows: [CanvasWindowID: CanvasWindow] = [:]

    private init() {}

    func prepare(
        _ page: CanvasPage, id: CanvasWindowID, placement: CanvasPlacement,
        readyBound: Duration, onDismiss: @escaping @Sendable (CanvasWindowID) -> Void
    ) async -> CanvasReceipt {
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let window = CanvasWindow(
            id: id, frame: placement.frame(on: screen), onDismiss: onDismiss)
        windows[id] = window
        let reported = await window.load(page, bound: readyBound)
        return CanvasReceipt(
            id: id, ready: reported?.ready ?? false, log: reported?.log,
            timedOut: reported == nil)
    }

    func show(_ id: CanvasWindowID, placement: CanvasPlacement) -> Bool {
        guard let window = windows[id] else { return false }
        let screen = NSScreen.main?.frame ?? window.frame
        window.setFrame(placement.frame(on: screen), display: true)
        // FRONT, NEVER ACTIVE. `makeKeyAndOrderFront` would pull Mary forward
        // and take the keyboard from whatever the person was typing into.
        window.orderFrontRegardless()
        return true
    }

    func hide(_ id: CanvasWindowID) {
        windows[id]?.orderOut(nil)
    }

    func close(_ id: CanvasWindowID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        window.tearDown()
    }

    func closeAll() {
        for id in Array(windows.keys) { close(id) }
    }
}

/// The page's one word back: `webkit.messageHandlers.canvas.postMessage({ready, log})`.
struct CanvasPageReport: Sendable, Equatable {
    var ready: Bool
    var log: String?
}

/// A borderless, floating, never-key window with one web view in it.
@MainActor
final class CanvasWindow: NSWindow {

    private let id: CanvasWindowID
    private let onDismiss: @Sendable (CanvasWindowID) -> Void
    private let webView: WKWebView
    private let handler = ReportHandler()
    private var continuation: CheckedContinuation<CanvasPageReport?, Never>?
    private var reported: CanvasPageReport?

    init(
        id: CanvasWindowID, frame: CGRect,
        onDismiss: @escaping @Sendable (CanvasWindowID) -> Void
    ) {
        self.id = id
        self.onDismiss = onDismiss
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(handler, name: "canvas")
        webView = WKWebView(frame: CGRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false

        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.autoresizingMask = [.width, .height]
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        content.addSubview(webView)
        // THE CLICK CATCHER, above the web view, which would otherwise take
        // the click and do nothing with it.
        let catcher = ClickCatcher(frame: content.bounds) { [weak self] in
            guard let self else { return }
            self.onDismiss(self.id)
        }
        catcher.autoresizingMask = [.width, .height]
        content.addSubview(catcher)
        contentView = content

        handler.onReport = { [weak self] report in
            guard let self else { return }
            self.reported = report
            self.continuation?.resume(returning: report)
            self.continuation = nil
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Load the page and wait for its word, or for the bound.
    func load(_ page: CanvasPage, bound: Duration) async -> CanvasPageReport? {
        webView.loadHTMLString(page.html, baseURL: nil)
        if let reported { return reported }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let seconds = Double(bound.components.seconds)
                + Double(bound.components.attoseconds) / 1e18
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(returning: nil)
            }
        }
    }

    func tearDown() {
        orderOut(nil)
        continuation?.resume(returning: nil)
        continuation = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "canvas")
        webView.stopLoading()
        webView.removeFromSuperview()
        close()
    }
}

/// Receives the page's report. A class of its own so the web view's content
/// controller (which retains its handlers) never retains the window.
private final class ReportHandler: NSObject, WKScriptMessageHandler {
    var onReport: ((CanvasPageReport) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        let body = message.body as? [String: Any] ?? [:]
        let ready = body["ready"] as? Bool ?? false
        let log = body["log"] as? String
        onReport?(CanvasPageReport(ready: ready, log: log))
    }
}

/// A transparent view that turns one click into a dismissal.
private final class ClickCatcher: NSView {
    private let onClick: () -> Void

    init(frame: CGRect, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The window is never key, so the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick() }
}
