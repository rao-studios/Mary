//
//  AmbientCapture.swift
//  MaryFoundation
//
//  WHAT: Injected turn context — surfaces, facts, selection. Not the whole store.
//  IN:   MaryAmbient capture builder (live types → tokens).
//  OUT:  BehavioralInput, BehavioralTrainingPair.
//  PIN:  Nil = no prompt built; empty = assembled, nothing to see. Places/slots
//        are Strings. Holds real text; privacy is store/switch/budgets, not redaction here.
//
//  MIRRORS THE AMBIENT CORE ON PURPOSE. Each type here shadows a live MaryAmbient
//  one field for field, because these rows PERSIST — episodes are written to the
//  Totem corpus and decoded on later runs, so this schema must stay backward
//  compatible while the live types are free to change. Do not dedup them onto the
//  ambient types; project in AmbientCaptureBuilder, the one place they meet.
//

import Foundation

/// Application of a captured surface.
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

/// Injected surface: app, active window, tier-0 elements.
public struct SurfaceCapture: Codable, Hashable, Sendable {

    /// Place token (`"textedit"`). Not a live place type — see header.
    public var place: String

    public var application: CapturedApplication
    public var windowTitle: String?
    public var windowFrame: AXFrame?

    /// Published elements with identity and frame.
    public var elements: [AXElementRecord]

    /// Walked but dropped (no frame). Count, not a zero rect.
    public var framelessDropped: Int

    /// `elements` hit the capture cap.
    public var truncated: Bool

    /// Walk time (may precede the turn; surfaces are polled).
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

/// Injected fact about a place, with age.
public struct FactCapture: Codable, Hashable, Sendable {

    /// Place token.
    public var place: String

    /// Slot token (`"file"`, `"viewport"`, `"selection"`).
    public var slot: String

    public var text: String

    /// Age at inject. Load-bearing — authority decays.
    public var ageSeconds: Double

    /// Provenance token (poll / cache / asked read).
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

/// Selection, if any.
public struct SelectionCapture: Codable, Hashable, Sendable {
    public var place: String
    public var application: CapturedApplication?
    public var text: String
    /// Truncated by injection budget.
    public var truncated: Bool
    /// Evidence-channel token. App-told vs inferred gates mutation.
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

/// Query needs, as tokens.
public struct NeedCapture: Codable, Hashable, Sendable {
    /// Ability ids named by the utterance.
    public var abilities: [String]
    /// Discipline a cue named, if any.
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

/// One candidate application and its evidence.
public struct CandidateCapture: Codable, Hashable, Sendable {
    /// Place token.
    public var place: String
    /// Intersection of needed abilities this app declares.
    public var conformsByAbilities: [String]
    public var conformsByDiscipline: Bool
    public var targetClasses: [String]
    public var hasEyes: Bool
    /// Strongest live signal + age. Nil = nothing recent here.
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

/// What could serve the need, and where it landed. See vs use.
public struct RealmCapture: Codable, Hashable, Sendable {

    /// Query requirements.
    public var need: NeedCapture

    /// Candidates in resolver order.
    public var candidates: [CandidateCapture]

    /// Winning place token. Nil is observed: need named, nobody pointed.
    public var place: String?

    /// Choosing signal: named, deictic, frontmost, pinned.
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

/// World as injected for one turn.
public struct AmbientCapture: Codable, Hashable, Sendable {

    /// Ranking-mode token.
    public var mode: String

    /// Leading place token. Nil if nothing led.
    public var lead: String?

    public var surfaces: [SurfaceCapture]
    public var facts: [FactCapture]
    public var selection: SelectionCapture?

    /// Realm judgement. Nil = not computed; empty candidates = none.
    /// PIN: when present, must agree with `lead`.
    public var realm: RealmCapture?

    /// Prompt text as rendered. Kept beside structure so renderer drift is visible.
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

    /// Assembled, found nothing. Distinct from nil (none assembled).
    public static func empty(mode: String) -> AmbientCapture {
        AmbientCapture(mode: mode)
    }

    public var isEmpty: Bool {
        surfaces.isEmpty && facts.isEmpty && selection == nil && realm == nil
            && renderedSurfaceLines.isEmpty && renderedBlocks.isEmpty
            && renderedMentions.isEmpty
    }

    /// Pretty-print for inspector surfaces.
    public var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
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
