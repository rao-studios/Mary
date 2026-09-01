//
//  OfferedProse.swift
//  MaryBrain
//
//  WHAT: Prose Mary herself offered — acceptance writes those exact bytes.
//  IN:   last spoken reply
//  OUT:  OfferedProseReferent / write-verb acceptance
//  PIN:  Sibling of discussedPassageReferent; two acceptance roads cannot cross.
//
import MaryAmbient
import Foundation

public enum OfferedProse {

    // MARK: - Extracting what she offered

    /// The floor a span must clear to be prose rather than a phrase. A short
    /// quoted fragment is usually a word the sentence is ABOUT ("call it
    /// 'the Citadel'?"), not a draft on offer.
    static let minimumCharacters = 40
    static let minimumWords = 8

    /// The frames that mark a span as a PROPOSAL rather than a quotation.
    static let offerFrames = [
        "something like", "something such as", "how about", "what about",
        "such as", "for example", "for instance", "maybe", "perhaps",
        "try", "along the lines of", "start with", "starts with",
        "begins with", "opens with", "goes",
    ]

    /// How far before the span an offer frame may sit and still be framing it.
    static let frameWindow = 80

    /// THE PROSE THIS REPLY OFFERED, or nil.
    public static func offer(in spokenReply: String?) -> String? {
        guard let spokenReply else { return nil }
        let reply = spokenReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return nil }

        // 1. IT MUST BE AN OFFER. The same two tests `bareAcceptance`'s offer
        //    rung already applies — a question, whose words carry a transform
        //    verb. One spelling of "she offered something", not two.
        guard reply.hasSuffix("?"), AmbientRanker.namesTransform(reply) else { return nil }

        // 2. EXACTLY ONE qualifying quoted span. Two means she offered a
        //    CHOICE, and choosing for the user is the false positive this
        //    whole file exists to refuse.
        let spans = qualifyingSpans(in: reply)
        guard spans.count == 1, let span = spans.first else { return nil }

        // 3. AN OFFER FRAME must sit just before it.
        guard isFramed(span, in: reply) else { return nil }
        return span.text
    }

    /// One quoted run, with where it sat — the position is what the frame
    /// check needs.
    struct Span: Equatable {
        var text: String
        var start: Int
    }

    /// Every quoted run that could be a draft.
    static func qualifyingSpans(in reply: String) -> [Span] {
        let openers: [Character: Character] = [
            "\"": "\"", "\u{201C}": "\u{201D}", "\u{2018}": "\u{2019}",
        ]
        var spans: [Span] = []
        let characters = Array(reply)
        var index = 0
        while index < characters.count {
            guard let closer = openers[characters[index]] else {
                index += 1
                continue
            }
            var cursor = index + 1
            while cursor < characters.count, characters[cursor] != closer {
                cursor += 1
            }
            guard cursor < characters.count else { break }
            let inner = String(characters[(index + 1)..<cursor])
            if qualifies(inner) { spans.append(Span(text: inner, start: index)) }
            index = cursor + 1
        }
        return spans
    }

    /// Is this run a DRAFT, rather than a phrase the sentence is about?
    static func qualifies(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return false }
        guard trimmed.count <= PassageWidening.maxSpan else { return false }
        guard trimmed.split(whereSeparator: \.isWhitespace).count >= minimumWords
        else { return false }
        // A question is another question, not prose to write.
        guard !trimmed.hasSuffix("?") else { return false }
        // Tool-call syntax that leaked into the spoken lane is never prose.
        guard !trimmed.contains("{"), !trimmed.contains("</") else { return false }
        return true
    }

    /// Does an offer frame sit within `frameWindow` characters before it?
    static func isFramed(_ span: Span, in reply: String) -> Bool {
        let characters = Array(reply)
        let lower = max(0, span.start - frameWindow)
        let preceding = String(characters[lower..<span.start])
            .lowercased()
            .filter { $0 != "*" && $0 != "_" }
        return offerFrames.contains { preceding.contains($0) }
    }

    // MARK: - Hearing the acceptance

    /// The objects an acceptance may point at — and nothing else. Every one is
    /// ANAPHORIC: it names no part of any document, so it can only mean the
    /// thing just offered.
    static let anaphoricObjects = [
        "that", "this", "it", "those", "these", "that bit", "that line",
        "that part", "that paragraph", "that sentence", "that version",
        "your version", "what you said", "what you just said",
        "what you wrote", "the above", "all that", "all of that",
    ]

    /// The quantifiers that may sit between the verb and the object —
    /// "add ALL OF that", "write THE WHOLE THING".
    static let quantifiers = [
        "all", "all of", "the rest", "the rest of", "every bit", "every bit of",
        "the whole", "the whole thing", "the lot", "the lot of",
    ]

    /// What a person says before the verb when they are agreeing. Bounded and
    /// closed — every member has to be harmless in front of a write verb.
    static let agreementPrefixes = [
        "please", "yes", "yeah", "yep", "yup", "sure", "ok", "okay",
        "alright", "right", "great", "perfect", "oh",
    ]

    /// The verbs that mean PUT IT ON THE PAGE.
    /// PIN: Deliberately narrower than `EditIntentClassifier.insertVerbs`: this list only has to cover the acceptance of an offer
    static let writeVerbs = [
        "add", "write", "insert", "put", "use", "keep", "type", "include",
        "go with", "take",
    ]

    /// DOES THIS UTTERANCE ACCEPT AN OFFER BY ASKING FOR IT TO BE WRITTEN?
    public static func accepts(_ utterance: String) -> Bool {
        let sentences = utterance
            .split(whereSeparator: { ".!?;\u{2014}\u{2013}".contains($0) })
            .map(String.init)
        // Sentence splitting IN ADDITION to `clauses`, not instead of it: `EditIntentClassifier.clauseBreaks` deliberately carries no dash
        let clauses = sentences.flatMap { EditIntentClassifier.clauses(of: $0) }
        return clauses.contains(where: acceptsClause)
    }

    static func acceptsClause(_ clause: String) -> Bool {
        var text = EditIntentClassifier
            .stripPreamble(clause, applicationAliases: [])
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".!,".contains(last) { text.removeLast() }
        // THE SOUND OF AGREEING, before the verb. "yes please add that" and "please write that" are the same act as "add that"
        while true {
            let peeled = agreementPrefixes.first { text == $0 || text.hasPrefix($0 + " ") }
            guard let peeled else { break }
            text = String(text.dropFirst(peeled.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while text.hasSuffix(" please") { text = String(text.dropLast(7)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let verb = writeVerbs.first(where: {
            text == $0 || text.hasPrefix($0 + " ")
        }) else { return false }
        var rest = String(text.dropFirst(verb.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An optional quantifier, then the object — and NOTHING after it. A
        // trailing clause ("add that to the Purpose section") names a target,
        // which this gate must not answer for.
        if let quantifier = quantifiers
            .sorted(by: { $0.count > $1.count })
            .first(where: { rest == $0 || rest.hasPrefix($0 + " ") }) {
            rest = String(rest.dropFirst(quantifier.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.hasPrefix("of ") { rest = String(rest.dropFirst(3)) }
        }
        return anaphoricObjects.contains(rest)
    }

    /// THE WHOLE-UTTERANCE VETO: an acceptance may not also name a target.
    public static func namesAnotherTarget(
        _ utterance: String, applicationAliases: Set<String>
    ) -> Bool {
        if NamedPartClassifier.namedPart(in: utterance) != nil { return true }
        if EditIntentClassifier.intent(
            in: utterance, applicationAliases: applicationAliases) != nil {
            return true
        }
        return false
    }
}
