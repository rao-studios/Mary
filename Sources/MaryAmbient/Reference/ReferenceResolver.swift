//
//  ReferenceResolver.swift
//  MaryBrain
//
//  WHAT: Which container does this turn mean? One ladder, every world.
//  IN:   ReferenceFocus rows. Extracted from TextEditWindowResolver (matchers verbatim).
//  OUT:  ReferenceDecision
//

import Foundation

public enum ReferenceResolver {

    /// One container the resolver may choose, with everything the rungs need.
    public struct Candidate: Sendable, Equatable {
        /// WHERE THIS CONTAINER LIVES.
        public var place: AmbientPlace
        public var key: String
        /// The registry's handle, when one has been minted.
        public var handle: String?
        public var title: String
        public var subtitle: String?
        /// Nil means UNREAD, never empty — the content rung must SKIP it.
        public var body: String?
        /// Position in the world's own enumeration.
        public var listIndex: Int
        public var isFront: Bool
        /// Lower is more salient. Nil means no referential evidence at all.
        public var salience: Int?

        public init(
            place: AmbientPlace, key: String, handle: String? = nil,
            title: String, subtitle: String? = nil, body: String? = nil,
            listIndex: Int, isFront: Bool = false, salience: Int? = nil
        ) {
            self.place = place
            self.key = key
            self.handle = handle
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.listIndex = listIndex
            self.isFront = isFront
            self.salience = salience
        }

        /// The built-in spelling.
        public init(
            attention: AmbientAttention, key: String, handle: String? = nil,
            title: String, subtitle: String? = nil, body: String? = nil,
            listIndex: Int, isFront: Bool = false, salience: Int? = nil
        ) {
            self.init(
                place: .lane(attention), key: key, handle: handle, title: title,
                subtitle: subtitle, body: body, listIndex: listIndex,
                isFront: isFront, salience: salience)
        }
    }

    /// Which rung fired — carried so a wrong pick is diagnosable from the
    /// trace rather than by re-deriving the ladder by hand.
    public enum Rung: String, Sendable, Equatable {
        case handle, title, subtitle, content, ordinal, anaphora
    }

    /// HOW SURE THE PICK IS. Three named cases mirroring `PassageConfidence`
    /// deliberately — the tree already has this vocabulary and a second one
    /// would drift.
    public enum Confidence: Sendable, Equatable {
        /// One candidate matched and nothing else could have.
        case exact
        /// Several matched and a RULE picked between them — a strictly-longer
        /// title, the salience order. A real decision, made on a real reason.
        case chosen
    }

    /// A container that also matched. Kept because a correction needs something
    /// to re-aim AT, and because "several matched" is unsayable without it.
    public struct Rival: Sendable, Equatable {
        public var place: AmbientPlace
        public var key: String
        public var title: String

        public init(place: AmbientPlace, key: String, title: String) {
            self.place = place
            self.key = key
            self.title = title
        }

        /// The built-in spelling.
        public init(attention: AmbientAttention, key: String, title: String) {
            self.init(place: .lane(attention), key: key, title: title)
        }
    }

    public struct Choice: Sendable, Equatable {
        public var place: AmbientPlace
        public var key: String
        public var rung: Rung
        public var confidence: Confidence = .exact
        /// The runner-up, when a rule had to pick.
        public var alternative: Rival?

        public init(
            place: AmbientPlace, key: String, rung: Rung,
            confidence: Confidence = .exact, alternative: Rival? = nil
        ) {
            self.place = place
            self.key = key
            self.rung = rung
            self.confidence = confidence
            self.alternative = alternative
        }

        /// The built-in spelling.
        public init(
            attention: AmbientAttention, key: String, rung: Rung,
            confidence: Confidence = .exact, alternative: Rival? = nil
        ) {
            self.init(
                place: .lane(attention), key: key, rung: rung,
                confidence: confidence, alternative: alternative)
        }
    }

    /// WHAT THE LADDER CONCLUDED — three outcomes, not an optional. THE SPLIT THIS EXISTS FOR,
    /// measured before it was written: `nil` used to mean two different things and only one of
    /// them is dangerous.
    public enum Outcome: Sendable, Equatable {
        /// Nothing in the utterance referred to a container. The one in front is
        /// right, and this is the common answer.
        case none
        case resolved(Choice)
        /// A reference WAS made and could not be settled. `phrase` is what they
        /// said; `rivals` is what it could have meant.
        case ambiguous(phrase: String, rivals: [Rival])
    }

    /// Words that mean "not the one in front" without naming anything.
    /// Deliberately short: a longer list would start matching ordinary prose
    /// about the container in front.
    public static let otherPhrases = [
        "the other one", "the other note", "the other window", "the other document",
        "my other note", "in the other", "that other one",
    ]

    /// Words that mean "the one I had a moment ago".
    public static let previousPhrases = [
        "the one i was just in", "the one i was in", "the note i was just in",
        "where i just was", "the last one", "the previous one", "the one before",
    ]

    // MARK: - The ladder

    /// THE LADDER. `.none` is the common answer and it means "the one in front". `listing` is
    /// the ordered keys a listing binding last showed the model, already checked for staleness
    /// by the caller. Nil means no live listing.
    public static func outcome(
        utterance: String,
        candidates: [Candidate],
        listing: [String]? = nil,
        listingIsNewestEvidence: Bool = false
    ) -> Outcome {
        guard !candidates.isEmpty else { return .none }
        let text = utterance.lowercased()

        // Each rung answers hit / miss / engaged-but-unsettled. LAZY, AND IT HAS TO BE. The first
        // version of this built all six results into an array before looping, which ran every rung
        // on every turn.
        let rungs: [(Rung, () -> RungResult)] = [
            (.handle, { handleMatch(text, candidates: candidates) }),
            (.title, { uniqueTitleMatch(text, candidates: candidates) }),
            (.subtitle, { uniqueSubtitleMatch(text, candidates: candidates) }),
            (.content, { uniqueContentMatch(text, candidates: candidates) }),
            (.ordinal, { ordinalMatch(
                text, candidates: candidates,
                listing: listing, listingIsNewestEvidence: listingIsNewestEvidence) }),
            (.anaphora, { anaphoraMatch(text, candidates: candidates) }),
        ]

        for (rung, evaluate) in rungs {
            switch evaluate() {
            case .miss:
                continue
            case .hit(let candidate, let confidence, let alternative):
                return .resolved(Choice(
                    place: candidate.place, key: candidate.key, rung: rung,
                    confidence: confidence, alternative: alternative.map(rival)))
            case .ambiguous(let phrase, let rivals):
                return .ambiguous(phrase: phrase, rivals: rivals.map(rival))
            }
        }
        return .none
    }

    /// The old shape, kept so every existing caller and test is untouched while the readers are
    /// wired one at a time. `.ambiguous` reads as abstention here — which IS today's behaviour,
    /// and precisely what the gate changes for a destructive act.
    public static func resolve(
        utterance: String,
        candidates: [Candidate],
        listing: [String]? = nil,
        listingIsNewestEvidence: Bool = false
    ) -> Choice? {
        guard case .resolved(let choice) = outcome(
            utterance: utterance, candidates: candidates,
            listing: listing, listingIsNewestEvidence: listingIsNewestEvidence)
        else { return nil }
        return choice
    }

    /// WHAT ONE RUNG CONCLUDED. `.miss` falls through; the other two stop the
    /// ladder.
    enum RungResult {
        case miss
        case hit(Candidate, Confidence, alternative: Candidate?)
        /// The rung ENGAGED — the utterance spoke its language — and could not
        /// settle it.
        case ambiguous(phrase: String, rivals: [Candidate])
    }

    public static func rival(_ candidate: Candidate) -> Rival {
        Rival(place: candidate.place, key: candidate.key, title: candidate.title)
    }

    // MARK: - 0. Handle

    /// Only handles the registry actually minted resolve — an invented `W9`
    /// abstains rather than indexing into anything.
    static func handleMatch(_ text: String, candidates: [Candidate]) -> RungResult {
        for candidate in candidates {
            guard let handle = candidate.handle?.lowercased(), !handle.isEmpty else { continue }
            if text.contains("[\(handle)]") || text.contains(" \(handle) ")
                || text.hasSuffix(" \(handle)") {
                // A handle is an identity the registry minted. Nothing was
                // decided, so nothing can be contested.
                return .hit(candidate, .exact, alternative: nil)
            }
        }
        return .miss
    }

    // MARK: - 1. Title

    /// A title match that picks out ONE container. Lifted verbatim from
    /// `TextEditWindowResolver`, including both abstain rules.
    static func uniqueTitleMatch(_ text: String, candidates: [Candidate]) -> RungResult {
        let exact = candidates.filter {
            !$0.title.isEmpty
                && !referentialWords.contains($0.title.lowercased())
                && mentions($0.title.lowercased(), in: text)
        }
        if exact.count == 1 {
            // A LONE MATCH IS STILL AMBIGUOUS IF IT IS A PREFIX of another open container's name. "put
            // it in the untitled one" contains "Untitled" and not "Untitled 21", so a plain uniqueness
            // test picks `Untitled` confidently out of eleven notes all called some form of it.
            let name = exact[0].title.lowercased()
            let shadowedBy = candidates.filter {
                $0.key != exact[0].key && $0.title.lowercased().hasPrefix(name)
            }
            guard shadowedBy.isEmpty else {
                // THEY NAMED THE FAMILY, NOT A MEMBER. "the untitled one" over eleven `Untitled N` notes.
                return .ambiguous(phrase: exact[0].title, rivals: [exact[0]] + shadowedBy)
            }
            return .hit(exact[0], .exact, alternative: nil)
        }
        if exact.count > 1 {
            // The LONGEST is the most specific — "untitled 21" beats
            // "untitled" — but only when strictly longer than every rival, or
            // we are back to guessing.
            let sorted = exact.sorted { $0.title.count > $1.title.count }
            if sorted.count >= 2, sorted[0].title.count > sorted[1].title.count {
                // A RULE PICKED — strictly the most specific name. A real
                // decision on a real reason, so the runner-up is carried.
                return .hit(sorted[0], .chosen, alternative: sorted[1])
            }
            return .ambiguous(phrase: sorted[0].title, rivals: sorted)
        }
        // A stem match: the user said "grocery" and the note is "groceries.txt".
        let stems = candidates.filter { candidate in
            let base = (candidate.title as NSString).deletingPathExtension.lowercased()
            guard base.count >= 4 else { return false }
            return mentions(base, in: text)
        }
        if stems.count == 1 { return .hit(stems[0], .exact, alternative: nil) }
        if stems.count > 1 {
            return .ambiguous(phrase: stems[0].title, rivals: stems)
        }
        return .miss
    }

    /// TITLES THAT CANNOT BE REFERENCES, because they are how English POINTS. THE BUG THIS
    /// FIXES, caught by its own test: a container titled `One` matched the word "one" inside
    /// "open the second one", so the title rung answered a question the ORDINAL rung owned.
    public static let referentialWords: Set<String> = [
        "one", "ones", "thing", "things", "it", "this", "that", "these", "those",
        "other", "last", "first", "next", "previous", "note",
        "document", "documents", "window", "windows", "file", "files",
        "first", "second", "third", "fourth", "fifth",
        "sixth", "seventh", "eighth", "ninth", "tenth",
    ]

    /// A TITLE IS MENTIONED WHEN IT APPEARS AS A WORD, not as a substring. THE BUG THIS FIXES,
    /// caught by its own test: a container titled `A` matched the `a` inside "read [W9] to me".
    public static func mentions(_ needle: String, in text: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchFrom = text.startIndex
        while let found = text.range(of: needle, range: searchFrom..<text.endIndex) {
            let beforeOK = found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex
                || !isWordCharacter(text[found.upperBound])
            if beforeOK && afterOK { return true }
            guard found.upperBound < text.endIndex else { return false }
            searchFrom = text.index(after: found.lowerBound)
        }
        return false
    }

    public static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - 2. Subtitle

    /// THE RUNG THAT CARRIES A WORLD WITH USELESS TITLES.
    static func uniqueSubtitleMatch(_ text: String, candidates: [Candidate]) -> RungResult {
        let withSubtitles = candidates.filter { $0.subtitle?.isEmpty == false }
        guard candidates.count > 1, !withSubtitles.isEmpty else { return .miss }
        return firstDiscriminatingWord(text, over: withSubtitles) { $0.subtitle }
    }

    // MARK: - 3. Content

    /// A word from the utterance appearing in exactly one cached body. Containers whose body is
    /// not cached are SKIPPED, never treated as empty. Treating absence of evidence as evidence
    /// of absence is how a resolver becomes confident and wrong.
    static func uniqueContentMatch(_ text: String, candidates: [Candidate]) -> RungResult {
        guard candidates.count > 1 else { return .miss }
        let readable = candidates.filter { $0.body?.isEmpty == false }
        guard !readable.isEmpty else { return .miss }
        return firstDiscriminatingWord(text, over: readable) { $0.body }
    }

    /// THE SHARED SHAPE OF THE SUBTITLE AND CONTENT RUNGS: walk the utterance's distinctive
    /// words longest-first and stop at the first that picks out ONE container. A word matching
    /// SEVERAL is reported rather than skipped. That is the change: "the sourdough.
    static func firstDiscriminatingWord(
        _ text: String, over candidates: [Candidate],
        field: (Candidate) -> String?
    ) -> RungResult {
        for word in distinctiveWords(in: text) {
            let hits = candidates.filter {
                field($0)?.range(
                    of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            if hits.count == 1 { return .hit(hits[0], .exact, alternative: nil) }
            if hits.count > 1 { return .ambiguous(phrase: word, rivals: hits) }
        }
        return .miss
    }

    /// The utterance's content words, longest first — a long word is more
    /// likely to be the distinctive one, so "the ambient engine note" resolves
    /// on "ambient" rather than on "note".
    public static func distinctiveWords(in text: String, limit: Int = 6) -> [String] {
        text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 5 && !stopWords.contains($0) && !phraseWords.contains($0) }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    /// EVERY WORD THE LADDER'S OWN PHRASES ARE MADE OF, so the content rung can never answer a
    /// question the anaphora rung owns. THE DEFECT THIS FIXES, seen in live output: the refusal
    /// read `"other" could be Untitled, Untitled 29`.
    public static let phraseWords: Set<String> = Set(
        (otherPhrases + previousPhrases)
            .flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
            .map(String.init))

    /// Words long enough to pass the length filter but far too common to
    /// discriminate between one person's documents. Every one of these appeared
    /// in an ordinary revision request while this was being written.
    public static let stopWords: Set<String> = [
        "about", "there", "these", "those", "which", "where", "would", "could",
        "should", "please", "change", "replace", "rewrite", "delete", "remove",
        // NO PRODUCT NAMES. Three sat in this list, so a correction naming
        // one of three editors was recognised and one naming any other was
        // not — a vocabulary that worked for whoever wrote it.
        "instead", "another", "window", "windows", "opened",
        "document", "documents", "forward",
    ]

    // MARK: - 4. Ordinal

    /// Numbers a person says when they mean a row.
    public static let spokenOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    ]

    /// ORDINALS BIND TO A PRESENTED LIST, and only to one. THE RULE, and it is the user's own:
    /// NEWEST EVIDENCE WINS. An ordinal takes a roster row only when that listing is the most
    /// recent referential event.
    static func ordinalMatch(
        _ text: String, candidates: [Candidate],
        listing: [String]?, listingIsNewestEvidence: Bool
    ) -> RungResult {
        func candidate(forKey key: String) -> Candidate? {
            candidates.first { $0.key == key }
        }
        func spoken() -> (word: String, position: Int)? {
            for (word, position) in spokenOrdinals where text.contains(" \(word) ")
                || text.hasSuffix(" \(word)") || text.contains("the \(word) one") {
                return (word, position)
            }
            return nil
        }
        let counting = spoken()
        let terminal = text.contains("the last one") || text.contains("the last note")
            || text.contains("the last document")

        guard let listing, !listing.isEmpty, listingIsNewestEvidence else {
            // A COUNTING ORDINAL WITH NO LIVE LISTING IS A REFERENCE WE CANNOT SETTLE, not a miss.
            // "the second one" means a row in a list, and if no list is live there is nothing to
            // count.
            if let counting, !terminal {
                return .ambiguous(phrase: "the \(counting.word) one", rivals: candidates)
            }
            return .miss
        }
        if let counting {
            guard counting.position <= listing.count,
                  let hit = candidate(forKey: listing[counting.position - 1])
            else {
                return .ambiguous(phrase: "the \(counting.word) one", rivals: candidates)
            }
            return .hit(hit, .exact, alternative: nil)
        }
        if terminal, let hit = candidate(forKey: listing[listing.count - 1]) {
            return .hit(hit, .exact, alternative: nil)
        }
        return .miss
    }

    // MARK: - 5. Anaphora

    /// "The other one" / "the last one" — against SALIENCE, never list
    /// position, and never the container in front.
    static func anaphoraMatch(_ text: String, candidates: [Candidate]) -> RungResult {
        let phrase = (otherPhrases + previousPhrases).first { text.contains($0) }
        guard let phrase else { return .miss }

        let others = candidates.filter { !$0.isFront }
        guard !others.isEmpty else { return .miss }
        // N = 2 IS EXACT, not a guess: two containers, one in front, and "the
        // other one" has precisely one answer needing no salience at all.
        if others.count == 1 { return .hit(others[0], .exact, alternative: nil) }

        let ranked = others
            .filter { $0.salience != nil }
            .sorted { ($0.salience ?? .max) < ($1.salience ?? .max) }
        guard let best = ranked.first else {
            // THE CELL THE WHOLE DESIGN CAME FROM. They said "the other one", there are several, and
            // nothing distinguishes them.
            return .ambiguous(phrase: phrase, rivals: others)
        }
        // Salience picked, on a real reason. `.chosen`, with the runner-up.
        return .hit(best, .chosen, alternative: ranked.dropFirst().first)
    }
}
