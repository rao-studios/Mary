//
//  ActionClassifier.swift
//  MaryBrain
//
//  WHAT: Deterministic "is this an action command?"
//  OUT:  AmbientEngine / AmbientIntent.actionCommand
//  PIN:  Conservative — false positive silences an answer; false negative keeps today's behavior.
//

import Foundation

public enum ActionClassifier {

    /// Imperative verbs that open a command when they LEAD the utterance. Deliberately excludes
    /// ambiguous openers . `resume` was already present, and `listen` is here under a bound.
    public static let actionVerbs: Set<String> = [
        "add", "play", "open", "create", "draw", "insert", "type", "write",
        "move", "rename", "delete", "trash", "set", "turn", "skip",
        "pause", "resume", "continue", "make", "start", "mark", "close",
        "commit", "push", "send", "reveal", "import", "split",
        "put", "queue", "shuffle", "launch", "listen",
    ]

    /// Imperative verbs from the coding/editing register — same rhythm, kept as a separate set
    /// so the pin test names the delegation-shaped cohort.
    public static let codingActionVerbs: Set<String> = [
        "strip", "fix", "remove", "refactor", "update", "change", "extract",
        "convert", "wire", "edit", "implement", "rewrite", "replace", "delegate",
    ]

    /// The PROSE-REVISION cohort.
    public static let reviseActionVerbs: Set<String> = [
        "reword", "rephrase", "revise", "tighten", "shorten", "condense",
        "expand", "polish", "correct", "proofread", "swap", "substitute",
    ]

    /// Openers that mean the user wants an ANSWER — always spoken rhythm.
    public static let questionOpeners: Set<String> = [
        "what", "what's", "why", "how", "when", "who", "where", "which",
        "is", "are", "am", "do", "does", "did", "can", "could", "would",
        "should", "tell", "read", "show", "list", "search", "find",
        "check", "describe", "explain", "summarize", "give",
    ]

    /// Words that lead an imperative WITHOUT changing it. "Just play the theme" is "play the
    /// theme" said casually. DELIBERATELY NOT the polite REQUEST FRAMES ("can you…"). Those are
    /// pinned false here on purpose.
    public static let discourseMarkers: Set<String> = ["just", "please"]

    /// The direction and object words that form a complete music transport request without an
    /// imperative verb: "next track" / "previous song". These are deliberately NOT folded into
    /// `actionVerbs`. `next` and `previous` describe ordinary non-action things.
    private static let transportDirections: Set<String> = ["next", "previous"]
    private static let transportObjects: Set<String> = ["track", "song"]

    private static func isBoundedTransportRequest(_ words: [String]) -> Bool {
        var candidate = words
        if candidate.last == EditIntentClassifier.politeTail {
            candidate.removeLast()
        }
        guard candidate.count == 2 else { return false }
        return transportDirections.contains(candidate[0])
            && transportObjects.contains(candidate[1])
    }

    /// True when the utterance is a clear action command. Strips a leading address ("mary",
    /// "hey mary") and any filler in front of the verb.
    public static func isActionCommand(
        _ utterance: String,
        applicationAliases: Set<String> = []
    ) -> Bool {
        let trimmedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsQuestionMark = trimmedUtterance.contains("?")
        let hasOneTerminalQuestionMark = trimmedUtterance.last == "?"
            && trimmedUtterance.dropLast().contains("?") == false
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // Leading address ("mary, add…" / "hey mary play…"), filler ("just play…") and backchannel
        // ("so play…"), in any order and any number. AN APPLICATION NAME IS AN ADDRESS TOO.
        var peeledAlias = false
        while let first = words.first,
              EditIntentClassifier.addressWords.contains(first)
                  || EditIntentClassifier.backchannelWords.contains(first)
                  || discourseMarkers.contains(first)
                  || (!peeledAlias && applicationAliases.contains(first)) {
            if applicationAliases.contains(first),
               !EditIntentClassifier.addressWords.contains(first),
               !EditIntentClassifier.backchannelWords.contains(first),
               !discourseMarkers.contains(first) {
                peeledAlias = true
            }
            words.removeFirst()
        }
        // POLITE REQUEST FRAMES, peeled ONLY in front of the instant cohort. "Can you play the
        // next song" is an instruction; "can you fix the build" is a conversation about one.
        var acceptedPoliteRequest = false
        if words.count >= 2 {
            for index in stride(from: words.count - 2, through: 0, by: -1)
            where EditIntentClassifier.requestFrames.contains([words[index], words[index + 1]]) {
                var peeled = Array(words.dropFirst(index + 2))
                if peeled.first == EditIntentClassifier.politeTail { peeled.removeFirst() }
                if let verb = peeled.first,
                   actionVerbs.contains(verb)
                       || reviseActionVerbs.contains(verb)
                       || isBoundedTransportRequest(peeled) {
                    words = peeled
                    acceptedPoliteRequest = true
                }
                break
            }
        }
        let isDirectTransportRequest = isBoundedTransportRequest(words)
        // A direct polite action request remains a request when ASR gives it question punctuation.
        // So does the closed transport shorthand above: "next track?" has no informational reading
        // once it is bounded to exactly a music object.
        if containsQuestionMark {
            guard acceptedPoliteRequest || isDirectTransportRequest,
                  hasOneTerminalQuestionMark else { return false }
            // A polite frame with a hedged/alternative tail is not a committed
            // command merely because ASR placed one question mark at the end.
            let hesitationTokens: Set<String> = ["or", "maybe", "unless", "wait"]
            guard hesitationTokens.isDisjoint(with: words) else { return false }
        }
        guard let first = words.first else { return false }
        if questionOpeners.contains(first) { return false }
        // A lone verb ("continue", "go") is conversational flow, not a
        // command — the rhythm needs an object to act on.
        guard words.count >= 2 else { return false }
        // "LISTEN" IS ALSO A DISCOURSE MARKER, and it is the one music verb that is.
        if first == "listen", words[1] != "to" { return false }
        if isDirectTransportRequest { return true }
        if actionVerbs.contains(first) || reviseActionVerbs.contains(first) { return true }
        // Scoped to the coding cohort so every pre-existing verdict stays byte-identical: "update
        // me on the build" / "fix us up" want an ANSWER or banter, not an edit ("make me a
        // playlist" stays a command — actionVerbs already decided above).
        if words[1] == "me" || words[1] == "us" { return false }
        return codingActionVerbs.contains(first)
    }
}
