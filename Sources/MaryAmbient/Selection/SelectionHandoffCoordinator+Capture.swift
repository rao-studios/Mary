//
//  SelectionHandoffCoordinator+Capture.swift
//  MaryBrain
//
//  WHAT: Invoke registered capture hooks when a source yields or a request needs the race barrier.
//  IN:   SelectionHandoffCoordinator.swift (split)
//  OUT:  CaptureOutcome → AmbientContextStore
//  PIN:  Transport ordering only — does not decide what the user's request means.
//

import AppKit
import ApplicationServices
import Foundation
import os

extension SelectionHandoffCoordinator {

    /// Whether this exact process still owns the source surface at the moment an Accessibility
    /// read finishes. This is transport ordering only: it rejects a stale read after another
    /// application has taken over; it does not decide what the user's request means.
    public func sourceStillOwnsFocus(applicationID: String, processID: pid_t) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.bundleIdentifier == applicationID
            && frontmost.processIdentifier == processID
    }

    /// Authorize an AX result *after* its potentially blocking read. An active source preflight
    /// (or Pages' live observer) may still be current while its source is frontmost.
    public func acceptsCapturedSelection(
        applicationID: String,
        processID: pid_t,
        trigger: CaptureTrigger,
        at now: Date = Date()
    ) -> Bool {
        let sourceOwnsFocus = sourceStillOwnsFocus(
            applicationID: applicationID, processID: processID)
        // A pending race barrier exists only to bridge source -> Mary. If the source still owns
        // focus, this is not that boundary; the explicit active-source preflight below is the only
        // path that may commit a hands-free selection in that state.
        if sourceOwnsFocus {
            return Self.captureResultIsAuthorized(
                trigger: trigger, sourceOwnsFocus: true, hasDeferredLease: false)
        }

        // A deferred handoff is intentionally only Page/TextEdit -> Mary, never Page/TextEdit ->
        // some unrelated app. Looking at this boundary protects the interval before AppKit has
        // delivered the new app's activation notification.
        guard let composerApplicationID = Bundle.main.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == composerApplicationID
        else { return false }
        return Self.captureResultIsAuthorized(
            trigger: trigger,
            sourceOwnsFocus: false,
            hasDeferredLease: acceptsDeferredSelectionEvent(
                applicationID: applicationID, at: now))
    }

    /// Pure policy seam for lifecycle ordering tests. Focus here is not a
    /// routing input; it is the source epoch check made after AX returns.
    public static func captureResultIsAuthorized(
        trigger: CaptureTrigger,
        sourceOwnsFocus: Bool,
        hasDeferredLease: Bool
    ) -> Bool {
        switch trigger {
        case .activeSourcePreflight:
            return sourceOwnsFocus
        case .sourceDeactivation:
            // Pages also uses this label for a live observer callback. The lifecycle method no longer
            // calls `capture` on deactivation, so allowing the source-frontmost observer case does not
            // reopen the source -> arbitrary-app handoff race.
            return sourceOwnsFocus || hasDeferredLease
        case .pendingRaceBarrier:
            return !sourceOwnsFocus && hasDeferredLease
        }
    }

    /// Capture the app that is actually still active at speech/request start. This closes the
    /// hands-free path: voice input does not necessarily bring Mary forward, so it may have no
    /// deactivation event to hand the highlight off.
    @discardableResult
    public func captureCurrentSource(
        applicationID: String?,
        composerApplicationID: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let applicationID,
              applicationID != composerApplicationID
        else { return false }
        return capture(applicationID: applicationID, trigger: .activeSourcePreflight)
    }

    /// Production adapter for the current source check.  The injectable
    /// overload above keeps its semantics testable without an NSWorkspace.
    @discardableResult
    public func captureFrontmostExternalSource() -> Bool {
        captureCurrentSource(
            applicationID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Async production preflight. The source id is sampled once before any
    /// awaited callback; post-read authorization inside each specialist then
    /// rejects a result if focus or the handoff lease changed meanwhile.
    @discardableResult
    public func captureFrontmostExternalSourceAsync() async -> Bool {
        guard let applicationID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              applicationID != Bundle.main.bundleIdentifier
        else { return false }
        return await captureAsync(
            applicationID: applicationID,
            trigger: .activeSourcePreflight)
    }

    /// Register an application-agnostic source-selection ability. This is the
    /// bridge that lets a generic text surface hand its highlight off before
    /// Mary takes focus, without turning every running app into a plugin.
    @discardableResult
    public func registerAnySource(
        capture: @escaping @Sendable (String, CaptureTrigger) -> CaptureOutcome
    ) -> UUID {
        let id = UUID()
        anySourceBox.withLock { $0[id] = capture }
        return id
    }

    /// Compatibility adapter for generic abilities which either published a
    /// selection or found no evidence.
    @discardableResult
    public func registerAnySource(
        capture: @escaping @Sendable (String, CaptureTrigger) -> Bool
    ) -> UUID {
        registerAnySource { applicationID, trigger -> CaptureOutcome in
            capture(applicationID, trigger) ? .published : .noEvidence
        }
    }

    /// Convenience for generic abilities that need no special caret handling.
    @discardableResult
    public func registerAnySource(
        capture: @escaping @Sendable (String) -> Bool
    ) -> UUID {
        registerAnySource { applicationID, _ in capture(applicationID) }
    }

    /// Deliver a lifecycle handoff to the source app's registered abilities. A dedicated
    /// representation gets the first attempt.
    @discardableResult
    public func captureOutcome(
        applicationID: String?,
        trigger: CaptureTrigger = .sourceDeactivation
    ) -> CaptureOutcome {
        guard let applicationID else { return .noEvidence }
        let callbacks = box.withLock { registrations in
            registrations[applicationID].map { Array($0.values) } ?? []
        } + familyBox.withLock { registrations in
            registrations.flatMap { prefix, callbacks in
                ApplicationRegistration.isInFamily(
                    applicationID.lowercased(), prefix: prefix)
                    ? Array(callbacks.values) : []
            }
        }
        var outcome: CaptureOutcome = .noEvidence
        for callback in callbacks {
            // Invoke every registered representation even after one has handled the source; a second
            // observer can still perform its source-local lifecycle work. Combine afterward so only an
            // all-`noEvidence` specialist set reaches the generic ability.
            outcome = CaptureOutcome.combining(outcome, callback(trigger))
        }
        guard outcome == .noEvidence else { return outcome }
        let genericCallbacks = anySourceBox.withLock { Array($0.values) }
        for callback in genericCallbacks {
            outcome = CaptureOutcome.combining(
                outcome, callback(applicationID, trigger))
        }
        return outcome
    }

    /// Async source delivery used only at the request boundary. Every specialist still gets its
    /// source-local lifecycle attempt; generic AX fallback runs only if both synchronous and
    /// asynchronous specialists report no positive evidence.
    @discardableResult
    public func captureOutcomeAsync(
        applicationID: String?,
        trigger: CaptureTrigger = .sourceDeactivation
    ) async -> CaptureOutcome {
        guard let applicationID else { return .noEvidence }
        let callbacks = box.withLock { registrations in
            registrations[applicationID].map { Array($0.values) } ?? []
        } + familyBox.withLock { registrations in
            registrations.flatMap { prefix, callbacks in
                ApplicationRegistration.isInFamily(
                    applicationID.lowercased(), prefix: prefix)
                    ? Array(callbacks.values) : []
            }
        }
        let asyncCallbacks = asyncBox.withLock { registrations in
            registrations[applicationID].map { Array($0.values) } ?? []
        }
        var outcome: CaptureOutcome = .noEvidence
        for callback in callbacks {
            outcome = CaptureOutcome.combining(outcome, callback(trigger))
        }
        for callback in asyncCallbacks {
            outcome = CaptureOutcome.combining(outcome, await callback(trigger))
        }
        guard outcome == .noEvidence else { return outcome }
        let genericCallbacks = anySourceBox.withLock { Array($0.values) }
        for callback in genericCallbacks {
            outcome = CaptureOutcome.combining(
                outcome, callback(applicationID, trigger))
        }
        return outcome
    }

    @discardableResult
    public func captureAsync(
        applicationID: String?,
        trigger: CaptureTrigger = .sourceDeactivation
    ) async -> Bool {
        await captureOutcomeAsync(
            applicationID: applicationID,
            trigger: trigger).handled
    }

    /// Boolean compatibility for lifecycle callers that only need to know whether some source
    /// ability claimed the interaction. A specialist's intentional abstention counts as
    /// claimed, specifically so it suppresses generic fallback.
    @discardableResult
    public func capture(
        applicationID: String?,
        trigger: CaptureTrigger = .sourceDeactivation
    ) -> Bool {
        captureOutcome(applicationID: applicationID, trigger: trigger).handled
    }

}
