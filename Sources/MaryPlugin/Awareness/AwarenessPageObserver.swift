//
//  AwarenessPageObserver.swift
//  MaryPlugin
//
//  WHAT: The standing brief for a page, and the interaction history that keeps
//        a browser in the conversation after the window behind it comes forward.
//  IN:   AwarenessPageResolver (shell via AX) + the engine's last read
//  OUT:  promptContribution → the browser place's section; FocusEvidence
//  PIN:  OFF THE TURN'S REFRESH BUDGET, exactly like `AwarenessObserver`, and
//        for the same reason: that 1 s window is shared by every sensing
//        observer and a page identity does not change in a second.
//        ATTENTION IS EARNED FROM INTERACTIONS, NOT FROM BEING FRONTMOST.
//        `stickyLead` and `admittedPlaceMentions` both key on `.activity`
//        evidence, and only the code, prose and corpus observers ever stamped
//        it — so a browser fell out of the conversation the moment any other
//        window came forward, taking every browsing skill out of the roster
//        with it. A page someone is actually moving through is real work, and
//        this is where the ledger is told so.
//        NO PIXELS ON A POLL. The shell is Accessibility; what is ON the page is
//        pixels, read only when a skill asks. What this DOES do on a navigation
//        is retract — offers from the page someone just left are worse than none.
//

import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation
import os

public final class AwarenessPageObserver: MaryObserver, @unchecked Sendable {

    public static let shared = AwarenessPageObserver()

    public let id = "awareness-page"

    /// `AwarenessObserver`'s cadence, for its reason.
    public static let pollSeconds: TimeInterval = 5

    /// What a watcher can see without waiting for a turn.
    public struct Snapshot: Sendable, Equatable {
        public var identity: String?
        public var brief: String?
        public var offers: Int
        public var rosterAge: TimeInterval?
        public var lastNavigation: Date?
    }

    private struct Settled: Equatable {
        var applicationID: String
        var identity: String
    }

    private let settledBox = OSAllocatedUnfairLock<Settled?>(initialState: nil)
    private let placeBox = OSAllocatedUnfairLock<AmbientPlace?>(initialState: nil)
    private let briefBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let lineBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let snapshotBox = OSAllocatedUnfairLock<Snapshot>(
        initialState: Snapshot(offers: 0))
    private let poller = SinglePollerClaim()
    private let inFlight = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let support: AwarenessSupport

    /// Injected so a test can drive a page without a browser, and so the poll
    /// never reaches for a global the caller cannot stand in for.
    private let site: @Sendable (Date) async -> AwarenessPageSite?
    private let onNavigation: @Sendable (AmbientPlace, String?) async -> Void

    public init(
        support: AwarenessSupport = .shared,
        site: (@Sendable (Date) async -> AwarenessPageSite?)? = nil,
        onNavigation: (@Sendable (AmbientPlace, String?) async -> Void)? = nil
    ) {
        self.support = support
        self.site = site ?? { now in
            // THE ROSTER A SKILL ALREADY PRODUCED, never a fresh look.
            let engine = await BrowserEngine.live.snapshot()
            let roster = engine.lastRoster.map { ($0, $0.capturedAt) }
            return AwarenessPageResolver.resolve(roster: roster, now: now)
        }
        self.onNavigation = onNavigation ?? { place, bundleID in
            // THE PAGE THEY LEFT IS NOT ON OFFER ANY MORE. Mary retracts on her
            // OWN navigations already; this is the other half — the person
            // clicking a link themselves, which nothing was watching for.
            await BrowserEngine.live.retractSlate()
            // AND THIS IS REAL WORK IN A PLACE. See the file header.
            WorkspaceFocusTracker.shared.noteWork(place: place, processBundleID: bundleID)
        }
    }

    // MARK: - MaryObserver

    public var observedPlace: AmbientPlace? { placeBox.withLock { $0 } }

    public func promptContribution() -> String? { briefBox.withLock { $0 } }

    /// One line when the page did not lead — demotion is volume, not erasure.
    public var ambientLine: String? { lineBox.withLock { $0 } }

    public var holdsWholeDocument: Bool { false }

    /// EMPTY ON PURPOSE — see the file header.
    public var ambientSenses: Set<AmbientSense> { [] }

    public func snapshot() -> Snapshot { snapshotBox.withLock { $0 } }

    public func activate() async {
        poller.claim { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.pollSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.pollOnce()
            }
        }
        Task { [weak self] in await self?.pollOnce() }
    }

    public func deactivate() async {
        poller.release()
        retract()
    }

    // MARK: - The poll

    public func pollOnce(at now: Date = Date()) async {
        let entered = inFlight.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard entered else { return }
        defer { inFlight.withLock { $0 = false } }

        guard support.all.contains(where: \.hasWebSurface) else {
            retract()
            return
        }
        guard let site = await site(now) else {
            retract()
            return
        }

        let place = AmbientPlaceResolver.browserPlace
        let settled = Settled(
            applicationID: site.registration.applicationID,
            identity: site.identity)
        let previous = settledBox.withLock { $0 }
        // THEY WENT SOMEWHERE. Not Mary — she retracts on her own navigations
        // inside the engine — so this is the person browsing, which is both a
        // reason to drop the old offers and evidence they are working here.
        var navigated = false
        if previous?.identity != settled.identity, previous != nil || site.roster != nil {
            navigated = previous != nil
            if navigated {
                await onNavigation(place, site.registration.bundleIdentifiers.first)
            }
        }

        let brief = AwarenessBrief.page(
            shell: site.shell,
            // A ROSTER FROM THE PAGE THEY JUST LEFT DESCRIBES NOTHING HERE.
            roster: navigated ? nil : site.roster,
            age: navigated ? nil : site.rosterAge,
            browser: site.registration.displayName)
        settledBox.withLock { $0 = settled }
        placeBox.withLock { $0 = place }
        briefBox.withLock { $0 = brief }
        lineBox.withLock {
            $0 = "Browsing \(site.shell.siteName ?? site.registration.displayName)"
                + (site.shell.title.map { " — \"\($0)\"" } ?? "") + "."
        }
        snapshotBox.withLock {
            $0 = Snapshot(
                identity: settled.identity,
                brief: brief,
                offers: navigated ? 0 : (site.roster?.actionable.count ?? 0),
                rosterAge: navigated ? nil : site.rosterAge,
                lastNavigation: navigated ? now : $0.lastNavigation)
        }
        let line = "awareness-page — \(settled.identity)"
            + " offers=\(navigated ? 0 : (site.roster?.actionable.count ?? 0))"
            + (navigated ? " navigated" : "")
        TurnLog.logger.info("\(line, privacy: .public)")
    }

    /// Test seam, mirroring `AwarenessObserver.adoptStandingBriefForTests`.
    func adoptStandingBriefForTests(place: AmbientPlace, brief: String) {
        placeBox.withLock { $0 = place }
        briefBox.withLock { $0 = brief }
    }

    private func retract() {
        settledBox.withLock { $0 = nil }
        placeBox.withLock { $0 = nil }
        briefBox.withLock { $0 = nil }
        lineBox.withLock { $0 = nil }
        snapshotBox.withLock { $0 = Snapshot(offers: 0) }
    }
}
