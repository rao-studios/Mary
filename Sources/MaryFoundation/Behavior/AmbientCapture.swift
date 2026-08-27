//
//  AmbientCapture.swift
//  MaryFoundation
//
//  THE INPUT HALF OF THE BEHAVIORAL CODEC — what Mary was looking at when she
//  was asked.
//
//  A request is not just its words. "Change the second paragraph" means
//  nothing without the document; "the other one" means nothing without the
//  roster. This is the structured form of the context that was actually put
//  in front of the model for one turn — the surfaces with their elements and
//  frames, the facts with their ages, the selection — captured so that the
//  pair (what she saw, what she did) is recoverable later.
//
//  WHAT WAS INJECTED, NOT WHAT WAS HELD. The store knows more than any one
//  turn uses; ranking and budgets decide what the model actually conditions
//  on. Capturing the whole store would teach a future model to act on context
//  the live one never received — the training input would not match the
//  inference input, which is the one thing behavioural cloning cannot
//  tolerate. It would also widen the privacy surface to documents the turn
//  never touched. So: exactly what was injected, no more.
//
//  ABSENT IS NOT EMPTY. A nil capture means no context was assembled at all
//  — a deterministic path that never built a prompt. An EMPTY capture means
//  one was assembled and there was nothing to see. Those are different facts
//  about the world and the codec keeps them different.
//
//  TOKENS, NOT ENUMS — the one rule that makes this file boring on purpose.
//  Places, slots and provenance are `String` here, never the live types they
//  came from. A written episode is a historical record; if it referenced
//  today's enums it would silently change meaning when a case is renamed, and
//  fail to decode when one is removed. The mapping from live type to token
//  lives in exactly one place (MaryAmbient's capture builder) and is pinned
//  by test there. Everything below just carries the words.
//
//  PRIVACY POSTURE, STATED PLAINLY. This type holds real content: fact text,
//  a selection, an excerpt of a document. That is a deliberate departure from
//  the redaction discipline the diagnostic ledgers keep — those record ids
//  and counts and cannot hold text by construction. A behavioural dataset
//  that redacted its own input would be useless. So the protections are
//  elsewhere and must stay: the store writes to a private directory, the
//  recording is switchable and purgeable, and the budgets above bound how
//  much text can reach here at all. Never widen this type without revisiting
//  that.
//

import Foundation

/// The application a captured surface belonged to.
public struct CapturedApplication: Codable, Hashable, Sendable {
    public var name: String
    public var bundleID: String?
    public var pid: Int32?

    public init(name: String, bundleID: String? = nil, pid: Int32? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
    }
}

/// One screen surface as it was injected: an application, its active window,
/// and the elements the tier-0 walk published.
public struct SurfaceCapture: Codable, Hashable, Sendable {

    /// The place this surface belongs to, as a token — `"textedit"`,
    /// `"applications"`. See the file header on why this is not a place type.
    public var place: String

    public var application: CapturedApplication
    public var windowTitle: String?
    public var windowFrame: AXFrame?

    /// The published elements, each carrying its own identity and frame.
    public var elements: [AXElementRecord]

    /// Elements the walk saw but this capture dropped for want of a frame.
    ///
    /// A count rather than a silence. A record needs geometry, and inventing
    /// a zero rect to fill the field would be a lie in the shape of data —
    /// so those elements are omitted and counted, and the invariant "walked
    /// elements have frames" stays observable rather than assumed.
    public var framelessDropped: Int

    /// Whether `elements` was cut short by the capture's element cap.
    public var truncated: Bool

    /// When the walk behind this surface happened — which may be a little
    /// before the turn, since surfaces are polled.
    public var capturedAt: Date

    public init(
        place: String,
        application: CapturedApplication,
        windowTitle: String? = nil,
        windowFrame: AXFrame? = nil,
        elements: [AXElementRecord] = [],
        framelessDropped: Int = 0,
        truncated: Bool = false,
        capturedAt: Date
    ) {
        self.place = place
        self.application = application
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.elements = elements
        self.framelessDropped = framelessDropped
        self.truncated = truncated
        self.capturedAt = capturedAt
    }

    private enum CodingKeys: String, CodingKey {
        case place, application, windowTitle, windowFrame
        case elements, framelessDropped, truncated, capturedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        place = try values.decode(String.self, forKey: .place)
        application = try values.decode(CapturedApplication.self, forKey: .application)
        windowTitle = try values.decodeIfPresent(String.self, forKey: .windowTitle)
        windowFrame = try values.decodeIfPresent(AXFrame.self, forKey: .windowFrame)
        elements = try values.decodeIfPresent([AXElementRecord].self, forKey: .elements) ?? []
        framelessDropped = try values.decodeIfPresent(Int.self, forKey: .framelessDropped) ?? 0
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
    }
}

/// One held fact as it was injected — a claim about a place, with its age.
public struct FactCapture: Codable, Hashable, Sendable {

    /// Place token — see the file header.
    public var place: String

    /// Slot token: which kind of claim this is — `"file"`, `"viewport"`,
    /// `"selection"`.
    public var slot: String

    public var text: String

    /// How old the claim was when injected.
    ///
    /// Load-bearing, not decoration: a fact renders with its age and loses
    /// authority as it grows, so a future model reading this needs to know
    /// the difference between "the document says X" and "the document said X
    /// four minutes ago".
    public var ageSeconds: Double

    /// Where the claim came from — a poll, a cached body, a read the user
    /// asked for. A token; see the file header.
    public var provenance: String?

    public init(
        place: String,
        slot: String,
        text: String,
        ageSeconds: Double,
        provenance: String? = nil
    ) {
        self.place = place
        self.slot = slot
        self.text = text
        self.ageSeconds = ageSeconds
        self.provenance = provenance
    }
}

/// What the user had selected, if anything.
public struct SelectionCapture: Codable, Hashable, Sendable {
    public var place: String
    public var application: CapturedApplication?
    public var text: String
    /// Whether the selection was truncated by the injection budget.
    public var truncated: Bool
    /// The evidence channel it arrived through — a token; the distinction
    /// between "the app told us" and "we inferred it" is what decides whether
    /// a selection may authorize a mutation.
    public var channel: String?
    public var capturedAt: Date

    public init(
        place: String,
        application: CapturedApplication? = nil,
        text: String,
        truncated: Bool = false,
        channel: String? = nil,
        capturedAt: Date
    ) {
        self.place = place
        self.application = application
        self.text = text
        self.truncated = truncated
        self.channel = channel
        self.capturedAt = capturedAt
    }
}

/// WHAT THE QUERY REQUIRED, as tokens.
public struct NeedCapture: Codable, Hashable, Sendable {
    /// Ability ids the utterance asked for.
    public var abilities: [String]
    /// The discipline a cue named, when one did.
    public var discipline: String?

    public init(abilities: [String] = [], discipline: String? = nil) {
        self.abilities = abilities
        self.discipline = discipline
    }

    private enum CodingKeys: String, CodingKey { case abilities, discipline }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        abilities = try values.decodeIfPresent([String].self, forKey: .abilities) ?? []
        discipline = try values.decodeIfPresent(String.self, forKey: .discipline)
    }
}

/// ONE APPLICATION THAT COULD HAVE SERVED, and the evidence about it.
public struct CandidateCapture: Codable, Hashable, Sendable {
    /// Place token — see the file header on why this is not a place type.
    public var place: String
    /// The needed abilities this one declares — the intersection, so an
    /// application conforming to two needs appears once carrying both.
    public var conformsByAbilities: [String]
    public var conformsByDiscipline: Bool
    public var targetClasses: [String]
    public var hasEyes: Bool
    /// The strongest live signal for this place and its age, when there was
    /// one. Absent means the user had done nothing here recently — which is
    /// usually why a conforming candidate lost.
    public var evidence: String?
    public var evidenceAgeSeconds: Double?

    public init(
        place: String,
        conformsByAbilities: [String] = [],
        conformsByDiscipline: Bool = false,
        targetClasses: [String] = [],
        hasEyes: Bool = false,
        evidence: String? = nil,
        evidenceAgeSeconds: Double? = nil
    ) {
        self.place = place
        self.conformsByAbilities = conformsByAbilities
        self.conformsByDiscipline = conformsByDiscipline
        self.targetClasses = targetClasses
        self.hasEyes = hasEyes
        self.evidence = evidence
        self.evidenceAgeSeconds = evidenceAgeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case place, conformsByAbilities, conformsByDiscipline
        case targetClasses, hasEyes, evidence, evidenceAgeSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        place = try values.decode(String.self, forKey: .place)
        conformsByAbilities =
            try values.decodeIfPresent([String].self, forKey: .conformsByAbilities) ?? []
        conformsByDiscipline =
            try values.decodeIfPresent(Bool.self, forKey: .conformsByDiscipline) ?? false
        targetClasses = try values.decodeIfPresent([String].self, forKey: .targetClasses) ?? []
        hasEyes = try values.decodeIfPresent(Bool.self, forKey: .hasEyes) ?? false
        evidence = try values.decodeIfPresent(String.self, forKey: .evidence)
        evidenceAgeSeconds = try values.decodeIfPresent(Double.self, forKey: .evidenceAgeSeconds)
    }
}

/// WHAT COULD HAVE SERVED, AND WHERE IT LANDED — the judgement half of the
/// input.
///
/// The surfaces and facts above record what Mary could SEE. This records what
/// she could USE, which is a different question and the one a future model
/// has to learn: a row saying "she typed into TextEdit" teaches an
/// association, and the same row saying "three applications conformed to
/// writing, TextEdit led on an activation four seconds old, the other two
/// were cold" teaches the choice.
public struct RealmCapture: Codable, Hashable, Sendable {

    /// What the query required.
    public var need: NeedCapture

    /// Everything that could have served it, in the resolver's order.
    public var candidates: [CandidateCapture]

    /// The place that won, as a token. Nil is a real observation: a turn can
    /// name a need, find applications that conform, and still point at
    /// nothing — nobody is in any of them and the user named none.
    public var place: String?

    /// WHICH SIGNAL CHOSE — named, deictic, frontmost, pinned. "TextEdit,
    /// because it was named" and "TextEdit, because it was in front" are
    /// different turns to learn from even when the place is identical.
    public var decidedBy: String?

    public init(
        need: NeedCapture = .init(),
        candidates: [CandidateCapture] = [],
        place: String? = nil,
        decidedBy: String? = nil
    ) {
        self.need = need
        self.candidates = candidates
        self.place = place
        self.decidedBy = decidedBy
    }

    private enum CodingKeys: String, CodingKey { case need, candidates, place, decidedBy }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        need = try values.decodeIfPresent(NeedCapture.self, forKey: .need) ?? .init()
        candidates = try values.decodeIfPresent(
            [CandidateCapture].self, forKey: .candidates) ?? []
        place = try values.decodeIfPresent(String.self, forKey: .place)
        decidedBy = try values.decodeIfPresent(String.self, forKey: .decidedBy)
    }
}

/// Everything the model was given about the world for one turn.
public struct AmbientCapture: Codable, Hashable, Sendable {

    /// How ranking chose what to include — token for the ranking mode.
    public var mode: String

    /// The place that led the turn, if one did. Token; nil when nothing led.
    public var lead: String?

    public var surfaces: [SurfaceCapture]
    public var facts: [FactCapture]
    public var selection: SelectionCapture?

    /// WHAT COULD HAVE SERVED THE NEED, and where it landed.
    ///
    /// Nil until the resolver that computes a realm exists — it needs the
    /// capability index, the roster and the focus signal together, which
    /// arrive with the brain. Nil here means "nobody worked out the
    /// candidates", never "there were none"; an empty `candidates` inside a
    /// present realm is the second thing, and the two are different rows.
    ///
    /// `lead` above stays and is not redundant: it is the place the prompt
    /// actually used. When both exist they must agree, and that is pinned —
    /// a dataset that disagreed with the prompt about the where would teach
    /// the wrong lesson confidently.
    public var realm: RealmCapture?

    /// THE RENDERED TEXT, exactly as it reached the prompt.
    ///
    /// Kept alongside the structured form rather than instead of it, and both
    /// halves earn their place. The structure is what a future model should
    /// learn to act on; these strings are what this build's model actually
    /// read. Keeping both means a disagreement between them — a renderer
    /// change that quietly alters what the model sees — is visible in the
    /// data instead of invisible.
    public var renderedSurfaceLines: [String]
    public var renderedBlocks: [String]
    public var renderedMentions: [String]

    public init(
        mode: String,
        lead: String? = nil,
        surfaces: [SurfaceCapture] = [],
        facts: [FactCapture] = [],
        selection: SelectionCapture? = nil,
        realm: RealmCapture? = nil,
        renderedSurfaceLines: [String] = [],
        renderedBlocks: [String] = [],
        renderedMentions: [String] = []
    ) {
        self.mode = mode
        self.lead = lead
        self.surfaces = surfaces
        self.facts = facts
        self.selection = selection
        self.realm = realm
        self.renderedSurfaceLines = renderedSurfaceLines
        self.renderedBlocks = renderedBlocks
        self.renderedMentions = renderedMentions
    }

    /// A capture that was assembled and found nothing. Distinct from a nil
    /// capture, which means none was assembled — see the file header.
    public static func empty(mode: String) -> AmbientCapture {
        AmbientCapture(mode: mode)
    }

    public var isEmpty: Bool {
        surfaces.isEmpty && facts.isEmpty && selection == nil && realm == nil
            && renderedSurfaceLines.isEmpty && renderedBlocks.isEmpty
            && renderedMentions.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case mode, lead, surfaces, facts, selection, realm
        case renderedSurfaceLines, renderedBlocks, renderedMentions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? ""
        lead = try values.decodeIfPresent(String.self, forKey: .lead)
        surfaces = try values.decodeIfPresent([SurfaceCapture].self, forKey: .surfaces) ?? []
        facts = try values.decodeIfPresent([FactCapture].self, forKey: .facts) ?? []
        selection = try values.decodeIfPresent(SelectionCapture.self, forKey: .selection)
        realm = try values.decodeIfPresent(RealmCapture.self, forKey: .realm)
        renderedSurfaceLines =
            try values.decodeIfPresent([String].self, forKey: .renderedSurfaceLines) ?? []
        renderedBlocks = try values.decodeIfPresent([String].self, forKey: .renderedBlocks) ?? []
        renderedMentions =
            try values.decodeIfPresent([String].self, forKey: .renderedMentions) ?? []
    }
}
