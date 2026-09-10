//
//  SelectionHandoffCoordinator+Registration.swift
//  MaryBrain
//
//  WHAT: Register / unregister source-owned selection capture hooks.
//  IN:   application abilities
//  OUT:  SelectionHandoffCoordinator (boxes)
//
import AppKit
import ApplicationServices
import Foundation
import os

extension SelectionHandoffCoordinator {


    /// Register an application's source-owned capture hook. More than one
    /// ability may subscribe to an application, so teardown is token-based.
    @discardableResult
    public func register(
        applicationID: String,
        capture: @escaping @Sendable (CaptureTrigger) -> CaptureOutcome
    ) -> UUID {
        let id = UUID()
        box.withLock { registrations in
            registrations[applicationID, default: [:]][id] = capture
        }
        return id
    }

    /// Register one specialist for a validated bundle-identifier family.
    /// Package admission owns validation; this coordinator only applies the
    /// shared boundary-aware membership predicate at lifecycle delivery.
    @discardableResult
    public func register(
        applicationFamilyPrefix: String,
        capture: @escaping @Sendable (CaptureTrigger) -> CaptureOutcome
    ) -> UUID {
        let id = UUID()
        familyBox.withLock { registrations in
            registrations[applicationFamilyPrefix.lowercased(), default: [:]][id]
                = capture
        }
        return id
    }

    /// Register a request-boundary source capture that may await a bounded application
    /// transaction.
    @discardableResult
    public func registerAsync(
        applicationID: String,
        capture: @escaping @Sendable (CaptureTrigger) async -> CaptureOutcome
    ) -> UUID {
        let id = UUID()
        asyncBox.withLock { registrations in
            registrations[applicationID, default: [:]][id] = capture
        }
        return id
    }

    /// Compatibility adapter for simple source abilities. Returning `false`
    /// means this ability saw no source evidence; specialists that need to
    /// preserve an unreadable/ambiguous result use the outcome overload.
    @discardableResult
    public func register(
        applicationID: String,
        capture: @escaping @Sendable (CaptureTrigger) -> Bool
    ) -> UUID {
        register(applicationID: applicationID) { trigger -> CaptureOutcome in
            capture(trigger) ? .published : .noEvidence
        }
    }

    /// Convenience for representations whose result does not depend on the
    /// lifecycle trigger. Kept so simple third-party plugins can adopt the
    /// handoff contract without learning its caret-clear distinction.
    @discardableResult
    public func register(
        applicationID: String,
        capture: @escaping @Sendable () -> Bool
    ) -> UUID {
        register(applicationID: applicationID) { _ in capture() }
    }

    public func unregister(_ id: UUID) {
        box.withLock { registrations in
            for applicationID in Array(registrations.keys) {
                registrations[applicationID]?[id] = nil
                if registrations[applicationID]?.isEmpty == true {
                    registrations[applicationID] = nil
                }
            }
        }
        asyncBox.withLock { registrations in
            for applicationID in Array(registrations.keys) {
                registrations[applicationID]?[id] = nil
                if registrations[applicationID]?.isEmpty == true {
                    registrations[applicationID] = nil
                }
            }
        }
        anySourceBox.withLock { $0[id] = nil }
        familyBox.withLock { registrations in
            for prefix in Array(registrations.keys) {
                registrations[prefix]?[id] = nil
                if registrations[prefix]?.isEmpty == true {
                    registrations[prefix] = nil
                }
            }
        }
    }

}
