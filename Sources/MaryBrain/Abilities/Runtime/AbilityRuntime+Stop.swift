//
//  AbilityRuntime+Stop.swift
//  MaryBrain
//
//  WHAT: One in-flight call, and the request to stop it.
//  IN:   the Stop chip (by run id)
//  OUT:  cancellation asked of the running worker
//  PIN:  Cancelling a Task is a REQUEST, not a guarantee — the run records
//        what actually happened, never what was asked for.
//
import Foundation

extension AbilityRuntime {

    /// Ask one running call to stop. Safe after settle — a late stop is not an error.
    public func cancelRun(id: String) {
        let cancel = inFlightRuns.withLock { runs -> (@Sendable () -> Void)? in
            guard var run = runs[id] else { return nil }
            run.stopRequested = true
            runs[id] = run
            return run.cancel
        }
        cancel?()
    }

    /// Which calls are still running — the ids a Stop control may offer.
    public var runningRunIDs: Set<String> {
        Set(inFlightRuns.withLock { $0.keys })
    }

    /// Register this call's canceller; nil when nested (stop the owner).
    func registerInFlight(
        _ cancel: @escaping @Sendable () -> Void
    ) -> String? {
        guard let identity = RunContext.runID else { return nil }
        inFlightRuns.withLock { $0[identity] = InFlightRun(cancel: cancel) }
        return identity
    }

    func releaseInFlight(_ identity: String?) {
        guard let identity else { return }
        inFlightRuns.withLock { $0[identity] = nil }
    }

    func wasStopRequested(_ identity: String?) -> Bool {
        guard let identity else { return false }
        return inFlightRuns.withLock { $0[identity]?.stopRequested ?? false }
    }
}
