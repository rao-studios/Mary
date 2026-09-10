//
//  NamedPartClassifier.swift
//  MaryBrain
//
//  WHAT: Does this utterance name a part of the document? Fetch-first switch.
//  OUT:  pre-read before speaking lane
//  PIN:  Skill results cannot reach the speaking lane — the live document channel must.
//

import Foundation

public enum NamedPartClassifier {

    /// Nouns that name a PART of a document rather than the whole of it. "item", "list" and
    /// "entry" WERE here and are gone deliberately.
    public static let partNouns = [
        "part", "section", "paragraph", "passage", "bit", "chapter", "page",
        "line", "heading", "header", "excerpt", "quote", "sentence", "clause",
        "appendix", "footnote", "chunk", "piece", "portion", "segment",
        "subsection", "point", "table", "figure",
    ]

    /// What sits between the part-noun and the thing that identifies it. Deliberately wide:
    /// every one of these is unambiguous AFTER a part-noun, which is what makes the wide list
    /// safe. EVERY CONNECTOR HERE IDENTIFIES A PASSAGE BY ITS CONTENT. That is the rule.
    public static let connectors = [
        "about", "on", "regarding", "concerning", "discussing", "mentioning",
        "covering", "describing", "titled", "called", "named", "headed",
        "labelled", "labeled", "starting with", "beginning with",
        // THE RELATIVE-CLAUSE FORMS OF THE TWO ABOVE, and their absence cost a pre-read on a
        // passage the user identified perfectly clearly: "the implementation section THAT STARTS
        // WITH I built a minimum viable product".
        "that starts with", "which starts with",
        "that begins with", "which begins with",
        "that says", "which says", "that talks about", "that mentions",
        "that covers", "that discusses", "where",
    ]

    /// Divisions a document numbers directly ("section 5", "chapter three"). "item" is out for
    /// the same reason it left `partNouns`: "what's item 3 on my list" is a reminders question,
    /// and answering it with a Pages `find` for "item 3" is worse than not reading at all.
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

    /// THE EYELESS VETO. Words that name an ambient DATA SOURCE — a world with no window,
    /// answered by EventKit or SQLite rather than by reading a document.
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

    /// The phrase to hand a targeted read, or nil when the utterance names no part of anything.
    /// Case is preserved — the read matches case-insensitively, and the binding echoes the
    /// phrase back in its bounds label ("…from \"batteries\"").
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

    /// Trim a spoken capture down to something a document might contain verbatim: no leading
    /// article, nothing past a clause break, at most five words, no trailing punctuation.
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
