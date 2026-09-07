//
//  TripRecording.swift
//  MaryPlugin
//
//  WHAT: One leg's whole story, written down — what was decided, what was seen,
//        what was done to the machine, and what came of it.
//  IN:   RecordingSeams (the engine's own boundary) + the runners
//  OUT:  *.recording.json beside the trip; the replay suite; the scoreboard
//  PIN:  A RECORDING IS THE EVIDENCE, AND EVERY BROWSING DEFECT SO FAR WAS
//        UNREPRODUCIBLE WITHOUT ONE. The strip that won on page order, the echo
//        that won on word cover, the fragment at the crop's edge read as the
//        transport — each was found by driving a browser by hand, and each
//        vanished the moment the page changed. What makes them arithmetic is a
//        record of the READ, the ROUTE and the ACT together: a page fixture
//        alone re-argues routing and can say nothing about a receipt.
//        NO ADDRESSES, NO PIXELS, NO ABSOLUTE POINTS. Sites are named, never
//        spelled; page reads are rows and facts, never an image; a point is
//        stated as a fraction of the page frame, which is what makes it
//        comparable between one machine's display and another's.
//        WHAT FAILED IS ALSO EVIDENCE. A recording carries its own verdict and
//        the LAYER that failed, so a round's findings are a file rather than a
//        person's memory of a terminal.
//

import CoreGraphics
import Foundation
import MaryComputerUse

// MARK: - The pieces the seams see

/// One thing done to the machine, in the page's own coordinates.
///
/// PIN: A FRACTION OF THE PAGE FRAME, NOT A SCREEN POINT. A recording made on
/// one display and replayed against another must describe the same place on the
/// page, and an absolute point describes somebody's monitor.
public struct RecordedAct: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
        case click, hover, glide, move, scroll, drag
        case type, key
        case pressShell, openLocation, bringForward, restoreCursor
        /// The stage given back to the application that had it before the act.
        case restoreFront
    }

    public var kind: Kind
    /// Where, as a fraction of the page frame. Nil for the acts that have no place.
    public var atX: Double?
    public var atY: Double?
    /// A drag's destination, same units.
    public var toX: Double?
    public var toY: Double?
    /// A scroll's delta, in the units the pointer driver takes.
    public var delta: Double?
    /// How many characters were typed. NEVER what they were: a recording that
    /// held the text would hold the query, and this lane holds no query strings.
    public var typedLength: Int?
    /// `return`, `escape`, `tab` — the only three this lane may press.
    public var key: String?
    /// A shell control's declared label. Package data, not a page's words.
    public var shellLabel: String?
    /// How far into the leg it happened.
    public var atMilliseconds: Int

    public init(
        kind: Kind, atX: Double? = nil, atY: Double? = nil,
        toX: Double? = nil, toY: Double? = nil, delta: Double? = nil,
        typedLength: Int? = nil, key: String? = nil, shellLabel: String? = nil,
        atMilliseconds: Int = 0
    ) {
        self.kind = kind
        self.atX = atX
        self.atY = atY
        self.toX = toX
        self.toY = toY
        self.delta = delta
        self.typedLength = typedLength
        self.key = key
        self.shellLabel = shellLabel
        self.atMilliseconds = atMilliseconds
    }

    /// A point in screen coordinates, said as a fraction of the page.
    public static func fraction(
        of point: CGPoint, in frame: CGRect
    ) -> (x: Double, y: Double) {
        guard frame.width > 0, frame.height > 0 else { return (0, 0) }
        return (
            Double((point.x - frame.minX) / frame.width),
            Double((point.y - frame.minY) / frame.height))
    }
}

/// A shell read, with the address turned back into a site name.
///
/// PIN: THE SITE, NEVER THE ADDRESS — the same rule the spoken lane keeps. A
/// recording checked into the repository must not be the one place a query
/// string survives, and a shell reading is where one would.
public struct RecordedShell: Sendable, Equatable, Codable {
    public var title: String?
    public var site: String?
    public var tabCount: Int
    public var activeTabIndex: Int?
    public var canGoBack: Bool?
    public var canGoForward: Bool?
    public var hasPageFrame: Bool
    public var pageFrameSource: String
    public var atMilliseconds: Int

    public init(
        title: String? = nil, site: String? = nil, tabCount: Int = 0,
        activeTabIndex: Int? = nil, canGoBack: Bool? = nil,
        canGoForward: Bool? = nil, hasPageFrame: Bool = false,
        pageFrameSource: String = "", atMilliseconds: Int = 0
    ) {
        self.title = title
        self.site = site
        self.tabCount = tabCount
        self.activeTabIndex = activeTabIndex
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.hasPageFrame = hasPageFrame
        self.pageFrameSource = pageFrameSource
        self.atMilliseconds = atMilliseconds
    }

    public init(_ reading: WebSurfaceAX.Reading, atMilliseconds: Int) {
        self.init(
            title: reading.title,
            site: reading.siteName,
            tabCount: reading.tabs.count,
            activeTabIndex: reading.activeTabIndex,
            canGoBack: reading.canGoBack,
            canGoForward: reading.canGoForward,
            hasPageFrame: reading.pageFrame != nil,
            pageFrameSource: reading.pageFrameSource,
            atMilliseconds: atMilliseconds)
    }
}

/// One page read — the rows, their facts, what it cost, and whether a
/// classifier ran at all.
public struct RecordedPageRead: Sendable, Equatable, Codable {
    public var page: PageRosterFixture
    public var atMilliseconds: Int

    public init(page: PageRosterFixture, atMilliseconds: Int) {
        self.page = page
        self.atMilliseconds = atMilliseconds
    }
}

/// What the media lane made of the player, without the pixels.
public struct RecordedMedia: Sendable, Equatable, Codable {
    public var controlsVisible: Bool
    public var playback: String
    public var witnesses: [String]
    public var hasPlayPause: Bool
    public var hasVolume: Bool
    public var hasFullscreen: Bool
    public var hasProgress: Bool
    public var hasVolumeTrack: Bool
    public var progressFraction: Double?
    public var isMuted: Bool?
    public var controlCount: Int
    public var atMilliseconds: Int

    public init(_ reading: MediaControlReading, atMilliseconds: Int) {
        controlsVisible = reading.controlsVisible
        playback = reading.playback.rawValue
        witnesses = reading.witnesses
        hasPlayPause = reading.playPause != nil
        hasVolume = reading.volume != nil
        hasFullscreen = reading.fullscreen != nil
        hasProgress = reading.progress != nil
        hasVolumeTrack = reading.volumeTrack != nil
        progressFraction = reading.progress?.fraction
        isMuted = reading.isMuted
        controlCount = reading.others.count
        self.atMilliseconds = atMilliseconds
    }
}

/// One row's decision, as the trace made it — identities, bounded ints and one
/// sentence, exactly what `PageRouteTrace` already carries.
public struct RecordedRouteDecision: Sendable, Equatable, Codable {
    public var ordinal: Int
    public var disposition: String
    public var label: String
    public var reason: String
    public var lexical: Int
    public var lexicalBasis: String
    public var semantic: Int
    public var affordance: Int
    public var provenance: Int
    public var structure: Int
    /// The facts that row carried when it was judged — the whole reason a
    /// refusal is readable.
    public var facts: Int

    public init(
        ordinal: Int, disposition: String, label: String, reason: String,
        lexical: Int, lexicalBasis: String, semantic: Int, affordance: Int,
        provenance: Int, structure: Int, facts: Int
    ) {
        self.ordinal = ordinal
        self.disposition = disposition
        self.label = label
        self.reason = reason
        self.lexical = lexical
        self.lexicalBasis = lexicalBasis
        self.semantic = semantic
        self.affordance = affordance
        self.provenance = provenance
        self.structure = structure
        self.facts = facts
    }
}

/// One whole page arbitration.
public struct RecordedRoute: Sendable, Equatable, Codable {
    public var goal: String
    public var verb: String
    /// The query an `openResult` was weighed against — the person's own words.
    public var query: String?
    public var eligibleCount: Int
    public var goalUnmatched: Bool
    public var selectedOrdinal: Int?
    public var rivalOrdinals: [Int]
    public var decisions: [RecordedRouteDecision]
    public var atMilliseconds: Int

    public init(
        goal: String, verb: String, query: String? = nil, eligibleCount: Int,
        goalUnmatched: Bool, selectedOrdinal: Int? = nil,
        rivalOrdinals: [Int] = [], decisions: [RecordedRouteDecision] = [],
        atMilliseconds: Int = 0
    ) {
        self.goal = goal
        self.verb = verb
        self.query = query
        self.eligibleCount = eligibleCount
        self.goalUnmatched = goalUnmatched
        self.selectedOrdinal = selectedOrdinal
        self.rivalOrdinals = rivalOrdinals
        self.decisions = decisions
        self.atMilliseconds = atMilliseconds
    }
}

/// One command's receipt.
public struct RecordedReceipt: Sendable, Equatable, Codable {
    public var kind: String
    public var target: String?
    public var delivery: String
    /// `navigation`, `targetChanged`, `textAppeared`, `rosterChanged`,
    /// `mediaState`, or `none`.
    public var receipt: String
    public var landed: Bool
    public var spoken: String

    public init(
        kind: String, target: String? = nil, delivery: String,
        receipt: String, landed: Bool, spoken: String
    ) {
        self.kind = kind
        self.target = target
        self.delivery = delivery
        self.receipt = receipt
        self.landed = landed
        self.spoken = spoken
    }
}

// MARK: - The turn's own half

/// WHICH SKILL THE WORDS REACHED, AND ON WHAT LANE.
///
/// PIN: FILLED BY THE TURN-LEVEL RUNNER, EMPTY FROM THE PROBE. The arbitrator,
/// the triage and the confidence shape all live in MaryBrain, above this layer.
/// A recording states them as plain values so the file is one shape whoever made
/// it, and a leg with no routing block simply has nothing to say here.
public struct RecordedRouting: Sendable, Equatable, Codable {
    public var intent: String?
    public var intentScore: Double?
    public var uniqueSkill: String?
    public var lane: String?
    public var shape: String?
    public var arguments: [String: String]
    /// Every skill the roster offered, sorted.
    public var offered: [String]
    /// The abilities that stood in the election, and the ones struck out with why.
    public var electionActive: [String]
    public var electionStruck: [String: String]
    /// The corpus's top few, for reading a near miss.
    public var topAffinities: [String: Double]

    public init(
        intent: String? = nil, intentScore: Double? = nil,
        uniqueSkill: String? = nil, lane: String? = nil, shape: String? = nil,
        arguments: [String: String] = [:], offered: [String] = [],
        electionActive: [String] = [], electionStruck: [String: String] = [:],
        topAffinities: [String: Double] = [:]
    ) {
        self.intent = intent
        self.intentScore = intentScore
        self.uniqueSkill = uniqueSkill
        self.lane = lane
        self.shape = shape
        self.arguments = arguments
        self.offered = offered
        self.electionActive = electionActive
        self.electionStruck = electionStruck
        self.topAffinities = topAffinities
    }
}

/// The machine model, before and after.
public struct RecordedAmbient: Sendable, Equatable, Codable {
    public var lead: String?
    public var leadFocus: String?
    public var frontApplicationID: String?
    public var pinned: String?
    /// The front tab, by whatever identity the world holds — a title, never an
    /// address.
    public var frontContainer: String?
    public var containerCount: Int?
    /// How many element scopes at the browser's place were fresh.
    public var freshScopes: Int?
    /// Whether the engine still held a roster for this page.
    public var hasSession: Bool?

    public init(
        lead: String? = nil, leadFocus: String? = nil,
        frontApplicationID: String? = nil, pinned: String? = nil,
        frontContainer: String? = nil, containerCount: Int? = nil,
        freshScopes: Int? = nil, hasSession: Bool? = nil
    ) {
        self.lead = lead
        self.leadFocus = leadFocus
        self.frontApplicationID = frontApplicationID
        self.pinned = pinned
        self.frontContainer = frontContainer
        self.containerCount = containerCount
        self.freshScopes = freshScopes
        self.hasSession = hasSession
    }
}

/// What reached the mouth, and what the ledger says happened to a read.
public struct RecordedSpeech: Sendable, Equatable, Codable {
    /// Whether anything at all was said. The text is kept because a turn's own
    /// words are not a page's words, and a silent turn is only visible by its
    /// absence.
    public var spoken: String
    public var spokeInTurn: Bool
    /// `ReadRoute` raw values this turn recorded.
    public var readRoutes: [String]
    /// Whether Mary's own pre-read served this turn.
    public var awarenessServed: Bool?

    public init(
        spoken: String = "", spokeInTurn: Bool = false,
        readRoutes: [String] = [], awarenessServed: Bool? = nil
    ) {
        self.spoken = spoken
        self.spokeInTurn = spokeInTurn
        self.readRoutes = readRoutes
        self.awarenessServed = awarenessServed
    }
}

// MARK: - One leg, whole

/// Which layer of the lane failed. See `TripLayer` for what each admits as a fix.
public enum TripFailureLayer: String, Sendable, Equatable, Codable, CaseIterable {
    /// Which skill the words reached, on which lane.
    case abilityRouting = "R1"
    /// The machine model: provider, lead, session, scope, stage.
    case ambient = "A"
    /// The reading had nothing to pick.
    case perception = "P"
    /// The reading had it and the route did not pick it.
    case pageRouting = "R2"
    /// THE PAGE IN FRONT OF THE LEG WAS NOT THE PAGE THE LEG IS ABOUT.
    ///
    /// PIN: THE LAYER THAT DID NOT EXIST, AND SO EVERY CASE OF IT WAS FILED
    /// AGAINST THE ROUTER. `act` sat at 63% for three rounds on two legs, and
    /// neither was a routing fault: one asked a pizza-order form to check a
    /// "remember me" box that is not on it, and the other asked for "news" on a
    /// page that has two different controls called News — where the engine
    /// refused for ambiguity and NAMED BOTH RIVALS, which is the behaviour the
    /// whole refusal ladder exists to produce. Calling either R2 says the router
    /// missed a row that was there. It did not, and a scoreboard that says so
    /// sends the next round after the wrong layer.
    /// IT IS THE TRIP'S FAULT OR THE MACHINE'S, never the engine's — a seed
    /// address that does not hold what the leg names, or a phrase the page uses
    /// twice. Both are fixed by staging, which is why it is its own column.
    case stage = "X"
    /// The journey went a road the leg did not name — it searched where it
    /// should have gone to the site, or the other way about. A layer of its
    /// own because every step underneath it may be right: the acts landed,
    /// the router chose well, and the SEQUENCE was not the one asked for.
    case journey = "J"
    /// The route was right and the act was not.
    case execution = "E"
    /// It landed and nobody heard.
    case speech = "S"
    /// Everything passed, slowly.
    case timing = "T"
}

/// How a leg came out.
public enum TripVerdict: String, Sendable, Equatable, Codable, CaseIterable {
    case passed
    case failed
    /// Waiting on a round that has not landed.
    case pending
    /// The machine could not be put in the state the leg needs — no seed for
    /// the page class, no phrase for a keyed leg, no browser running.
    case unstageable
}

/// One leg's whole story.
public struct TripLegRecording: Sendable, Equatable, Codable {
    public var index: Int
    /// The words that were actually said, after any keyed substitution.
    public var say: String
    public var verdict: TripVerdict
    public var layer: TripFailureLayer?
    /// One sentence saying what was expected and what happened.
    public var because: String?

    public var routing: RecordedRouting?
    public var providerApplicationID: String?
    public var providerRationale: String?
    public var ambientBefore: RecordedAmbient?
    public var ambientAfter: RecordedAmbient?

    public var shells: [RecordedShell]
    public var pageReads: [RecordedPageRead]
    public var media: [RecordedMedia]
    public var routes: [RecordedRoute]
    public var acts: [RecordedAct]
    public var receipts: [RecordedReceipt]

    public var ok: Bool
    public var landed: Bool
    public var refusal: String?
    public var outcomeSpoken: String
    public var speech: RecordedSpeech?
    /// WHICH LAYERS THIS RUNNER COULD OBSERVE AT ALL.
    ///
    /// PIN: A RUNNER THAT CANNOT SEE A LAYER MUST NOT BE READ AS PASSING IT.
    /// The two runners answer different halves on purpose. The probe dispatches
    /// the binding, so it knows the receipt, whether the act landed and which
    /// application answered — and nothing about which skill the words would have
    /// reached. A turn knows the routing, the lane and what was said — and
    /// nothing about `landed`, because the brain consumes the outcome and it
    /// never reaches a `BehavioralActionRecord` (that type says so itself).
    /// Folding the two into one silent default would let a turn-level run report
    /// a media leg as passing when nothing checked that it landed, which is the
    /// exact defect the corpus exists to catch. Nil means "judge everything",
    /// which is what a hand-written recording in a test wants.
    /// Which road a journey took — `WatchRecipe.Road`, when one ran.
    public var journeyRoad: String?
    public var observableLayers: [TripFailureLayer]?
    /// The engine's own words, timestamped — one vocabulary for every watcher.
    public var timeline: [String]
    public var elapsedMilliseconds: Int

    public init(
        index: Int, say: String, verdict: TripVerdict = .passed,
        layer: TripFailureLayer? = nil, because: String? = nil,
        routing: RecordedRouting? = nil,
        providerApplicationID: String? = nil, providerRationale: String? = nil,
        ambientBefore: RecordedAmbient? = nil, ambientAfter: RecordedAmbient? = nil,
        shells: [RecordedShell] = [], pageReads: [RecordedPageRead] = [],
        media: [RecordedMedia] = [], routes: [RecordedRoute] = [],
        acts: [RecordedAct] = [], receipts: [RecordedReceipt] = [],
        ok: Bool = false, landed: Bool = false, refusal: String? = nil,
        outcomeSpoken: String = "", speech: RecordedSpeech? = nil,
        journeyRoad: String? = nil,
        observableLayers: [TripFailureLayer]? = nil,
        timeline: [String] = [], elapsedMilliseconds: Int = 0
    ) {
        self.index = index
        self.say = say
        self.verdict = verdict
        self.layer = layer
        self.because = because
        self.routing = routing
        self.providerApplicationID = providerApplicationID
        self.providerRationale = providerRationale
        self.ambientBefore = ambientBefore
        self.ambientAfter = ambientAfter
        self.shells = shells
        self.pageReads = pageReads
        self.media = media
        self.routes = routes
        self.acts = acts
        self.receipts = receipts
        self.ok = ok
        self.landed = landed
        self.refusal = refusal
        self.outcomeSpoken = outcomeSpoken
        self.speech = speech
        self.journeyRoad = journeyRoad
        self.observableLayers = observableLayers
        self.timeline = timeline
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    /// Can this recording answer for that layer?
    public func canJudge(_ layer: TripFailureLayer) -> Bool {
        observableLayers?.contains(layer) ?? true
    }

    /// What the probe can answer for: it drives the bindings, so it sees the
    /// page, the act and the clock — and no turn happened, so it sees no routing.
    public static let probeLayers: [TripFailureLayer] = [
        .ambient, .perception, .pageRouting, .journey, .execution, .timing,
    ]

    /// What a whole turn can answer for: which skill the words reached, on which
    /// lane, where the lead was, and whether anything was said.
    ///
    /// PIN: NOT THE CLOCK. A leg's budget is about the ENGINE's work — the read,
    /// the act, the second look — and a turn spends most of its time in a
    /// language model whose pace is nobody's finding. MEASURED: a find that
    /// took 409ms through the probe took 44 seconds through the turn, and was
    /// reported as a timing failure of a verb that had already answered in
    /// under half a second. The probe holds the clock; the turn holds the words.
    public static let turnLayers: [TripFailureLayer] = [
        .abilityRouting, .ambient, .speech,
    ]

    /// The best receipt this leg produced — the one `landed` rests on.
    public var bestReceipt: String {
        let ranked = ["navigation", "targetChanged", "textAppeared", "mediaState",
                      "rosterChanged"]
        for rank in ranked where receipts.contains(where: { $0.receipt == rank }) {
            return rank
        }
        return "none"
    }
}

/// One trip's run.
public struct TripRecording: Sendable, Equatable, Codable {
    public var tripID: String
    public var category: String
    /// Which runner made it — `probe` (the engine directly) or `turn` (a whole
    /// turn through the brain). They record different halves and both are needed.
    public var runner: String
    /// The round this was recorded in — `0`, `1`, … See docs/browsing-trips.md.
    public var round: String
    /// Which browser the round drove, as the registration's own id.
    ///
    /// PIN: NO DEFAULT, BECAUSE A DEFAULT WOULD BE A BROWSER'S NAME IN SWIFT.
    /// The whole lane learns which browsers exist from `safari.mary` and
    /// `chrome.mary`; a recording that assumed one would be the single place
    /// this codebase named a browser, and `ApplicationNameTests` caught exactly
    /// that. The caller has already resolved a registration and passes its id.
    public var browser: String
    public var recordedAt: Date
    public var legs: [TripLegRecording]

    public init(
        tripID: String, category: String, runner: String, round: String,
        browser: String = "", recordedAt: Date = Date(),
        legs: [TripLegRecording] = []
    ) {
        self.tripID = tripID
        self.category = category
        self.runner = runner
        self.round = round
        self.browser = browser
        self.recordedAt = recordedAt
        self.legs = legs
    }

    public var passed: Bool { legs.allSatisfy { $0.verdict != .failed } }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> TripRecording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TripRecording.self, from: data)
    }

    public static func load(from url: URL) throws -> TripRecording {
        try decode(Data(contentsOf: url))
    }

    /// `<trip id>.<runner>.recording.json`, beside the trip it belongs to.
    public var fileName: String { "\(tripID).\(runner).recording.json" }

    /// Every recording under a directory, with what could not be read — see
    /// `BrowsingTrip.corpus`, and the same reason.
    public static func all(
        under root: URL
    ) -> (recordings: [(url: URL, recording: TripRecording)],
          unreadable: [(url: URL, problem: String)]) {
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        else { return ([], []) }
        var found: [(url: URL, recording: TripRecording)] = []
        var unreadable: [(url: URL, problem: String)] = []
        for url in walk.compactMap({ $0 as? URL })
            .filter({ $0.lastPathComponent.hasSuffix(".recording.json") })
            .sorted(by: { $0.path < $1.path }) {
            do {
                found.append((url, try TripRecording.load(from: url)))
            } catch {
                unreadable.append((url, String(describing: error)))
            }
        }
        return (found, unreadable)
    }
}
