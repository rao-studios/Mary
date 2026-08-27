//
//  ActionClassifier.swift
//  MaryBrain
//
//  Deterministic "is this an action COMMAND?" — the switch for the
//  action-first rhythm: a clear imperative ("add a pink case", "play the
//  jazz playlist") acts IMMEDIATELY with no spoken confirmation; the
//  transcript's Ability | Skill badges are the reply. Questions ("what's on my
//  calendar") keep the full spoken rhythm.
//
//  Same philosophy as FocusOverride.classifyOverride: word-start
//  cues, CONSERVATIVE on purpose — a false positive silences an answer the
//  user wanted to hear, a false negative merely keeps today's behavior.
//

import Foundation

public enum ActionClassifier {

    /// Imperative verbs that open a command when they LEAD the utterance.
    /// Deliberately excludes ambiguous openers ("write" alone often heads
    /// questions like "write down what I said?" — no: keep write; exclude
    /// truly ambiguous ones like "get", "look", "go").
    ///
    /// THE FAILURE THE MUSIC ROW FIXES, in the user's words: Apple Music "opened
    /// and played a song, and then followed up after completing the task as if
    /// it was doing it at the moment." "Put on some jazz" is as plain an
    /// imperative as "play the jazz playlist", but this list is CLOSED with no
    /// fallback — `play` and `open` were in it and `put`, `queue`, `shuffle` and
    /// `launch` were not — so the turn took the SPOKEN rhythm, and a spoken
    /// rhythm on an action that finishes in under a second is a promise about
    /// something already done. The verbs a person actually uses to start music
    /// or an app belong beside the two that were already here.
    ///
    /// `resume` was already present, and `listen` is here under a bound — see
    /// `isActionCommand`.
    public static let actionVerbs: Set<String> = [
        "add", "play", "open", "create", "draw", "insert", "type", "write",
        "move", "rename", "delete", "trash", "set", "turn", "skip",
        "pause", "resume", "continue", "make", "start", "mark", "close",
        "commit", "push", "send", "reveal", "import", "split",
        "put", "queue", "shuffle", "launch", "listen",
    ]

    /// Imperative verbs from the coding/editing register — same rhythm, kept
    /// as a separate set so the pin test names the delegation-shaped cohort.
    /// These lead general-English imperatives too ("fix the build", "remove
    /// the duplicate case"); a question with them opens with a "?" or a
    /// question opener, both vetoed above.
    public static let codingActionVerbs: Set<String> = [
        "strip", "fix", "remove", "refactor", "update", "change", "extract",
        "convert", "wire", "edit", "implement", "rewrite", "replace", "delegate",
    ]

    /// The PROSE-REVISION cohort — `EditIntentClassifier.replaceVerbs` minus
    /// the words already spoken for above.
    ///
    /// They were in neither set, which is how "can you please reword it"
    /// reached the model as conversation: `reword` is a revision verb to
    /// `EditIntentClassifier` and to `AmbientRanker.namesTransform`, and a
    /// nonsense word to the one classifier that decides the turn's RHYTHM.
    /// Three vocabularies, two of them agreeing.
    ///
    /// Kept as its own set rather than folded into `actionVerbs` so the polite
    /// frame peel can admit it deliberately: "can you reword it" acts, and the
    /// coding cohort's pinned verdicts are untouched.
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

    /// Words that lead an imperative WITHOUT changing it. "Just play the
    /// theme" is "play the theme" said casually.
    ///
    /// THE FAILURE THIS FIXES (live, in the user's words: Apple Music "is not
    /// executing the play and next track… and she keeps saying I'm on it").
    /// Every verb test below reads `words.first`, so one filler word in front
    /// hid the verb completely: "just play the theme" classified on "just",
    /// came back false, and the turn took the SPOKEN rhythm — Lane A promised
    /// "I'm on it — playing Rao's theme now" while nothing suppressed it and
    /// no action-turn retry was available to re-roll a NOOP. Exactly the
    /// unanchoring `EditIntentClassifier.backchannelWords` was written for,
    /// one classifier over.
    ///
    /// DELIBERATELY NOT the polite REQUEST FRAMES ("can you…"). Those are
    /// pinned false here on purpose — see `ActionRhythmTests` — and peeling
    /// them is a separate decision with a different cost.
    public static let discourseMarkers: Set<String> = ["just", "please"]

    /// The direction and object words that form a complete music transport
    /// request without an imperative verb: "next track" / "previous song".
    ///
    /// These are deliberately NOT folded into `actionVerbs`. `next` and
    /// `previous` describe ordinary non-action things ("next week", "previous
    /// version"), so treating either as a verb would silence unrelated turns.
    /// The recognizer below admits only the closed two-word cross-product,
    /// optionally followed by the ordinary politeness tail.
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

    /// True when the utterance is a clear action command. Strips a leading
    /// address ("mary", "hey mary") and any filler in front of the verb.
    /// A question mark still vetoes informational and ambiguous questions, but
    /// not a direct polite request whose `can/could/would you` frame resolves to
    /// the instant/reversible action cohort below. Voice transcription commonly
    /// punctuates those requests as questions; punctuation must not turn
    /// "Can you create a circle in Sketch?" into Skill-free conversation.
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
        // Leading address ("mary, add…" / "hey mary play…"), filler
        // ("just play…") and backchannel ("so play…"), in any order and any
        // number. `addressWords` and `backchannelWords` are read from
        // EditIntentClassifier rather than respelled — its own comment asks
        // for exactly that ("only one of them should have to be spelled
        // here"), and two copies of one vocabulary is how the two classifiers
        // would start disagreeing about the same sentence.
        //
        // AN APPLICATION NAME IS AN ADDRESS TOO. "Sketch can you add a white
        // circle" is the same command as "can you add a white circle" — but
        // the app name is not in `addressWords`, so the peel used to stop on
        // word 0, the polite frame was never seen, and an app-addressed
        // imperative routed as conversation (live: the sketch turn that
        // ad-libbed "Got it" with no dispatch). The caller supplies the
        // known aliases because they are runtime data (registered
        // applications), not vocabulary; an empty set is byte-identical to
        // the old behavior. AT MOST ONE alias is consumed — "Sketch Pages
        // add…" is somebody listing apps, not addressing two.
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
        // POLITE REQUEST FRAMES, peeled ONLY in front of the instant cohort.
        //
        // "Can you play the next song" is an instruction; "can you fix the
        // build" is a conversation about one. Both open on a question opener,
        // and this classifier vetoed both — pinned twice as "conservative:
        // polite form", because silencing an answer the user wanted is its
        // expensive direction to be wrong in.
        //
        // THE SPLIT IS THE EXISTING VOCABULARY, not a new list. `actionVerbs`
        // is the instant/app cohort (play, open, skip, pause, launch…) where
        // the act is immediate and reversible and there is nothing to discuss;
        // `codingActionVerbs` (fix, refactor, rewrite…) is where a polite form
        // genuinely often wants an answer first. So the frame is peeled only
        // when an `actionVerbs` verb is behind it, and `can you fix the build`
        // keeps its pinned verdict untouched.
        //
        // The peel is TENTATIVE until the verb is checked: nothing is
        // committed when the frame turns out to lead anything else, so the
        // question-opener veto below still sees the sentence exactly as the
        // user said it.
        //
        // THE FRAME IS FOUND ANYWHERE, not only at the head. THE FAILURE THIS
        // FIXES (live, from the Routes pane): "Where you didn't write it here
        // can you write it in untitled 34" classified `perceive via deixis` —
        // the roster arbitrated 0 of 69 Skills and the Writing Surface's
        // `type_at_cursor` died at dispatch on the Writing Ability's
        // compose/revise gate. Every check here read the sentence's HEAD, so
        // the context clause ("Where you didn't write it here") swallowed the
        // command clause whole: "where" vetoed as a question opener while the
        // deixis scan — which reads the WHOLE utterance — latched onto "here".
        // `EditIntentClassifier.intent(in:)` went clause-local for exactly
        // this shape ("To see the implementation section here … can you revise
        // that section"); this is the same repair for the compose register,
        // scoped to the one clause boundary a person marks explicitly: the
        // request frame itself. The LAST frame wins because the trailing
        // clause is the operative one — everything before it was context.
        // Every one-clause verdict is unchanged: a lone head frame is simply
        // the last frame.
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
        // A direct polite action request remains a request when ASR gives it
        // question punctuation. So does the closed transport shorthand above:
        // "next track?" has no informational reading once it is bounded to
        // exactly a music object. Every other question keeps the conservative
        // spoken rhythm, including informational `can you tell...`, capability
        // questions such as `can Sketch...`, and the deliberately separate
        // coding cohort (`can you fix...`).
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
        // "LISTEN" IS ALSO A DISCOURSE MARKER, and it is the one music verb
        // that is. "Listen to some jazz" is a command; "listen, what's on my
        // calendar" is a question wearing the same first word, and this
        // classifier's standing bias is that a false positive SILENCES a reply
        // the user asked for while a false negative merely keeps today's
        // behavior. So it leads a command only when "to" follows it; the bare
        // marker keeps the spoken rhythm. It stays in `actionVerbs` above
        // rather than in a set of its own — one vocabulary, one bound on it.
        if first == "listen", words[1] != "to" { return false }
        if isDirectTransportRequest { return true }
        if actionVerbs.contains(first) || reviseActionVerbs.contains(first) { return true }
        // Scoped to the coding cohort so every pre-existing verdict stays
        // byte-identical: "update me on the build" / "fix us up" want an
        // ANSWER or banter, not an edit ("make me a playlist" stays a
        // command — actionVerbs already decided above).
        if words[1] == "me" || words[1] == "us" { return false }
        return codingActionVerbs.contains(first)
    }
}
