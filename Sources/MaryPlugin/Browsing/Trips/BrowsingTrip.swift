//
//  BrowsingTrip.swift
//  MaryPlugin
//
//  WHAT: One browsing journey a person actually takes, written down as legs —
//        the utterance, and the SHAPE of what must happen, in Mary's vocabulary.
//  IN:   a path the caller passes (staged under ~/.mary/trips)
//  OUT:  mary-web-probe --trip, Sand --trip, the grammar and replay suites
//  PIN:  A TRIP NAMES A CLASS OF PAGE AND A CLASS OF ROW, NEVER A SITE.
//        The whole point of driving the engine from real journeys is to generalize
//        it, and an expectation written as "the winner is the row labelled X on
//        site Y" generalizes to nothing — it is a hard-coded route wearing a test's
//        clothes, and the next page defeats it. So there is NO label field, no
//        address field and no coordinate anywhere in this grammar: what a leg may
//        assert about the row it reached is the FACTS the seal decided about it,
//        its affordance, its kind, and its position within its kind. The validator
//        below refuses the rest mechanically rather than trusting the author.
//        THE UTTERANCE IS THE PERSON'S OWN WORDS and may say anything at all,
//        including a site's name — it is what they SAID, not what Mary must match.
//        ADDRESSES LIVE OUTSIDE THE REPOSITORY. Staging Chrome on "a results page"
//        needs a real address, and the browsing lane speaks site names and never
//        URLs; a recorded trip must not be the one place a query string survives.
//        See `TripStaging` — the seeds are read from ~/.mary/trips/stage.json.
//

import Foundation
import MaryAmbient
import MaryComputerUse

// MARK: - The closed vocabularies

/// What KIND of page a leg needs under it. Never a site, never an address.
public enum TripPageClass: String, Sendable, Equatable, Codable, CaseIterable {
    /// Anything at all — the leg does not care what is on screen.
    case any
    /// A search engine's own results.
    case resultsPage
    /// A page whose main content is a video player.
    case watchPage
    /// Prose with headings — the thing `read_page_text` answers about.
    case article
    /// A dialog covering the page, with something to press in it.
    case consentWall
    /// A site with its own search box, for the search-within-a-site path.
    case siteWithSearchBox
    /// Fields and a submit.
    case form
    /// A page holding something to drag to a position.
    case sliderPage
    /// Nothing loaded.
    case blank
}

/// Which lane answered the utterance.
public enum TripLane: String, Sendable, Equatable, Codable, CaseIterable {
    /// One skill won the corpus uniquely and its arguments were fillable — no
    /// model round at all.
    case confidence
    /// The model was asked.
    case model
    /// Nothing dispatched.
    ///
    /// PIN: NAMED `nothing`, WITH THE RAW VALUE "none", ON PURPOSE. A case called
    /// `none` collides with `Optional.none` at every Swift call site that passes
    /// `.none` to a `TripLane?` — it resolves to nil, the leg silently asserts no
    /// lane at all, and a test built that way passed for the wrong reason before
    /// the mismatch surfaced. The JSON keeps saying "none", which is what a trip
    /// author would write; only the Swift name steps out of the trap.
    case nothing = "none"
}

/// The argument shape the confidence lane could fill. Mirrors
/// `EmbeddingRouting.ConfidenceArgumentShape`, spelled out here because a trip
/// is data and MaryPlugin sits below MaryBrain.
public enum TripArgumentShape: String, Sendable, Equatable, Codable, CaseIterable {
    case noRequiredArguments
    case singleString
    case singleEnum
}

/// Which rung of the provider ladder chose the application.
public enum TripProviderRationale: String, Sendable, Equatable, Codable, CaseIterable {
    case named, interaction, pinned, focused, habit, staticPreference
}

/// What the goal was for. Mirrors `PageRouteVerb` without its query payload —
/// a trip states the verb, and the query is whatever the previous leg searched.
public enum TripRouteVerb: String, Sendable, Equatable, Codable, CaseIterable {
    case press, fill, adjust, reveal, openResult

    /// HOW THE TRACE SPELLS IT, WHICH IS NOT HOW A TRIP DOES.
    ///
    /// PIN: `PageRouteVerb.word` PRINTS `openResult` AS "result", and comparing
    /// a trip's raw value with a recorded verb silently never matched — a leg
    /// asking about the openResult arbitration was judged against the inner
    /// press and reported as routing with the wrong verb. Measured live on a
    /// search, which routes twice. One conversion, in the type that owns the
    /// vocabulary, rather than a string comparison at each reader.
    public var traceWord: String {
        self == .openResult ? "result" : rawValue
    }

    /// The trip's word for what a trace calls `word`.
    public static func named(traceWord: String) -> TripRouteVerb? {
        traceWord == "result" ? .openResult : TripRouteVerb(rawValue: traceWord)
    }
}

/// The receipt rank an act must produce. Mirrors `PageEffectEvidence`, plus
/// `none` for "delivered, nothing proved".
public enum TripReceipt: String, Sendable, Equatable, Codable, CaseIterable {
    case navigation, targetChanged, textAppeared, rosterChanged, mediaState, dialogAnswered, none
}

/// A refusal, by class. The engine's own `BrowserRefusal` cases, without their
/// payloads — a trip asserts WHICH refusal, never its sentence.
public enum TripRefusal: String, Sendable, Equatable, Codable, CaseIterable {
    case noBrowser, ambiguousBrowser, shellUnreadable, pageNotVisible
    case visionUnavailable, controlsNotFound, controlNotFound, stateUnchanged
    case navigationDidNotSettle, humanCheck, addressFieldNotFound, elementNotFound
    case ambiguousElement, planInvalid, interrupted, searchCompletedElsewhere
    case notFillable, notAdjustable, outOfTime, activationRefused, notImplemented
    /// The browser itself is asking something and nothing can proceed until it
    /// is answered. See `BrowserRefusal.browserIsAsking`.
    case browserIsAsking
    case workingWindowGone
}

/// Where the machine's attention must be after a leg.
public enum TripFrontAfter: String, Sendable, Equatable, Codable, CaseIterable {
    /// The browser is in front — what happens when it was in front already.
    case browser
    /// Whatever was in front BEFORE the leg is in front again. The invariant
    /// that makes the browser reachable from another surface without stealing it.
    case restored
}

/// A row's affordance, as a trip states it. Mirrors `SeenAffordance`.
public enum TripAffordance: String, Sendable, Equatable, Codable, CaseIterable {
    case press, fill, adjust, scroll, none
}

// MARK: - The blocks of one leg

/// Which skill the words must reach, on which lane.
public struct TripRoutingExpectation: Sendable, Equatable, Codable {
    /// The invocation name — `search_web`, `control_media`.
    public var skill: String
    /// The intent the triage must read. Nil when the leg does not care.
    public var intent: String?
    public var lane: TripLane?
    public var shape: TripArgumentShape?
    /// SKILLS THAT MUST NOT BE THE UNIQUE WINNER — the confident wrong action.
    ///
    /// PIN: THE CENSUS FOUND A CLASS THE GRAMMAR COULD NOT SAY. "Save this page"
    /// reaches reload_page at 0.81 on the confidence lane and would RELOAD the
    /// page with no model round; "fill in my email address" reaches
    /// open_location and would type that sentence into the address bar. A leg
    /// asserting the right skill cannot express that when no right skill exists
    /// yet; this can. With `lane: none` it says nothing at all may fire.
    public var mustNotReach: [String]?
    /// Arguments the lane must have filled, by name. The values are THE PERSON'S
    /// OWN WORDS lifted out of the utterance, which is what the confidence lane
    /// can do and what a trip is entitled to assert.
    public var arguments: [String: String]?

    public init(
        skill: String, intent: String? = nil, lane: TripLane? = nil,
        shape: TripArgumentShape? = nil, arguments: [String: String]? = nil,
        mustNotReach: [String]? = nil
    ) {
        self.skill = skill
        self.intent = intent
        self.lane = lane
        self.shape = shape
        self.arguments = arguments
        self.mustNotReach = mustNotReach
    }
}

/// Which application answered, and by which rung.
public struct TripProviderExpectation: Sendable, Equatable, Codable {
    public var applicationID: String?
    public var rationale: TripProviderRationale?

    public init(applicationID: String? = nil, rationale: TripProviderRationale? = nil) {
        self.applicationID = applicationID
        self.rationale = rationale
    }
}

/// THE ROW A GOAL MUST REACH, AS A CLASS.
///
/// PIN: FACTS, NOT A NAME. This is the type that makes the whole corpus
/// site-agnostic. "The second result" is `inResultGroup`, not `echoOfQuery`,
/// second within its kind — which is true of every search engine there has ever
/// been, and false of the navigation strip that used to win on page order.
public struct TripRowClass: Sendable, Equatable, Codable {
    /// Facts the winning row MUST carry. Spelled as `RowFacts` member names.
    public var facts: [String]?
    /// Facts it must NOT carry — usually the reason a wrong row used to win.
    public var factsAbsent: [String]?
    public var affordance: TripAffordance?
    /// The word a person would use — `video`, `link`, `field`.
    public var kind: String?
    /// Its position among rows of its own kind, 1-based — the same counting a
    /// listing speaks and `SpokenReference` resolves.
    public var ordinalWithinKind: Int?
    /// Which rung of the naming ladder reached it.
    public var lexicalBasis: String?
    /// WHETHER ANYTHING ACTUALLY NAMED THE ROW.
    ///
    /// PIN: A POSITION DOES NOT COUNT WHAT THE READING COULD NOT NAME. On a real
    /// results page the reading emitted "item 33" and "item 34" — synthesized
    /// positions, not words anybody wrote — between two real links. The router
    /// skips them, correctly, and a class that counted them made "the third link"
    /// mean a different row than it does on screen. `PageRow.isNamed` is the
    /// property; this is how a leg states it.
    public var named: Bool?

    /// DOES THIS CLASS PICK ANYTHING OUT?
    ///
    /// PIN: A CLASS OF `named: true` IS ANSWERED BY EVERY NAMED ROW, so "12 rows
    /// in the reading answer the class" is not evidence of anything — and it was
    /// being printed as though it were, and attributed to the router. A class
    /// that states a fact, a kind, an affordance or a position has actually
    /// narrowed the page and its count means what it says.
    public var discriminates: Bool {
        !(facts ?? []).isEmpty || !(factsAbsent ?? []).isEmpty
            || kind != nil || affordance != nil || ordinalWithinKind != nil
            || lexicalBasis != nil
    }

    public init(
        facts: [String]? = nil, factsAbsent: [String]? = nil,
        affordance: TripAffordance? = nil, kind: String? = nil,
        ordinalWithinKind: Int? = nil, lexicalBasis: String? = nil,
        named: Bool? = nil
    ) {
        self.facts = facts
        self.factsAbsent = factsAbsent
        self.affordance = affordance
        self.kind = kind
        self.ordinalWithinKind = ordinalWithinKind
        self.lexicalBasis = lexicalBasis
        self.named = named
    }
}

/// What the page routing must decide.
public struct TripPageExpectation: Sendable, Equatable, Codable {
    public var verb: TripRouteVerb?
    /// The row it must reach.
    public var winner: TripRowClass?
    /// Or the refusal it must give instead.
    public var refusal: TripRefusal?
    /// Whether the trace must admit the goal matched nothing — the flag that
    /// keeps a fallback from claiming it found what was asked for.
    public var goalUnmatched: Bool?
    /// How many rows had to be weighed at all. A refusal "for want of rows" and
    /// a refusal "having considered forty" are different findings.
    public var minimumEligible: Int?

    public init(
        verb: TripRouteVerb? = nil, winner: TripRowClass? = nil,
        refusal: TripRefusal? = nil, goalUnmatched: Bool? = nil,
        minimumEligible: Int? = nil
    ) {
        self.verb = verb
        self.winner = winner
        self.refusal = refusal
        self.goalUnmatched = goalUnmatched
        self.minimumEligible = minimumEligible
    }
}

/// What the act must produce.
public struct TripEngineExpectation: Sendable, Equatable, Codable {
    public var receipt: TripReceipt?
    /// PROVEN, not merely attempted.
    public var landed: Bool?
    public var refusal: TripRefusal?
    /// The whole leg, wall-clock. A leg that passes slowly is a `T` finding.
    public var budgetMs: Int?
    /// NOTHING ON THE PAGE MAY BE PRESSED.
    ///
    /// PIN: THE ONLY WAY TO SAY "AND IT DID NOT DO MORE THAN ASKED". A bare
    /// search that walks into a result still navigates and still lands, so every
    /// receipt expectation a leg can make passes while the browser sits on a page
    /// nobody asked for. What separates the two is whether a click was performed
    /// at all, and the recording knows.
    public var noPress: Bool?

    public init(
        receipt: TripReceipt? = nil, landed: Bool? = nil,
        refusal: TripRefusal? = nil, budgetMs: Int? = nil,
        noPress: Bool? = nil
    ) {
        self.receipt = receipt
        self.landed = landed
        self.refusal = refusal
        self.budgetMs = budgetMs
        self.noPress = noPress
    }
}

/// What the machine model must say before and after.
public struct TripAmbientExpectation: Sendable, Equatable, Codable {
    /// Place tokens — `browser`, `xcode`. Never a bundle id.
    public var leadBefore: String?
    public var leadAfter: String?
    public var frontAfter: TripFrontAfter?
    public var frontContainerChanged: Bool?
    /// The tab's page session was thrown away.
    public var sessionInvalidated: Bool?
    /// Its offers were retracted with it.
    public var scopeRetracted: Bool?
    public var pinned: String?

    public init(
        leadBefore: String? = nil, leadAfter: String? = nil,
        frontAfter: TripFrontAfter? = nil, frontContainerChanged: Bool? = nil,
        sessionInvalidated: Bool? = nil, scopeRetracted: Bool? = nil,
        pinned: String? = nil
    ) {
        self.leadBefore = leadBefore
        self.leadAfter = leadAfter
        self.frontAfter = frontAfter
        self.frontContainerChanged = frontContainerChanged
        self.sessionInvalidated = sessionInvalidated
        self.scopeRetracted = scopeRetracted
        self.pinned = pinned
    }
}

/// What must reach the mouth.
public struct TripSpeechExpectation: Sendable, Equatable, Codable {
    /// `forbidden` — the turn must not end having said nothing.
    public var silence: String?
    /// The read's own words must be spoken, not merely fetched.
    public var readBack: Bool?
    /// `ReadRoute` cases the ledger must NOT show.
    public var ledgerNot: [String]?

    public init(
        silence: String? = nil, readBack: Bool? = nil, ledgerNot: [String]? = nil
    ) {
        self.silence = silence
        self.readBack = readBack
        self.ledgerNot = ledgerNot
    }
}

/// One utterance, and the shape of what must happen.
/// WHICH ROAD A JOURNEY TOOK. A journey is several verbs said as one sentence,
/// and the thing worth pinning about it is the SEQUENCE: whether the results
/// answered, or whether the site the person named had to be opened and asked.
public struct TripJourneyExpectation: Sendable, Equatable, Codable {
    /// `results`, `siteSearch`, or `any` when either is a fair answer to this
    /// stage — a live search engine may or may not show the site's own row.
    public var road: String

    public init(road: String = "any") { self.road = road }
}

public struct TripLeg: Sendable, Equatable, Codable {
    /// THE PERSON'S OWN WORDS. Anything at all — this is what they said.
    public var say: String
    /// A LEG THAT MUST NAME SOMETHING ON A PAGE TAKES ITS WORDS FROM THE MACHINE.
    ///
    /// PIN: "PRESS THE THING CALLED X" IS THE PERSON'S SENTENCE, AND X BELONGS
    /// TO WHATEVER IS STAGED. A corpus that wrote one page's words into `say`
    /// would only run against that page, which is the hard-coding this whole
    /// grammar exists to refuse — so a leg like that names a KEY, and the phrase
    /// comes from the same out-of-repository file the addresses do. When the key
    /// has no phrase the leg is unstageable and says so; `say` still holds a
    /// generic default so the trip reads as a journey.
    public var sayKey: String?
    public var routing: TripRoutingExpectation?
    public var provider: TripProviderExpectation?
    public var page: TripPageExpectation?
    public var engine: TripEngineExpectation?
    public var ambient: TripAmbientExpectation?
    public var speech: TripSpeechExpectation?
    /// The road a journey leg took. See `TripJourneyExpectation`.
    public var journey: TripJourneyExpectation?
    /// ARGUMENTS AN ENGINE-LEVEL RUN NEEDS THAT A TURN GETS FROM THE MODEL.
    ///
    /// PIN: NOT THE SAME TABLE AS `routing.arguments`, AND THE DIFFERENCE IS A
    /// FINDING. `routing.arguments` says what the confidence lane MUST have
    /// filled from the sentence; this says what the probe has to supply to
    /// dispatch the binding at all. A seek was the case that separated them:
    /// the lane filled `action` from the word "skip", and `position` was an
    /// optional STRING no shape could fill — until `spokenSpan` (round 8).
    /// Folding the two tables together would still hide which is which.
    public var dispatch: [String: String]?
    /// ARGUMENTS THE MACHINE SUPPLIES, BY KEY. An address the person said out
    /// loud is a real address, and this repository holds none — so a leg that
    /// needs one names a key in the machine's phrase table, exactly as `sayKey`
    /// does for the words. Argument name → phrase key.
    public var dispatchKeys: [String: String]?
    /// The round that makes this leg possible. Until then it is counted as
    /// PENDING rather than failed — a corpus authored ahead of the engine has to
    /// distinguish "not built yet" from "built and wrong".
    public var pending: String?
    /// One line saying what this leg is for, printed beside its verdict.
    public var note: String?

    public init(
        say: String,
        sayKey: String? = nil,
        routing: TripRoutingExpectation? = nil,
        provider: TripProviderExpectation? = nil,
        page: TripPageExpectation? = nil,
        engine: TripEngineExpectation? = nil,
        ambient: TripAmbientExpectation? = nil,
        speech: TripSpeechExpectation? = nil,
        journey: TripJourneyExpectation? = nil,
        dispatch: [String: String]? = nil,
        dispatchKeys: [String: String]? = nil,
        pending: String? = nil,
        note: String? = nil
    ) {
        self.say = say
        self.sayKey = sayKey
        self.routing = routing
        self.provider = provider
        self.page = page
        self.engine = engine
        self.ambient = ambient
        self.speech = speech
        self.journey = journey
        self.dispatch = dispatch
        self.dispatchKeys = dispatchKeys
        self.pending = pending
        self.note = note
    }
}

/// What must be true before the first leg runs.
public struct TripStage: Sendable, Equatable, Codable {
    public var pageClass: TripPageClass
    /// `browser`, or a registered application's logical id — who is in front.
    public var front: String
    /// Pin this application before the trip, through `WorkspaceFocusTracker`.
    public var pin: String?
    /// A person navigates the front tab by hand between the named legs
    /// (0-based). The runner asks for it; `--staged` skips the trip instead.
    public var handNavigateBeforeLeg: Int?
    /// Something must be playing in the music app.
    public var musicPlaying: Bool?
    /// A second browser window must be open.
    public var twoWindows: Bool?
    /// The browser's window is minimized before the first leg. A stage the
    /// runner makes itself, through the same window primitives the engine's
    /// activation escalates to.
    public var minimized: Bool?
    /// The page's video is playing before the first leg — the state a person
    /// is in when they say "go back two minutes". The runner presses play
    /// through the engine's own verb, and the leg is unstageable if that
    /// does not land.
    public var mediaPlaying: Bool?
    /// A second, blank tab is open behind the staged page — the state a person
    /// is in when they say "switch to the other tab". The runner opens it
    /// through the browser's own new-tab chord and comes back to the first.
    public var twoTabs: Bool?
    /// The browser is asking something of its own before the first leg — a
    /// modal question over the page, the state a person is in when a reload
    /// raises "Confirm Form Resubmission". The runner stages it on the `form`
    /// class: submits the form by the seeded phrase, reloads, and proves the
    /// engine reports the question. Unstageable when it does not.
    public var askedByBrowser: Bool?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageClass = try container.decodeIfPresent(TripPageClass.self, forKey: .pageClass) ?? .any
        front = try container.decodeIfPresent(String.self, forKey: .front) ?? "browser"
        pin = try container.decodeIfPresent(String.self, forKey: .pin)
        handNavigateBeforeLeg = try container.decodeIfPresent(
            Int.self, forKey: .handNavigateBeforeLeg)
        musicPlaying = try container.decodeIfPresent(Bool.self, forKey: .musicPlaying)
        twoWindows = try container.decodeIfPresent(Bool.self, forKey: .twoWindows)
        minimized = try container.decodeIfPresent(Bool.self, forKey: .minimized)
        mediaPlaying = try container.decodeIfPresent(Bool.self, forKey: .mediaPlaying)
        twoTabs = try container.decodeIfPresent(Bool.self, forKey: .twoTabs)
        askedByBrowser = try container.decodeIfPresent(Bool.self, forKey: .askedByBrowser)
    }

    public init(
        pageClass: TripPageClass = .any, front: String = "browser",
        pin: String? = nil, handNavigateBeforeLeg: Int? = nil,
        musicPlaying: Bool? = nil, twoWindows: Bool? = nil, minimized: Bool? = nil,
        mediaPlaying: Bool? = nil, twoTabs: Bool? = nil, askedByBrowser: Bool? = nil
    ) {
        self.pageClass = pageClass
        self.front = front
        self.pin = pin
        self.handNavigateBeforeLeg = handNavigateBeforeLeg
        self.musicPlaying = musicPlaying
        self.twoWindows = twoWindows
        self.minimized = minimized
        self.mediaPlaying = mediaPlaying
        self.twoTabs = twoTabs
        self.askedByBrowser = askedByBrowser
    }
}

/// One journey.
public struct BrowsingTrip: Sendable, Equatable, Codable {
    public var id: String
    /// `arrive`, `search`, `read`, `act`, `media`, `tabs`, `recovery`, `context`.
    public var category: String
    /// What this trip is for, in one sentence.
    public var summary: String
    public var stage: TripStage
    public var legs: [TripLeg]
    /// Trips that navigate somebody's tab. The live runners ask first.
    public var navigates: Bool

    public init(
        id: String, category: String, summary: String,
        stage: TripStage = TripStage(), legs: [TripLeg] = [],
        navigates: Bool = false
    ) {
        self.id = id
        self.category = category
        self.summary = summary
        self.stage = stage
        self.legs = legs
        self.navigates = navigates
    }

    /// TOLERANT WHERE A DEFAULT IS OBVIOUS, STRICT EVERYWHERE ELSE.
    ///
    /// PIN: SWIFT'S SYNTHESIZED DECODING IGNORES A PROPERTY'S DEFAULT VALUE, so
    /// an omitted `navigates` threw and — walked through `compactMap(try?)` —
    /// took the whole trip out of the corpus without a word. Four categories
    /// vanished that way and every suite over them still passed, because a
    /// corpus that silently shrinks always passes. The default is written here
    /// so a hand-authored file may leave the quiet fields out; anything actually
    /// malformed still throws, and `corpus(under:)` reports it by name.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(String.self, forKey: .category)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        stage = try container.decodeIfPresent(TripStage.self, forKey: .stage) ?? TripStage()
        legs = try container.decodeIfPresent([TripLeg].self, forKey: .legs) ?? []
        navigates = try container.decodeIfPresent(Bool.self, forKey: .navigates) ?? false
    }

    public static let categories: Set<String> = [
        "arrive", "search", "read", "act", "media", "tabs", "recovery", "context",
        // Several verbs said as one sentence. Round 8.
        "journey",
    ]

    /// Every leg that is not waiting on a round.
    public var liveLegs: [(index: Int, leg: TripLeg)] {
        legs.enumerated().compactMap { $0.element.pending == nil ? ($0.offset, $0.element) : nil }
    }
}

// MARK: - The validator

/// THE SITE-AGNOSTICITY RULE, MADE MECHANICAL.
///
/// PIN: A REVIEWER CANNOT BE THE RULE. The plan's whole constraint is that no
/// trip hard-codes a route or a grammar, and the way that constraint dies is one
/// author writing one expectation about one page's words because it was quicker
/// than finding the fact behind it. Every check below refuses something that has
/// already been tempting in this lane.
public enum BrowsingTripValidator {

    /// What a trip may not contain anywhere in its EXPECTATIONS.
    public struct Issue: Sendable, Equatable, CustomStringConvertible {
        public var path: String
        public var problem: String
        public var description: String { "\(path): \(problem)" }

        public init(path: String, problem: String) {
            self.path = path
            self.problem = problem
        }
    }

    /// Common top-level domains, enough to catch a host written into an
    /// expectation. Not a security boundary — a rule with teeth for the mistake
    /// somebody will actually make.
    static let hostSuffixes = [
        ".com", ".org", ".net", ".io", ".co", ".uk", ".dev", ".ai", ".tv", ".fm",
        ".edu", ".gov", ".info", ".me",
    ]

    public static func validate(_ trip: BrowsingTrip) -> [Issue] {
        var issues: [Issue] = []

        if trip.id.isEmpty { issues.append(Issue(path: "id", problem: "is empty")) }
        if !BrowsingTrip.categories.contains(trip.category) {
            issues.append(Issue(
                path: "category",
                problem: "\"\(trip.category)\" is not one of "
                    + BrowsingTrip.categories.sorted().joined(separator: ", ")))
        }
        if trip.summary.isEmpty {
            issues.append(Issue(path: "summary", problem: "says nothing about what this pins"))
        }
        if trip.legs.isEmpty {
            issues.append(Issue(path: "legs", problem: "a trip with no legs goes nowhere"))
        }

        for (index, leg) in trip.legs.enumerated() {
            let path = "legs[\(index)]"
            if leg.say.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(Issue(path: "\(path).say", problem: "a leg says nothing"))
            }
            // THE UTTERANCE IS EXEMPT, and everything else is not.
            issues.append(contentsOf: expectationIssues(leg, at: path))
        }
        return issues
    }

    /// Every string inside a leg's EXPECTATIONS, checked for an address, a host,
    /// or a fact nobody derives.
    private static func expectationIssues(_ leg: TripLeg, at path: String) -> [Issue] {
        var issues: [Issue] = []

        func checkFree(_ value: String?, _ field: String, allowingWords: Bool = false) {
            guard let value, !value.isEmpty else { return }
            let lowered = value.lowercased()
            if lowered.contains("http") || lowered.contains("www.") {
                issues.append(Issue(
                    path: "\(path).\(field)",
                    problem: "holds an address; a trip names a class of page, never a site"))
            }
            if hostSuffixes.contains(where: { lowered.contains($0) }) {
                issues.append(Issue(
                    path: "\(path).\(field)",
                    problem: "holds a host name; the lane speaks site names and a fixture holds none"))
            }
            // AN EXPECTATION IS NOT A SENTENCE. A phrase this long in an
            // expectation is somebody asserting a page's own words.
            if !allowingWords, value.count > 48 {
                issues.append(Issue(
                    path: "\(path).\(field)",
                    problem: "is a phrase, not a class — expectations name facts, not what a page says"))
            }
        }

        if let routing = leg.routing {
            checkFree(routing.skill, "routing.skill")
            checkFree(routing.intent, "routing.intent")
            // ARGUMENTS ARE THE PERSON'S WORDS, so they may be a phrase — but
            // still never an address.
            for (name, value) in routing.arguments ?? [:] {
                checkFree(value, "routing.arguments.\(name)", allowingWords: true)
            }
            if let intent = routing.intent, !Self.knownIntents.contains(intent) {
                issues.append(Issue(
                    path: "\(path).routing.intent",
                    problem: "\"\(intent)\" is not an intent Mary reads"))
            }
        }

        if let provider = leg.provider {
            checkFree(provider.applicationID, "provider.applicationID")
        }

        if let page = leg.page, let winner = page.winner {
            for fact in winner.facts ?? [] where !Self.knownFacts.contains(fact) {
                issues.append(Issue(
                    path: "\(path).page.winner.facts",
                    problem: "\"\(fact)\" is not a RowFact the seal decides"))
            }
            for fact in winner.factsAbsent ?? [] where !Self.knownFacts.contains(fact) {
                issues.append(Issue(
                    path: "\(path).page.winner.factsAbsent",
                    problem: "\"\(fact)\" is not a RowFact the seal decides"))
            }
            checkFree(winner.kind, "page.winner.kind")
            checkFree(winner.lexicalBasis, "page.winner.lexicalBasis")
            if let basis = winner.lexicalBasis,
               PageRouteLexicalBasis(rawValue: basis) == nil {
                issues.append(Issue(
                    path: "\(path).page.winner.lexicalBasis",
                    problem: "\"\(basis)\" is not a rung of the naming ladder"))
            }
            if let ordinal = winner.ordinalWithinKind, ordinal < 1 {
                issues.append(Issue(
                    path: "\(path).page.winner.ordinalWithinKind",
                    problem: "counts from one, the way a listing speaks"))
            }
            if page.refusal != nil {
                issues.append(Issue(
                    path: "\(path).page",
                    problem: "expects a winner AND a refusal; a route does one or the other"))
            }
        }

        for token in leg.speech?.ledgerNot ?? [] where !Self.knownReadRoutes.contains(token) {
            issues.append(Issue(
                path: "\(path).speech.ledgerNot",
                problem: "\"\(token)\" is not a route the read ledger records"))
        }

        for (name, value) in leg.dispatch ?? [:] {
            checkFree(value, "dispatch.\(name)", allowingWords: true)
        }

        checkFree(leg.ambient?.leadBefore, "ambient.leadBefore")
        checkFree(leg.ambient?.leadAfter, "ambient.leadAfter")
        checkFree(leg.ambient?.pinned, "ambient.pinned")
        checkFree(leg.pending, "pending")

        return issues
    }

    /// The `RowFacts` member names a trip may assert.
    ///
    /// PIN: SPELLED OUT, BECAUSE AN OPTIONSET HAS NO CASE LIST. A member added
    /// to `RowFacts` and not added here is simply unassertable, which is a
    /// smaller failure than a typo'd fact silently passing.
    public static let knownFacts: Set<String> = [
        "callToAction", "bareAddress", "separatedStrip", "tooShortForTitle",
        "promoted", "inFurnitureBand", "behindOverlay", "inOverlay",
        "inResultGroup", "inToolbar", "inForm", "duplicateLabel", "echoOfQuery",
    ]

    /// `RowFacts` by name, so a runner can turn an assertion into a comparison.
    public static func facts(named names: [String]) -> RowFacts {
        var facts: RowFacts = []
        for name in names {
            switch name {
            case "callToAction": facts.insert(.callToAction)
            case "bareAddress": facts.insert(.bareAddress)
            case "separatedStrip": facts.insert(.separatedStrip)
            case "tooShortForTitle": facts.insert(.tooShortForTitle)
            case "promoted": facts.insert(.promoted)
            case "inFurnitureBand": facts.insert(.inFurnitureBand)
            case "behindOverlay": facts.insert(.behindOverlay)
            case "inOverlay": facts.insert(.inOverlay)
            case "inResultGroup": facts.insert(.inResultGroup)
            case "inToolbar": facts.insert(.inToolbar)
            case "inForm": facts.insert(.inForm)
            case "duplicateLabel": facts.insert(.duplicateLabel)
            case "echoOfQuery": facts.insert(.echoOfQuery)
            default: break
            }
        }
        return facts
    }

    /// The intents `AmbientIntent` declares. Spelled here for the same reason —
    /// MaryPlugin can see them, and a trip is checked before a turn runs.
    public static let knownIntents: Set<String> = Set(AmbientIntent.allCases.map(\.rawValue))

    /// The routes `ReadDeliveryLedger` records. MaryBrain owns that type, so a
    /// trip states them as words and the brain-side suite compares.
    public static let knownReadRoutes: Set<String> = [
        "prefetched", "spokenDetached", "registered", "discarded", "heldForQuiet",
        "droppedStale", "expiredUnanswered", "supersededToTranscript",
        "chainStalled", "droppedAsRestating",
    ]
}

// MARK: - Reading and writing them

public extension BrowsingTrip {

    static func decode(_ data: Data) throws -> BrowsingTrip {
        try JSONDecoder().decode(BrowsingTrip.self, from: data)
    }

    static func load(from url: URL) throws -> BrowsingTrip {
        try decode(Data(contentsOf: url))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Every trip under a directory, sorted, so a runner and a suite walk them
    /// in one order.
    ///
    /// PIN: WHAT IT COULD NOT READ IS PART OF THE ANSWER. This used to be a
    /// `compactMap(try?)`, which meant a trip with one bad field left the corpus
    /// entirely and every check over it passed — measured: four of eight
    /// categories disappeared and the suite went green. A walker that hides a
    /// file it could not read is describing a corpus nobody has.
    static func corpus(under root: URL) -> TripCorpus {
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        else { return TripCorpus() }
        var corpus = TripCorpus()
        for url in walk.compactMap({ $0 as? URL })
            .filter({ $0.lastPathComponent.hasSuffix(".trip.json") })
            .sorted(by: { $0.path < $1.path }) {
            do {
                corpus.trips.append((url, try BrowsingTrip.load(from: url)))
            } catch {
                corpus.unreadable.append((url, String(describing: error)))
            }
        }
        return corpus
    }

    /// The readable trips alone, for a caller that has already reported the rest.
    static func all(under root: URL) -> [(url: URL, trip: BrowsingTrip)] {
        corpus(under: root).trips
    }
}

/// What a walk of the corpus found, INCLUDING what it could not read.
public struct TripCorpus: Sendable {
    public var trips: [(url: URL, trip: BrowsingTrip)] = []
    /// A file that looks like a trip and would not decode, with the reason.
    public var unreadable: [(url: URL, problem: String)] = []

    public init() {}

    public var isEmpty: Bool { trips.isEmpty && unreadable.isEmpty }
}

// MARK: - Staging

/// WHERE A PAGE CLASS COMES FROM, AND WHY IT IS NOT IN THE REPOSITORY.
///
/// PIN: THE ADDRESSES LIVE ON THE MACHINE, NOT IN GIT. A live round has to put
/// Chrome on "a results page", which needs a real address, and this lane's whole
/// doctrine is that it speaks site names and holds URLs without ever writing them
/// down. `PageRosterFixture` masks them out of a recording for exactly this
/// reason; a seed file in the repository would put them straight back.
public enum TripStaging {

    /// `~/.mary/trips/stage.json` — `{ "resultsPage": "…", "watchPage": "…" }`.
    public static var seedsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".mary/trips/stage.json")
    }

    /// The address to open for a page class, when the person has written one.
    ///
    /// PIN: READ AS AN OBJECT WITH MIXED VALUES, NOT AS A FLAT STRING MAP. This
    /// decoded `[String: String]`, and the file also carries a `phrases` object
    /// — so decoding the WHOLE file failed and every page class came back
    /// without an address. Measured: a fully written seed file, and forty legs
    /// reporting "no address for …". The failure was visible only because an
    /// unstageable leg says which key it wanted; a runner that had guessed would
    /// have run the whole corpus against one page.
    public static func seed(for pageClass: TripPageClass) -> String? {
        guard pageClass != .any, pageClass != .blank,
              let data = FileManager.default.contents(atPath: seedsURL.path),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let value = object[pageClass.rawValue] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    /// EVERY SEEDED PAGE, keyed as written. A page class the grammar does not
    /// know is still a page somebody wrote down — the landscape sweep drives
    /// whatever is there, because the rule it measures is about the SHAPE of a
    /// page rather than about which classes the corpus happens to name.
    public static func seeds() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: seedsURL.path),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    /// The words a leg names by key — `{"phrases": {"namedRow": "…"}}` in the
    /// same file. Nil when the person has not written one, which makes the leg
    /// unstageable rather than wrong.
    public static func phrase(for key: String) -> String? {
        guard let data = FileManager.default.contents(atPath: seedsURL.path),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let phrases = object["phrases"] as? [String: String],
              let phrase = phrases[key], !phrase.isEmpty
        else { return nil }
        return phrase
    }

    /// What to say when a keyed leg has no phrase on this machine.
    public static func missingPhraseAdvice(for key: String) -> String {
        """
        no phrase for \"\(key)\" — add it to \(seedsURL.path) as \
        {"phrases": {"\(key)": "…"}}, in the words you would actually say
        """
    }

    /// What to print when a class has no seed — the runner cannot stage it, and
    /// saying which key is missing is the whole of the fix.
    public static func missingSeedAdvice(for pageClass: TripPageClass) -> String {
        """
        no address for \"\(pageClass.rawValue)\" — add it to \(seedsURL.path) \
        as {"\(pageClass.rawValue)": "…"} (kept out of the repository on purpose)
        """
    }
}
