//
//  PageRouter+Evidence.swift
//  MaryPlugin
//
//  WHAT: What is true of a row, as bounded numbers, and the order they are compared in.
//  IN:   PageRouter.arbitrate
//  OUT:  PageRouteEvidence + the rank vector
//  PIN:  THE ORDER IS THE DESIGN, NOT THE MAGNITUDES. A naming hit is compared before
//        meaning, meaning before the page's own structure, and structure before how sure
//        the reading was — so no pile of small priors can outweigh the person having said
//        the row's name. Summing everything into one number is what let a navigation strip
//        beat a result: it carried a little of several things while the answer carried a
//        lot of one.
//        SIGNED STRUCTURE, BECAUSE A PAGE ARGUES BOTH WAYS. Sitting in a result group is
//        evidence for; sitting behind a dialog, in a toolbar, or under a "sponsored"
//        marker is evidence against. A gate would be wrong for all of them — every one is
//        a judgement about layout that can be mistaken, and the words must be able to
//        overrule it.
//        THE CONSTANTS ARE MEASURED, NOT REASONED. Every floor here is checked against
//        recorded pages by `PageRouteCalibrationTests`; the numbers below are where that
//        measurement started, and moving one without re-running it is guessing.
//

import Foundation
import MaryComputerUse

public extension PageRouter {

    // MARK: - Floors

    /// What a row must mean to the goal before it can be reached at all, ×1000.
    ///
    /// MEASURED against recorded pages. It sits above `AmbientReferenceGate`'s 0.50
    /// acceptance — that gate answers "could this be meant", and a router that acts needs
    /// more — and below the ability roster's 0.62, because a label is a fragment where an
    /// ability's corpus is whole sentences.
    static let semanticFloor = 550

    /// And what a row the map did NOT offer must reach, when the words did not name it.
    /// Higher, because candidacy is the reading admitting it is unsure.
    static let candidateFloor = 700

    /// A naming rung at or above this is enough on its own.
    static let lexicalFloor = 200
    /// What a candidate's naming must reach instead — containment, not a loose word cover.
    static let candidateLexicalFloor = 300

    // MARK: - Terms

    /// The naming rung, as points.
    static func lexicalScore(_ rung: SpokenReference.Rung) -> Int {
        switch rung {
        case .ordinal: return 500
        case .exact: return 400
        case .contained: return 300
        case .allWords: return 200
        case .kindOnly: return 100
        }
    }

    static func basis(_ rung: SpokenReference.Rung) -> PageRouteLexicalBasis {
        switch rung {
        case .ordinal: return .ordinal
        case .exact: return .exact
        case .contained: return .contained
        case .allWords: return .allWords
        case .kindOnly: return .kindOnly
        }
    }

    /// How well the row's affordance fits the verb.
    static func affordanceScore(
        _ row: PageRow, verb: PageRouteVerb, standing: ArbitrationStanding
    ) -> Int {
        guard standing == .offered else { return 0 }
        if let wanted = verb.wantedAffordance {
            if row.affordance == wanted { return 100 }
            // Clicking a field is how a person focuses it — a real fit, a weaker one.
            if wanted == .press, row.affordance == .fill { return 40 }
            return 0
        }
        return row.affordance == .none ? 0 : 40
    }

    /// How sure the reading is — of the name, and of the affordance.
    ///
    /// PIN: `confidence` IS NEUTRAL AT ZERO. The reader does not populate it yet, so a
    /// term that punished zero would punish every row on every page equally, which is the
    /// same as punishing none and is a lie in the trace.
    static func provenanceScore(_ row: PageRow) -> Int {
        var score: Int
        switch row.labelSource {
        case .classifier: score = 40
        case .textInside: score = 30
        case .textAdjacent: score = 25
        case .icon: score = 10
        case .synthesized: score = 0
        }
        switch row.affordanceSource {
        case .classifier: score += 30
        case .grouping: score += 20
        case .shape: score += 10
        case .unknown: break
        }
        return score + Int((max(0, min(1, row.confidence)) * 30).rounded())
    }

    /// What the row's place on the page says about it, for and against.
    ///
    /// PIN: READS FACTS, DOES NOT DERIVE THEM. Every question here — is it in a
    /// result group, behind a dialog, in a strip of furniture, marked as paid for
    /// — was answered once at the seal. This weighs the answers.
    static func structureScore(
        _ row: PageRow, verb: PageRouteVerb, in domain: PageRouteDomain
    ) -> (score: Int, note: String?) {
        var score = 0
        var note: String?

        // NOTHING BEHIND A DIALOG CAN BE REACHED WHILE IT IS THERE — and this is a
        // prior, not a gate, because an overlay is itself a guess about geometry.
        if row.facts.contains(.behindOverlay) {
            score -= 200
            note = "is behind the dialog"
        }

        switch verb {
        case .openResult:
            if row.facts.contains(.inResultGroup) { score += 60 }
            if row.affordanceSource == .grouping { score += 40 }
            if row.facts.contains(.inToolbar) { score -= 80 }
            if row.facts.contains(.inForm) { score -= 60 }
            if row.facts.contains(.inFurnitureBand) {
                score -= 60
                note = note ?? "is a strip of page furniture"
            }
            if row.facts.contains(.promoted) {
                score -= 100
                note = note ?? "is marked as promoted"
            }
            if let named = domain.kindNamedInGoal, row.kind != named {
                score -= 50
                note = note ?? "isn't a \(named.spokenWord)"
            }

        case .fill:
            if row.kind == .field { score += 60 }
            if row.facts.contains(.inForm) { score += 40 }
            // A LABEL BESIDE A BOX IS A FORM'S LABEL FOR ITS FIELD.
            if row.labelSource == .textAdjacent { score += 20 }

        case .press:
            if row.facts.contains(.inOverlay) { score += 80 }
            if let named = domain.kindNamedInGoal, row.kind != named {
                score -= 50
                note = note ?? "isn't a \(named.spokenWord)"
            }

        case .adjust, .reveal:
            break
        }

        // THE SITE THE PERSON NAMED, credited among the rows that survived the
        // gate. The gate does the refusing (see `PageRouter+Gates`); this only
        // separates a row that PROVES it goes there from one whose destination
        // nothing published, which the gate deliberately lets through.
        if let wanted = domain.siteNamedInGoal, row.site == wanted { score += 70 }
        return (score, note)
    }

    // MARK: - Ranking

    /// The order the terms are compared in, for this verb.
    ///
    /// PIN: PAGE ORDER IS NOT IN HERE. It is evidence only when the person spoke a
    /// position, and then it arrives as the `ordinal` rung — authored, not assumed. As an
    /// ordering it decides only which of two otherwise identical rows is listed first.
    static func rankVector(
        _ evidence: PageRouteEvidence, verb: PageRouteVerb, hasGoal: Bool
    ) -> [Int] {
        guard hasGoal else {
            // NO GOAL, NO WORDS TO WEIGH. What the page's own structure says is all there
            // is, and after it the reading's confidence in what it saw.
            return [evidence.structure, evidence.provenance]
        }
        switch verb {
        case .openResult:
            return [evidence.lexical, evidence.semantic, evidence.structure, evidence.provenance]
        case .press, .fill, .adjust, .reveal:
            return [
                evidence.lexical, evidence.semantic, evidence.structure,
                evidence.affordance, evidence.provenance,
            ]
        }
    }

    /// Lexicographic, descending, with the row's own position as the last word — so two
    /// rows nothing can separate are still ordered the same way on every run.
    static func ranksBefore(
        _ lhs: (vector: [Int], ordinal: Int), _ rhs: (vector: [Int], ordinal: Int)
    ) -> Bool {
        for (left, right) in zip(lhs.vector, rhs.vector) where left != right {
            return left > right
        }
        return lhs.ordinal < rhs.ordinal
    }
}
