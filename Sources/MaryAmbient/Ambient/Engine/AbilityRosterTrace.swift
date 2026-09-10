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
    /// THE RAW SCORE, INCLUDING BELOW THE FLOOR — and that is the whole point
    /// of carrying it beside `evidence`. `evidence.total` is affinity×1000 only
    /// for a Skill that CLEARED the floor; a Skill that did not never enters the
    /// gating map at all, so its total is computed on the other branch and the
    /// two numbers are not comparable. A bench asking "how close was it?" needs
    /// the number the floor was compared against, unrounded and unfiltered.
    /// Nil when this turn had no embedding opinion at all.
    public var affinity: Float?
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
        affinity: Float? = nil,
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
        self.affinity = affinity
        self.selectedAlternative = selectedAlternative
        self.fallbackFor = fallbackFor
        self.reason = reason
    }
}

/// Which rule decided the Ability election this turn.
///
/// PIN: THE ELECTION IS A DECISION AND HAD NO ROW. Every Skill carried a
/// sentence saying why it was or was not offered, but an Ability losing its
/// conflict group silenced ALL of its Skills at once with one borrowed line
/// ("its Ability lost or conservatively declined the active Ability conflict")
/// and no way to see what it lost to, or by what. That is the decision that
/// hid `control_playback` behind a browser, so it gets a row of its own.
public enum AbilityElectionRegime: String, Codable, Hashable, Sendable {
    /// The Skill corpus decided: an Ability with a member above the floor is
    /// admitted, because the words already proved the member relevant.
    case semantic
    /// No embedding index — the Ability's own routing predicates elect.
    case lexical
}

/// One Ability's standing in this turn's election.
public struct AbilityElectionRow: Codable, Hashable, Sendable, Identifiable {
    public var packageID: PackageID
    public var abilityID: AbilityID
    public var abilityTitle: String
    public var conflictGroup: String?
    public var regime: AbilityElectionRegime
    /// What the Ability's own routing predicates scored (the lexical vote).
    /// Carried in both regimes: under `.semantic` it is what WOULD have decided,
    /// which is exactly what a bench needs in order to understand the old answer.
    public var predicateScore: Int
    /// The best affinity any of this Ability's Skills reached, when the turn had
    /// an embedding opinion.
    public var bestMemberAffinity: Float?
    public var isActive: Bool
    public var reason: String

    public var id: String { packageID.rawValue + "/" + abilityID.rawValue }

    public init(
        packageID: PackageID,
        abilityID: AbilityID,
        abilityTitle: String,
        conflictGroup: String?,
        regime: AbilityElectionRegime,
        predicateScore: Int,
        bestMemberAffinity: Float? = nil,
        isActive: Bool,
        reason: String
    ) {
        self.packageID = packageID
        self.abilityID = abilityID
        self.abilityTitle = abilityTitle
        self.conflictGroup = conflictGroup
        self.regime = regime
        self.predicateScore = predicateScore
        self.bestMemberAffinity = bestMemberAffinity
        self.isActive = isActive
        self.reason = reason
    }
}

/// Which lane answered the turn, named by the lane itself.
public enum SemanticTurnLane: Codable, Hashable, Sendable {
    /// Dispatched with no model round: one Skill won the corpus outright and
    /// its arguments were fillable from the sentence. `stages` is the peeling
    /// the extractor actually did, in order.
    case confidence(invocationName: String, argumentsJSON: String, stages: [String])
    /// Handed to the model with the roster offered.
    case model
    /// The screen was already offering a control that served the goal.
    case affordance(labels: [String], score: Float)
}

/// The one semantic read of the turn, as a value.
///
/// PIN: THIS WAS THE RICHEST ROUTING FACT IN THE SYSTEM AND REACHED os_log
/// ALONE. `TurnTriage.Verdict` already computed intent, its score, its runner-up,
/// every offered affinity and the unique pick — once per turn — and the only way
/// to see any of it was Console. A bench that has to guess at the numbers cannot
/// tune the corpus, which is what both benches exist to do.
public struct SemanticTurnVerdict: Codable, Hashable, Sendable {
    public var intent: String?
    public var intentScore: Float
    public var intentRunnerUp: String?
    public var promotedByUniqueSkill: Bool
    /// The two thresholds, carried rather than re-derived, so a reader compares
    /// the numbers against the same floor the turn used.
    public var floor: Float
    public var margin: Float
    /// The Skill that won the corpus outright, when one did.
    public var uniqueSkill: String?
    public var lane: SemanticTurnLane?

    public init(
        intent: String? = nil,
        intentScore: Float = 0,
        intentRunnerUp: String? = nil,
        promotedByUniqueSkill: Bool = false,
        floor: Float,
        margin: Float,
        uniqueSkill: String? = nil,
        lane: SemanticTurnLane? = nil
    ) {
        self.intent = intent
        self.intentScore = intentScore
        self.intentRunnerUp = intentRunnerUp
        self.promotedByUniqueSkill = promotedByUniqueSkill
        self.floor = floor
        self.margin = margin
        self.uniqueSkill = uniqueSkill
        self.lane = lane
    }
}

public struct AbilityRosterTrace: Codable, Hashable, Sendable {
    public var decisions: [AbilityRosterDecision]
    /// How each Ability fared in this turn's conflict-group election.
    public var election: [AbilityElectionRow]
    /// What the embedding made of the turn. Nil with no index at all.
    public var semantic: SemanticTurnVerdict?

    public init(
        decisions: [AbilityRosterDecision] = [],
        election: [AbilityElectionRow] = [],
        semantic: SemanticTurnVerdict? = nil
    ) {
        self.decisions = decisions
        self.election = election
        self.semantic = semantic
    }

    public static let empty = AbilityRosterTrace()

    public var selected: [AbilityRosterDecision] {
        decisions.filter { $0.disposition == .selected }
    }

    /// The same trace, carrying what the turn's words were judged to mean.
    /// The roster is arbitrated inside `AbilityRuntime`, which cannot see the
    /// turn's semantic read; the turn loop holds both and joins them here.
    public func carrying(_ semantic: SemanticTurnVerdict?) -> AbilityRosterTrace {
        var copy = self
        copy.semantic = semantic
        return copy
    }
}
