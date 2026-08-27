//
//  NamedPartClassifier.swift
//  MaryBrain
//
//  Deterministic "does this utterance name a PART of the document?" — the
//  switch for fetch-first: read the named part BEFORE the speaking lane
//  starts, so the voice answers from the passage instead of denying it and
//  retracting later.
//
//  THE FAILURE THIS FIXES (confirmed against a live bug): asked to read "the
//  part about batteries", `pages_body` found it — "characters 12927–13835 of
//  15775, from \"batteries\"" — and the voice said "I don't see anything
//  about batteries or a section 5". Skill results structurally cannot reach
//  the speaking lane (`spokenMessages()` drops `.tool`; Lane A's messages are
//  snapshotted before Lane B is even spawned), so the only channel that
//  works is the one the live document already rides. This classifier decides
//  which turns get to use it.
//
//  BIAS: the opposite of ActionClassifier's. That one is conservative because
//  a false positive silences an answer the user wanted; this one leans TOWARD
//  firing because a false positive costs one bounded read (~100–300ms, on
//  these turns only) whose result is ADDED to the prompt and never replaces
//  anything, while a false negative is the shipped bug. The bounds that keep
//  that lean safe are structural, not verbal:
//
//  1. It never runs on an ACTION turn — those have no speaking lane to feed.
//  2. Its result is only ever used when a document-shaped world actually
//     leads the turn (`AbilityDispatching.readNamedPart` answers nil
//     otherwise), so a coding turn, or a turn with nothing open, pays nothing.
//  3. It requires a part-NOUN with a connector, an explicitly numbered
//     division, or "what does it say about X". A bare topic word never fires,
//     so ordinary conversation takes no extra read.
//  4. The phrase it extracts is clipped hard (see `clean`) — a `find` of a
//     whole spoken sentence would never match a document anyway.
//  5. It NEVER fires on an utterance that names an ambient data source (see
//     `namesAmbientSource`). That bound is newer than the others and it is
//     the only one that had to be added after a shipped failure: the lean
//     toward firing is only free while a false positive costs latency, and
//     "read me the items on my shopping list" proved it could cost the answer
//     itself.
//

import Foundation

public enum NamedPartClassifier {

    /// Nouns that name a PART of a document rather than the whole of it.
    ///
    /// "item", "list" and "entry" WERE here and are gone deliberately. With
    /// the wide connector list below, "read me the items ON my shopping list"
    /// and "the entry ON my calendar for tomorrow" both matched — so a
    /// REMINDERS or CALENDAR question fired a Pages pre-read, and a hit
    /// injected a Pages passage as "the authority for their question" while
    /// the real answer was suppressed. Those three words name a row in a list
    /// far more often than a division of a document; every genuinely
    /// document-shaped division ("section", "paragraph", "appendix") is still
    /// here. A missed pre-read costs a bonus; a wrong one cost the answer.
    public static let partNouns = [
        "part", "section", "paragraph", "passage", "bit", "chapter", "page",
        "line", "heading", "header", "excerpt", "quote", "sentence", "clause",
        "appendix", "footnote", "chunk", "piece", "portion", "segment",
        "subsection", "point", "table", "figure",
    ]

    /// What sits between the part-noun and the thing that identifies it.
    /// Deliberately wide: every one of these is unambiguous AFTER a part-noun,
    /// which is what makes the wide list safe.
    ///
    /// EVERY CONNECTOR HERE IDENTIFIES A PASSAGE BY ITS CONTENT. That is the
    /// rule the list is allowed to be wide under, and it is why bare "with"
    /// WAS here and is gone deliberately.
    ///
    /// THE FAILURE THIS FIXES (live capture, in Pages): "replace the Purpose
    /// section with the tighter version" matched `section` + `with` and
    /// captured "the tighter version" — the REPLACEMENT, not the target.
    /// `clean` stripped the article to "tighter version", `pages_body
    /// find: "tighter version"` searched the document for prose that by
    /// definition was not in it yet, `foundNothing` came back, and
    /// `readNamedPart` refused it. The turn reached the Skill execution lane with ZERO
    /// document text — so she called `type_at_cursor`, landed the revision
    /// wherever the caret happened to be, and left the Purpose section
    /// standing.
    ///
    /// "with" is unambiguous after a part-noun in theory, which is exactly why
    /// it read as safe when the list was written. In practice it is the only
    /// word here that ALSO introduces a payload: "<target> with <replacement>".
    /// A phrase after "about"/"titled"/"where" is something to LOOK FOR; a
    /// phrase after bare "with" is as often something to WRITE, and a READ
    /// classifier that guesses between them captures the wrong half of the
    /// sentence. `EditIntentClassifier` owns that shape and splits it
    /// non-greedily, target before payload. Only the BARE word leaves:
    /// "starting with" and "beginning with" stay, because the phrase they
    /// introduce is content — they name where a passage begins, never what to
    /// put there.
    ///
    /// THE HONEST COST: a read genuinely phrased "the section with the
    /// batteries" loses its pre-read. It falls back to the window-framing rule
    /// — she answers from the document already framed for her, or says the
    /// passage is outside what she can see and offers to look. That is the
    /// correct answer, not a denial, and it is the same trade the part-noun
    /// trim made: a missed pre-read costs a bonus, a wrong one cost the answer.
    public static let connectors = [
        "about", "on", "regarding", "concerning", "discussing", "mentioning",
        "covering", "describing", "titled", "called", "named", "headed",
        "labelled", "labeled", "starting with", "beginning with",
        // THE RELATIVE-CLAUSE FORMS OF THE TWO ABOVE, and their absence cost a
        // pre-read on a passage the user identified perfectly clearly: "the
        // implementation section THAT STARTS WITH I built a minimum viable
        // product". "starting with" was here and "that starts with" was not,
        // which is a grammatical accident rather than a decision — both name
        // where a passage begins, and neither can introduce a payload, which
        // is the rule bare "with" was removed for.
        "that starts with", "which starts with",
        "that begins with", "which begins with",
        "that says", "which says", "that talks about", "that mentions",
        "that covers", "that discusses", "where",
    ]

    /// Divisions a document numbers directly ("section 5", "chapter three").
    /// "item" is out for the same reason it left `partNouns`: "what's item 3
    /// on my list" is a reminders question, and answering it with a Pages
    /// `find` for "item 3" is worse than not reading at all.
    public static let numberedNouns = [
        "section", "chapter", "part", "paragraph", "page", "appendix",
        "figure", "table", "step", "article", "clause",
    ]

    /// Spoken numbers → digits. A transcript says "section five"; documents
    /// almost always print "Section 5", and the read gets ONE attempt — so the
    /// digit form is the one worth spending it on.
    public static let spokenNumbers: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18",
        "nineteen": "19", "twenty": "20",
    ]

    /// Words that end the useful part of a captured phrase — everything after
    /// one of them is qualification the document won't spell the same way.
    private static let clauseBreaks: Set<String> = [
        "that", "which", "and", "or", "but", "so", "because", "if", "when",
        "then", "please", "again", "for", "to", "at", "from", "into", "out",
        "aloud", "loud", "thanks", "ok", "okay",
    ]

    private static let leadingArticles: Set<String> = [
        "the", "a", "an", "my", "our", "your", "their", "its", "his", "her", "this", "that",
    ]

    /// Spoken tails a document never carries — "the paragraph about synthetic
    /// media SAY" is the question's grammar leaking into the search phrase.
    private static let trailingFillers: Set<String> = [
        "say", "says", "said", "saying", "mean", "means", "meant", "go",
        "goes", "is", "was", "are", "were", "about", "again", "please",
        "aloud", "loud", "bit", "part", "one",
    ]

    /// Phrases that identify nothing. "the part about it" names a part in
    /// grammar only; spending the turn's read on `find: "it"` would match the
    /// first two characters in the document and answer worse than not reading.
    private static let uselessPhrases: Set<String> = [
        "it", "this", "that", "these", "those", "they", "them", "us", "me",
        "you", "one", "thing", "things", "there", "here", "something",
        "anything", "everything", "stuff", "all",
    ]

    /// THE EYELESS VETO. Words that name an ambient DATA SOURCE — a world with
    /// no window, answered by EventKit or SQLite rather than by reading a
    /// document. When one of these appears, the utterance is about something
    /// that is not on screen and never needed to be, so no workspace pre-read
    /// may claim it.
    ///
    /// THE FAILURE THIS FIXES (traced): "read me the items on my shopping
    /// list" fired a Pages `find`, and a HIT both injected a Pages passage as
    /// "the authority for their question" AND armed the silent-settle arm — so
    /// the reminders read that had the real answer never spoke. Trimming the
    /// part-nouns closes the exact phrasings that were traced; this closes the
    /// class. Deliberately narrow: it names the sources whose vocabulary
    /// genuinely collides with document words, not every eyeless world, because
    /// over-vetoing costs a bonus read while under-vetoing cost the answer.
    public static let ambientSourceWords = [
        "calendar", "reminder", "event", "events",
        "appointment", "appointments", "schedule", "agenda",
        "shopping list", "grocery list", "to-do list", "todo list",
        "inbox", "email", "e-mail", "unread",
    ]

    public static func namesAmbientSource(_ utterance: String) -> Bool {
        let text = " " + utterance.lowercased() + " "
        return ambientSourceWords.contains { text.contains(" \($0)") }
    }

    /// The phrase to hand a targeted read, or nil when the utterance names no
    /// part of anything. Case is preserved — the read matches
    /// case-insensitively, and the binding echoes the phrase back in its
    /// bounds label ("…from \"batteries\"").
    public static func namedPart(in utterance: String) -> String? {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !namesAmbientSource(text) else { return nil }

        // 1. "<part noun> <connector> <phrase>" — the shape the bug arrived in
        //    ("read me the part about batteries").
        let nouns = partNouns.joined(separator: "|")
        let joins = connectors.joined(separator: "|")
        if let captured = firstCapture(
            in: text,
            pattern: "\\b(?:\(nouns))s?\\s+(?:\(joins))\\s+(.+)$"),
           let phrase = clean(captured) {
            return phrase
        }

        // 2. "what does it say about <phrase>" — no part-noun, but naming a
        //    subject and asking what the document says about it is the same
        //    request wearing different clothes.
        if let captured = firstCapture(
            in: text,
            pattern: "\\b(?:what|where)\\s+(?:does|do)\\s+(?:it|this|that|the\\s+\\w+|my\\s+\\w+|the\\s+\\w+\\s+\\w+)\\s+says?\\s+(?:about|on|regarding)\\s+(.+)$"),
           let phrase = clean(captured) {
            return phrase
        }

        // 3. A numbered division, searched as the document would print it.
        let numbered = numberedNouns.joined(separator: "|")
        let spoken = spokenNumbers.keys.sorted().joined(separator: "|")
        if let match = captures(
            in: text,
            pattern: "\\b(\(numbered))\\s+(\\d{1,3}(?:\\.\\d{1,3})*|\(spoken))\\b"),
           match.count == 2 {
            let number = spokenNumbers[match[1].lowercased()] ?? match[1]
            return "\(match[0]) \(number)"
        }

        return nil
    }

    // MARK: - Extraction

    private static func firstCapture(in text: String, pattern: String) -> String? {
        captures(in: text, pattern: pattern)?.first
    }

    /// Every capture group of the FIRST match, or nil when nothing matched.
    private static func captures(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else { return nil }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let groupRange = Range(match.range(at: index), in: text) else { continue }
            groups.append(String(text[groupRange]))
        }
        return groups.isEmpty ? nil : groups
    }

    /// Trim a spoken capture down to something a document might contain
    /// verbatim: no leading article, nothing past a clause break, at most five
    /// words, no trailing punctuation. A `find` that is a whole sentence
    /// matches nothing, so the clip is not caution — it is what makes the one
    /// read we spend worth spending.
    public static func clean(_ captured: String) -> String? {
        var words = captured
            .replacingOccurrences(of: ",", with: " , ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        if let first = words.first, leadingArticles.contains(first.lowercased()) {
            words.removeFirst()
        }
        var kept: [String] = []
        for word in words {
            let bare = word.trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted).lowercased()
            if word == "," || (!kept.isEmpty && clauseBreaks.contains(bare)) { break }
            kept.append(word)
            if kept.count == 5 { break }
        }
        // The question's own grammar trails the phrase ("the paragraph about
        // synthetic media SAY") and no document spells it that way.
        while let last = kept.last,
              trailingFillers.contains(
                last.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()) {
            kept.removeLast()
        }
        let phrase = kept.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.,;:!?\"'“”‘’()-"))
        // A one-character find matches half the document; a pronoun ("the part
        // about it") identifies nothing at all.
        let bare = phrase.lowercased()
        guard phrase.count >= 2,
              !clauseBreaks.contains(bare),
              !leadingArticles.contains(bare),
              !uselessPhrases.contains(bare) else { return nil }
        return phrase
    }
}
