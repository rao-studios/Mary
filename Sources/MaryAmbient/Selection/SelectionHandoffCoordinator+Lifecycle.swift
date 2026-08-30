//
//  SelectionHandoffCoordinator+Lifecycle.swift
//  MaryBrain
//
//  WHAT: Workspace activation bookkeeping for source-owned selection capture.
//  IN:   SelectionHandoffCoordinator.swift (split)
//  OUT:  pendingSource / capture on yield
//  PIN:  No source is read until it yields focus or a request needs the short race barrier.
//

import AppKit
import ApplicationServices
import Foundation
import os

extension SelectionHandoffCoordinator {

    /// The runtime observed an ordinary source application become active.
    /// This is bookkeeping only; no source is read until it yields focus or a
    /// request needs the short race barrier below.
    public func noteSourceActivated(applicationID: String?, at _: Date = Date()) {
        lifecycleBox.withLock { state in
            // A notification without an app identity still establishes that the prior source is no
            // longer trustworthy. Keeping it would let the next composer activation retry an unrelated
            // old highlight simply because AppKit omitted metadata.
            state.lastSourceApplicationID = applicationID
            state.pendingSource = nil
        }
    }

    /// Mary's request surface became active. Arm the source that was most recently observed
    /// active for one short pre-turn retry.
    public func noteComposerActivated(at now: Date = Date()) {
        lifecycleBox.withLock { state in
            // A matched deactivation has already armed the exact source. Do
            // not replace it with a looser activation-age guess merely
            // because AppKit delivered the two notifications in this order.
            if let pending = state.pendingSource, pending.expiresAt >= now {
                return
            }
            guard let source = state.lastSourceApplicationID else {
                state.pendingSource = nil
                return
            }
            state.pendingSource = (
                applicationID: source,
                expiresAt: now.addingTimeInterval(Self.preTurnCaptureWindow))
        }
    }

    /// Source deactivation is the usual handoff signal. It leaves the same source available for
    /// the narrowly bounded pre-turn retry, but does NOT read it here. `didDeactivate` is
    /// delivered while AppKit can still report the source as frontmost.
    public func noteSourceDeactivated(applicationID: String?, at now: Date = Date()) {
        guard let applicationID else { return }
        lifecycleBox.withLock { state in
            // AppKit can deliver an old deactivation after a newer app has already activated.
            guard state.lastSourceApplicationID == applicationID else {
                return
            }
            state.pendingSource = (
                applicationID: applicationID,
                expiresAt: now.addingTimeInterval(Self.preTurnCaptureWindow))
        }
    }

    /// A terminated process can no longer answer the bounded retry. Forget it
    /// from lifecycle bookkeeping; the runtime separately invalidates that
    /// process's raw handoff in `AmbientContextStore`.
    public func noteSourceTerminated(applicationID: String?) {
        guard let applicationID else { return }
        lifecycleBox.withLock { state in
            if state.lastSourceApplicationID == applicationID {
                state.lastSourceApplicationID = nil
            }
            if state.pendingSource?.applicationID == applicationID {
                state.pendingSource = nil
            }
        }
    }

    /// Called synchronously immediately before a brain turn snapshots ambient selection. It is
    /// intentionally one-shot: this is a source-to-composer transition barrier, never a
    /// periodic remembered-focus heuristic.
    public func capturePendingSource(at now: Date = Date()) {
        let pending = lifecycleBox.withLock { state -> (applicationID: String, expiresAt: Date)? in
            guard let pending = state.pendingSource else { return nil }
            guard pending.expiresAt >= now else {
                // `pending` was just unwrapped while holding this lock, so
                // this is the lease we are expiring; there is no optional
                // timestamp to compare again.
                state.pendingSource = nil
                if state.lastSourceApplicationID == pending.applicationID {
                    state.lastSourceApplicationID = nil
                }
                return nil
            }
            // Keep the lease live while its synchronous AX callback runs. If a different source
            // activates during that read, activation clears the lease and the callback's post-read
            // authorization rejects the result.
            return pending
        }
        guard let pending else { return }
        _ = capture(applicationID: pending.applicationID, trigger: .pendingRaceBarrier)
        lifecycleBox.withLock { state in
            // Consume only the exact lease we captured. A later activation or
            // deactivation may have replaced it while AX was reading.
            if state.pendingSource?.applicationID == pending.applicationID,
               state.pendingSource?.expiresAt == pending.expiresAt {
                state.pendingSource = nil
                // This was one request's one-shot bridge. Do not let a later
                // activation of Mary with no intervening external source
                // recreate the old app as a fresh handoff candidate.
                if state.lastSourceApplicationID == pending.applicationID {
                    state.lastSourceApplicationID = nil
                }
            }
        }
    }

    /// Async request-boundary counterpart used by the brain turn.
    public func capturePendingSourceAsync(at now: Date = Date()) async {
        let pending = lifecycleBox.withLock { state -> (
            applicationID: String, expiresAt: Date
        )? in
            guard let pending = state.pendingSource else { return nil }
            guard pending.expiresAt >= now else {
                state.pendingSource = nil
                if state.lastSourceApplicationID == pending.applicationID {
                    state.lastSourceApplicationID = nil
                }
                return nil
            }
            return pending
        }
        guard let pending else { return }
        _ = await captureAsync(
            applicationID: pending.applicationID,
            trigger: .pendingRaceBarrier)
        lifecycleBox.withLock { state in
            if state.pendingSource?.applicationID == pending.applicationID,
               state.pendingSource?.expiresAt == pending.expiresAt {
                state.pendingSource = nil
                if state.lastSourceApplicationID == pending.applicationID {
                    state.lastSourceApplicationID = nil
                }
            }
        }
    }

    /// Whether a delayed source-observer callback may still describe the interaction currently
    /// being handed to Mary. This is ordering containment, not focus routing: it never chooses
    /// a world or a representation.
    public func acceptsDeferredSelectionEvent(
        applicationID: String?, at now: Date = Date()
    ) -> Bool {
        guard let applicationID else { return false }
        return lifecycleBox.withLock { state in
            guard state.lastSourceApplicationID == applicationID,
                  let pending = state.pendingSource
            else { return false }
            guard pending.applicationID == applicationID,
                  pending.expiresAt >= now
            else {
                if pending.expiresAt < now {
                    state.pendingSource = nil
                    if state.lastSourceApplicationID == applicationID {
                        state.lastSourceApplicationID = nil
                    }
                }
                return false
            }
            return true
        }
    }

}
