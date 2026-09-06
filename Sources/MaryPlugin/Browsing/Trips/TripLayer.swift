//
//  TripLayer.swift
//  MaryPlugin
//
//  WHAT: Which layer of the lane failed a leg, and the one sentence that says so.
//  IN:   a TripLeg's expectations + the TripLegRecording of what happened
//  OUT:  the verdict on the recording; the scoreboard; what a round is allowed to fix
//  PIN:  A FAILURE WITH NO LAYER IS A FAILURE NOBODY CAN FIX GENERICALLY. "The
//        second result did not open" has at least five causes — the words reached
//        the wrong skill, the wrong browser answered, the reading held no result
//        rows at all, the reading held them and the router picked furniture, the
//        router picked right and the press did nothing — and the honest repair
//        for each lives in a different file. Guessing between them is how a lane
//        grows a condition about a page instead of a rule about pages.
//        THE ORDER IS THE PIPELINE'S. The first check that fails owns the leg,
//        because everything downstream of a wrong skill is describing a turn
//        nobody asked for.
//        P AND R2 ARE THE PAIR THAT MATTERS. "Nothing in the reading could have
//        answered" is a DETECTOR finding and belongs in VisionAX with a fixture;
//        "the answer was in the reading and the route passed it over" is a
//        ROUTING finding and belongs in a row fact or a domain rule. Told apart
//        by asking the recorded page whether any row satisfies the class — which
//        is the whole reason a recording keeps the rows and their facts.
//

import Foundation
import MaryComputerUse

public enum TripLayer {

    /// What a leg came to, and why.
    public struct Judgement: Sendable, Equatable {
        public var verdict: TripVerdict
        public var layer: TripFailureLayer?
        public var because: String?

        public init(
            verdict: TripVerdict, layer: TripFailureLayer? = nil,
            because: String? = nil
        ) {
            self.verdict = verdict
            self.layer = layer
            self.because = because
        }

        public static let passed = Judgement(verdict: .passed)

        static func failed(_ layer: TripFailureLayer, _ because: String) -> Judgement {
            Judgement(verdict: .failed, layer: layer, because: because)
        }
    }

    /// Judge one leg. The first failing check in pipeline order owns it.
    public static func judge(
        leg: TripLeg, recording: TripLegRecording
    ) -> Judgement {
        if let round = leg.pending {
            return Judgement(
                verdict: .pending, because: "waiting on \(round)")
        }
        if recording.verdict == .unstageable {
            return Judgement(
                verdict: .unstageable,
                because: recording.because ?? "the machine could not be put in this state")
        }

        let checks: [(TripFailureLayer, (TripLeg, TripLegRecording) -> Judgement?)] = [
            (.abilityRouting, routing), (.ambient, ambient),
            (.perception, perception), (.pageRouting, pageRouting),
            (.execution, execution), (.speech, speech), (.timing, timing),
        ]
        for (layer, check) in checks where recording.canJudge(layer) {
            if let judgement = check(leg, recording) { return judgement }
        }
        return .passed
    }

    // MARK: - R1 — which skill, on which lane

    static func routing(_ leg: TripLeg, _ recording: TripLegRecording) -> Judgement? {
        guard let wanted = leg.routing else { return nil }
        // A PROBE RUN HAS NO ROUTING TO JUDGE. It dispatches the binding
        // directly, which answers a different question honestly; the turn-level
        // runner is what fills this in.
        guard let found = recording.routing else { return nil }

        // THE CONFIDENT WRONG ACTION, FIRST. A skill the leg forbids winning is
        // a finding whatever else is true of the turn.
        if let winner = found.uniqueSkill, wanted.mustNotReach?.contains(winner) == true {
            return .failed(
                .abilityRouting,
                "reached \(winner), which must not answer this" + topAffinities(found))
        }
        // NOTHING AT ALL SHOULD FIRE. The verb does not exist yet, and until it
        // does the honest turn is one that asks rather than one that acts.
        if wanted.lane == TripLane.nothing {
            if let winner = found.uniqueSkill {
                return .failed(
                    .abilityRouting,
                    "dispatched \(winner) where nothing should have" + topAffinities(found))
            }
            return nil
        }
        if let intent = wanted.intent, let read = found.intent, intent != read {
            return .failed(
                .abilityRouting,
                "read as \(read), not \(intent)"
                    + (found.offered.isEmpty ? "" : " · offered \(found.offered.count)"))
        }
        if let skill = found.uniqueSkill, skill != wanted.skill {
            return .failed(
                .abilityRouting, "reached \(skill), not \(wanted.skill)")
        }
        if found.uniqueSkill == nil, wanted.lane == .confidence {
            return .failed(
                .abilityRouting,
                "no unique winner, so \(wanted.skill) cost a model round"
                    + topAffinities(found))
        }
        if let lane = wanted.lane, let ran = found.lane, lane.rawValue != ran {
            return .failed(
                .abilityRouting, "took the \(ran) lane, not \(lane.rawValue)")
        }
        if let shape = wanted.shape, let filled = found.shape, shape.rawValue != filled {
            return .failed(
                .abilityRouting,
                "its arguments read as \(filled), which the confidence lane cannot fill as \(shape.rawValue)")
        }
        for (name, value) in wanted.arguments ?? [:] {
            guard let filled = found.arguments[name] else {
                return .failed(.abilityRouting, "did not fill \(name)")
            }
            // FOLDED, BECAUSE A PERSON'S WORDS ARRIVE WITH THEIR PUNCTUATION.
            guard RowFactsDerivation.folded(filled)
                == RowFactsDerivation.folded(value) else {
                return .failed(
                    .abilityRouting, "filled \(name) with something else")
            }
        }
        return nil
    }

    private static func topAffinities(_ routing: RecordedRouting) -> String {
        let top = routing.topAffinities
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key) \(String(format: "%.2f", $0.value))" }
        return top.isEmpty ? "" : " · " + top.joined(separator: ", ")
    }

    // MARK: - A — the machine model

    static func ambient(_ leg: TripLeg, _ recording: TripLegRecording) -> Judgement? {
        if let wanted = leg.provider?.applicationID,
           let answered = recording.providerApplicationID,
           wanted != answered {
            return .failed(.ambient, "\(answered) answered, not \(wanted)")
        }
        if let wanted = leg.provider?.rationale,
           let rung = recording.providerRationale,
           wanted.rawValue != rung {
            return .failed(.ambient, "chosen by \(rung), not \(wanted.rawValue)")
        }

        guard let wanted = leg.ambient else { return nil }

        if let lead = wanted.leadBefore, let was = recording.ambientBefore?.lead,
           lead != was {
            return .failed(.ambient, "\(was) led into this leg, not \(lead)")
        }
        if let lead = wanted.leadAfter, let now = recording.ambientAfter?.lead,
           lead != now {
            return .failed(.ambient, "\(now) leads after it, not \(lead)")
        }
        if let front = wanted.frontAfter,
           let before = recording.ambientBefore?.frontApplicationID,
           let after = recording.ambientAfter?.frontApplicationID {
            switch front {
            case .restored where after != before:
                return .failed(
                    .ambient,
                    "left \(after) in front; \(before) was there before and is owed it back")
            case .browser where after == before && recording.acts.contains(where: {
                $0.kind == .bringForward
            }):
                // Nothing to say: the browser was already in front.
                break
            default: break
            }
        }
        if let pinned = wanted.pinned, let held = recording.ambientAfter?.pinned,
           pinned != held {
            return .failed(.ambient, "the pin says \(held), not \(pinned)")
        }
        if wanted.sessionInvalidated == true,
           recording.ambientAfter?.hasSession == true {
            return .failed(
                .ambient,
                "the page's session survived a change that makes every row in it wrong")
        }
        if let changed = wanted.frontContainerChanged, changed,
           let before = recording.ambientBefore?.frontContainer,
           let after = recording.ambientAfter?.frontContainer,
           before == after {
            return .failed(.ambient, "the front tab did not change")
        }
        return nil
    }

    // MARK: - P and R2 — the reading, then the route

    static func perception(_ leg: TripLeg, _ recording: TripLegRecording) -> Judgement? {
        guard let page = leg.page, let winner = page.winner else { return nil }
        guard let route = route(for: page, in: recording) else { return nil }
        // The route reached something. Whether it reached the RIGHT thing is R2.
        guard route.selectedOrdinal == nil || !satisfied(winner, by: route, in: recording)
        else { return nil }
        guard candidates(for: winner, in: recording).isEmpty else { return nil }

        return .failed(
            .perception,
            "no row in this reading answers the class"
                + " (\(route.decisions.count) rows read"
                + (recording.pageReads.last.map { $0.page.classified == false
                    ? ", NO CLASSIFIER" : "" } ?? "")
                + ") — the recall belongs in the detector")
    }

    static func pageRouting(_ leg: TripLeg, _ recording: TripLegRecording) -> Judgement? {
        guard let page = leg.page else { return nil }
        guard let route = route(for: page, in: recording) else {
            // A LEG THAT STATES A PAGE EXPECTATION AND ROUTED NOTHING never got
            // as far as the page. Ambient or execution has already spoken if it
            // was their doing; otherwise the read itself did not happen.
            return page.winner == nil && page.refusal == nil
                ? nil
                : .failed(.pageRouting, "nothing was routed against this page")
        }

        if let verb = page.verb, verb.traceWord != route.verb {
            return .failed(
                .pageRouting, "routed as \(route.verb), not \(verb.traceWord)")
        }
        if let unmatched = page.goalUnmatched, unmatched != route.goalUnmatched {
            return .failed(
                .pageRouting,
                unmatched
                    ? "claimed it matched the goal when it fell back"
                    : "reported the goal unmatched")
        }
        if let minimum = page.minimumEligible, route.eligibleCount < minimum {
            return .failed(
                .pageRouting,
                "only \(route.eligibleCount) rows were eligible, under \(minimum)"
                    + " — this is a refusal for want of rows, not a considered one")
        }
        if let refusal = page.refusal {
            guard route.selectedOrdinal == nil else {
                return .failed(
                    .pageRouting,
                    "reached a row where \(refusal.rawValue) was owed")
            }
            if let given = recording.refusal, given != refusal.rawValue {
                return .failed(
                    .pageRouting, "refused with \(given), not \(refusal.rawValue)")
            }
            return nil
        }
        guard let winner = page.winner else { return nil }
        guard route.selectedOrdinal != nil else {
            return .failed(
                .pageRouting,
                "reached nothing, though \(candidates(for: winner, in: recording).count)"
                    + " row(s) in the reading answer the class")
        }
        guard satisfied(winner, by: route, in: recording) else {
            return .failed(
                .pageRouting,
                "reached row \(route.selectedOrdinal ?? 0), which "
                    + mismatch(winner, route: route, recording: recording))
        }
        return nil
    }

    // MARK: - E — the act

    /// REFUSALS THAT MEAN "I COULD NOT SEE IT", which is a reading failure
    /// wherever it is reported from.
    ///
    /// PIN: MEASURED ON THE MEDIA TRIPS. Six transport legs refused
    /// `controlsNotFound` on a page that genuinely holds a player, and every one
    /// was filed under EXECUTION because the leg happened to state an engine
    /// expectation and not a page one. The executor did exactly what it was
    /// told; nothing was ever found to press. Sending that finding to the
    /// receipt ladder is sending it to the wrong file — it belongs to the
    /// detector, or to the reveal that was supposed to make the controls appear.
    static let sightRefusals: Set<String> = [
        "controlsNotFound", "controlNotFound", "visionUnavailable", "pageNotVisible",
    ]

    static func execution(_ leg: TripLeg, _ recording: TripLegRecording) -> Judgement? {
        guard let wanted = leg.engine else { return nil }

        // A REFUSAL THE LEG DID NOT ASK FOR, ABOUT SOMETHING NOT SEEN.
        if let refused = recording.refusal, Self.sightRefusals.contains(refused),
           wanted.refusal?.rawValue != refused {
            return .failed(
                .perception,
                "refused \(refused) — nothing was found to act on"
                    + (recording.media.last.map {
                        " (\($0.controlCount) control(s) seen, controls visible: \($0.controlsVisible))"
                    } ?? ""))
        }

        if let refusal = wanted.refusal {
            guard recording.refusal == refusal.rawValue else {
                return .failed(
                    .execution,
                    "refused with \(recording.refusal ?? "nothing") where \(refusal.rawValue) was owed")
            }
            return nil
        }
        if let receipt = wanted.receipt, receipt != .none {
            let best = recording.bestReceipt
            guard best == receipt.rawValue else {
                return .failed(
                    .execution,
                    "its best receipt was \(best), not \(receipt.rawValue)"
                        + (recording.refusal.map { " · refused \($0)" } ?? ""))
            }
        }
        if let landed = wanted.landed, landed != recording.landed {
            return .failed(
                .execution,
                landed
                    ? "did not land — \(recording.bestReceipt) is not proof"
                        + (recording.refusal.map { ", refused \($0)" } ?? "")
                    : "claimed to land on evidence that is only a sign")
        }
        return nil
    }

    // MARK: - S — the mouth

    static func speech(_ leg: TripLeg, _ recording: TripLegRecording) -> Judgement? {
        guard let wanted = leg.speech, let found = recording.speech else { return nil }

        if wanted.silence == "forbidden", found.spoken.isEmpty {
            return .failed(
                .speech,
                "the turn ended having said nothing"
                    + (found.readRoutes.isEmpty
                        ? "" : " · read went \(found.readRoutes.joined(separator: ", "))"))
        }
        if wanted.readBack == true, found.spokeInTurn == false {
            return .failed(
                .speech,
                "what it read was not said in the turn that asked"
                    + (found.readRoutes.isEmpty
                        ? "" : " · \(found.readRoutes.joined(separator: ", "))"))
        }
        for forbidden in wanted.ledgerNot ?? []
        where found.readRoutes.contains(forbidden) {
            return .failed(.speech, "the read went \(forbidden)")
        }
        return nil
    }

    // MARK: - T — the clock

    static func timing(_ leg: TripLeg, _ recording: TripLegRecording) -> Judgement? {
        guard let budget = leg.engine?.budgetMs,
              recording.elapsedMilliseconds > budget
        else { return nil }
        return .failed(
            .timing,
            "took \(recording.elapsedMilliseconds)ms against a \(budget)ms budget")
    }

    /// THE ROUTE A LEG IS TALKING ABOUT.
    ///
    /// PIN: A LEG CAN ROUTE MORE THAN ONCE, AND "THE LAST ONE" IS THE WRONG
    /// ANSWER. Measured live: a search navigates, reads, arbitrates `.openResult`
    /// to choose an answer, then presses it — and pressing arbitrates AGAIN with
    /// `.press`. A leg stating `verb: openResult` was being judged against the
    /// inner press and reported as routing with the wrong verb, which is the
    /// classifier blaming the router for the classifier's own reading. When a leg
    /// names a verb, the route it means is the one argued with that verb.
    static func route(
        for expectation: TripPageExpectation, in recording: TripLegRecording
    ) -> RecordedRoute? {
        guard let verb = expectation.verb else { return recording.routes.last }
        return recording.routes.last { $0.verb == verb.traceWord }
            ?? recording.routes.last
    }

    // MARK: - Reading a row class against a recorded page

    /// Every ordinal in the last recorded page that answers this class.
    ///
    /// PIN: THE ORDINAL COUNTS WITHIN WHAT THE REST OF THE CLASS ADMITS. "The
    /// second result" is the second row that is in a result group and is not the
    /// query echoed back — not the second row on the page, which is what counting
    /// at large did and how a navigation strip came to be opened.
    public static func candidates(
        for wanted: TripRowClass, in recording: TripLegRecording
    ) -> [Int] {
        guard let page = recording.pageReads.last?.page else { return [] }
        let required = BrowsingTripValidator.facts(named: wanted.facts ?? [])
        let forbidden = BrowsingTripValidator.facts(named: wanted.factsAbsent ?? [])

        var matching = page.rows.filter { row in
            let facts = RowFacts(rawValue: row.facts ?? 0)
            guard facts.isSuperset(of: required) else { return false }
            guard facts.isDisjoint(with: forbidden) else { return false }
            if let affordance = wanted.affordance,
               row.affordance != affordance.rawValue { return false }
            if let kind = wanted.kind, row.kind != kind { return false }
            return true
        }
        matching.sort { $0.ordinal < $1.ordinal }

        guard let ordinal = wanted.ordinalWithinKind else {
            return matching.map(\.ordinal)
        }
        guard ordinal <= matching.count else { return [] }
        return [matching[ordinal - 1].ordinal]
    }

    /// Did the route reach a row that answers the class?
    public static func satisfied(
        _ wanted: TripRowClass, by route: RecordedRoute, in recording: TripLegRecording
    ) -> Bool {
        guard let selected = route.selectedOrdinal else { return false }
        if let basis = wanted.lexicalBasis,
           route.decisions.first(where: { $0.ordinal == selected })?.lexicalBasis != basis {
            return false
        }
        return candidates(for: wanted, in: recording).contains(selected)
    }

    /// What is wrong with the row it did reach — the sentence a reader acts on.
    static func mismatch(
        _ wanted: TripRowClass, route: RecordedRoute, recording: TripLegRecording
    ) -> String {
        guard let selected = route.selectedOrdinal,
              let row = recording.pageReads.last?.page.rows.first(where: {
                  $0.ordinal == selected
              })
        else { return "is not in the reading at all" }

        let facts = RowFacts(rawValue: row.facts ?? 0)
        let required = BrowsingTripValidator.facts(named: wanted.facts ?? [])
        let forbidden = BrowsingTripValidator.facts(named: wanted.factsAbsent ?? [])

        if !facts.isDisjoint(with: forbidden) {
            let named = (wanted.factsAbsent ?? []).filter {
                !BrowsingTripValidator.facts(named: [$0]).isDisjoint(with: facts)
            }
            return "is \(named.joined(separator: " and "))"
        }
        if !facts.isSuperset(of: required) {
            let missing = (wanted.facts ?? []).filter {
                facts.isDisjoint(with: BrowsingTripValidator.facts(named: [$0]))
            }
            return "is not \(missing.joined(separator: " or "))"
        }
        if let affordance = wanted.affordance, row.affordance != affordance.rawValue {
            return "affords \(row.affordance), not \(affordance.rawValue)"
        }
        if let kind = wanted.kind, row.kind != kind {
            return "is a \(row.kind ?? "row of no named kind"), not a \(kind)"
        }
        if let ordinal = wanted.ordinalWithinKind {
            let admitted = candidates(
                for: TripRowClass(
                    facts: wanted.facts, factsAbsent: wanted.factsAbsent,
                    affordance: wanted.affordance, kind: wanted.kind),
                in: recording)
            let place = admitted.firstIndex(of: selected).map { $0 + 1 }
            return place.map { "is number \($0) of its kind, not \(ordinal)" }
                ?? "is not among the rows the class admits"
        }
        if let basis = wanted.lexicalBasis {
            let reached = route.decisions.first { $0.ordinal == selected }?.lexicalBasis
            return "was reached by \(reached ?? "nothing"), not \(basis)"
        }
        return "does not answer the class"
    }
}
