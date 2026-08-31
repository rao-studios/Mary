//
//  AmbientIntentGate.swift
//  MaryAmbient
//
//  WHAT: Question forms that decide which durable context to consult.
//  OUT:  memory lane / relationship-family vocabulary → Totem
//  PIN:  Small projection — augments the user's words with graph intent.
//

import MaryFoundation
import Foundation

/// The question forms Mary uses to decide which durable context to consult.
public enum AmbientQuestion: String, CaseIterable, Hashable, Sendable, Codable {
    case what
    case which
    case `where`
    case how
    case why
    case when
    case who
}

/// The query shape used to select both a memory lane and relationship-family
/// vocabulary. The projection is deliberately small: it augments the user's
/// words with graph intent instead of embedding a whole conversation again.
public struct AmbientQuestionSignature: Sendable, Equatable {
    public var questions: Set<AmbientQuestion>
    public var predicateFamilies: Set<String>
    public var lanePriority: [TotemLane]
    public var semanticProjection: String

    public init(
        questions: Set<AmbientQuestion> = [],
        predicateFamilies: Set<String> = [],
        lanePriority: [TotemLane] = [.personal],
        semanticProjection: String = ""
    ) {
        self.questions = questions
        self.predicateFamilies = predicateFamilies
        self.lanePriority = lanePriority
        self.semanticProjection = semanticProjection
    }
}

/// A retrieval decision for the two logical Totems.
public struct TotemMemoryPlan: Sendable, Equatable {
    public var lanes: Set<TotemLane>
    public var abilityTargets: [AbilityTotemTarget]
    public var lanePriority: [TotemLane]
    public var relationshipHints: [String]
    /// When true, relationship hints should reach other projects that
    /// practice the same discipline — without merging those projects' groups.
    public var expandDisciplineUsage: Bool

    public init(
        lanes: Set<TotemLane> = [.personal],
        abilityTargets: [AbilityTotemTarget] = [],
        lanePriority: [TotemLane]? = nil,
        relationshipHints: [String] = [],
        expandDisciplineUsage: Bool = false
    ) {
        self.lanes = lanes
        self.abilityTargets = Array(Set(abilityTargets)).sorted()
        let defaultPriority: [TotemLane] = [.ability, .personal].filter(lanes.contains)
        let requestedPriority = (lanePriority ?? defaultPriority).filter(lanes.contains)
        self.lanePriority = requestedPriority.isEmpty ? defaultPriority : requestedPriority
        self.relationshipHints = Array(Set(relationshipHints)).sorted()
        self.expandDisciplineUsage = expandDisciplineUsage
    }

    public static let personal = TotemMemoryPlan()
}

/// Separates question interpretation from turn execution.
public struct AmbientIntentGate: Sendable, Equatable {
    public var questions: Set<AmbientQuestion>
    public var requestedAbilities: Set<AbilityID>
    public var applications: [String]
    /// The subset of `applications` asserted by what an application is SHOWING rather than by
    /// its name (`AmbientAddressProbe`).
    public var addressedApplications: Set<String>
    public var signature: AmbientQuestionSignature
    public var memory: TotemMemoryPlan

    public init(
        questions: Set<AmbientQuestion> = [],
        requestedAbilities: Set<AbilityID> = [],
        applications: [String] = [],
        addressedApplications: Set<String> = [],
        signature: AmbientQuestionSignature? = nil,
        memory: TotemMemoryPlan = .personal
    ) {
        self.questions = questions
        self.requestedAbilities = requestedAbilities
        self.applications = Array(Set(applications)).sorted()
        self.addressedApplications = addressedApplications
        self.signature = signature ?? .init(questions: questions)
        self.memory = memory
    }

    public static func resolve(
        utterance: String,
        routingQuery: String? = nil,
        leadApplicationID: String?,
        profiles: [ApplicationProfile],
        abilities: any AbilityCapabilityIndex = AmbientCapabilityIndexProvider.current,
        /// Applications the utterance addressed by their live contents (see `AmbientAddressProbe`).
        /// Additive: they join `applications`, never `named`, so every rung below that reads a NAME
        /// keeps reading only names.
        addressed: [AmbientAddress] = []
    ) -> AmbientIntentGate {
        let questions = questionForms(in: utterance)
        let signature = questionSignature(utterance: utterance, questions: questions)
        let requestedAbilities = abilities.requestedAbilities(
            in: routingQuery ?? utterance)
        let named = profiles.filter { $0.isMentioned(in: utterance) }
        let addressedIDs = Set(addressed.map(\.applicationID))
            .filter { id in profiles.contains { $0.id == id } }
        let applicationIDs = Array(Set(named.map(\.id)).union(addressedIDs))
        // EXACT NAMES ONLY. Abilities decide the turn's REGISTER (writing vs
        // operating), and addressing is not a register claim: a browser
        // showing a document does not make the turn a writing turn.
        let namedAbilities = Set(named.flatMap(\.abilities))
        let isArchitecture = requestedAbilities.contains(.architect)
        let isWriting = requestedAbilities.contains(.writing)
            && (namedAbilities.contains(.writing)
                || profiles.first(where: { $0.id == leadApplicationID })?.abilities.contains(.writing) == true)
        let inheritsApplication = leadApplicationID != nil
            && AmbientRanker.referencesApplicationAnaphorically(utterance)
        let prefersAbility = !applicationIDs.isEmpty
            || isArchitecture
            || (questions.contains(.how) && !namedAbilities.isEmpty)
            || inheritsApplication
            || !requestedAbilities.isEmpty
        var abilityIDs = requestedAbilities.union(namedAbilities)
        if abilityIDs.isEmpty, prefersAbility, let lead = leadApplicationID,
           let profile = profiles.first(where: { $0.id == lead }) {
            abilityIDs = profile.abilities
        }
        let targets = abilityIDs.sorted { $0.rawValue < $1.rawValue }.map { id in
            AbilityTotemTarget(
                abilityID: id,
                paradigm: abilities.paradigm(of: id) ?? Self.inferredParadigm(id))
        }
        let hasAbilityTarget = !targets.isEmpty
        let expandDisciplineUsage = targets.contains { $0.paradigm == .discipline }

        let lanes: Set<TotemLane>
        if hasAbilityTarget && (
            isArchitecture || isWriting
                || (prefersAbility && questions.intersection([.what, .which, .`where`, .why]).isEmpty == false)
        ) {
            lanes = [.ability, .personal]
        } else if hasAbilityTarget && prefersAbility {
            lanes = [.ability]
        } else {
            lanes = [.personal]
        }
        var hints = Array(signature.predicateFamilies)
        if expandDisciplineUsage {
            hints.append("practices")
            hints.append(contentsOf: targets
                .filter { $0.paradigm == .discipline }
                .map(\.abilityID.rawValue))
        }
        return AmbientIntentGate(
            questions: questions,
            requestedAbilities: requestedAbilities,
            applications: applicationIDs,
            addressedApplications: addressedIDs,
            signature: signature,
            memory: TotemMemoryPlan(
                lanes: lanes,
                abilityTargets: targets,
                lanePriority: signature.lanePriority,
                relationshipHints: hints,
                expandDisciplineUsage: expandDisciplineUsage && lanes.contains(.ability)))
    }

    /// When the index has no paradigm, the craft axis is the honest fallback:
    /// coding and writing are disciplines; anything else is expertise until
    /// a package says otherwise.
    private static func inferredParadigm(_ id: AbilityID) -> AbilityParadigm {
        WorkspaceFocus.abilityOrder.contains(id) ? .discipline : .applicationExpertise
    }

    private static func questionForms(in utterance: String) -> Set<AmbientQuestion> {
        let words = utterance.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return Set(words.compactMap(AmbientQuestion.init(rawValue:)))
    }

    private static func questionSignature(
        utterance: String, questions: Set<AmbientQuestion>
    ) -> AmbientQuestionSignature {
        let predicateFamilies = Set(questions.flatMap { question -> [String] in
            switch question {
            case .who: return ["person", "owns", "works on"]
            case .how: return ["supports", "operates", "workflow"]
            case .where: return ["contains", "part of", "location"]
            case .why: return ["reason", "decided", "rationale"]
            case .when: return ["before", "after", "occurred"]
            case .what: return ["is", "contains", "describes"]
            case .which: return ["contains", "selects", "belongs to"]
            }
        })
        let priority: [TotemLane]
        if !questions.intersection([.how, .`where`]).isEmpty {
            priority = [.ability, .personal]
        } else if !questions.intersection([.who, .why, .when]).isEmpty {
            priority = [.personal, .ability]
        } else {
            priority = [.ability, .personal]
        }
        let cue = predicateFamilies.sorted().joined(separator: ", ")
        return .init(
            questions: questions,
            predicateFamilies: predicateFamilies,
            lanePriority: priority,
            semanticProjection: cue.isEmpty ? utterance : "\(utterance) [relationships: \(cue)]")
    }
}
