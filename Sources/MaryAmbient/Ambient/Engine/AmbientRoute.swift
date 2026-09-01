//
//  AmbientRoute.swift
//  MaryAmbient
//
//  WHAT: Complete, shareable routing decision for one turn.
//  IN:   AmbientEngine
//  OUT:  prompt assembly / AmbientContextStore.noteRoute
//

import Foundation

/// The surface that receives a writing revision this turn.
public enum AmbientWritingTarget: String, Sendable, Equatable, Codable {
    /// The user's source-owned selection is the exact text to replace, even
    /// when the request surface is currently frontmost.
    case selection
    /// A named passage must be resolved before it can be changed.
    case passage
}

/// Raw classifier verdicts, evaluated once per route.
public struct AmbientVerdicts: Sendable, Equatable {
    /// Operate/compose this turn — embeddings, or ActionClassifier when none.
    public var actionTurn: Bool
    /// `EditIntentClassifier`'s answer, whole — a shape and target list would drop
    /// `payload`, `anchor`, `destination` and `isAnaphoric`.
    public var editIntent: EditIntent?
    /// The shape alone, for the trace lines that only ever wanted the verb.
    public var editShape: EditIntent.Shape? { editIntent?.shape }
    public var editTargets: [String] { editIntent?.target ?? [] }
    /// `NamedPartClassifier.namedPart`.
    public var namedPart: String?
    /// `NamedPartClassifier.namesAmbientSource`.
    public var namesAmbientSource: Bool
    /// `AmbientRanker.isDeictic`.
    public var isDeictic: Bool
    /// `AmbientRanker.namesTransform`.
    public var namesTransform: Bool
    /// `FocusOverride.classifyOverride`.
    public var focusOverride: WorkspaceFocus?
    /// A bare yes/no, when the utterance is one.
    public var bareDecision: Bool?

    public init(
        actionTurn: Bool = false,
        editIntent: EditIntent? = nil,
        namedPart: String? = nil,
        namesAmbientSource: Bool = false,
        isDeictic: Bool = false,
        namesTransform: Bool = false,
        focusOverride: WorkspaceFocus? = nil,
        bareDecision: Bool? = nil
    ) {
        self.actionTurn = actionTurn
        self.editIntent = editIntent
        self.namedPart = namedPart
        self.namesAmbientSource = namesAmbientSource
        self.isDeictic = isDeictic
        self.namesTransform = namesTransform
        self.focusOverride = focusOverride
        self.bareDecision = bareDecision
    }
}

/// The typed answer to what this turn is and what it needs.
public struct AmbientRoute: Sendable, Equatable {

    public var intent: AmbientIntent
    /// Which signal settled `intent`. See `AmbientSignal`.
    public var decidedBy: AmbientSignal
    /// The raw verdicts that produced `intent`, computed once.
    public var verdicts: AmbientVerdicts
    /// The question form, requested ability, and durable-memory lanes for this turn.
    public var gate: AmbientIntentGate
    /// The freshest behavioral signal available when this turn was routed.
    public var world: AmbientWorld.Snapshot?
    /// Whether that attention is the semantic referent/target of this turn. `attention` remains
    /// available when false for diagnostics and ordering, but prompt construction must not
    /// present it as what deictic words mean.
    public var selectionDefinesTurn: Bool

    // MARK: - Where the turn leads

    /// Logical application identity selected from the open Application Registry.
    public var leadApplicationID: String?

    /// WHERE the turn leads, as ONE value: the lead world when a built-in leads,
    /// `(.applications, id)` when a registered Dynamic application does.
    ///
    /// DERIVED, NOT STORED, and the direction is forced: a legacy registration
    /// resolves to `.lane(...)` and a browser family to a shared place, so the id
    /// cannot be recovered from the place. The ladder only runs this way.
    public var leadPlace: AmbientPlace? {
        Self.leadPlace(leadApplicationID: leadApplicationID)
    }

    /// WHAT COULD HAVE SERVED THIS TURN, and which of them did. Resolved once, at route
    /// construction, from the same need and signals that decide everything else about the turn.
    public var realm: AmbientRealm?

    /// Destinations the utterance named outright.
    public var namedPlaces: Set<AmbientPlace>

    /// Worlds that supplied routing evidence for this turn. Ability packages may constrain
    /// individual Skills with typed predicates; this diagnostic set is never itself an
    /// execution allowlist. STAYS A WORLD SET, and now for a better reason than the old one.
    public var candidateAttentions: Set<AmbientAttention>

    // MARK: - Needs

    /// The surface that receives a revision, when this is a writing turn.
    public var writingTarget: AmbientWritingTarget?
    /// A named document part to read as context for a selected-text revision.
    /// It is never the mutation target.
    public var supportingContext: String?
    /// This turn should locate a passage before any lane exists (G1).
    public var needsLocate: Bool
    /// This turn should try the fetch-first pre-read.
    public var needsPreRead: Bool
    /// This turn plausibly needs Ability execution rather than conversation only.
    public var needsExecution: Bool

    /// How the ambient store ranked its facts for this utterance.
    public var rankingMode: AmbientRankingMode

    /// `namedPlaces` defaults to its derivation so every construction carries
    /// coherent places without spelling them. `leadPlace` is not a parameter at
    /// all — it derives, so the two cannot be handed in disagreeing.
    public init(
        intent: AmbientIntent,
        decidedBy: AmbientSignal,
        verdicts: AmbientVerdicts = AmbientVerdicts(),
        gate: AmbientIntentGate = AmbientIntentGate(),
        world: AmbientWorld.Snapshot? = nil,
        selectionDefinesTurn: Bool = false,
        leadApplicationID: String? = nil,
        namedPlaces: Set<AmbientPlace>? = nil,
        realm: AmbientRealm? = nil,
        candidateAttentions: Set<AmbientAttention> = [],
        writingTarget: AmbientWritingTarget? = nil,
        supportingContext: String? = nil,
        needsLocate: Bool = false,
        needsPreRead: Bool = false,
        needsExecution: Bool = false,
        rankingMode: AmbientRankingMode = .relevance
    ) {
        self.intent = intent
        self.decidedBy = decidedBy
        self.verdicts = verdicts
        self.gate = gate
        self.world = world
        self.selectionDefinesTurn = selectionDefinesTurn
        self.leadApplicationID = leadApplicationID
        self.namedPlaces = namedPlaces ?? Self.namedPlaces(gate: gate)
        self.realm = realm
        self.candidateAttentions = candidateAttentions
        self.writingTarget = writingTarget
        self.supportingContext = supportingContext
        self.needsLocate = needsLocate
        self.needsPreRead = needsPreRead
        self.needsExecution = needsExecution
        self.rankingMode = rankingMode
    }

    /// THE RESOLUTION LADDER, spelled once. The registration answers if the roster knows the
    /// id; a bare id it does not know is still a place — naming something Mary has not been
    /// taught is a fact about the turn, not an absence of one.
    public static func leadPlace(leadApplicationID: String?) -> AmbientPlace? {
        guard let id = leadApplicationID, !id.isEmpty else { return nil }
        return AmbientApplicationIndexProvider.current.registration(id: id)?.place
            ?? .application(id)
    }

    /// Every application the gate matched by name, as places.
    public static func namedPlaces(
        gate: AmbientIntentGate,
        /// Places an address probe asserted, carried separately because the
        /// gate cannot reach them — an address is evidence from a different
        /// ladder than a mention.
        addressedPlaces: Set<AmbientPlace> = []
    ) -> Set<AmbientPlace> {
        var places: Set<AmbientPlace> = []
        for id in gate.applications {
            guard let registration =
                    AmbientApplicationIndexProvider.current.registration(id: id)
            else { continue }
            places.insert(registration.place)
        }
        places.formUnion(addressedPlaces)
        return places
    }

}

public extension AmbientRoute {
    /// Applies the request-boundary routing decision to a later snapshot of held facts.
    /// Non-selection context may continue to refresh while the turn runs.
    func admitsHeldFact(_ fact: AmbientFact) -> Bool {
        guard fact.slot == .selection else { return true }
        guard selectionDefinesTurn,
              let world,
              world.isDirectReference,
              let selectedText = world.selectedText,
              world.matches(fact),
              fact.attention == world.attention,
              fact.applicationID == world.applicationID,
              fact.subject == world.subject,
              fact.capturedAt == world.capturedAt
        else { return false }

        // AmbientKey identifies a superseding slot, not one capture. Source,
        // timestamp, and content close that identity gap so a later highlight
        // in the same application cannot masquerade as this turn's referent.
        return fact.content == String(selectedText.prefix(AmbientFact.contentCap))
    }

    /// Whether this turn acts rather than converses — the POST-route answer.
    /// (`verdicts.actionTurn` is the classifier's pre-route guess, kept for traces.)
    var isActionTurn: Bool {
        intent == .operate || intent == .compose || verdicts.editIntent != nil
    }

    /// The direct attention this route actually accepted as its referent.
    /// Diagnostic attention remains on the route when this is nil.
    var routedSelectionWorld: AmbientWorld.Snapshot? {
        selectionDefinesTurn && world?.isDirectReference == true
            ? world
            : nil
    }

    /// Deictic question about a standing editor highlight — Lane A should inspire a look/read.
    var inspiresSight: Bool { routedSelectionWorld != nil }

    /// Attention after semantic containment. `attention` itself deliberately
    /// retains a rejected source packet for diagnostics; consumers that can
    /// influence prompts, routing, or execution use this projection instead.
    var routedWorld: AmbientWorld.Snapshot? {
        guard world?.isDirectReference == true else { return world }
        return routedSelectionWorld
    }

    /// Exact identity check between the source-owned packet frozen for this turn and the
    /// selection the route accepted. `AmbientWorld.Snapshot` has no packet UUID, so all immutable
    /// source/value fields participate.
    func admitsSelectionHandoff(_ handoff: AmbientSelectionHandoff) -> Bool {
        guard let world = routedSelectionWorld,
              handoff.attention == world.attention,
              handoff.applicationID == world.applicationID,
              handoff.subject == world.subject,
              handoff.text == world.selectedText,
              handoff.capturedAt == world.capturedAt,
              handoff.editability == world.selectionEditability,
              handoff.sourceEvidence == world.selectionSourceEvidence,
              handoff.payloadRecovery == world.selectionPayloadRecovery
        else { return false }
        return true
    }
}
