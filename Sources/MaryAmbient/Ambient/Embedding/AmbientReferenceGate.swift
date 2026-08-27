//
//  AmbientReferenceGate.swift
//  MaryAmbient
//
//  THE FRONT DOOR for mapping a spoken referent onto the ambient world.
//  Every "which element did they mean" question — a canvas layer, a prose
//  passage, a held fact — is answered here: the scope's records are RANKED
//  BY RELEVANCY to the phrase (embedding similarity over each element's
//  serialized claims), filtered by what the invoked functionality REQUIRES
//  of its target (a move needs a frame), and returned best-first with
//  scores, so resolution can offer a best guess and its runner-up instead
//  of a coin toss or silence.
//
//  THE LEXICON IS SUPPORT, NOT THE DOOR. `AmbientKindLexicon` participates
//  three subordinate ways — floors (an exact kind/name/synonym hit outranks
//  any semantic guess), a precision veto (a known kind word never ranks an
//  element of a different known kind it does not admit), and the whole
//  ranker in degraded mode (no OS embedding asset). It never widens the
//  gate: open vocabulary — "screenshot", "the sunrise one" — is the
//  embedding's to answer, which is exactly the category the old hardcoded
//  synonym rows were patching one live miss at a time.
//

import Foundation

/// One element, scored. `basis` says what carried it — the strongest
/// contributor — for briefs and traces.
public struct RankedAmbientElement: Sendable, Equatable {
    public enum Basis: Sendable, Equatable {
        /// Embedding similarity alone.
        case semantic
        /// The phrase spoke the element's own kind word.
        case lexicalKind
        /// The phrase spoke the element's name.
        case lexicalName
        /// A closed-class synonym admitted the element's kind.
        case lexicalSynonym
    }
    public var record: AmbientElementRecord
    public var score: Float
    public var basis: Basis

    public init(record: AmbientElementRecord, score: Float, basis: Basis) {
        self.record = record
        self.score = score
        self.basis = basis
    }
}

public enum AmbientReferenceGate {

    /// Below this an element is not offered at all. Calibrated with the
    /// opt-in harness against the shipped OS sentence embedding, whose
    /// scores run compressed: "screenshot"→image claims measure 0.555–0.599
    /// while the rejections sit at 0.432 ("screenshot"→text) and below.
    /// The one same-band collision — "rectangle"→oval at 0.599 — is closed
    /// class, which is the veto's job, not the threshold's; precision for
    /// open vocabulary still matters more than recall, because a wrong
    /// target moves the wrong layer.
    public static let acceptanceThreshold: Float = 0.50

    /// Floors for lexical certainty. An exact hit must outrank any
    /// semantic guess, and the floors keep their own order: an element the
    /// phrase names AND kinds ("the header oval" against an Oval named
    /// "Header") beats the element's own kind word beats its name beats a
    /// synonym.
    static let nameAndKindFloor: Float = 0.98
    static let kindFloor: Float = 0.95
    static let nameFloor: Float = 0.92
    static let synonymFloor: Float = 0.88

    /// THE FRONT DOOR. Ranks the scope's elements by relevancy to the
    /// phrase, keeps only those able to serve the invocation (`requires`),
    /// and returns them best-first. Ties keep record order — for a canvas
    /// that is outline order, preserving the topmost-on-page instinct.
    public static func rank(
        phrase: String,
        scope: AmbientElementScope,
        requires: AmbientElementCapabilities = [],
        store: AmbientElementIndexStore = .shared
    ) -> [RankedAmbientElement] {
        guard let index = store.index(for: scope) else { return [] }
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let semantic = store.queryVector(for: trimmed)
            .map(index.semanticScores(forQueryVector:)) ?? [:]

        let lowered = trimmed.lowercased()
        let words = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // The vocabulary for THIS scope's application, when an admitted
        // package declares one. No lexicon → the synonym floor and the
        // precision veto stand down; kind and name floors survive because
        // they need no table (a provider's own kind word self-matches).
        let lexicon = AmbientArtifactLexiconProvider.lexicon(forApplication: scope.key)
        // The union of kinds the phrase's CLOSED-CLASS words admit; nil when
        // the phrase speaks no known kind word and the veto stands down.
        let admittedKinds: Set<String>? = {
            guard let lexicon else { return nil }
            let admissions = words.compactMap { lexicon.admittedKinds(for: $0) }
            guard !admissions.isEmpty else { return nil }
            return admissions.reduce(into: Set<String>()) { $0.formUnion($1) }
        }()

        var ranked: [(element: RankedAmbientElement, order: Int)] = []
        for (order, record) in index.records.enumerated() {
            guard record.capabilities.isSuperset(of: requires) else { continue }
            var score = semantic[record.elementID] ?? 0
            var basis = RankedAmbientElement.Basis.semantic

            let namedHit = nameMatches(record.name, in: lowered)
            let kindHit = words.contains(record.kindWord)
            let synonymHit = !kindHit
                && (lexicon?.phrase(lowered, admits: record.kindWord) ?? false)
            let floor: (Float, RankedAmbientElement.Basis)? = {
                if namedHit, kindHit || synonymHit {
                    return (nameAndKindFloor, .lexicalName)
                }
                if kindHit { return (kindFloor, .lexicalKind) }
                if namedHit { return (nameFloor, .lexicalName) }
                if synonymHit { return (synonymFloor, .lexicalSynonym) }
                return nil
            }()
            if let (floorScore, floorBasis) = floor, score < floorScore {
                score = floorScore
                basis = floorBasis
            }

            // PRECISION VETO. The phrase spoke a known kind word; this
            // element is of a known kind those words do not admit —
            // "rectangle" cannot mean an Oval however cozy the vectors.
            // A spoken NAME survives the veto, because a name outranks a
            // kind: "the header oval" may still mean the Text named
            // "Header", exactly as the pre-gate name band did.
            if let lexicon, let admittedKinds,
               lexicon.providerKinds.contains(record.kindWord),
               !admittedKinds.contains(record.kindWord),
               !namedHit {
                continue
            }

            guard score >= acceptanceThreshold else { continue }
            ranked.append((
                RankedAmbientElement(record: record, score: score, basis: basis),
                order))
        }
        return ranked
            .sorted { lhs, rhs in
                lhs.element.score != rhs.element.score
                    ? lhs.element.score > rhs.element.score
                    : lhs.order < rhs.order
            }
            .map(\.element)
    }

    /// Classification probe: does this word plausibly name ANY element of
    /// the scope? The cheap yes/no the cue classifier needs — one word
    /// vectorization plus dots, or lexicon floors in degraded mode.
    public static func names(
        _ word: String,
        inScope scope: AmbientElementScope,
        store: AmbientElementIndexStore = .shared
    ) -> Bool {
        !rank(phrase: word, scope: scope, store: store).isEmpty
    }

    /// Word-boundary containment of the element's name (whole or any word
    /// of it) in the phrase — "the header oval" matches a layer named
    /// "Header". Mirrors the ledger's historical matcher.
    static func nameMatches(_ name: String?, in phrase: String) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        if ReferenceResolver.mentions(name, in: phrase) { return true }
        return name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { ReferenceResolver.mentions(String($0), in: phrase) }
    }
}
