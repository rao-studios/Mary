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
//  Realms, slots and provenance are `String` here, never the live types they
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

    /// The realm this surface belongs to, as a token — `"textedit"`,
    /// `"applications"`. See the file header on why this is not a realm type.
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

    /// Realm token — see the file header.
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

/// Everything the model was given about the world for one turn.
public struct AmbientCapture: Codable, Hashable, Sendable {

    /// How ranking chose what to include — token for the ranking mode.
    public var mode: String

    /// The realm that led the turn, if one did. Token; nil when nothing led.
    public var lead: String?

    public var surfaces: [SurfaceCapture]
    public var facts: [FactCapture]
    public var selection: SelectionCapture?

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
        renderedSurfaceLines: [String] = [],
        renderedBlocks: [String] = [],
        renderedMentions: [String] = []
    ) {
        self.mode = mode
        self.lead = lead
        self.surfaces = surfaces
        self.facts = facts
        self.selection = selection
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
        surfaces.isEmpty && facts.isEmpty && selection == nil
            && renderedSurfaceLines.isEmpty && renderedBlocks.isEmpty
            && renderedMentions.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case mode, lead, surfaces, facts, selection
        case renderedSurfaceLines, renderedBlocks, renderedMentions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? ""
        lead = try values.decodeIfPresent(String.self, forKey: .lead)
        surfaces = try values.decodeIfPresent([SurfaceCapture].self, forKey: .surfaces) ?? []
        facts = try values.decodeIfPresent([FactCapture].self, forKey: .facts) ?? []
        selection = try values.decodeIfPresent(SelectionCapture.self, forKey: .selection)
        renderedSurfaceLines =
            try values.decodeIfPresent([String].self, forKey: .renderedSurfaceLines) ?? []
        renderedBlocks = try values.decodeIfPresent([String].self, forKey: .renderedBlocks) ?? []
        renderedMentions =
            try values.decodeIfPresent([String].self, forKey: .renderedMentions) ?? []
    }
}
