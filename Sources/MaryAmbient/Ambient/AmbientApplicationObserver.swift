//
//  AmbientApplicationObserver.swift
//  MaryAmbient
//
//  WHAT: Eyes a registered application earned — poll the declared perception contract.
//  IN:   ApplicationRegistration.hasEyes
//  OUT:  AmbientContextStore.replacePerceived
//  PIN:  One lane per sighted registration, on its declared cadence.
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
        var place: AmbientPlace
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

    /// Re-derives the lane set from the live registry.
    public func activate() {
        let sighted = AmbientApplicationIndexProvider.current.all.filter(\.hasEyes)
        var retired: [AmbientPlace] = []
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
        let retired: [AmbientPlace] = lanesBox.withLock { lanes in
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
        enum StoreAction { case replace(AmbientPlace, TimeInterval), retract(AmbientPlace), none }
        let action: StoreAction = lanesBox.withLock { lanes in
            guard var current = lanes[registrationID] else { return .none }
            defer { lanes[registrationID] = current }
            if facts != nil {
                current.misses = 0
                return .replace(current.place, current.freshFor)
            }
            current.misses += 1
            // The app is gone or the read is broken. Between here and the next success, Mary holds
            // nothing — a stale outline standing as live sight is the lie this component exists to
            // end, not to automate.
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
