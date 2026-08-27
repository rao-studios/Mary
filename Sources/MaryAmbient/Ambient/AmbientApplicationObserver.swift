//
//  AmbientApplicationObserver.swift
//  MaryAmbient
//
//  THE EYES A REGISTERED APPLICATION EARNED, FINALLY OPEN.
//
//  A package that declares a perception contract has said, and admission has
//  verified: here is a non-mutating operation you may run unattended, this
//  often. `ApplicationRegistration.hasEyes` has answered true for such an app
//  since the contract landed — and NOTHING POLLED. Every consumer of the
//  contract (the passage budget, the enum gate, the pane) was wired to a
//  claim no component made true: a Sketch fact aged out unless the model
//  happened to call a read skill, which is exactly the "live-looking card
//  over a document nothing reads" the admission validator exists to refuse.
//
//  This is the driver. One lane per sighted registration, each on its own
//  declared cadence, in the digest refresher's exact idiom:
//
//   - SLEEP FIRST, ALWAYS. The first tick lands one interval after
//     activation, never at it — activation happens at boot and on every
//     Settings save, and a poll storm at boot is the digest's documented
//     failure. The loop never awaits the work either: it pokes and sleeps,
//     so no hung read can wedge the cadence.
//   - COALESCED per lane: a poke that lands while a read runs marks pending
//     and collapses; everything that arrived during a run becomes one re-run.
//   - The WORK is installed, not known. This package cannot name the
//     executor that runs a `.mary` operation — that is the whole layering —
//     so the reader is a closure the brain installs, and until it is
//     installed the observer is a set of silent timers, honestly: no reader,
//     no claims.
//
//  A FAILING LANE RETRACTS. Three consecutive misses (the app quit, the tool
//  vanished, consent revoked) forget the lane's perceived facts rather than
//  leaving a stale outline standing as live knowledge. The lane keeps
//  polling — the app coming back is the common case — but between the
//  retraction and the next success, Mary honestly holds nothing.
//

import Foundation
import os

public final class AmbientApplicationObserver: @unchecked Sendable {

    public static let shared = AmbientApplicationObserver()

    /// What one poll does: run the registration's declared document operation
    /// and return the perceived facts it yields — or nil when the read could
    /// not be taken (app not running, tool unavailable, script failure).
    public typealias Reader = @Sendable (
        _ registrationID: String, _ documentOperation: String
    ) async -> [AmbientFact]?

    /// Misses before a lane's perceived facts are retracted.
    public static let missBudget = 3

    private let store: AmbientContextStore
    private let readerBox = OSAllocatedUnfairLock<Reader?>(initialState: nil)
    private let lanesBox = OSAllocatedUnfairLock<[String: Lane]>(initialState: [:])
    /// Test seam, the digest's `workOverride` precedent: what ONE poll does.
    /// Production wires the executor bridge; a test wires a counter, which is
    /// how cadence and retraction are pinned without timers or subprocesses.
    private let workOverride: (@Sendable (String) async -> Void)?

    private struct Lane {
        var registrationID: String
        var operation: String
        var pollSeconds: Int
        var freshFor: TimeInterval
        var place: AmbientRealm
        var task: Task<Void, Never>?
        var running = false
        var pending = false
        var misses = 0
    }

    public init(
        store: AmbientContextStore = .shared,
        workOverride: (@Sendable (String) async -> Void)? = nil
    ) {
        self.store = store
        self.workOverride = workOverride
    }

    /// Installed once by the layer that can name the executor. Idempotent;
    /// the last caller wins.
    public func installReader(_ read: @escaping Reader) {
        readerBox.withLock { $0 = read }
    }

    /// Re-derives the lane set from the live registry. Idempotent — called at
    /// boot and on every registry change; lanes whose registration kept its
    /// contract keep their timers (and their cadence phase), lanes whose
    /// registration vanished are cancelled and their perceived facts
    /// forgotten.
    public func activate() {
        let sighted = AmbientApplicationIndexProvider.current.all.filter(\.hasEyes)
        var retired: [AmbientRealm] = []
        lanesBox.withLock { lanes in
            var wanted: Set<String> = []
            for registration in sighted {
                guard let perception = registration.perception,
                      let operation = perception.documentOperation
                else { continue }
                wanted.insert(registration.id)
                if var lane = lanes[registration.id] {
                    // An edited package may have changed the cadence or the
                    // operation; the lane follows without losing its phase.
                    lane.operation = operation
                    lane.pollSeconds = perception.pollSeconds
                    lane.freshFor = TimeInterval(perception.pollSeconds) * 1.5
                    lane.place = registration.place
                    lanes[registration.id] = lane
                    continue
                }
                var lane = Lane(
                    registrationID: registration.id,
                    operation: operation,
                    pollSeconds: perception.pollSeconds,
                    freshFor: TimeInterval(perception.pollSeconds) * 1.5,
                    place: registration.place)
                lane.task = loop(registrationID: registration.id,
                                 pollSeconds: perception.pollSeconds)
                lanes[registration.id] = lane
            }
            for (id, lane) in lanes where !wanted.contains(id) {
                lane.task?.cancel()
                retired.append(lane.place)
                lanes[id] = nil
            }
        }
        for place in retired {
            store.forgetPerceived(place: place)
        }
    }

    /// Full stop: every lane cancelled, every lane's perceived facts
    /// forgotten. The observer never claims sight it no longer maintains.
    public func deactivate() {
        let retired: [AmbientRealm] = lanesBox.withLock { lanes in
            let places = lanes.values.map(\.place)
            for lane in lanes.values { lane.task?.cancel() }
            lanes.removeAll()
            return places
        }
        for place in retired {
            store.forgetPerceived(place: place)
        }
    }

    /// The lane's cadence: sleep first, poke, never await the work.
    private func loop(registrationID: String, pollSeconds: Int) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollSeconds) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.requestPoll(registrationID: registrationID)
            }
        }
    }

    /// COALESCED, NEVER STACKED — the digest's rule, per lane.
    func requestPoll(registrationID: String) {
        let shouldStart: Bool = lanesBox.withLock { lanes in
            guard var lane = lanes[registrationID] else { return false }
            if lane.running {
                lane.pending = true
                lanes[registrationID] = lane
                return false
            }
            lane.running = true
            lanes[registrationID] = lane
            return true
        }
        guard shouldStart else { return }
        Task { [weak self] in
            await self?.poll(registrationID: registrationID)
        }
    }

    private func poll(registrationID: String) async {
        if let workOverride {
            await workOverride(registrationID)
            finishPoll(registrationID: registrationID)
            return
        }
        guard let lane = lanesBox.withLock({ $0[registrationID] }),
              let read = readerBox.withLock({ $0 })
        else {
            finishPoll(registrationID: registrationID)
            return
        }
        let facts = await read(lane.registrationID, lane.operation)
        // Decide under the lock, ACT outside it — the store takes its own
        // lock, and the house rule (PassageRecipes' accessor) is that nothing
        // is invoked while one is held.
        enum StoreAction { case replace(AmbientRealm, TimeInterval), retract(AmbientRealm), none }
        let action: StoreAction = lanesBox.withLock { lanes in
            guard var current = lanes[registrationID] else { return .none }
            defer { lanes[registrationID] = current }
            if facts != nil {
                current.misses = 0
                return .replace(current.place, current.freshFor)
            }
            current.misses += 1
            // The app is gone or the read is broken. Between here and the
            // next success, Mary holds nothing — a stale outline standing
            // as live sight is the lie this component exists to end, not to
            // automate.
            return current.misses == Self.missBudget
                ? .retract(current.place) : .none
        }
        switch action {
        case .replace(let place, let freshFor):
            // Perceived truth replaces perceived truth; asked-for facts and
            // other lanes are untouched — `replacePerceived` is lane-scoped
            // by construction.
            store.replacePerceived(
                world: place.world,
                application: place.application,
                with: (facts ?? []).map { fact in
                    var stamped = fact
                    stamped.freshFor = freshFor
                    return stamped
                })
        case .retract(let place):
            store.forgetPerceived(place: place)
        case .none:
            break
        }
        finishPoll(registrationID: registrationID)
    }

    private func finishPoll(registrationID: String) {
        let rerun: Bool = lanesBox.withLock { lanes in
            guard var lane = lanes[registrationID] else { return false }
            lane.running = false
            let pending = lane.pending
            lane.pending = false
            lanes[registrationID] = lane
            return pending
        }
        if rerun { requestPoll(registrationID: registrationID) }
    }

    // MARK: - Test seams

    public var laneIDsForTesting: [String] {
        lanesBox.withLock { Array($0.keys).sorted() }
    }

    func missesForTesting(_ registrationID: String) -> Int {
        lanesBox.withLock { $0[registrationID]?.misses ?? -1 }
    }
}
