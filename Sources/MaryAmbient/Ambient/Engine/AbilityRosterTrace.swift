//
//  AbilityRosterTrace.swift
//  MaryAmbient
//
//  WHAT: What the roster stage decided, as a value.
//  IN:   MaryBrain arbitrator (frozen registry)
//  OUT:  AmbientTraceLog
//  PIN:  Trace is evidence about a turn; choosing a roster stays in MaryBrain.
//
import Foundation

public struct AbilityRosterSkillKey: Codable, Hashable, Sendable {
    public var packageID: PackageID
    public var abilityID: AbilityID
    public var skillID: SkillID

    public init(packageID: PackageID, abilityID: AbilityID, skillID: SkillID) {
        self.packageID = packageID
        self.abilityID = abilityID
        self.skillID = skillID
    }
}

/// The bounded facts that participated in roster arbitration. Scores are derived solely
/// from `AbilityRoutingContext` and closed schema fields.
public struct AbilityRoutingEvidenceScore: Codable, Hashable, Sendable {
    public var total: Int
    public var directInteraction: Int
    public var focusedWorkspace: Int
    public var preference: Int

    public init(
        total: Int = 0,
        directInteraction: Int = 0,
        focusedWorkspace: Int = 0,
        preference: Int = 0
    ) {
        self.total = total
        self.directInteraction = directInteraction
        self.focusedWorkspace = focusedWorkspace
        self.preference = preference
    }
}

public enum AbilityRosterDisposition: String, Codable, Hashable, Sendable {
    case selected
    case ineligible
    case inactiveAbility
    case fallbackStandby
    case conflictLost
    case clarificationRequired
    case abstained
}

/// Privacy-safe debugger evidence for one Skill. It records identities and
/// bounded numeric evidence, never Interaction payloads or user-selected text.
public struct AbilityRosterDecision: Codable, Hashable, Sendable, Identifiable {
    public var key: AbilityRosterSkillKey
    public var reference: AbilitySkillReference
    public var conflictGroup: String?
    public var policy: RoutingConflictPolicy
    public var disposition: AbilityRosterDisposition
    public var evidence: AbilityRoutingEvidenceScore
    public var selectedAlternative: AbilitySkillReference?
    public var fallbackFor: AbilitySkillReference?
    public var reason: String

    public var id: AbilityRosterSkillKey { key }

    public init(
        key: AbilityRosterSkillKey,
        reference: AbilitySkillReference,
        conflictGroup: String?,
        policy: RoutingConflictPolicy,
        disposition: AbilityRosterDisposition,
        evidence: AbilityRoutingEvidenceScore,
        selectedAlternative: AbilitySkillReference? = nil,
        fallbackFor: AbilitySkillReference? = nil,
        reason: String
    ) {
        self.key = key
        self.reference = reference
        self.conflictGroup = conflictGroup
        self.policy = policy
        self.disposition = disposition
        self.evidence = evidence
        self.selectedAlternative = selectedAlternative
        self.fallbackFor = fallbackFor
        self.reason = reason
    }
}

public struct AbilityRosterTrace: Codable, Hashable, Sendable {
    public var decisions: [AbilityRosterDecision]

    public init(decisions: [AbilityRosterDecision] = []) {
        self.decisions = decisions
    }

    public static let empty = AbilityRosterTrace()

    public var selected: [AbilityRosterDecision] {
        decisions.filter { $0.disposition == .selected }
    }
}
