//
//  AbilityDispatching.swift
//  MaryBrain
//
//  The brain's seam to the activities system, moved whole from
//  MaryBrain.swift's preamble: the `AbilityDispatching` protocol
//  (ActivityRegistry conforms), its defaulted extension, and `SeerPass`
//  (what one spoken pass needs beyond the live focus).
//
//  Everything moved verbatim; no behavior change. No access promotions were
//  needed — every declaration here was already a top-level type.
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
    /// application, including Dynamic providers that have no AmbientWorld
    /// enum case. Nil when no profile owns the frontmost bundle identity.
    var focusedApplicationID: String? { get }
    /// How many skills THIS turn would expose, WITHOUT building them.
    ///
    /// `schemas` is not a stored property: reading it calls `focusProvider()`
    /// — which in the app resolves the whole focus decision — and constructs
    /// ~130 `ModelSkillSchema` values. Correct and cheap enough once per model
    /// round; pure waste for a debugger row that wants an integer. The Routes
    /// pane asked for `schemas.count` and silently bought a second focus
    /// resolution on every single turn.
    var schemaCount: Int { get }
    /// Privacy-safe conflict/fallback decisions for the frozen turn roster.
    var abilityRosterTrace: AbilityRosterTrace { get }
    func dispatch(name: String, argumentsJSON: String) async -> SkillOutcome

    /// RUN A SEQUENCE OF ACTIONS — the door a future model's emitted plan
    /// walks through.
    ///
    /// PLUMBING ONLY, and deliberately so: nothing user-facing calls this
    /// yet. It exists now because the behavioral codec's whole point is that
    /// `BehavioralAction` is the EMIT shape as well as the observed one — a
    /// model trained on episodes emits a sequence of the same objects it was
    /// shown. Building the entrance while the shape is being designed is how
    /// the shape stays honest; discovering later that the recorded object
    /// cannot be replayed would mean the dataset described something Mary
    /// cannot do.
    ///
    /// STOPS ON THE FIRST NON-SUCCESS, because a sequence is a plan and a
    /// plan whose second step failed has no business running its fifth. The
    /// records returned cover what actually ran, so the caller can see where
    /// it stopped and why.
    func perform(
        sequence: [BehavioralAction], episodeID: UUID?
    ) async -> [BehavioralActionRecord]
    /// Called at the start of every user turn (pending-confirmation expiry
    /// bookkeeping). Default: no-op.
    func beginTurn()
    /// Whether a confirmable action is genuinely waiting. The brain trusts
    /// THIS — never the "CONFIRM:" text, which any Skill output could forge.
    var hasPendingSkillConfirmation: Bool { get }
    /// Stable identity of the action currently awaiting approval. Orchestration
    /// compares this at the dispatch boundary so a pending action inherited
    /// from an earlier turn cannot make an unrelated current action ask for
    /// approval. A newly parked replacement has a new identity even while
    /// `hasPendingSkillConfirmation` remains true throughout.
    var pendingSkillConfirmationID: UUID? { get }
    /// The stored question of the action awaiting approval, spoken to the
    /// user VERBATIM. Held rather than re-derived from outcome summaries,
    /// because the summary is machine-framed tool data ("CONFIRM: …") and
    /// parsing the question back out of it is how a model-directed clause
    /// once reached the user's ears word for word.
    var pendingSkillConfirmationPreview: String? { get }
    /// True for query Skills (`.read`) that shouldn't be archived into the
    /// Totem context — depositing every read (read_lines, read_symbol,
    /// current_file, …) turns them into retrievable "documents" that Seer's
    /// RAG re-surfaces as self-referential noise in the voice. Only mutations
    /// are worth recalling. Default false (deposit).
    func isReadOnly(_ skillName: String) -> Bool
    /// The screen look, identified structurally — its summary IS the answer's
    /// content, so the routine settle policy must never silence it the way a
    /// deposited machine receipt is silenced. Default false.
    func isLookSkill(_ skillName: String) -> Bool
    /// A cognitive activation — instruction for the model's next round, no
    /// application effect. The lane continuation treats these like reads so a
    /// compose→type compound is continued into its delivery half instead of
    /// terminating on the activation. Default false.
    func isNonEffectful(_ skillName: String) -> Bool
    /// The binding staged a surface (created/opened/raised) without delivering
    /// the asked-for work. Same continuation role as `isNonEffectful`, and the
    /// stage-failure recovery gate reads it too. Default false.
    func preparesSurface(_ skillName: String) -> Bool
    /// WHICH PLACE owns a Skill — the dispatcher is the only thing that knows.
    ///
    /// EYES ARE AN UPGRADE, NEVER A PRECONDITION: this is how a turn tells
    /// "the Skill the user actually invoked" apart from "whatever application
    /// happens to be open", so a calendar action taken while an editor leads
    /// is filed, scoped and reported as a calendar action. Default nil.
    func place(ofSkill skillName: String) -> AmbientPlace?
    /// The lane a Skill's place sits in, for the few readers that genuinely
    /// want the lane rather than the where.
    func world(ofSkill skillName: String) -> AmbientWorld?
    /// FETCH-FIRST: read the named part of whatever the user is looking at,
    /// synchronously, before the speaking lane spawns — the passage then rides
    /// the live-work channel that already works end to end.
    ///
    /// Answers nil whenever nothing in view can serve the request (the leading
    /// world has no targeted read, or the read failed). That nil is the
    /// structural bound on the classifier's deliberate bias toward firing: an
    /// over-eager match on a coding turn, or with nothing open, costs nothing
    /// at all. Default: nil — no pre-read, today's behaviour.
    func readNamedPart(_ phrase: String) async -> String?
    /// THE PRE-LANE LOOK — `readNamedPart`'s sibling for sight: run the
    /// screen look synchronously before either lane spawns, so the voice
    /// speaks the description in-turn instead of denying sight while the
    /// hands look. Nil = declined (an eyed world leads), refused, or missed;
    /// the turn proceeds lookless. Default nil — no look, prior behavior.
    func lookAtScreen(_ query: String?) async -> String?
    /// Whether a pre-lane look WOULD run right now (no eyed world leads, the
    /// binding installed) — asked before promising one. Default false.
    func wouldServeLook() -> Bool
    /// LOCATE-FIRST: find the passage a REVISION is about, before either lane
    /// exists, and hand back a handle plus the verb that changes it.
    ///
    /// `readNamedPart`'s sibling and its opposite. That one fetches TEXT TO
    /// SPEAK for a question; this one produces A THING TO ACT ON for a command,
    /// and it exists because the gates below need a FACT to stand on. A
    /// paragraph asking the model to prefer `replace_passage` is necessary and
    /// insufficient — this tree has three times replaced an instruction the
    /// model ignored with a mechanism it could not (`ActionClassifier`,
    /// `bareDecision`, `hasPendingSkillConfirmation`), and every one of those needed
    /// something true to test.
    ///
    /// Nil is common and costs exactly nothing: no leading world, a world that
    /// composes but cannot revise, nothing open, nothing found. No gate fires,
    /// the turn behaves precisely as it did before any of this existed, and the
    /// report says plainly she could not locate it. That is what makes the
    /// classifier's deliberate over-reach free — `EditIntentClassifier` answers
    /// "this sentence is SHAPED like a revision", never "there is something
    /// here to revise", and this nil is where the second question gets asked.
    /// Default: nil — no locate, today's behaviour.
    func locatePassage(_ intent: EditIntent) async -> LocatedPassage?
    /// The same locate with a WORLD HINT for the one turn shape that has no
    /// live focus to lean on: an accepted offer, where the world the passage
    /// was discussed in is a conversation fact the brain carries. The hint
    /// fills a nil focus, never outranks a live one. Default: forwards to the
    /// hint-less requirement, so existing conformers change nothing.
    func locatePassage(_ intent: EditIntent, worldHint: AmbientWorld?) async -> LocatedPassage?
    // THE ARTIFACT LANE IS NOT IN THIS CUT. Five members used to sit here —
    // a skill's create-or-mutate role, the redirect a blocked create should
    // take, and the created-surface referent arming — all of them serving a
    // canvas domain (shapes on a page, with ids and geometry) that Mary does
    // not have. They come back together with it or not at all.
    /// The one targeted read a world declares — what a `WorldVeto` redirect
    /// names as the right way to look at the leading document. Nil means the
    /// world has none, and a veto with nothing to redirect to must not arm.
    /// Default: nil.
    func targetedReadInvocation(forWorld world: AmbientWorld) -> (binding: String, parameter: String)?
}

public extension AbilityDispatching {
    /// The loop, defaulted, so every conformer — the real runtime and every
    /// fake — gets identical sequence semantics for free.
    func perform(
        sequence: [BehavioralAction], episodeID: UUID? = nil
    ) async -> [BehavioralActionRecord] {
        var records: [BehavioralActionRecord] = []
        for action in sequence {
            let startedAt = Date()
            let outcome = await dispatch(
                name: action.intention, argumentsJSON: action.argumentsJSON)
            let record = BehavioralActionRecord(
                outcome: outcome,
                intention: action.intention,
                argumentsJSON: action.argumentsJSON,
                reference: action.skill,
                runID: UUID().uuidString,
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
    var abilitySnapshot: AbilityRuntimeSnapshot { AbilityLibrary.shared.snapshot() }
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
    func world(ofSkill skillName: String) -> AmbientWorld? { place(ofSkill: skillName)?.world }
    func readNamedPart(_ phrase: String) async -> String? { nil }
    func lookAtScreen(_ query: String?) async -> String? { nil }
    func wouldServeLook() -> Bool { false }
    func locatePassage(_ intent: EditIntent) async -> LocatedPassage? { nil }
    func locatePassage(_ intent: EditIntent, worldHint: AmbientWorld?) async -> LocatedPassage? {
        await locatePassage(intent)
    }
    func targetedReadInvocation(forWorld world: AmbientWorld) -> (binding: String, parameter: String)? {
        nil
    }
}
/// What ONE spoken pass needs beyond the live focus. A struct, not a widening
/// parameter list: this was `(String?, WorkspaceFocus?)`, the fetch-first
/// passage and the read-report flag make it four, and a positional
/// `(String?, WorkspaceFocus?, [String], Bool)` is precisely how the wrong
/// argument lands in the wrong slot.
///
/// `groundedResults` and `readReport` are MUTUALLY EXCLUSIVE at every call
/// site, and must stay that way: their personas contradict each other outright
/// ("never repeat the content that was written" vs "read the passage back at
/// whatever length it needs").
public struct SeerPass: Sendable {
    /// Finished ACTIONS to report — the detached follow-up persona.
    public var groundedResults: String?
    /// Text READ for this turn: the fetch-first pre-read, or a read the
    /// orchestrator lane performed and joined. Lands LAST, inside the live
    /// block — see MaryPrompts.seerInstructions(readPassages:).
    public var readPassages: [String]
    /// This pass exists only to speak `readPassages` back — the read persona.
    public var readReport: Bool
    /// The world to resolve against. Nil = resolve LIVE, which is what every
    /// in-turn pass wants; callers that outlive their turn (a detached
    /// routine's follow-up) pass the world they were spawned in.
    public var assertedFocus: WorkspaceFocus?

    /// Labels of routines from EARLIER turns that are still running. Carried
    /// on the pass so the note becomes a SECTION of the voice plan rather than
    /// a string appended after it — appending put it after the terminal
    /// live-work block, i.e. inside what the model reads as the document.
    public var runningActionLabels: [String]

    /// A LOOK FIRED FOR THIS VERY TURN and nothing is in hand yet (the
    /// pre-lane look missed its budget; Lane B carries it). The voice must
    /// say it's looking — never deny sight — and the description follows as
    /// the spoken follow-up.
    public var lookUnderway: Bool

    /// Which `RetrievalTraceLedger` row this pass's prompt build books to —
    /// observation only. Nil books nothing, and nil is CORRECT for the two
    /// passes that are not exchanges: an ambient remark answers no user turn
    /// (there is no row to join), and a detached routine's follow-up outlives
    /// the turn that spawned it (booking there would file a late prompt under
    /// an exchange the user has already moved past).
    public var exchangeID: UUID?

    public init(
        groundedResults: String? = nil,
        readPassages: [String] = [],
        readReport: Bool = false,
        assertedFocus: WorkspaceFocus? = nil,
        runningActionLabels: [String] = [],
        lookUnderway: Bool = false,
        exchangeID: UUID? = nil
    ) {
        self.groundedResults = groundedResults
        self.readPassages = readPassages
        self.readReport = readReport
        self.assertedFocus = assertedFocus
        self.runningActionLabels = runningActionLabels
        self.lookUnderway = lookUnderway
        self.exchangeID = exchangeID
    }
}
