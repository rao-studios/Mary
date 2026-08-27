//
//  SchemaSignalModels.swift
//  MaryBrain
//
//  Split out of SchemaSignalRuntime.swift (docs/DECOMPOSITION.md Wave 2) —
//  pure relocation, no declaration changed.
//

import MaryFoundation
import Foundation
import os

public enum SchemaSignalRuntimeError: LocalizedError, Sendable, Equatable {
    case unknownInteraction(InteractionID)
    case unknownPerception(PerceptionID)
    case unavailableAdapter(AdapterID)
    case undeclaredInteraction(AdapterID, InteractionID)
    case undeclaredPerception(AdapterID, PerceptionID)
    case wrongValueType(expected: ValueTypeID, actual: ValueTypeID)
    case invalidValue([ValueValidationIssue])
    case invalidScope(SourceResolution)
    case invalidEvidence(String)
    case ownershipMismatch(InteractionOwnership)
    case privacyMismatch(required: DataPrivacyClass, actual: DataPrivacyClass)
    case unsupportedClearPolicy(InteractionClearPolicy)

    public var errorDescription: String? {
        switch self {
        case .unknownInteraction(let id):
            return "Interaction schema \(id.rawValue) is not active."
        case .unknownPerception(let id):
            return "Perception schema \(id.rawValue) is not active."
        case .unavailableAdapter(let id):
            return "Adapter \(id.rawValue) is not installed and available."
        case .undeclaredInteraction(let adapter, let interaction):
            return "Adapter \(adapter.rawValue) does not publish \(interaction.rawValue)."
        case .undeclaredPerception(let adapter, let perception):
            return "Adapter \(adapter.rawValue) does not publish \(perception.rawValue)."
        case .wrongValueType(let expected, let actual):
            return "Expected Value type \(expected.rawValue), received \(actual.rawValue)."
        case .invalidValue(let issues):
            return issues.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
        case .invalidScope(let resolution):
            return "The signal's \(resolution.rawValue) scope does not satisfy its schema."
        case .invalidEvidence(let channel):
            return "Evidence channel \(channel) is not declared by the Interaction schema."
        case .ownershipMismatch(let ownership):
            return "The Value scope does not prove the Interaction's \(ownership.rawValue) ownership."
        case .privacyMismatch(let required, let actual):
            return "Signal requires \(required.rawValue) privacy, received \(actual.rawValue)."
        case .unsupportedClearPolicy(let policy):
            return "The Interaction schema does not permit \(policy.rawValue) clearing."
        }
    }
}

/// A validated, source-owned Interaction instance. Payload stays private to
/// the execution path; diagnostics use `reference` only.
public struct RuntimeInteractionInstance: Sendable, Identifiable, Hashable {
    public var id: UUID { reference.id }
    public let reference: InteractionInstanceReference
    public let value: ValueEnvelope
    public let adapterID: AdapterID
    public let evidenceChannel: String
    public let evidenceRank: Int
    public let canAuthorizeMutation: Bool

    init(
        reference: InteractionInstanceReference,
        value: ValueEnvelope,
        adapterID: AdapterID,
        evidenceChannel: String,
        evidenceRank: Int,
        canAuthorizeMutation: Bool
    ) {
        self.reference = reference
        self.value = value
        self.adapterID = adapterID
        self.evidenceChannel = evidenceChannel
        self.evidenceRank = evidenceRank
        self.canAuthorizeMutation = canAuthorizeMutation
    }
}

public struct PerceptionInstanceReference: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let schemaID: PerceptionID
    public let scope: SourceScope
    public let capturedAt: Date
    public let expiresAt: Date
    public let valueDigest: String

    public init(
        id: UUID,
        schemaID: PerceptionID,
        scope: SourceScope,
        capturedAt: Date,
        expiresAt: Date,
        valueDigest: String
    ) {
        self.id = id
        self.schemaID = schemaID
        self.scope = scope
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.valueDigest = valueDigest
    }
}

public struct RuntimePerceptionInstance: Sendable, Identifiable, Hashable {
    public var id: UUID { reference.id }
    public let reference: PerceptionInstanceReference
    public let value: ValueEnvelope
    public let adapterID: AdapterID

    init(
        reference: PerceptionInstanceReference,
        value: ValueEnvelope,
        adapterID: AdapterID
    ) {
        self.reference = reference
        self.value = value
        self.adapterID = adapterID
    }
}

/// Immutable signal state for a turn. The registry may receive Bluetooth or
/// application updates concurrently, but routing and execution in this task
/// continue against this exact set.
public struct SchemaSignalTurnSnapshot: Sendable, Equatable {
    public let interactions: [RuntimeInteractionInstance]
    public let perceptions: [RuntimePerceptionInstance]

    public init(
        interactions: [RuntimeInteractionInstance] = [],
        perceptions: [RuntimePerceptionInstance] = []
    ) {
        self.interactions = interactions.sorted { lhs, rhs in
            if lhs.evidenceRank == rhs.evidenceRank {
                return lhs.reference.capturedAt > rhs.reference.capturedAt
            }
            return lhs.evidenceRank > rhs.evidenceRank
        }
        self.perceptions = perceptions.sorted {
            $0.reference.capturedAt > $1.reference.capturedAt
        }
    }

    public static let empty = SchemaSignalTurnSnapshot()

    public var interactionIDs: Set<InteractionID> {
        Set(interactions.map { $0.reference.schemaID })
    }

    public var perceptionIDs: Set<PerceptionID> {
        Set(perceptions.map { $0.reference.schemaID })
    }

    public func interactions(requiredBy skill: SkillSchema) -> [RuntimeInteractionInstance] {
        let required = Set(skill.requirements.interactions)
        guard !required.isEmpty else { return [] }
        return interactions.filter { required.contains($0.reference.schemaID) }
    }

    public func interactions(declaredBy skill: SkillSchema) -> [RuntimeInteractionInstance] {
        let declared = Set(
            skill.requirements.interactions
                + skill.requirements.optionalInteractions)
        guard !declared.isEmpty else { return [] }
        return interactions.filter { declared.contains($0.reference.schemaID) }
    }

    public func perceptions(declaredBy skill: SkillSchema) -> [RuntimePerceptionInstance] {
        let declared = Set(
            skill.requirements.perceptions
                + skill.requirements.optionalPerceptions)
        guard !declared.isEmpty else { return [] }
        return perceptions.filter { declared.contains($0.reference.schemaID) }
    }

    public func consumedReferences(for skill: SkillSchema) -> [InteractionInstanceReference] {
        interactions(declaredBy: skill).map(\.reference)
    }

    public func mutationAuthorizationFailure(
        for skill: SkillSchema,
        effect: CapabilityEffect
    ) -> String? {
        guard effect.isMutation else { return nil }
        for required in skill.requirements.interactions {
            let candidates = interactions.filter { $0.reference.schemaID == required }
            if candidates.isEmpty {
                return "requires a current \(required.rawValue) Interaction"
            }
            if !candidates.contains(where: \.canAuthorizeMutation) {
                return "requires mutation-authorizing evidence for \(required.rawValue)"
            }
        }
        return nil
    }
}

enum SchemaSignalTurnContext {
    @TaskLocal static var snapshot: SchemaSignalTurnSnapshot?
}
