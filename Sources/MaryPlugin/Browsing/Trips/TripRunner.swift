//
//  TripRunner.swift
//  MaryPlugin
//
//  WHAT: Take a trip against a real browser, one leg at a time, and write down
//        everything that happened.
//  IN:   a BrowsingTrip + the browsing adapter's own bindings + the engine's events
//  OUT:  TripRecording, judged
//  PIN:  IT DISPATCHES THE BINDING THE RUNTIME WOULD DISPATCH. Not the engine
//        method underneath it — the `SkillBinding` closure itself, so the
//        argument gates, the address admission and `SkillOutcome.landed` are the
//        real ones. A runner that called `engine.pressOnPage` directly would
//        measure a lane nobody's turn takes.
//        THE ROUTES COME FROM THE ENGINE'S OWN STREAM. A leg can route more than
//        once — a search navigates, reads, routes, presses — and
//        `snapshot().lastRoute` remembers one. The event stream is what every
//        other watcher already reads, so the recording and Sand's route pane
//        describe the same turn.
//        UNSTAGEABLE IS NOT FAILED. A machine with no seed for a page class, no
//        phrase for a keyed leg, or no browser running cannot answer the
//        question the leg asks — and counting that as a defect would fill a
//        round's findings with somebody's setup.
//

import Foundation
import MaryComputerUse
import MaryFoundation

public actor TripRunner {

    /// What the runner needs that it cannot decide for itself.
    public struct Setup: Sendable {
        /// Which round is being recorded. Written into the file.
        public var round: String
        /// `probe` (the bindings directly) or `turn` (a whole turn).
        public var runner: String
        /// The registration's own id — see `TripRecording.browser`, and the
        /// reason there is no default.
        public var browser: String
        /// Skip the legs whose stage needs a person — a hand navigation, a
        /// second window, music playing.
        public var staged: Bool
        /// Only this leg, when a round is re-running one.
        public var onlyLeg: Int?

        public init(
            round: String = "0", runner: String = "probe", browser: String = "",
            staged: Bool = false, onlyLeg: Int? = nil
        ) {
            self.round = round
            self.runner = runner
            self.browser = browser
            self.staged = staged
            self.onlyLeg = onlyLeg
        }
    }

    /// What one leg's dispatch answered, however it was dispatched.
    public struct LegOutcome: Sendable {
        public var ok: Bool
        public var landed: Bool
        public var summary: String
        public var refusal: String?
        public var providerApplicationID: String?

        public init(
            ok: Bool, landed: Bool, summary: String,
            refusal: String? = nil, providerApplicationID: String? = nil
        ) {
            self.ok = ok
            self.landed = landed
            self.summary = summary
            self.refusal = refusal
            self.providerApplicationID = providerApplicationID
        }
    }

    private let recorder: TripRecorder
    private var routes: [RecordedRoute] = []
    private var receipts: [RecordedReceipt] = []
    private var timeline: [String] = []
    private var watching: Task<Void, Never>?

    public init(recorder: TripRecorder) {
        self.recorder = recorder
    }

    // MARK: - Watching the engine

    /// Follow the engine's own event stream for as long as the trip runs.
    public func watch(_ events: AsyncStream<BrowserEngineEvent>) {
        watching = Task { [weak self] in
            for await event in events {
                await self?.receive(event)
            }
        }
    }

    public func stopWatching() {
        watching?.cancel()
        watching = nil
    }

    private func receive(_ event: BrowserEngineEvent) async {
        let at = await recorder.elapsedForTests()
        timeline.append("\(at)ms  \(event.line)")
        switch event {
        case .routed(let trace):
            routes.append(RecordedRoute(
                trace, facts: await factsByOrdinal(), atMilliseconds: at))
        case .receipt(let receipt):
            receipts.append(RecordedReceipt(receipt))
        default:
            break
        }
    }

    /// What the last page read said about each row — the evidence a route was
    /// argued from, so a refusal can be read without re-deriving anything.
    private func factsByOrdinal() async -> [Int: RowFacts] {
        guard let page = await recorder.lastPage() else { return [:] }
        return Dictionary(
            page.rows.map { ($0.ordinal, RowFacts(rawValue: $0.facts ?? 0)) },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: - One leg

    /// Begin a leg: the recorder starts over and the per-leg gatherings clear.
    public func beginLeg() async {
        await recorder.begin()
        routes = []
        receipts = []
        timeline = []
    }

    /// Everything gathered since `beginLeg`, as one leg's record.
    public func finishLeg(
        index: Int, say: String, outcome: LegOutcome,
        routing: RecordedRouting? = nil,
        providerRationale: String? = nil,
        before: RecordedAmbient? = nil, after: RecordedAmbient? = nil,
        speech: RecordedSpeech? = nil
    ) async -> TripLegRecording {
        let gathered = await recorder.gathered()
        return TripLegRecording(
            index: index, say: say,
            routing: routing,
            providerApplicationID: outcome.providerApplicationID,
            providerRationale: providerRationale,
            ambientBefore: before, ambientAfter: after,
            shells: gathered.shells, pageReads: gathered.pageReads, media: gathered.media,
            routes: routes, acts: gathered.acts, receipts: receipts,
            ok: outcome.ok, landed: outcome.landed, refusal: outcome.refusal,
            outcomeSpoken: outcome.summary, speech: speech,
            timeline: timeline, elapsedMilliseconds: gathered.elapsed)
    }

    /// A leg the machine could not be put in a state to answer.
    public nonisolated static func unstageable(
        index: Int, say: String, because: String
    ) -> TripLegRecording {
        TripLegRecording(
            index: index, say: say, verdict: .unstageable, because: because)
    }
}

// MARK: - Arguments

/// WHAT TO DISPATCH A LEG WITH, WHEN THE LANE IS NOT THERE TO FILL IT.
///
/// PIN: THE PROBE ASKS THE ENGINE, NOT THE BRAIN. A turn-level run gets its
/// arguments from the confidence lane or the model, and asserts them; an
/// engine-level run has to state them, and the honest sources are the trip
/// (what the person's words carry) and the machine (what an address is). Anything
/// else would be this file inventing a target for a page it has not seen, which
/// is the hard-coding the whole corpus exists to refuse.
public enum TripArguments {

    public enum Resolution: Sendable {
        case ready([String: String])
        /// The machine cannot answer this leg, and why.
        case unstageable(String)
    }

    /// The phrase key an address is kept under, for a leg that navigates.
    public static let addressKey = "address"

    public static func resolve(
        leg: TripLeg, spoken: String, parameters: [ModelSkillSchema.Parameter],
        pageClass: TripPageClass
    ) -> Resolution {
        // THE LANE'S ARGUMENTS FIRST, THEN WHAT ONLY A MODEL COULD HAVE ADDED.
        var arguments = leg.routing?.arguments ?? [:]
        for (name, value) in leg.dispatch ?? [:] { arguments[name] = value }
        for parameter in parameters where parameter.required {
            guard arguments[parameter.name] == nil else { continue }
            switch parameter.name {
            case "address", "url":
                // A FRONT DOOR, KEPT ON THE MACHINE. `SpokenAddress.admit` takes
                // a bare host outright and anything deeper only if the person
                // said it, so a seed with a path is refused by the gate rather
                // than by this file.
                guard let seed = TripStaging.seed(for: pageClass)
                    ?? TripStaging.phrase(for: addressKey)
                else {
                    return .unstageable(TripStaging.missingPhraseAdvice(for: addressKey))
                }
                arguments[parameter.name] = seed
            default:
                // A SINGLE REMAINING REQUIRED STRING IS THE PERSON'S OWN WORDS.
                // "Open the second one" IS the goal a page verb takes; the router
                // folds it, and pretending otherwise would mean the corpus
                // holding phrases from pages.
                guard parameter.enumValues?.isEmpty ?? true else {
                    return .unstageable(
                        "\(parameter.name) is one of "
                            + (parameter.enumValues ?? []).joined(separator: "/")
                            + " and the trip does not say which")
                }
                arguments[parameter.name] = spoken
            }
        }
        return .ready(arguments)
    }

    /// The words this leg actually says — its own, or the machine's for a keyed one.
    public static func spoken(_ leg: TripLeg) -> Resolution {
        guard let key = leg.sayKey else { return .ready(["say": leg.say]) }
        guard let phrase = TripStaging.phrase(for: key) else {
            return .unstageable(TripStaging.missingPhraseAdvice(for: key))
        }
        return .ready(["say": phrase])
    }
}

// MARK: - Reaching into the recorder

extension TripRecorder {
    /// The elapsed clock, for the runner's timeline.
    func elapsedForTests() -> Int { elapsed }

    /// The most recent page read, for the facts a route was argued from.
    func lastPage() -> PageRosterFixture? { gathered().pageReads.last?.page }
}
