// The complete, shareable routing decision for one turn.

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
    /// `ActionClassifier.isActionCommand` — passed in, not re-run.
    public var actionTurn: Bool
    /// `EditIntentClassifier`'s shape, when it found one.
    public var editShape: EditIntent.Shape?
    public var editTargets: [String]
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
        editShape: EditIntent.Shape? = nil,
        editTargets: [String] = [],
        namedPart: String? = nil,
        namesAmbientSource: Bool = false,
        isDeictic: Bool = false,
        namesTransform: Bool = false,
        focusOverride: WorkspaceFocus? = nil,
        bareDecision: Bool? = nil
    ) {
        self.actionTurn = actionTurn
        self.editShape = editShape
        self.editTargets = editTargets
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
    public var attention: AmbientAttention?
    /// Whether that attention is the semantic referent/target of this turn.
    /// `attention` remains available when false for diagnostics and ordering,
    /// but prompt construction must not present it as what deictic words mean.
    /// A conflicting explicitly named world or application makes this false.
    public var selectionDefinesTurn: Bool

    // MARK: - Worlds

    /// The world that leads schema routing for this turn. It normally mirrors
    /// the focus arbiter's lead. A fresh source-owned selection referred to
    /// deictically—or selected as the revision target—overrides it inside this
    /// route only; persistent workspace focus is never mutated by an
    /// Interaction.
    public var lead: AmbientWorld?

    /// Logical application identity selected from the open Application
    /// Registry. Unlike `lead`, this is open-ended and can name an
    /// Ability-provided Dynamic application without adding an enum case.
    ///
    /// STORED, DELIBERATELY NOT `leadPlace?.application`. This id and `lead`
    /// are produced by two independent ladders in `AmbientEngine.resolve` —
    /// the world from the arbiter/named-world ladder, the id from the
    /// named/inherited/focused-application ladder — and the id is routinely a
    /// NATIVE plugin owner (`effectiveLead?.pluginOwner` → "pages"), which a
    /// place can never carry: a native place has a nil lane by the pinned
    /// host-lane shape (AmbientPlaceABITests). Projecting it off `leadPlace`
    /// would therefore nil it on every native-led turn. The pair stays
    /// stored until place-M2 unifies the two ladders.
    public var leadApplicationID: String?

    /// WHERE the turn leads, as ONE value: the lead world when a built-in
    /// leads, `(.applications, id)` when a registered Dynamic application does.
    /// Derived once at route construction by `Self.leadPlace(lead:
    /// leadApplicationID:)` unless a caller supplies it explicitly.
    public var leadPlace: AmbientPlace?

    /// Workspace worlds the utterance named outright — "fix the typo in my
    /// Scrivener chapter" while Xcode is frontmost names `.scrivener`.
    public var namedWorlds: Set<AmbientWorld>

    /// Named destinations as PLACES: `namedWorlds` as places, unioned with
    /// every registered Dynamic application the gate matched by name.
    /// COMPOSED from `gate.applications` rather than re-matching the
    /// utterance — the gate already ran `ApplicationProfile.isMentioned`,
    /// and a second spelling of "did the user name it" is how two layers
    /// come to disagree.
    public var namedPlaces: Set<AmbientPlace>

    /// Worlds that supplied routing evidence for this turn. Ability packages
    /// may constrain individual Skills with typed predicates; this diagnostic
    /// set is never itself an execution allowlist.
    ///
    /// STAYS A WORLD SET, and now for a better reason than the old one.
    ///
    /// Bonnie's comment here said candidacy could never have a home — that a
    /// place set would be "a second spelling of a decision the arbiter
    /// already owns". That was true while nothing modelled candidacy. It has
    /// a home now: `AmbientRealm` is the conforming set, and the resolver
    /// that computes one is the arbiter's, so there is exactly one spelling
    /// and this is not it. What stays here is what it always was — a
    /// DIAGNOSTIC of which of Mary's own lanes supplied routing evidence,
    /// never an execution allowlist and never a set of places.
    public var candidateWorlds: Set<AmbientWorld>

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

    /// `leadPlace`/`namedPlaces` default to their derivations so every
    /// existing construction — the engine's and the tests' — carries coherent
    /// places without spelling them; passing either explicitly is reserved
    /// for callers that already resolved them.
    public init(
        intent: AmbientIntent,
        decidedBy: AmbientSignal,
        verdicts: AmbientVerdicts = AmbientVerdicts(),
        gate: AmbientIntentGate = AmbientIntentGate(),
        attention: AmbientAttention? = nil,
        selectionDefinesTurn: Bool = false,
        lead: AmbientWorld? = nil,
        leadApplicationID: String? = nil,
        leadPlace: AmbientPlace? = nil,
        namedWorlds: Set<AmbientWorld> = [],
        namedPlaces: Set<AmbientPlace>? = nil,
        candidateWorlds: Set<AmbientWorld> = [],
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
        self.attention = attention
        self.selectionDefinesTurn = selectionDefinesTurn
        self.lead = lead
        self.leadApplicationID = leadApplicationID
        self.leadPlace = leadPlace
            ?? Self.leadPlace(lead: lead, leadApplicationID: leadApplicationID)
        self.namedWorlds = namedWorlds
        self.namedPlaces = namedPlaces
            ?? Self.namedPlaces(namedWorlds: namedWorlds, gate: gate)
        self.candidateWorlds = candidateWorlds
        self.writingTarget = writingTarget
        self.supportingContext = supportingContext
        self.needsLocate = needsLocate
        self.needsPreRead = needsPreRead
        self.needsExecution = needsExecution
        self.rankingMode = rankingMode
    }

    /// THE RESOLUTION LADDER, spelled once. A registered DYNAMIC application
    /// id wins the lane — its place is `(.applications, id)` by the pinned
    /// host-lane shape — otherwise the lead world answers for itself. A
    /// NATIVE application id ("pages") deliberately does not redirect the
    /// place: the world ladder already chose the world, and a native place
    /// never discriminates a lane inside its own world.
    public static func leadPlace(
        lead: AmbientWorld?, leadApplicationID: String?
    ) -> AmbientPlace? {
        if let id = leadApplicationID,
           let registration = AmbientApplicationIndexProvider.current.registration(id: id),
           registration.legacyWorld == nil {
            return registration.place
        }
        return lead.map(AmbientPlace.lane)
    }

    /// Named worlds as places, plus the gate's registered Dynamic mentions.
    /// Native ids in `gate.applications` are already covered by
    /// `namedWorlds`; only lane-carrying registrations add a member here.
    public static func namedPlaces(
        namedWorlds: Set<AmbientWorld>, gate: AmbientIntentGate,
        /// Places an address probe asserted. Carried SEPARATELY because the
        /// registration rung below cannot reach them: it skips every profile
        /// with a legacy world, and the browser workspace's profile
        /// (`safari`) has one — so an addressed browser would otherwise
        /// admit no place at all, and the roster scoping that reads this set
        /// would never see it.
        addressedPlaces: Set<AmbientPlace> = []
    ) -> Set<AmbientPlace> {
        var places = Set(namedWorlds.map(AmbientPlace.lane))
        for id in gate.applications {
            guard let registration =
                    AmbientApplicationIndexProvider.current.registration(id: id),
                  registration.legacyWorld == nil
            else { continue }
            places.insert(registration.place)
        }
        places.formUnion(addressedPlaces)
        return places
    }

}

public extension AmbientRoute {
    /// Applies the request-boundary routing decision to a later snapshot of
    /// held facts. Non-selection context may continue to refresh while the
    /// turn runs. A selection may not: it is an ephemeral, source-owned input
    /// and only the exact capture claimed by this route can cross the turn
    /// boundary.
    func admitsHeldFact(_ fact: AmbientFact) -> Bool {
        guard fact.slot == .selection else { return true }
        guard selectionDefinesTurn,
              let attention,
              attention.isDirectReference,
              let selectedText = attention.selectedText,
              attention.matches(fact),
              fact.world == attention.world,
              fact.applicationID == attention.applicationID,
              fact.subject == attention.subject,
              fact.capturedAt == attention.capturedAt
        else { return false }

        // AmbientKey identifies a superseding slot, not one capture. Source,
        // timestamp, and content close that identity gap so a later highlight
        // in the same application cannot masquerade as this turn's referent.
        return fact.content == String(selectedText.prefix(AmbientFact.contentCap))
    }

    /// The direct attention this route actually accepted as its referent.
    /// Diagnostic attention remains on the route when this is nil.
    var routedSelectionAttention: AmbientAttention? {
        selectionDefinesTurn && attention?.isDirectReference == true
            ? attention
            : nil
    }

    /// Attention after semantic containment. `attention` itself deliberately
    /// retains a rejected source packet for diagnostics; consumers that can
    /// influence prompts, routing, or execution use this projection instead.
    var routedAttention: AmbientAttention? {
        guard attention?.isDirectReference == true else { return attention }
        return routedSelectionAttention
    }

    /// Exact identity check between the source-owned packet frozen for this
    /// turn and the selection the route accepted. `AmbientAttention` has no
    /// packet UUID, so all immutable source/value fields participate. The
    /// TaskLocal selection snapshot closes the remaining identity boundary.
    func admitsSelectionHandoff(_ handoff: AmbientSelectionHandoff) -> Bool {
        guard let attention = routedSelectionAttention,
              handoff.world == attention.world,
              handoff.applicationID == attention.applicationID,
              handoff.subject == attention.subject,
              handoff.text == attention.selectedText,
              handoff.capturedAt == attention.capturedAt,
              handoff.editability == attention.selectionEditability,
              handoff.sourceEvidence == attention.selectionSourceEvidence,
              handoff.payloadRecovery == attention.selectionPayloadRecovery
        else { return false }
        return true
    }
}
