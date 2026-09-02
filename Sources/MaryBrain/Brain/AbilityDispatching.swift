//
//  AbilityDispatching.swift
//  MaryBrain
//
//  WHAT: Brain seam onto the activities system + SeerPass.
//  IN:   MaryBrain turn loop
//  OUT:  AbilityRuntime.dispatch / fetch-first / locate
//  PIN:  Sibling of MaryBrain.swift; treat split members as private.
//
import MaryVoice
import Foundation

/// What the brain needs from the activities system — ActivityRegistry conforms.
public protocol AbilityDispatching: Sendable {
    var schemas: [ModelSkillSchema] { get }
    /// The immutable schema graph currently projected by the dispatcher.
    /// `AbilityTurnContext` freezes this value for the duration of a turn.
    var abilitySnapshot: AbilityRuntimeSnapshot { get }
    /// Frozen package/ability/skill identity for receipts and conversation
    /// badges. External providers still use their wire term "Skill"; Mary's
    /// domain records the invocation as a Skill belonging to an Ability.
    func skillReference(for invocationName: String) -> AbilitySkillReference
    /// The installed application capability catalog.
    var applicationProfiles: [ApplicationProfile] { get }
    /// Exact logical identity for the currently frontmost admitted
    /// application, including Dynamic providers that have no AmbientAttention
    /// enum case. Nil when no profile owns the frontmost bundle identity.
    var focusedApplicationID: String? { get }
    /// How many skills THIS turn would expose, WITHOUT building them.
    var schemaCount: Int { get }
    /// Privacy-safe conflict/fallback decisions for the frozen turn roster.
    var abilityRosterTrace: AbilityRosterTrace { get }
    /// ONE ACT, ONE IDENTITY. `runID` is the model's own invocation id — the string the chip, the session ledger and the sealed episode all key on.
    func dispatch(name: String, argumentsJSON: String, runID: String?) async -> SkillOutcome

    /// Ask one running call to stop, by the id its chip shows. A dispatcher
    /// with nothing in flight — every test fake — does nothing, which is the
    /// honest answer rather than a fatal.
    func cancelRun(id: String)

    /// Calls still running, keyed by the id the chip shows. Default empty.
    var runningRunIDs: Set<String> { get }

    /// Live ceiling on ordinary Skill dispatch (1…10 s). Named long jobs ignore it.
    func setOrdinarySkillTimeout(_ seconds: TimeInterval)

    /// RUN A SEQUENCE OF ACTIONS — the door a future model's emitted plan walks through.
    /// PIN: PLUMBING ONLY, and deliberately so: nothing user-facing calls this yet.
    func perform(
        sequence: [BehavioralAction], episodeID: UUID?
    ) async -> [BehavioralActionRecord]
    /// Called at the start of every user turn (pending-confirmation expiry
    /// bookkeeping). Default: no-op.
    func beginTurn()
    /// Whether a confirmable action is genuinely waiting. The brain trusts
    /// THIS — never the "CONFIRM:" text, which any Skill output could forge.
    var hasPendingSkillConfirmation: Bool { get }
    /// Stable identity of the action currently awaiting approval.
    var pendingSkillConfirmationID: UUID? { get }
    /// The stored question of the action awaiting approval, spoken to the user VERBATIM.
    var pendingSkillConfirmationPreview: String? { get }
    /// True for query Skills (`.read`) that shouldn't be archived into the Totem context
    func isReadOnly(_ skillName: String) -> Bool
    /// The screen look, identified structurally — its summary IS the answer's
    /// content, so the routine settle policy must never silence it the way a
    /// deposited machine receipt is silenced. Default false.
    func isLookSkill(_ skillName: String) -> Bool
    /// A cognitive activation — instruction for the model's next round, no application effect.
    func isNonEffectful(_ skillName: String) -> Bool
    /// The binding staged a surface (created/opened/raised) without delivering
    /// the asked-for work. Same continuation role as `isNonEffectful`, and the
    /// stage-failure recovery gate reads it too. Default false.
    func preparesSurface(_ skillName: String) -> Bool
    /// WHICH PLACE owns a Skill — the dispatcher is the only thing that knows.
    func place(ofSkill skillName: String) -> AmbientPlace?
    /// The lane a Skill's place sits in, for the few readers that genuinely
    /// want the lane rather than the where.
    func attention(ofSkill skillName: String) -> AmbientAttention?
    /// FETCH-FIRST: read the named part of whatever the user is looking at, synchronously, before the speaking lane spawns
    func readNamedPart(_ phrase: String) async -> String?
    /// THE PRE-LANE LOOK — `readNamedPart`'s sibling for sight: run the screen look synchronously before either lane spawns
    func lookAtScreen(_ query: String?) async -> String?
    /// Whether a pre-lane look WOULD run right now (look_at_screen is
    /// installed). Targeted reads are not eyes. Default false.
    func wouldServeLook() -> Bool
    /// Fetch-first: selection read, buffer/document inspect, then look —
    /// before either lane speaks. `isRead` tells the caller whether the
    /// passage came from a genuine read (Lane B already holds it) or a look.
    func fetchDeclaredEditorSight(query: String?) async -> (passage: String, isRead: Bool)?
    /// FETCH-FIRST FOR THE CRAFT ITSELF: the unit the user is inside, and what
    /// reaches it. Nil when nothing followed is in front, when the turn is not
    /// one this should serve, or when there is nothing true to say.
    func fetchAwareness(query: String) async -> AwarenessSight?
    /// LOCATE-FIRST: find the passage a REVISION is about, before either lane exists, and hand back a handle plus the verb that changes it.
    /// `readNamedPart`'s sibling and its opposite.
    func locatePassage(_ intent: EditIntent) async -> LocatedPassage?
    /// The same locate with a WORLD HINT for the one turn shape that has no live focus to lean on: an accepted offer
    func locatePassage(_ intent: EditIntent, attentionHint: AmbientAttention?) async -> LocatedPassage?
    // THE ARTIFACT LANE IS NOT IN THIS CUT. Five members used to sit here
    func targetedReadInvocation(forAttention attention: AmbientAttention) -> (binding: String, parameter: String)?
}

public extension AbilityDispatching {
    /// The loop, defaulted, so every conformer — the real runtime and every
    /// fake — gets identical sequence semantics for free.
    func cancelRun(id: String) {}

    var runningRunIDs: Set<String> { [] }

    func setOrdinarySkillTimeout(_ seconds: TimeInterval) {}

    func perform(
        sequence: [BehavioralAction], episodeID: UUID? = nil
    ) async -> [BehavioralActionRecord] {
        var records: [BehavioralActionRecord] = []
        for action in sequence {
            let startedAt = Date()
            // Minted once and used for BOTH the dispatch and the record, so a
            // replayed step is one identity end to end — the same rule the
            // model-driven path now follows with the wire id.
            let runID = UUID().uuidString
            let outcome = await dispatch(
                name: action.intention, argumentsJSON: action.argumentsJSON,
                runID: runID)
            let record = BehavioralActionRecord(
                outcome: outcome,
                intention: action.intention,
                argumentsJSON: action.argumentsJSON,
                reference: action.skill,
                runID: runID,
                startedAt: startedAt)
            records.append(record)
            guard record.disposition == .succeeded else { break }
        }
        return records
    }

    /// Correct-but-slow default, so a stub dispatcher gets it for free. The
    /// real registry overrides it with an arithmetic answer.
    var schemaCount: Int { schemas.count }
    var abilityRosterTrace: AbilityRosterTrace { .empty }
    var applicationProfiles: [ApplicationProfile] { [] }
    var focusedApplicationID: String? { nil }
    /// Empty unless the dispatcher freezes a registry. Loading the live
    /// library here would vectorize every package as a side effect of routing.
    var abilitySnapshot: AbilityRuntimeSnapshot { .empty }
    func skillReference(for invocationName: String) -> AbilitySkillReference {
        abilitySnapshot.reference(forInvocation: invocationName)
    }
    func beginTurn() {}
    var hasPendingSkillConfirmation: Bool { false }
    var pendingSkillConfirmationID: UUID? {
        // Compatibility for lightweight dispatchers that predate identity:
        // absent/present transitions remain observable, while a pending that
        // was already present compares equal across the current dispatch.
        hasPendingSkillConfirmation
            ? UUID(uuidString: "00000000-0000-0000-0000-000000000001")
            : nil
    }
    var pendingSkillConfirmationPreview: String? { nil }
    func isReadOnly(_ skillName: String) -> Bool { false }
    func isLookSkill(_ skillName: String) -> Bool { false }
    func isNonEffectful(_ skillName: String) -> Bool { false }
    func preparesSurface(_ skillName: String) -> Bool { false }
    func place(ofSkill skillName: String) -> AmbientPlace? { nil }
    func attention(ofSkill skillName: String) -> AmbientAttention? { place(ofSkill: skillName)?.attention }
    func readNamedPart(_ phrase: String) async -> String? { nil }
    func lookAtScreen(_ query: String?) async -> String? { nil }
    func wouldServeLook() -> Bool { false }
    func fetchDeclaredEditorSight(query: String?) async -> (passage: String, isRead: Bool)? { nil }
    func fetchAwareness(query: String) async -> AwarenessSight? { nil }
    func locatePassage(_ intent: EditIntent) async -> LocatedPassage? { nil }
    func locatePassage(_ intent: EditIntent, attentionHint: AmbientAttention?) async -> LocatedPassage? {
        await locatePassage(intent)
    }
    func targetedReadInvocation(forAttention attention: AmbientAttention) -> (binding: String, parameter: String)? {
        nil
    }
}
/// What one awareness pass found: the work itself, and its bearings.
///
/// TWO FIELDS, NOT ONE STRING, because they are answers to different
/// questions and land in different places. The UNIT is text Mary read and may
/// quote — it rides the same road every other pre-read takes. The
/// SURROUNDINGS are references with file and line, which are bearings for
/// speaking about the unit and never something to recite.
public struct AwarenessSight: Sendable, Equatable {
    /// The declaration or passage the user is inside.
    public var unit: String?
    /// What reaches it, what it reaches, and where their words landed.
    public var surroundings: String?

    public init(unit: String? = nil, surroundings: String? = nil) {
        self.unit = unit
        self.surroundings = surroundings
    }

    /// Nothing was found. The caller treats this as no pass at all.
    public var isEmpty: Bool {
        (unit?.isEmpty ?? true) && (surroundings?.isEmpty ?? true)
    }
}

/// What ONE spoken pass needs beyond the live focus.
public struct SeerPass: Sendable {
    /// Finished ACTIONS to report — the detached follow-up persona.
    public var groundedResults: String?
    /// Text READ for this turn: the fetch-first pre-read, or a read the
    /// orchestrator lane performed and joined. Lands LAST, inside the live
    /// block — see MaryPrompts.seerInstructions(readPassages:).
    public var readPassages: [String]
    /// This pass exists only to speak `readPassages` back — the read persona.
    public var readReport: Bool
    /// THE TURN ASKED FOR NOTHING — `AmbientIntent.converse`.
    public var conversational: Bool
    /// The world to resolve against. Nil = resolve LIVE, which is what every
    /// in-turn pass wants; callers that outlive their turn (a detached
    /// routine's follow-up) pass the world they were spawned in.
    public var assertedFocus: WorkspaceFocus?

    /// Labels of routines from EARLIER turns that are still running.
    public var runningActionLabels: [String]

    /// A LOOK FIRED FOR THIS VERY TURN and nothing is in hand yet (the pre-lane look missed its budget; Lane B carries it).
    public var lookUnderway: Bool

    /// The turn World already holds a highlight this question is about — a look/read is incoming even before lookUnderway.
    public var inspiredSight: Bool

    /// THE ROUTER'S OWN VERDICT was perceive — a judgment question about
    /// work in hand ("what do you think of this"), not small talk and not a
    /// plain recitation request.
    public var perceiving: Bool

    /// TRACED THIS TURN: what reaches the work in front of them and what it
    /// reaches, each naming its own file and line. Beside `readPassages`
    /// rather than inside it — a bearing is not a passage, and the voice must
    /// not recite one.
    public var awareness: [String]

    /// Which `RetrievalTraceLedger` row this pass's prompt build books to — observation only.
    public var exchangeID: UUID?

    public init(
        groundedResults: String? = nil,
        readPassages: [String] = [],
        readReport: Bool = false,
        conversational: Bool = false,
        assertedFocus: WorkspaceFocus? = nil,
        runningActionLabels: [String] = [],
        lookUnderway: Bool = false,
        inspiredSight: Bool = false,
        perceiving: Bool = false,
        awareness: [String] = [],
        exchangeID: UUID? = nil
    ) {
        self.groundedResults = groundedResults
        self.readPassages = readPassages
        self.readReport = readReport
        self.conversational = conversational
        self.assertedFocus = assertedFocus
        self.runningActionLabels = runningActionLabels
        self.lookUnderway = lookUnderway
        self.inspiredSight = inspiredSight
        self.perceiving = perceiving
        self.awareness = awareness
        self.exchangeID = exchangeID
    }
}
