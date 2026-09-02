//
//  AwarenessObserver.swift
//  MaryPlugin
//
//  WHAT: The standing brief — what the unit in front of the user IS, and what
//        reaches it, held ready before anyone asks.
//  IN:   AwarenessSiteResolver (which reads what the surface observers publish)
//  OUT:  promptContribution → the lead place's full section, both lanes
//  PIN:  OFF THE TURN'S REFRESH BUDGET, and `ambientSenses` is deliberately
//        empty to keep it there: that 1 s window is shared by every sensing
//        observer, and a walk over a project has no business inside it. This
//        one settles on its own 5 s cadence instead, so its brief may be up
//        to a poll old — which is honest, because it describes the shape of
//        the work rather than the caret's exact position.
//        It opens no Accessibility connection of its own: the element it
//        reads through is the one `CodeSurfaceEditorCache` already holds, and
//        the file it is looking at is the one `DeclaredTextSightStore`
//        already published.
//

import Foundation
import MaryAmbient
import MaryFoundation
import os

public final class AwarenessObserver: MaryObserver, @unchecked Sendable {

    public static let shared = AwarenessObserver()

    public let id = "awareness"

    /// Human-scale, and the same cadence the caret and corpus observers
    /// settled on for the same reason.
    public static let pollSeconds: TimeInterval = 5

    /// What the last completed poll settled on.
    private struct Settled: Equatable {
        var applicationID: String
        var relativePath: String
        var unitName: String
        var unitLine: Int
    }

    private let settledBox = OSAllocatedUnfairLock<Settled?>(initialState: nil)
    private let placeBox = OSAllocatedUnfairLock<AmbientPlace?>(initialState: nil)
    private let briefBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let poller = SinglePollerClaim()
    private let inFlight = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let support: AwarenessSupport

    public init(support: AwarenessSupport = .shared) {
        self.support = support
    }

    // MARK: - MaryObserver

    /// The followed application, while a unit is standing. Nil when there is
    /// nothing to say, so this observer never enters the arbitration empty and
    /// takes a lead away from a place that has real work in it.
    public var observedPlace: AmbientPlace? {
        placeBox.withLock { $0 }
    }

    /// The bearings. Merged into the lead place's own section beside the caret
    /// window, which is why it carries no body of its own.
    public func promptContribution() -> String? {
        briefBox.withLock { $0 }
    }

    /// Nothing: this observer does not describe a place, it describes what is
    /// AROUND the work in one. A place that did not lead gets its identity
    /// line from the surface observer that owns it.
    public var ambientLine: String? { nil }

    public var holdsWholeDocument: Bool { false }

    /// EMPTY ON PURPOSE — see the file header. The 1 s per-turn refresh is for
    /// observers whose reading can go stale between a poll and a question; a
    /// neighbourhood does not change in a second, and pricing a project walk
    /// into every turn would.
    public var ambientSenses: Set<AmbientSense> { [] }

    public func activate() async {
        poller.claim { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.pollSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.pollOnce()
            }
        }
        // PRIMED, BUT NOT ON THE LAUNCH PATH. The other observers read one
        // window and return in milliseconds; this one may walk a whole
        // repository the first time, and the composition root awaits every
        // `activate()` in turn — so priming inline would hold app launch for
        // as long as the project is large. The first poll runs immediately,
        // beside the boot rather than inside it, and the brief appears a
        // moment later; the poll loop's own first tick is a sleep away.
        Task { [weak self] in self?.pollOnce() }
    }

    public func deactivate() async {
        poller.release()
        retract()
    }

    // MARK: - The poll

    public func pollOnce(at now: Date = Date()) {
        let entered = inFlight.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard entered else { return }
        defer { inFlight.withLock { $0 = false } }

        guard !support.all.isEmpty else { return }
        guard let site = AwarenessSiteResolver.resolve(support: support) else {
            retract()
            return
        }
        guard let root = site.root, let corpus = site.corpus else {
            // Followed, but with no project to walk. Honest silence: the
            // caret window still describes the file.
            retract()
            return
        }
        guard let unit = AwarenessAdapter.unit(at: site, symbol: nil) else {
            retract()
            return
        }

        let settled = Settled(
            applicationID: site.registration.applicationID,
            relativePath: site.relativePath,
            unitName: unit.name,
            unitLine: unit.startLine)
        // SAME UNIT, SAME ANSWER. Tracing a project costs real work; the user
        // moving the caret within one function is not new work.
        if settledBox.withLock({ $0 }) == settled, briefBox.withLock({ $0 }) != nil {
            return
        }

        let declarations = CorpusDeclarationIndexCache.shared.index(
            root: root, corpus: corpus, at: now)
        let callers = CorpusTracer.callers(
            of: unit.name, root: root, corpus: corpus,
            declarations: declarations, at: now)
        let callees = CorpusTracer.callees(
            in: unit.body, own: unit.name, corpus: corpus,
            declarations: declarations, in: site.relativePath)

        let place = AmbientPlace.application(site.registration.applicationID)
        settledBox.withLock { $0 = settled }
        placeBox.withLock { $0 = place }
        briefBox.withLock {
            $0 = AwarenessBrief.standing(
                unit: unit, fileName: site.fileName,
                callers: callers, callees: callees,
                complete: declarations.isComplete)
        }
        let line = "awareness — \(unit.display) in \(site.fileName)"
            + " callers=\(callers.count) callees=\(callees.count)"
        TurnLog.logger.info("\(line, privacy: .public)")
    }

    /// Test seam: a standing brief without Accessibility or a project.
    func adoptStandingBriefForTests(place: AmbientPlace, brief: String) {
        placeBox.withLock { $0 = place }
        briefBox.withLock { $0 = brief }
    }

    private func retract() {
        settledBox.withLock { $0 = nil }
        placeBox.withLock { $0 = nil }
        briefBox.withLock { $0 = nil }
    }
}

/// The support bundle, matching the other observers' shape.
public enum AwarenessObserverSupport {
    public static var all: [any MaryObserver] { [AwarenessObserver.shared] }
}
