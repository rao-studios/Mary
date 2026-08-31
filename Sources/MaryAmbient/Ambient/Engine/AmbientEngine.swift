//
//  AmbientEngine.swift
//  MaryAmbient
//
//  WHAT: Resolves a turn once, before prompts or executable Skills are assembled.
//  IN:   classifiers / attention / lead / profiles
//  OUT:  AmbientRoute → prompt and memory
//  PIN:  Engine picks a place; attention is the standing lanes; the snapshot is this turn's packet at that place.
//

import Foundation

/// Resolves a turn once, before prompts or executable Skills are assembled.
public enum AmbientEngine {

    public struct Inputs: Sendable {
        public var utterance: String
        /// Embedding query. Nil — ability nomination still uses `utterance`.
        public var routingQuery: String?
        public var actionTurn: Bool
        /// Embedding operate / perceive / converse. Nil keeps the lexical ladder.
        public var embeddingIntent: AmbientIntent?
        public var editIntent: EditIntent?
        public var bareDecision: Bool?
        public var hasPendingSkillConfirmation: Bool
        public var activeRoutineCount: Int
        public var world: AmbientWorld.Snapshot?
        public var leadApplicationID: String?
        public var profiles: [ApplicationProfile]
        /// Applications whose LIVE CONTENTS the utterance may be addressing: where each one's
        /// ambient elements live, and what routing calls it.
        public var addressCandidates: [AmbientAddressProbe.Candidate]
        /// The turn's live focus evidence, kind and age per place — what the
        /// realm needs and `FocusSignal` has already thrown away.
        public var focus: FocusSignal
        public var evidence: [AmbientPlace: FocusEvidence]
        /// Immutable ability graph used for this routing decision. Nil asks
        /// the library for its active (lazily loaded) registry.
        public var abilitySnapshot: (any AbilityCapabilityIndex)?
        public var now: Date

        public init(
            utterance: String,
            routingQuery: String? = nil,
            actionTurn: Bool = false,
            embeddingIntent: AmbientIntent? = nil,
            editIntent: EditIntent? = nil,
            bareDecision: Bool? = nil,
            hasPendingSkillConfirmation: Bool = false,
            activeRoutineCount: Int = 0,
            world: AmbientWorld.Snapshot? = nil,
            leadApplicationID: String? = nil,
            profiles: [ApplicationProfile] = [],
            addressCandidates: [AmbientAddressProbe.Candidate] = [],
            focus: FocusSignal = FocusSignal(),
            evidence: [AmbientPlace: FocusEvidence] = [:],
            abilitySnapshot: (any AbilityCapabilityIndex)? = nil,
            now: Date = Date()
        ) {
            self.utterance = utterance
            self.routingQuery = routingQuery
            self.actionTurn = actionTurn
            self.embeddingIntent = embeddingIntent
            self.editIntent = editIntent
            self.bareDecision = bareDecision
            self.hasPendingSkillConfirmation = hasPendingSkillConfirmation
            self.activeRoutineCount = activeRoutineCount
            self.world = world
            self.leadApplicationID = leadApplicationID
            self.profiles = profiles
            self.addressCandidates = addressCandidates
            self.focus = focus
            self.evidence = evidence
            self.abilitySnapshot = abilitySnapshot
            self.now = now
        }
    }

    public static func resolve(_ inputs: Inputs) -> AmbientRoute {
        let attention = inputs.world?.isFresh(at: inputs.now) == true ? inputs.world : nil
        let explicitlyNamedPlaces = AmbientRanker.explicitlyNamedPlaces(
            in: inputs.utterance)
        let namedApplicationProfiles = inputs.profiles
            .filter { $0.isMentioned(in: inputs.utterance) }
        let namedApplications = Set(namedApplicationProfiles.map(\.id))
        // A NAMED APPLICATION STANDS THE CUE CLASSIFIER DOWN. `namedPlaces` falls back to the
        // DISCIPLINE vocabulary when nothing is named outright — "this document" reads as writing,
        // and every place that writes becomes a candidate.
        let namedPlaces = namedApplications.isEmpty
            ? AmbientRanker.namedPlaces(in: inputs.utterance)
            : explicitlyNamedPlaces
        let isDeictic = AmbientRanker.isDeictic(inputs.utterance)

        // A source-owned selection is a one-turn interaction, not a workspace focus signal.
        let conflictPlaces = explicitlyNamedPlaces.isEmpty && namedPlaces.count == 1
            ? namedPlaces
            : explicitlyNamedPlaces
        // ONE IDENTITY, TWO NAMESPACES.
        let conflictsWithNamedPlace = attention.map { attention in
            conflictPlaces.contains { place in
                guard let application = place.application,
                      let profile = inputs.profiles.first(where: {
                          $0.id.caseInsensitiveCompare(application) == .orderedSame
                      })
                else { return place != attention.place }
                return !applicationProfile(profile, represents: attention)
            }
        } ?? false
        let conflictsWithNamedApplication = attention.map { attention in
            namedApplicationProfiles.contains {
                !applicationProfile($0, represents: attention)
            }
        } ?? false
        let selectionDefinesTurn = attention?.isDirectReference == true
            && (isDeictic || inputs.editIntent != nil)
            && !conflictsWithNamedPlace
            && !conflictsWithNamedApplication
        // Keep the raw packet on AmbientRoute for diagnostics, but classifiers
        // and downstream schema routing may only see a direct selection after
        // the conflict decision above accepted it as this turn's referent.
        let routedWorld = attention?.isDirectReference == true
            ? (selectionDefinesTurn ? attention : nil)
            : attention
        // TRUE NAMES ONLY.
        let explicitlyNamedLead = explicitlyNamedPlaces.count == 1
            ? explicitlyNamedPlaces.first : nil
        let explicitlyNamedApplicationID = namedApplications.count == 1
            ? namedApplications.first : nil
        let attentionApplicationID = attention.flatMap { attention in
            inputs.profiles.first {
                applicationProfile($0, represents: attention)
            }?.id
        }
        // ONE LADDER, ONE ANSWER. A world-typed lead used to be computed
        // beside this and kept as a second field; see `AmbientRoute` on why
        // two answers to "where does this turn lead" is one too many.
        let leadApplicationID = selectionDefinesTurn
            ? (attentionApplicationID ?? explicitlyNamedLead?.application)
            : (explicitlyNamedApplicationID
                // A LITERALLY NAMED place outranks a different frontmost one.
                ?? explicitlyNamedLead?.application
                ?? inputs.leadApplicationID)
        var routedInputs = inputs
        routedInputs.world = routedWorld
        routedInputs.leadApplicationID = leadApplicationID
        let abilitySnapshot = inputs.abilitySnapshot ?? AmbientCapabilityIndexProvider.current
        // ADDRESSED, NOT NAMED — and the separation above is the point.
        let addressed = AmbientAddressProbe.address(
            utterance: inputs.utterance,
            candidates: inputs.addressCandidates,
            excluding: namedApplications)
        let gate = AmbientIntentGate.resolve(
            utterance: inputs.utterance,
            routingQuery: inputs.routingQuery,
            leadApplicationID: leadApplicationID,
            profiles: inputs.profiles,
            abilities: abilitySnapshot,
            addressed: addressed)
        let verdicts = AmbientVerdicts(
            actionTurn: inputs.actionTurn,
            editShape: inputs.editIntent?.shape,
            editTargets: inputs.editIntent?.target ?? [],
            namedPart: NamedPartClassifier.namedPart(in: inputs.utterance),
            namesAmbientSource: NamedPartClassifier.namesAmbientSource(inputs.utterance),
            isDeictic: isDeictic,
            namesTransform: AmbientRanker.namesTransform(inputs.utterance),
            focusOverride: FocusOverride.classifyOverride(utterance: inputs.utterance),
            bareDecision: inputs.bareDecision)
        let (intent, signal) = classify(
            routedInputs,
            verdicts: verdicts,
            namedPlaces: namedPlaces,
            gate: gate,
            leadApplicationID: leadApplicationID,
            world: routedWorld)
        let writingTarget: AmbientWritingTarget?
        if inputs.editIntent == nil {
            writingTarget = nil
        } else if selectionDefinesTurn,
                  let attention,
                  attention.isDirectReference,
                  directSelectionCanReceiveRevision(attention) {
            writingTarget = .selection
        } else {
            writingTarget = .passage
        }
        let supportingContext = writingTarget == .selection ? verdicts.namedPart : nil

        // `(lead, leadApplicationID)` come from the two independent ladders above and legitimately
        // COEXIST — a native lead world beside a Dynamic focused-application id.
        let allNamedPlaces = namedPlaces.union(
            AmbientRoute.namedPlaces(
                gate: gate, addressedPlaces: Set(addressed.map(\.place))))
        return AmbientRoute(
            intent: intent,
            decidedBy: signal,
            verdicts: verdicts,
            gate: gate,
            world: attention,
            selectionDefinesTurn: selectionDefinesTurn,
            leadApplicationID: leadApplicationID,
            // The addressed places ride EXPLICITLY: an address is evidence from a different ladder
            // than a mention, and the gate cannot reach it — without this the roster scoping would
            // never see an application the user addressed by its live contents.
            namedPlaces: allNamedPlaces,
            // THE REALM, RESOLVED ONCE. It reads the focus signal rather than
            // re-deciding with it, so `realm.place == leadPlace` holds by
            // construction wherever both exist — see `AmbientRealmResolver`.
            realm: AmbientRealmResolver.resolve(.init(
                utterance: inputs.utterance,
                abilityQuery: inputs.routingQuery,
                namedPlaces: allNamedPlaces,
                discipline: verdicts.focusOverride,
                decidedBy: signal,
                focus: inputs.focus,
                evidence: inputs.evidence,
                registrations: inputs.profiles.isEmpty
                    ? nil : AmbientApplicationIndexProvider.current.all,
                abilities: abilitySnapshot,
                now: inputs.now)),
            candidateAttentions: candidateAttentions(
                intent: intent, lead: AmbientRoute.leadPlace(
                    leadApplicationID: leadApplicationID),
                named: namedPlaces),
            writingTarget: writingTarget,
            supportingContext: supportingContext,
            needsLocate: writingTarget == .passage,
            needsPreRead: inputs.editIntent == nil && !inputs.actionTurn && verdicts.namedPart != nil,
            needsExecution: needsExecution(for: intent),
            // ASKED OF THE PLACE. `effectiveLead` is world-typed and answers `.otherApps` for a taught
            // application, so the budget rule compared the user's words against the shared host lane
            // rather than against the manuscript they were in.
            rankingMode: AmbientRanker.mode(
                utterance: inputs.utterance,
                focusedPlace: AmbientRoute.leadPlace(
                    leadApplicationID: leadApplicationID)))
    }

    /// Application profiles use logical identities while source-owned packets carry
    /// process identities (a bundle id). Compare place / bundle / logical id.
    /// PIN: the applications host adapter is transport, never a selection's identity.
    private static func applicationProfile(
        _ profile: ApplicationProfile,
        represents world: AmbientWorld.Snapshot
    ) -> Bool {
        if AmbientAttention.from(pluginOwner: profile.id) == .applications {
            return false
        }
        if let placeID = world.place.application,
           placeID.caseInsensitiveCompare(profile.id) == .orderedSame {
            return true
        }
        guard let applicationID = world.applicationID else { return false }
        let normalizedApplicationID = applicationID.lowercased()
        if profile.applicationIdentifiers.contains(where: {
            $0.lowercased() == normalizedApplicationID
        }) {
            return true
        }
        if profile.id.lowercased() == normalizedApplicationID { return true }
        if profile.aliases.contains(where: {
            $0.lowercased() == normalizedApplicationID
        }) {
            return true
        }
        // Generic Accessibility selections keep the real app name as subject.
        return world.attention == .applications
            && world.subject.map(profile.isMentioned(in:)) == true
    }

    private static func classify(
        _ inputs: Inputs,
        verdicts: AmbientVerdicts,
        namedPlaces: Set<AmbientPlace>,
        gate: AmbientIntentGate,
        leadApplicationID: String?,
        world: AmbientWorld.Snapshot?
    ) -> (AmbientIntent, AmbientSignal) {
        if inputs.hasPendingSkillConfirmation, inputs.bareDecision != nil {
            return (.decide, .pendingDecision)
        }
        if inputs.activeRoutineCount > 0, inputs.bareDecision == false {
            return (.halt, .routineStop)
        }
        if inputs.editIntent != nil {
            return (.revise, .editIntent)
        }
        if gate.requestedAbilities.contains(.architect) {
            return (.architect, .architectAbility)
        }
        if let embeddingIntent = inputs.embeddingIntent {
            return (embeddingIntent, .embedding)
        }
        if inputs.actionTurn {
            let leadAbilities = inputs.profiles.first(where: { $0.id == leadApplicationID })?.abilities ?? []
            let namedAbilities = Set(
                inputs.profiles
                    .filter { gate.applications.contains($0.id) }
                    .flatMap(\.abilities))
            // THE ROSTER IS THE ONLY SOURCE.
            if leadAbilities.contains(.writing) || namedAbilities.contains(.writing) {
                return (.compose, .writingRegister)
            }
            return (.operate, .actionCommand)
        }
        if world?.isDirectReference == true, verdicts.isDeictic {
            return (.perceive, .world)
        }
        if verdicts.isDeictic {
            return (.perceive, .deixis)
        }
        if let id = inputs.leadApplicationID,
           namedPlaces.contains(where: { $0.application == id }) {
            return (.perceive, .namedLeadAttention)
        }
        if verdicts.namesAmbientSource {
            return (.ask, .ambientSource)
        }
        if verdicts.namedPart != nil {
            return (.ask, .namedPart)
        }
        return (.converse, .none)
    }

    private static func needsExecution(for intent: AmbientIntent) -> Bool {
        switch intent {
        case .architect, .converse:
            return false
        default:
            return true
        }
    }

    /// A selection is always a valid conversational referent. It becomes a mutation target only
    /// when its exact source surface is allowed to receive prose.
    private static func directSelectionCanReceiveRevision(
        _ world: AmbientWorld.Snapshot
    ) -> Bool {
        // Payload recovery is a useful source of *reading* context, but its characters did not
        // come from the live source element. Likewise, a canvas descendant does not identify the
        // focused AX element the typer must revalidate.
        guard world.selectionPayloadRecovery == nil,
              world.selectionSourceEvidence?.isExact == true
        else {
            return false
        }
        guard let applicationID = world.applicationID else { return false }
        return SelectionSurfacePolicy.isWritableProseSurface(
            applicationID: applicationID,
            editability: world.selectionEditability ?? .unknown)
    }

    /// WHICH OF MARY'S OWN LANES supplied routing evidence — a diagnostic,
    /// never an execution allowlist. Dispatch still resolves against every
    /// installed package.
    public static func candidateAttentions(
        intent: AmbientIntent, lead: AmbientPlace?, named: Set<AmbientPlace>
    ) -> Set<AmbientAttention> {
        var candidates = Set(AmbientAttention.allCases.filter { !$0.hasEyes })
        candidates.formUnion(named.compactMap { $0.hasEyes ? $0.attention : nil })
        guard intent != .converse else { return candidates }
        if let lead, lead.hasEyes { candidates.insert(lead.attention) }
        return candidates
    }
}
