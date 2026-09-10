//
//  CanvasService.swift
//  MaryPlugin
//
//  WHAT: The canvas engine — which pages are up, what each one said, and the
//        stage lease they share.
//  IN:   CanvasPlugin (the Skills), DanceEngine (a plugin with a beat)
//  OUT:  CanvasSnapshot + CanvasEvent
//  PIN:  ONE LEASE FOR EVERY PAGE. The stage is held while anything is
//        showing and released the moment nothing is, so a later stage Skill
//        from any package clears the canvas rather than acting behind it.
//        A REFUSAL IS A SENTENCE. Every "no" here names why, so a plugin can
//        say it back and a probe can print it.
//

import CoreGraphics
import Foundation
import MaryComputerUse
import os

public struct CanvasWindowRecord: Sendable, Equatable {
    public var id: CanvasWindowID
    public var title: String
    public var placement: CanvasPlacement
    public var ready: Bool
    public var showing: Bool
    public var preparedAt: Date
}

public struct CanvasSnapshot: Sendable, Equatable {
    public var windows: [CanvasWindowRecord]
    public var holdsStage: Bool
    public var lastRefusal: CanvasRefusal?
    public var recent: [String]

    public var showing: [CanvasWindowRecord] { windows.filter(\.showing) }
}

public enum CanvasEvent: Sendable, Equatable {
    case prepared(CanvasReceipt, title: String)
    case shown(CanvasWindowID)
    case hidden(CanvasWindowID)
    case dismissed(CanvasWindowID, by: CanvasDismissal)
    case refused(CanvasRefusal)
    case stage(held: Bool)
}

/// Mary's canvas: the windows she draws in to show something.
public actor CanvasService {

    public struct Seams: Sendable {
        public var windows: any CanvasWindowing
        /// How long a page gets to say it is ready before it is shown anyway
        /// (with `ready: false` on its receipt) or refused by a caller that
        /// demands readiness.
        public var readyBound: Duration
        public var now: @Sendable () -> Date
        /// Whose stage the canvas holds. The process's, in production; a test
        /// gets its own, because the shared one is preempted by whichever
        /// suite runs beside it.
        public var stage: StageArbiter

        public init(
            windows: any CanvasWindowing,
            readyBound: Duration = .milliseconds(1500),
            now: @escaping @Sendable () -> Date = { Date() },
            stage: StageArbiter = .shared
        ) {
            self.windows = windows
            self.readyBound = readyBound
            self.now = now
            self.stage = stage
        }

        public static var live: Seams { Seams(windows: LiveCanvasWindows()) }
    }

    /// The canvas the app draws on. One per process: one screen.
    public static let live = CanvasService()

    private let seams: Seams
    private var records: [CanvasWindowID: CanvasWindowRecord] = [:]
    private var dismissHooks: [CanvasWindowID: @Sendable (CanvasWindowID, CanvasDismissal) -> Void] = [:]
    private var lease: UUID?
    private var lastRefusal: CanvasRefusal?
    private var recent: [String] = []
    private var observers: [UUID: AsyncStream<CanvasEvent>.Continuation] = [:]

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "canvas")

    public init(seams: Seams = .live) {
        self.seams = seams
    }

    // MARK: - Monitoring

    public func snapshot() -> CanvasSnapshot {
        CanvasSnapshot(
            windows: records.values.sorted { $0.preparedAt < $1.preparedAt },
            holdsStage: lease != nil,
            lastRefusal: lastRefusal,
            recent: recent)
    }

    public func events() -> AsyncStream<CanvasEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CanvasEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func emit(_ event: CanvasEvent) {
        let line: String
        switch event {
        case .prepared(let receipt, let title):
            line = "prepared \(receipt.id) \"\(title)\" ready=\(receipt.ready)"
                + (receipt.timedOut ? " (no report)" : "")
        case .shown(let id): line = "shown \(id)"
        case .hidden(let id): line = "hidden \(id)"
        case .dismissed(let id, let by): line = "dismissed \(id) by \(by)"
        case .refused(let refusal):
            lastRefusal = refusal
            line = "refused \(refusal.summary)"
        case .stage(let held): line = held ? "stage held" : "stage released"
        }
        recent.append(line)
        if recent.count > 64 { recent.removeFirst(recent.count - 64) }
        Self.log.info("\(line, privacy: .public)")
        for continuation in observers.values { continuation.yield(event) }
    }

    // MARK: - Showing a page

    /// What is up right now, oldest first.
    public func showing() -> [CanvasWindowID] {
        records.values.filter(\.showing).sorted { $0.preparedAt < $1.preparedAt }.map(\.id)
    }

    /// Prepare and show in one act — what a Skill wants.
    public func present(
        _ page: CanvasPage, placement: CanvasPlacement = .fullScreen,
        onDismiss: (@Sendable (CanvasWindowID, CanvasDismissal) -> Void)? = nil
    ) async -> Result<CanvasReceipt, CanvasRefusal> {
        switch await prepare(page, placement: placement, onDismiss: onDismiss) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let receipt):
            _ = await show(receipt.id, placement: placement)
            return .success(receipt)
        }
    }

    /// Load a page into a hidden window and hear what it says. The caller
    /// decides what `ready: false` means to it.
    public func prepare(
        _ page: CanvasPage, placement: CanvasPlacement = .fullScreen,
        onDismiss: (@Sendable (CanvasWindowID, CanvasDismissal) -> Void)? = nil
    ) async -> Result<CanvasReceipt, CanvasRefusal> {
        guard page.byteCount <= CanvasRefusal.pageByteLimit else {
            return .failure(refuse(.pageTooLarge(bytes: page.byteCount)))
        }
        guard await seams.windows.screenFrame() != nil else {
            return .failure(refuse(.noScreen))
        }
        if lease == nil {
            guard let acquired = await seams.stage.acquire(
                owner: "canvas", onPreempt: { [weak self] in
                    Task { await self?.preempted() }
                })
            else {
                let owner = seams.stage.currentOwner() ?? "something else"
                return .failure(refuse(.stageHeld(owner: owner)))
            }
            lease = acquired
            emit(.stage(held: true))
        }
        let id = CanvasWindowID()
        records[id] = CanvasWindowRecord(
            id: id, title: page.title, placement: placement, ready: false,
            showing: false, preparedAt: seams.now())
        if let onDismiss { dismissHooks[id] = onDismiss }
        let receipt = await seams.windows.prepare(
            page, id: id, placement: placement, readyBound: seams.readyBound,
            onDismiss: { [weak self] id in
                Task { await self?.dismissed(id, by: .click) }
            })
        records[id]?.ready = receipt.ready
        emit(.prepared(receipt, title: page.title))
        return .success(receipt)
    }

    /// The screen's frame, for a caller placing pages by hand.
    public func screenFrame() async -> CGRect? {
        await seams.windows.screenFrame()
    }

    @discardableResult
    public func show(_ id: CanvasWindowID, placement: CanvasPlacement? = nil) async -> Bool {
        guard var record = records[id] else {
            _ = refuse(.unknownWindow)
            return false
        }
        let where_ = placement ?? record.placement
        guard await seams.windows.show(id, placement: where_) else {
            records[id] = nil
            _ = refuse(.unknownWindow)
            return false
        }
        record.placement = where_
        record.showing = true
        records[id] = record
        emit(.shown(id))
        return true
    }

    public func hide(_ id: CanvasWindowID) async {
        guard records[id] != nil else { return }
        await seams.windows.hide(id)
        records[id]?.showing = false
        emit(.hidden(id))
    }

    /// Take one page down, for good.
    public func dismiss(_ id: CanvasWindowID) async -> Result<Void, CanvasRefusal> {
        guard records[id] != nil else { return .failure(refuse(.unknownWindow)) }
        await seams.windows.close(id)
        await dismissed(id, by: .caller)
        return .success(())
    }

    /// Take everything down. Says whether there was anything.
    @discardableResult
    public func dismissAll() async -> Bool {
        guard !records.isEmpty else { return false }
        await seams.windows.closeAll()
        for id in Array(records.keys) { await dismissed(id, by: .caller) }
        return true
    }

    // MARK: - Leaving

    private func preempted() async {
        guard !records.isEmpty else {
            releaseIfIdle()
            return
        }
        await seams.windows.closeAll()
        for id in Array(records.keys) { await dismissed(id, by: .preempt) }
    }

    private func dismissed(_ id: CanvasWindowID, by dismissal: CanvasDismissal) async {
        guard records.removeValue(forKey: id) != nil else { return }
        if dismissal == .click { await seams.windows.close(id) }
        emit(.dismissed(id, by: dismissal))
        if let hook = dismissHooks.removeValue(forKey: id) { hook(id, dismissal) }
        releaseIfIdle()
    }

    private func releaseIfIdle() {
        guard records.isEmpty, let lease else { return }
        seams.stage.release(lease)
        self.lease = nil
        emit(.stage(held: false))
    }

    private func refuse(_ refusal: CanvasRefusal) -> CanvasRefusal {
        emit(.refused(refusal))
        return refusal
    }
}
