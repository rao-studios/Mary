//
//  SemanticApplicationIndex.swift
//  MaryBrain
//
//  WHAT: Embedding recall over the applications a system-control Skill may be
//        pointed at — "textedit" and "the plain text editor" both reach the
//        same package, from that package's OWN declared names.
//  IN:   applicationAffinities + the package's own aliases/bundle names
//  OUT:  ApplicationReferenceResolution
//  PIN:  A WORD THE HOST ABILITY OWNS CANNOT NAME AN APPLICATION. Subtracting
//        the host's vocabulary is not a nicety — `window-management` claims the
//        token "window", so without it every application whose corpus mentions
//        windows scores on every window sentence and the ranking is noise.
//
import Foundation
import MaryFoundation

/// Prebuilt per-application vectors plus the query path. Built once per
/// registry reload; immutable and Sendable thereafter, like its four siblings.
public struct SemanticApplicationIndex: Sendable {

    /// Cosine similarity at or above this may name an application. The same
    /// number the rest of the routing seams use, deliberately — a resolution
    /// this feeds is one argument of a Skill the corpus already chose, so the
    /// bar to clear is the bar that chose it.
    ///
    /// MEASURED, NOT GUESSED (`EmbeddingCalibrationTests`, real `NLEmbedding`,
    /// the shipped packages). "Open a new textedit window" scores its own
    /// package at 1.000 — a declared name matched exactly — against 0.635 for
    /// the runner-up, so the honest cases are nowhere near this line. The line
    /// is there for the DISHONEST ones: "open a new calculator window", naming
    /// an application no package claims, tops out at 0.615 on `xcode`. Five
    /// thousandths of headroom is not much, which is why the margin below is
    /// not optional.
    public static let defaultThreshold: Float = 0.62

    /// How far ahead of the runner-up the leader must be to be THE answer.
    ///
    /// Application names cluster hard — two editors, two browsers — so a floor
    /// alone routinely admits a pair. Naming the wrong application is worse
    /// than naming none: none falls to the model, which can ask.
    ///
    /// TWO TESTS, AND THE SECOND ONE EARNS ITS KEEP. The calculator sentence
    /// above is caught twice over: 0.615 is under the floor, AND its lead over
    /// the runner-up (0.615 vs 0.576, a gap of 0.039) is under this margin.
    /// Either alone would have refused it; together they would still refuse it
    /// if the model shifted slightly under one of them.
    public static let defaultMargin: Float = 0.04

    /// One corpus term and its vector. THE TERM IS KEPT, not just its vector,
    /// because the host-vocabulary rule is a question about the WORDS ("does
    /// `window-management` also claim this term?") and answering it by
    /// comparing vectors for near-identity would be a slow, fuzzy spelling of
    /// a set membership test.
    private struct Term: Sendable {
        var text: String
        var vector: [Float]
    }

    private struct Entry: Sendable {
        var abilityID: AbilityID
        var applicationID: String
        var positives: [Term]
    }

    private let entries: [Entry]
    private let vectorizer: any UtteranceVectorizer
    private let threshold: Float
    private let margin: Float

    public var entryCount: Int { entries.count }

    /// One scored application.
    public struct Match: Sendable, Hashable {
        public var abilityID: AbilityID
        public var applicationID: String
        public var score: Float
    }

    /// Nil when nothing vectorized — an index that can only say "no" is dead
    /// weight, and every caller degrades to the model rather than to a guess.
    public static func build(
        records: [AbilityPackageRecord],
        vectorizer: any UtteranceVectorizer,
        templates: UtteranceTemplateExpander? = nil,
        /// Fixture ids to leave OUT of the corpus.
        ///
        /// HOLD-OUT, AND IT IS THE ONLY WAY THIS CORPUS CAN BE MEASURED. A
        /// route fixture is embedded here and then graded against this same
        /// index, where it matches itself at ~1.0 and (because scoring is
        /// max-over-positives) swamps every other term. Excluding it at build
        /// asks the real question: does the sentence still route when it is
        /// not teaching itself? Empty in production — nothing on the turn path
        /// passes this.
        excludingFixtures: Set<String> = [],
        threshold: Float = defaultThreshold,
        margin: Float = defaultMargin
    ) -> SemanticApplicationIndex? {
        var entries: [Entry] = []
        for record in records {
            let package = record.package
            guard let affinity = package.applicationAffinities.first else { continue }
            let ability = package.ability
            var terms: [String] = [affinity.title, ability.title]
            terms += package.applicationAffinities.map(\.title)
            terms += ability.aliases
            terms += ability.triggers.tokens
            terms += ability.triggers.phrases
            if let application = package.plugin?.application {
                terms += application.aliases
                terms.append(application.title)
                // `TextEdit.app` is not language. Say it as words so the
                // sentence embedding sees a name and not a filename.
                terms += application.bundleNames.map(Self.spoken)
            }
            terms += package.fixtures
                .filter { $0.teachesCorpus && !excludingFixtures.contains($0.id) }
                .map(\.utterance)
            terms = templates?.expand(terms, for: ability.id) ?? terms
            let positives = Self.corpus(terms).compactMap { term in
                vectorizer.vector(for: term).map {
                    Term(text: term.lowercased(), vector: Self.normalized($0))
                }
            }
            guard !positives.isEmpty else { continue }
            entries.append(Entry(
                abilityID: ability.id,
                applicationID: affinity.id,
                positives: positives))
        }
        guard !entries.isEmpty else { return nil }
        let dim = entries.first?.positives.first?.vector.count ?? 0
        MaryBrain.turnLog.info(
            "embed generate — applications=\(entries.count, privacy: .public) dim=\(dim, privacy: .public)")
        return SemanticApplicationIndex(
            entries: entries, vectorizer: vectorizer,
            threshold: threshold, margin: margin)
    }

    private init(
        entries: [Entry],
        vectorizer: any UtteranceVectorizer,
        threshold: Float,
        margin: Float
    ) {
        self.entries = entries
        self.vectorizer = vectorizer
        self.threshold = threshold
        self.margin = margin
    }

    /// Every candidate scored, ranked, nothing thresholded.
    ///
    /// THE SCORED SIBLING of `resolve`, and the benches read it: a candidate at
    /// 0.61 and one at 0.20 both fail to resolve and are completely different
    /// problems. `excluding` is the host Ability's own vocabulary.
    public func ranked(
        in utterance: String,
        candidates: [AbilityID],
        excluding hostVocabulary: Set<String> = []
    ) -> [Match] {
        guard !candidates.isEmpty else { return [] }
        let queries = Self.queryTerms(
            in: RoutingQuery.firstLine(utterance), excluding: hostVocabulary)
            .compactMap { vectorizer.vector(for: $0).map(Self.normalized) }
        guard !queries.isEmpty else { return [] }
        let wanted = Set(candidates)
        let owned = Set(hostVocabulary.map { $0.lowercased() })
        var matches: [Match] = []
        for entry in entries where wanted.contains(entry.abilityID) {
            var best: Float = -1
            for positive in entry.positives {
                // A TERM THE HOST ALSO OWNS IS NOT THIS APPLICATION'S NAME.
                // `window-management` declares the token "window", and several
                // application packages say it too. Left in, "bring the window
                // forward" would score every one of them on a word that names
                // the Ability rather than any application — the same fault
                // `assertionIsOnlyDisciplineVocabulary` fixes for disciplines,
                // where "music" belonged to multimedia and named Apple Music
                // on every single turn.
                guard !owned.contains(positive.text) else { continue }
                for query in queries {
                    best = max(best, Self.dot(positive.vector, query))
                }
            }
            guard best > -1 else { continue }
            matches.append(Match(
                abilityID: entry.abilityID,
                applicationID: entry.applicationID,
                score: best))
        }
        // Stable across launches: score, then id — the same rule the reverse
        // index sorts by.
        return matches.sorted {
            $0.score != $1.score
                ? $0.score > $1.score
                : $0.abilityID.rawValue < $1.abilityID.rawValue
        }
    }

    /// The one application a RANKING names, or nil.
    ///
    /// TWO TESTS, NOT ONE — clear the floor AND lead the runner-up by the
    /// margin. A contested pair resolves to nothing, which falls to the model,
    /// which can ask. Naming the wrong editor cannot be taken back.
    ///
    /// Takes the ranking rather than the utterance so a caller that already
    /// needs the full tier — every bench does, to show what was considered —
    /// does not pay for the scoring pass twice on the turn path.
    public func leader(of ranked: [Match]) -> Match? {
        guard let leader = ranked.first, leader.score >= threshold else { return nil }
        if let runnerUp = ranked.dropFirst().first,
           leader.score - runnerUp.score < margin {
            return nil
        }
        return leader
    }

    /// Score and cut in one call, for a caller that wants only the answer.
    public func resolve(
        in utterance: String,
        candidates: [AbilityID],
        excluding hostVocabulary: Set<String> = []
    ) -> Match? {
        leader(of: ranked(
            in: utterance, candidates: candidates, excluding: hostVocabulary))
    }

    /// THE NAME-SHAPED PIECES OF THE SENTENCE, not the sentence.
    ///
    /// MEASURED, AND THE FIRST ATTEMPT WAS WRONG. Scoring the whole utterance
    /// against a candidate's names put `xcode` at 0.462 AHEAD of `textedit` at
    /// 0.447 for "Open a new textedit window", with every candidate far under
    /// the floor. That is not a threshold problem, it is the wrong comparison:
    /// a five-word sentence embedded against the single word "TextEdit" is
    /// mostly measuring "open a new … window", which every candidate shares
    /// equally, so the residue that decides the ranking is noise.
    ///
    /// A NAME IS COMPARED TO A NAME. The sentence is cut into its content
    /// words and adjacent pairs — the pairs so a two-word spoken form ("text
    /// edit") is one query rather than two halves — and each is scored against
    /// each declared name. The best pairing wins.
    ///
    /// Dropped: the host ability's own vocabulary (`window`, `switch`), and
    /// function words. Both are about SHAPE, never about which application —
    /// no product name appears here, which `ApplicationNameTests` enforces.
    static func queryTerms(
        in utterance: String, excluding hostVocabulary: Set<String>
    ) -> [String] {
        let owned = Set(hostVocabulary.map { $0.lowercased() })
        let words = utterance.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !functionWords.contains($0) && !owned.contains($0) }
        guard !words.isEmpty else { return [] }
        var terms = words
        for index in words.indices.dropLast() {
            terms.append("\(words[index]) \(words[index + 1])")
        }
        return corpus(terms)
    }

    /// Shape, not subject. Kept small on purpose: a long stopword list starts
    /// deciding which sentences are about applications, which is the index's
    /// job and not a constant's.
    static let functionWords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "you", "your",
        "in", "on", "at", "to", "for", "of", "with", "into",
        "and", "or", "then", "please", "can", "could", "would",
        "open", "new", "another", "fresh", "start", "make", "give",
        "up", "some", "one", "is", "are", "it", "this", "that",
    ]

    /// Trimmed, de-duplicated, non-empty. Case is left alone — the vectorizer
    /// lowercases, and `TextEdit` reads as one word to a tokenizer that does not.
    private static func corpus(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            kept.append(trimmed)
        }
        return kept
    }

    /// `TextEdit.app` → `TextEdit`. Path-free already; this drops the extension.
    private static func spoken(_ bundleName: String) -> String {
        bundleName.hasSuffix(".app")
            ? String(bundleName.dropLast(4))
            : bundleName
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return -1 }
        var total: Float = 0
        for index in lhs.indices { total += lhs[index] * rhs[index] }
        return total
    }
}
