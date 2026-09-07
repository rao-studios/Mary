//
//  CanvasFakes.swift
//  MaryPluginTests
//
//  WHAT: The canvas's window seam, faked — shared by every suite that drives
//        a CanvasService or a DanceEngine without a screen.
//  OUT:  FakeCanvasWindows, CanvasFixtures.service
//  PIN:  ONE SET OF FAKES, the browsing suites' rule. Receipts are scripted by
//        page title, so a test says which page fails and which is silent.
//

import CoreGraphics
import Foundation
import MaryComputerUse
import Testing
@testable import MaryPlugin

final class FakeCanvasWindows: CanvasWindowing, @unchecked Sendable {
    /// A page whose title is here reports `ready: false` with this log.
    var failing: [String: String] = [:]
    /// A page whose title is here never reports at all.
    var silent: Set<String> = []
    /// A page whose title is here fails ONCE, then reads fine — a repair.
    var failOnce: [String: String] = [:]
    /// The most windows visible at any one time.
    private(set) var peakVisible = 0
    private var visible: Set<CanvasWindowID> = []
    var screen: CGRect? = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private(set) var prepared: [(id: CanvasWindowID, title: String, placement: CanvasPlacement)] = []
    private(set) var shown: [(id: CanvasWindowID, placement: CanvasPlacement)] = []
    private(set) var hidden: [CanvasWindowID] = []
    private(set) var closed: [CanvasWindowID] = []
    private(set) var closeAllCalls = 0
    private var dismissers: [CanvasWindowID: @Sendable (CanvasWindowID) -> Void] = [:]
    private var live: Set<CanvasWindowID> = []
    private let lock = NSLock()

    func screenFrame() async -> CGRect? { screen }

    func prepare(
        _ page: CanvasPage, id: CanvasWindowID, placement: CanvasPlacement,
        readyBound: Duration, onDismiss: @escaping @Sendable (CanvasWindowID) -> Void
    ) async -> CanvasReceipt {
        lock.lock(); defer { lock.unlock() }
        prepared.append((id, page.title, placement))
        dismissers[id] = onDismiss
        live.insert(id)
        if silent.contains(page.title) {
            return CanvasReceipt(id: id, ready: false, log: nil, timedOut: true)
        }
        if let log = failing[page.title] {
            return CanvasReceipt(id: id, ready: false, log: log)
        }
        if let log = failOnce.removeValue(forKey: page.title) {
            return CanvasReceipt(id: id, ready: false, log: log)
        }
        return CanvasReceipt(id: id, ready: true)
    }

    func show(_ id: CanvasWindowID, placement: CanvasPlacement) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard live.contains(id) else { return false }
        shown.append((id, placement))
        visible.insert(id)
        peakVisible = max(peakVisible, visible.count)
        return true
    }

    func hide(_ id: CanvasWindowID) async {
        lock.lock(); defer { lock.unlock() }
        hidden.append(id)
        visible.remove(id)
    }

    func close(_ id: CanvasWindowID) async {
        lock.lock(); defer { lock.unlock() }
        closed.append(id)
        live.remove(id)
        visible.remove(id)
        dismissers[id] = nil
    }

    func closeAll() async {
        lock.lock(); defer { lock.unlock() }
        closeAllCalls += 1
        closed.append(contentsOf: live)
        live.removeAll()
        visible.removeAll()
        dismissers.removeAll()
    }

    /// The person clicks a window.
    func click(_ id: CanvasWindowID) {
        let dismisser: (@Sendable (CanvasWindowID) -> Void)?
        lock.lock()
        dismisser = dismissers[id]
        lock.unlock()
        dismisser?(id)
    }

    var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return live.count
    }
}

enum CanvasFixtures {
    /// A service over fake windows and ITS OWN stage — the shared one is
    /// preempted by whatever suite runs beside this one.
    static func service(
        windows: FakeCanvasWindows = FakeCanvasWindows(),
        stage: StageArbiter = StageArbiter()
    ) -> CanvasService {
        CanvasService(seams: .init(
            windows: windows, readyBound: .milliseconds(10), stage: stage))
    }

    static func page(_ title: String) -> CanvasPage {
        CanvasPage(title: title, html: "<title>\(title)</title><p>\(title)</p>")
    }
}
