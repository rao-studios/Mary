//
//  CapabilityExecutionPolicy.swift
//  MaryBrain
//
//  WHAT: Closed execution policy for a capability (confirm / allow / refuse).
//  IN:   roster / safety gate
//  OUT:  policy applied at dispatch
//
import MaryFoundation
import Foundation

/// The closed runtime interpretation of every Capability constraint required
/// by one frozen Skill. Package strings are normalized here exactly once;
/// execution paths consume this typed policy rather than reinterpreting JSON.
struct CapabilityExecutionPolicy: Sendable, Equatable {
    var maximumDurationSeconds: TimeInterval?
    var maximumPayloadBytes: Int?
    var requiresStage: Bool
    var requiresUserConfirmation: Bool
    /// Nil means the Capability contract does not restrict target classes.
    /// Multiple required capabilities intersect their allowlists.
    var allowedTargetClasses: Set<String>?
    /// These guarantees can be proven only after the local adapter resolves a
    /// concrete source/target. Compatibility requires an exact attestation.
    var delegatedConstraints: Set<CapabilityConstraint>
    var effect: CapabilityEffect

    static let unconstrained = CapabilityExecutionPolicy(
        maximumDurationSeconds: nil,
        maximumPayloadBytes: nil,
        requiresStage: false,
        requiresUserConfirmation: false,
        allowedTargetClasses: nil,
        delegatedConstraints: [],
        effect: .none)

    init(capabilities: [CapabilitySchema]) {
        var duration: TimeInterval?
        var payload: Int?
        var stage = false
        var confirmation = false
        var targetSets: [Set<String>] = []
        var delegated: Set<CapabilityConstraint> = []
        var strongestEffect: CapabilityEffect = .none

        for capability in capabilities {
            if Self.effectRank(capability.effect) > Self.effectRank(strongestEffect) {
                strongestEffect = capability.effect
            }
            let capabilityTargets = Set(capability.constraints.compactMap { constraint in
                constraint.kind == .allowedTargetClass ? constraint.value : nil
            })
            if !capabilityTargets.isEmpty { targetSets.append(capabilityTargets) }

            for constraint in capability.constraints {
                switch constraint.kind {
                case .maximumDurationSeconds:
                    guard let candidate = TimeInterval(constraint.value),
                          candidate.isFinite,
                          candidate > 0 else { continue }
                    duration = min(duration ?? candidate, candidate)
                case .maximumPayloadBytes:
                    guard let candidate = Int(constraint.value), candidate > 0 else { continue }
                    payload = min(payload ?? candidate, candidate)
                case .requiresStage:
                    stage = true
                case .requiresUserConfirmation:
                    confirmation = true
                case .allowedTargetClass:
                    break
                case .requiresFrontmostApplication,
                     .requiresStableDocumentIdentity,
                     .sourceMustMatchTarget:
                    delegated.insert(constraint)
                }
            }
        }

        maximumDurationSeconds = duration
        maximumPayloadBytes = payload
        requiresStage = stage
        requiresUserConfirmation = confirmation
        allowedTargetClasses = targetSets.isEmpty
            ? nil
            : targetSets.dropFirst().reduce(targetSets[0]) { $0.intersection($1) }
        delegatedConstraints = delegated
        effect = strongestEffect
    }

    private init(
        maximumDurationSeconds: TimeInterval?,
        maximumPayloadBytes: Int?,
        requiresStage: Bool,
        requiresUserConfirmation: Bool,
        allowedTargetClasses: Set<String>?,
        delegatedConstraints: Set<CapabilityConstraint>,
        effect: CapabilityEffect
    ) {
        self.maximumDurationSeconds = maximumDurationSeconds
        self.maximumPayloadBytes = maximumPayloadBytes
        self.requiresStage = requiresStage
        self.requiresUserConfirmation = requiresUserConfirmation
        self.allowedTargetClasses = allowedTargetClasses
        self.delegatedConstraints = delegatedConstraints
        self.effect = effect
    }

    private static func effectRank(_ effect: CapabilityEffect) -> Int {
        switch effect {
        case .none: return 0
        case .read: return 1
        case .reversibleMutation: return 2
        case .mutation: return 3
        case .externalCommunication: return 4
        case .destructive: return 5
        }
    }
}

extension AbilityRuntime.Snapshot {
    /// EXACT, not memoized: the policy depends only on the capability list and
    /// this snapshot's own schemas, and `policiesByCapabilities` holds one
    /// entry per distinct list, built in `init`. A Skill from another snapshot
    /// (tests, rehearsal) still computes, so the answer is never wrong — only
    /// already-known for the skills this snapshot actually carries.
    func executionPolicy(for skill: SkillSchema) -> CapabilityExecutionPolicy {
        if let known = policiesByCapabilities[skill.requirements.capabilities] {
            return known
        }
        return CapabilityExecutionPolicy(capabilities: capabilitySchemas(requiredBy: skill))
    }
}
