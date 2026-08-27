//
//  AmbientAddressProbe.swift
//  MaryAmbient
//
//  DID THE USER ADDRESS AN APPLICATION BY SOMETHING IT IS SHOWING?
//
//  `ApplicationProfile.isMentioned` answers "did they say this app's NAME",
//  by exact whole-token match against authored aliases. That is the right
//  question and it fails closed in one specific way: a user looking at a
//  Google Doc says "this google doc", which is not a browser's name, so
//  nothing is addressed — and the turn falls to whatever stale lead the
//  tracker held. The repair is not a longer alias list (someone has to guess
//  every phrase in advance, forever); it is to ask the SECOND question:
//  does the utterance name something one of these applications is currently
//  showing?
//
//  WHY THIS IS NOT `AmbientReferenceGate`, though it reads the same index.
//  That gate answers "WHICH of these elements" for an application the user
//  has already opened, and its lexical floors are calibrated for that: its
//  name floor matches ANY WORD of an element's name (0.92), and its kind
//  floor fires on the kind word alone (0.95). Point those at THIS question
//  and a tab called "The DEFIANCE Act — Congress.gov" addresses the browser
//  on any sentence containing "the", while the word "tab" addresses it on
//  every record at once. Same index, same vectors, different question,
//  therefore different rules — and no floors.
//
//  ADDITIVE, NEVER A VETO. Nothing here can remove an application another
//  mechanism named: the result is unioned downstream, `excluding` keeps it
//  from re-deciding a literal name, and it has no subtraction path at all.
//  It also never mints a LEAD — the engine keeps its named-application set
//  literal precisely so `explicitlyNamedApplicationID` stays a true-names
//  question. Addressing admits a roster and arms a decaying referent; it
//  does not decide whose turn this is.
//
//  FAIL-CLOSED. No candidates, no index, or no embedding asset on the OS and
//  the semantic channel returns nothing — leaving the spoken-title channel,
//  which is pure token matching. Every degradation lands on today's
//  behaviour.
//

import Foundation

/// One application the utterance addressed by its live contents.
public struct AmbientAddress: Sendable, Equatable {
    public enum Basis: String, Sendable, Equatable {
        /// The embedding matched something the application is showing.
        case semantic
        /// The user spoke an observed title outright.
        case spokenTitle
    }

    /// The CLOSED profile-id vocabulary routing speaks.
    public var applicationID: String
    /// The scope's own realm — carried because `gate.applications` alone
    /// cannot admit one: `namedRealms` skips every registration with a
    /// legacy world, and the browser's profile has one.
    public var realm: AmbientRealm
    public var score: Float
    public var basis: Basis

    public init(applicationID: String, realm: AmbientRealm, score: Float, basis: Basis) {
        self.applicationID = applicationID
        self.realm = realm
        self.score = score
        self.basis = basis
    }
}

public enum AmbientAddressProbe {

    /// Where an application's elements live, and what routing calls it.
    public struct Candidate: Sendable, Equatable {
        public var scope: AmbientElementScope
        public var applicationID: String

        public init(scope: AmbientElementScope, applicationID: String) {
            self.scope = scope
            self.applicationID = applicationID
        }
    }

    /// THE SAME NUMBER `SemanticAbilityRequestIndex` USES, deliberately.
    /// Both ask "did this utterance assert a thing?", a question whose null
    /// hypothesis is true on the overwhelming majority of turns and whose
    /// false positive pollutes routing. The element gate's 0.50 answers a
    /// different question — "which of these, given the user already opened
    /// this app" — where the alternatives are peers and abstaining helps
    /// nobody. One constant for one question; move it once, with a
    /// calibration table, in this file.
    public static let acceptanceThreshold: Float = 0.62

    /// How fresh a scope's publication must be to speak for the world.
    public static let candidateHorizon: TimeInterval = 5 * 60

    /// G1's vocabulary: definite reference. Someone pointing at something
    /// that already exists says "this"/"the"/"my"; someone creating
    /// something says "a". The indefinite case is the main false-positive
    /// family ("draw a circle", "add a draft") and it is excluded by shape
    /// rather than by score.
    static let referentialWords: Set<String> = [
        "this", "that", "these", "those", "the",
        "my", "our", "your", "its", "his", "her", "their",
        "here", "there", "current", "currently", "open", "already",
    ]

    /// Addresses this utterance asserts, best first, one per application.
    public static func address(
        utterance: String,
        candidates: [Candidate],
        excluding: Set<String> = [],
        store: AmbientElementIndexStore = .shared
    ) -> [AmbientAddress] {
        // Zero cost on every turn where nothing published — which is every
        // pre-perception turn and every existing test.
        guard !candidates.isEmpty else { return [] }
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let words = tokens(of: trimmed)
        guard !words.isEmpty else { return [] }

        // G1 — REFERENTIAL SHAPE. Deliberately broader than
        // `referencesApplicationAnaphorically`, which requires a leading
        // continuation verb and would reject "what's in my google doc" — the
        // no-look path this exists to serve.
        guard !words.isDisjoint(with: referentialWords)
                || AmbientRanker.isDeictic(trimmed)
        else { return [] }

        // ONE vectorization for the whole turn — memoized in the store, so a
        // later probe of the same phrase costs dot products only.
        let query = store.queryVector(for: trimmed)
        var found: [AmbientAddress] = []

        for candidate in candidates where !excluding.contains(candidate.applicationID) {
            guard let index = store.index(for: candidate.scope) else { continue }
            let semantic = query.map { index.semanticScores(forQueryVector: $0) } ?? [:]

            var best: Float = 0
            var basis = AmbientAddress.Basis.semantic
            for entry in index.entries {
                guard isDistinctive(entry.record) else { continue }   // G3
                // G4 — the spoken-title channel: the user said the title, as
                // a contiguous multi-token window. This is `isMentioned`'s
                // matcher applied to an OBSERVED name instead of an authored
                // alias, which is the whole thesis in one rung, and the only
                // channel that survives degraded mode.
                if let name = entry.record.name, spoke(name, in: words) {
                    best = 1
                    basis = .spokenTitle
                    break
                }
                if let score = semantic[entry.record.elementID], score > best {
                    best = score
                    basis = .semantic
                }
            }
            guard best >= acceptanceThreshold else { continue }       // G2
            found.append(AmbientAddress(
                applicationID: candidate.applicationID,
                realm: candidate.scope.realm,
                score: best,
                basis: basis))
        }
        return found.sorted { $0.score > $1.score }
    }

    // MARK: - Guards

    /// G3 — could this record's name identify anything on its own? A tab
    /// called "Home", "New Tab" or "Untitled" must never address an
    /// application at any score, and the test is the tree's existing notion
    /// of a word worth matching on.
    static func isDistinctive(_ record: AmbientElementRecord) -> Bool {
        guard let name = record.name else { return false }
        let words = tokens(of: name)
        guard words.count >= 2 else { return false }
        return words.contains { $0.count >= 4 && !AmbientRanker.stopWords.contains($0) }
    }

    /// Contiguous whole-token window, ≥2 tokens — `ApplicationProfile
    /// .isMentioned`'s shape. NOT the element gate's `nameMatches`, which
    /// matches any single word of a name and would fire on "the".
    static func spoke(_ name: String, in utterance: [String]) -> Bool {
        let needle = tokens(of: name).filter { !$0.isEmpty }
        guard needle.count >= 2, utterance.count >= needle.count else { return false }
        for start in 0...(utterance.count - needle.count)
        where Array(utterance[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    static func tokens(of value: String) -> [String] {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

private extension Array where Element == String {
    func isDisjoint(with other: Set<String>) -> Bool {
        !contains(where: other.contains)
    }
}
