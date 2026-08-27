//
//  ReferenceResolver.swift
//  MaryBrain
//
//  WHICH CONTAINER DOES THIS TURN MEAN? One ladder, every world.
//
//  EXTRACTED FROM `TextEditWindowResolver`, and the matchers came across
//  VERBATIM — `TextEditTests`' nine resolver tests pass against this through a
//  thin shim without a line edited, which is the proof the move changed
//  nothing. That is the same bar `PassageBacking` set for itself.
//
//  WHY IT MOVED. TextEdit was the forcing case, not the feature. The user's
//  words: "I am NOT saying we should build something specifically for that to
//  work… when there's other floating containers of information small and large,
//  they work in this fluid dynamic at all times." A ladder that lives inside
//  one plugin is a ladder every other world has to reinvent, and five
//  reinventions of "which one did they mean" is five chances to answer
//  confidently and wrongly.
//
//  ═══════════════════════════════════════════════════════════════════════
//  THE RUNGS, and what each one is for.
//
//    0  HANDLE     `[W3]`, `[D7]` — an identity the registry minted this
//                  conversation. Nothing to guess. An invented handle abstains.
//    1  TITLE      Exact, then contained, then a stem match. Abstains when the
//                  match is a PREFIX of another open container's name.
//    2  SUBTITLE   First line, synopsis, subject. The rung that makes a world
//                  referenceable when its titles do not distinguish — measured:
//                  all eleven of this user's notes are named `Untitled N` — and
//                  the ONLY rung available to a world that can enumerate its
//                  containers but not read them.
//    3  CONTENT    A distinctive word from the utterance appearing in exactly
//                  one container's cached text.
//    4  ORDINAL    "the second one" against a list the user actually saw.
//    5  ANAPHORA   "the other one", "the last one" — against salience.
//    6  ABSTAIN    nil, meaning "the one in front". THE COMMON ANSWER.
//
//  ABSTAINING IS NOT A FAILURE. Most turns are about the container in front,
//  and answering "front" by abstaining rather than by asserting is what keeps
//  an explicit override authoritative.
//
//  NEVER BREAKS A TIE BY LIST POSITION. Two containers that match equally well
//  are a question for the user, not a coin toss — and the thing a coin toss
//  decides here is which of the user's documents gets rewritten.
//  ═══════════════════════════════════════════════════════════════════════
//
//  PURE. Rows, bodies, salience and handles are handed in; nothing here spawns
//  a script or reads a box, so the whole ladder is testable with no application
//  running at all.
//

import Foundation

public enum ReferenceResolver {

    /// One container the resolver may choose, with everything the rungs need.
    public struct Candidate: Sendable, Equatable {
        /// WHERE THIS CONTAINER LIVES. A place, because `ContainerRoster` has
        /// been place-carrying since taught applications began enrolling `[D#]`
        /// rows, and narrowing it here was the last place two taught corpora
        /// collapsed onto the one `.applications` host lane — indistinguishable to
        /// every rung below, and eyeless to every consumer above.
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
            world: AmbientWorld, key: String, handle: String? = nil,
            title: String, subtitle: String? = nil, body: String? = nil,
            listIndex: Int, isFront: Bool = false, salience: Int? = nil
        ) {
            self.init(
                place: .lane(world), key: key, handle: handle, title: title,
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
        public init(world: AmbientWorld, key: String, title: String) {
            self.init(place: .lane(world), key: key, title: title)
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
            world: AmbientWorld, key: String, rung: Rung,
            confidence: Confidence = .exact, alternative: Rival? = nil
        ) {
            self.init(
                place: .lane(world), key: key, rung: rung,
                confidence: confidence, alternative: alternative)
        }
    }

    /// WHAT THE LADDER CONCLUDED — three outcomes, not an optional.
    ///
    /// THE SPLIT THIS EXISTS FOR, measured before it was written: `nil` used to
    /// mean two different things and only one of them is dangerous.
    ///
    ///   - "delete the Tuesday line" names NO container, so falling back to the
    ///     one in front is not a guess, it is the correct reading.
    ///   - "delete the Tuesday line IN THE OTHER ONE" names one and we could not
    ///     settle which. Measured live: with eight notes open this abstained to
    ///     the front note, so the line was deleted from the wrong one.
    ///
    /// An optional cannot tell those apart, so a destructive gate built on it
    /// would either refuse every ordinary edit or catch neither case.
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

    /// THE LADDER. `.none` is the common answer and it means "the one in front".
    ///
    /// `listing` is the ordered keys a listing binding last showed the model,
    /// already checked for staleness by the caller. Nil means no live listing,
    /// and a COUNTING ordinal then reports `.ambiguous` rather than indexing
    /// into an enumeration the user never saw.
    public static func outcome(
        utterance: String,
        candidates: [Candidate],
        listing: [String]? = nil,
        listingIsNewestEvidence: Bool = false
    ) -> Outcome {
        guard !candidates.isEmpty else { return .none }
        let text = utterance.lowercased()

        // Each rung answers hit / miss / engaged-but-unsettled. The first rung
        // to say anything other than `.miss` ends the ladder — an ambiguity at
        // a strong rung must NOT be silently rescued by a weaker one, or the
        // weaker rung's guess becomes the answer to a question the strong rung
        // already knew it could not settle.
        //
        // LAZY, AND IT HAS TO BE. The first version of this built all six
        // results into an array before looping, which ran every rung on every
        // turn — including `uniqueContentMatch`, which scans every cached body —
        // even when a handle matched at rung 0. The ladder is consulted before
        // the model on EVERY turn, so that is work done for nothing on almost
        // all of them.
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

    /// The old shape, kept so every existing caller and test is untouched while
    /// the readers are wired one at a time. `.ambiguous` reads as abstention
    /// here — which IS today's behaviour, and precisely what the gate changes
    /// for a destructive act.
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
            // A LONE MATCH IS STILL AMBIGUOUS IF IT IS A PREFIX of another open
            // container's name. "put it in the untitled one" contains
            // "Untitled" and not "Untitled 21", so a plain uniqueness test
            // picks `Untitled` confidently out of eleven notes all called some
            // form of it. The user named the family, not one of them.
            let name = exact[0].title.lowercased()
            let shadowedBy = candidates.filter {
                $0.key != exact[0].key && $0.title.lowercased().hasPrefix(name)
            }
            guard shadowedBy.isEmpty else {
                // THEY NAMED THE FAMILY, NOT A MEMBER. "the untitled one" over
                // eleven `Untitled N` notes. Reported rather than dropped: this
                // is a reference that was made and cannot be settled, which is
                // exactly what a destructive act must refuse on.
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

    /// TITLES THAT CANNOT BE REFERENCES, because they are how English POINTS.
    ///
    /// THE BUG THIS FIXES, caught by its own test: a container titled `One`
    /// matched the word "one" inside "open the second one", so the title rung
    /// answered a question the ORDINAL rung owned — and answered it wrong.
    ///
    /// A note really can be called "one" or "notes". It simply cannot be
    /// referred to by that bare word, because the word is doing grammatical
    /// work in every sentence it appears in. Such a container stays reachable
    /// by handle, by subtitle, by content and by ordinal; only the title rung
    /// declines it.
    public static let referentialWords: Set<String> = [
        "one", "ones", "thing", "things", "it", "this", "that", "these", "those",
        "other", "last", "first", "next", "previous", "note",
        "document", "documents", "window", "windows", "file", "files",
        "first", "second", "third", "fourth", "fifth",
        "sixth", "seventh", "eighth", "ninth", "tenth",
    ]

    /// A TITLE IS MENTIONED WHEN IT APPEARS AS A WORD, not as a substring.
    ///
    /// THE BUG THIS FIXES, caught by its own test: a container titled `A`
    /// matched the `a` inside "read [W9] to me", so a one-character title
    /// referred to itself in almost every utterance. Bare containment cannot
    /// tell a name from a syllable.
    ///
    /// It also fixes a subtler one for free: `Untitled 2` no longer matches
    /// inside "untitled 21", because the character after the match is
    /// alphanumeric. That is the same family as the prefix-shadow abstain
    /// below, caught one layer earlier and without needing to abstain at all.
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

    /// THE RUNG THAT CARRIES A WORLD WITH USELESS TITLES, and the only one
    /// available to a world that can list its containers but not read them.
    ///
    /// Matched on the subtitle's own distinctive words rather than by
    /// containment, because a first line is a sentence and the user quotes a
    /// fragment of it.
    static func uniqueSubtitleMatch(_ text: String, candidates: [Candidate]) -> RungResult {
        let withSubtitles = candidates.filter { $0.subtitle?.isEmpty == false }
        guard candidates.count > 1, !withSubtitles.isEmpty else { return .miss }
        return firstDiscriminatingWord(text, over: withSubtitles) { $0.subtitle }
    }

    // MARK: - 3. Content

    /// A word from the utterance appearing in exactly one cached body.
    ///
    /// Containers whose body is not cached are SKIPPED, never treated as empty.
    /// Treating absence of evidence as evidence of absence is how a resolver
    /// becomes confident and wrong.
    static func uniqueContentMatch(_ text: String, candidates: [Candidate]) -> RungResult {
        guard candidates.count > 1 else { return .miss }
        let readable = candidates.filter { $0.body?.isEmpty == false }
        guard !readable.isEmpty else { return .miss }
        return firstDiscriminatingWord(text, over: readable) { $0.body }
    }

    /// THE SHARED SHAPE OF THE SUBTITLE AND CONTENT RUNGS: walk the utterance's
    /// distinctive words longest-first and stop at the first that picks out ONE
    /// container.
    ///
    /// A word matching SEVERAL is reported rather than skipped. That is the
    /// change: "the sourdough one" with two sourdough notes used to fall
    /// through and let a weaker rung guess, when the strong rung already knew
    /// the reference was real and unsettled.
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

    /// EVERY WORD THE LADDER'S OWN PHRASES ARE MADE OF, so the content rung can
    /// never answer a question the anaphora rung owns.
    ///
    /// THE DEFECT THIS FIXES, seen in live output: the refusal read
    /// `"other" could be Untitled, Untitled 29` — the CONTENT rung had matched
    /// the word "other" inside two notes' bodies and reported an ambiguity,
    /// pre-empting rung 5, which is the rung "the other one" belongs to. "other"
    /// is five characters, so it passed the length filter, and it was not a
    /// stopword.
    ///
    /// DERIVED from the phrase lists rather than hand-listed, because a word
    /// added to `otherPhrases` later would otherwise silently become matchable
    /// content again.
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

    /// ORDINALS BIND TO A PRESENTED LIST, and only to one.
    ///
    /// THE RULE, and it is the user's own: NEWEST EVIDENCE WINS. An ordinal
    /// takes a roster row only when that listing is the most recent referential
    /// event; once Mary has read something aloud or changed it, "the last one"
    /// means THAT. `listingIsNewestEvidence` is the caller's answer to which
    /// came last.
    ///
    /// COUNTING ORDINALS ABSTAIN WITHOUT A LISTING. "The second one" with no
    /// list the user ever saw is an index into an enumeration they cannot have
    /// meant — the coin toss this whole ladder refuses. Terminal words ("the
    /// last one") fall through to anaphora instead, which is a real answer.
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
            // A COUNTING ORDINAL WITH NO LIVE LISTING IS A REFERENCE WE CANNOT
            // SETTLE, not a miss. "the second one" means a row in a list, and
            // if no list is live there is nothing to count. Reported so a
            // destructive act refuses; a terminal word ("the last one") still
            // falls through to anaphora, which is a real answer.
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
            // THE CELL THE WHOLE DESIGN CAME FROM. They said "the other one",
            // there are several, and nothing distinguishes them. Measured live
            // with eight notes open: this used to abstain, the caller fell back
            // to the note in FRONT, and a delete landed in the wrong one.
            return .ambiguous(phrase: phrase, rivals: others)
        }
        // Salience picked, on a real reason. `.chosen`, with the runner-up.
        return .hit(best, .chosen, alternative: ranked.dropFirst().first)
    }
}
