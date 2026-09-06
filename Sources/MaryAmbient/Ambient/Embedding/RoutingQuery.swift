//
//  RoutingQuery.swift
//  MaryAmbient
//
//  WHAT: One string the embedding indexes vectorize for a turn.
//  IN:   utterance + live snapshot digest + recent user turns
//  OUT:  SemanticIntentIndex / ability / skill search
//  PIN:  Fact ranking still uses the raw utterance; this string is embeddings only.
//

import Foundation

public enum RoutingQuery {

    public static let historyCap = 3
    public static let turnCap = 160

    /// Utterance first, then clipped snapshot and history lines.
    public static func compose(
        utterance: String,
        world: AmbientWorld.Snapshot? = nil,
        recentUserTurns: [String] = []
    ) -> String {
        let spoken = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [spoken]
        if let world {
            lines.append(contentsOf: worldLines(world))
        }
        let recent = recentUserTurns
            .map { clip($0, cap: turnCap) }
            .filter { !$0.isEmpty }
            .suffix(historyCap)
        if !recent.isEmpty {
            lines.append("recent: " + recent.joined(separator: " | "))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func worldLines(_ snapshot: AmbientWorld.Snapshot) -> [String] {
        var lines: [String] = []
        let lead = snapshot.place.displayName
        if !lead.isEmpty {
            lines.append("lead: \(lead)")
        }
        if let subject = snapshot.subject ?? snapshot.selectedText,
           !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The label follows the sense: only a highlight is a selection.
            let label = snapshot.sense == .selection ? "selection" : "subject"
            lines.append("\(label): \(clip(subject, cap: 80))")
        }
        return lines
    }

    private static func clip(_ text: String, cap: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > cap else { return trimmed }
        return String(trimmed.prefix(cap))
    }

    // MARK: - The request, without the frame around it

    /// The words a request is WRAPPED in, which carry no routing information.
    ///
    /// PIN: ENGLISH REQUEST FRAMING, NOT A VOCABULARY OF TASKS. Every entry here
    /// is a way of ASKING rather than a thing to do — remove any of them and the
    /// sentence still says exactly what it wanted done. Nothing in this list
    /// names a surface, an application, a site or a verb, and a review that finds
    /// one has found a bug.
    /// SPELLED FOLDED, because that is what they are compared against — a
    /// contraction reaches this table as "im", never "i'm", and an entry with an
    /// apostrophe in it could not match anything.
    static let leadingFrames = [
        "can you please", "could you please", "would you please",
        "can you", "could you", "would you", "will you", "would you mind",
        "i want you to", "i need you to", "i would like you to",
        "id like you to", "please can you", "please could you",
        "go ahead and", "help me", "please",
        // A CORRECTION IS A FRAME TOO, and dictation is why it has to be. A
        // person who rejects an answer and asks again in one breath produces one
        // sentence with no punctuation in it — "No I'm not what's on this page
        // I'm looking at in Google Chrome" — and the rejection is scored as
        // though it were the request. MEASURED: nothing at all was offered for
        // that sentence, while its second half alone reaches `read_page` at
        // 0.765. The full sentence is still scored first and this is only ever
        // the better of the two, so a bare "no" is untouched: one word left is
        // not a request, and `bareRequest` returns nil.
        "no im not", "no i am not", "no i didnt", "no i did not",
        "no thats not", "no that is not", "no i meant", "i meant",
        "no not that", "not that", "actually", "no",
    ]

    /// The same, at the end of the sentence.
    static let trailingFrames = [
        "please", "for me", "thanks", "thank you", "if you can", "if you could",
    ]

    /// A preposition that introduces a surface — dropped with it, so
    /// "on Google Chrome" leaves nothing behind rather than a dangling "on".
    static let surfacePrepositions = ["in", "on", "from", "with", "using", "into", "over"]

    /// THE REQUEST WITH ITS FRAME REMOVED, or nil when there was no frame.
    ///
    /// PIN: THE SAME ARGUMENT AS `firstLine`, ONE LEVEL IN. A real sentence
    /// embedding scores what the whole string is ABOUT, and a request carries two
    /// things that are not about the task: the politeness that asks for it, and
    /// the surface it names. Both are already ROUTING FACTS by the time this is
    /// vectorized — the surface as `namedApplications`, the request as the
    /// intent — so leaving them in the sentence spends it twice.
    ///
    /// MEASURED against the on-device model, 2026-09-06, the shipped corpus:
    ///   "click on the first link"                       click_on_page 0.623 — offered
    ///   "Can you click on the first link"                             0.563 — NOTHING offered
    ///   "what's on this page"                             read_page 0.805 — offered
    ///   "What's on this page right now on Google Chrome"              0.597 — NOTHING offered
    /// In both cases the RANKING was already right and the floor threw it away.
    /// A politeness frame costs 0.06 to 0.21 of similarity; a named surface costs
    /// about the same again. Neither is a calibration problem — 0.62 is the right
    /// floor for a sentence that is all task — and lowering it to admit these
    /// would admit everything else at 0.56 too.
    ///
    /// NIL WHEN NOTHING WAS STRIPPED, so a caller can tell "the bare form" from
    /// "the same string again" and never vectorizes one sentence twice.
    /// NIL ALSO WHEN THE FRAME WAS THE WHOLE SENTENCE: "can you help me" has no
    /// request inside it, and scoring the empty string against every corpus would
    /// be noise with a floor under it.
    public static func bareRequest(
        _ utterance: String, surfaces: [[String]] = []
    ) -> String? {
        var words = firstLine(utterance)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        let before = words.count
        words = strippingSurfaces(words, surfaces: surfaces)
        words = strippingFrame(words, frames: leadingFrames, leading: true)
        words = strippingFrame(words, frames: trailingFrames, leading: false)
        guard words.count != before, !words.isEmpty else { return nil }
        // A SENTENCE OF ONE WORD IS NOT A REQUEST. "Can you" over "chrome" leaves
        // a surface name, which scores against whatever Skill is named alike.
        guard words.count > 1 else { return nil }
        return words.joined(separator: " ")
    }

    /// Longest frame first, so "can you please" is not left as "please".
    private static func strippingFrame(
        _ words: [String], frames: [String], leading: Bool
    ) -> [String] {
        var words = words
        var again = true
        while again {
            again = false
            for frame in frames.sorted(by: { $0.count > $1.count }) {
                let phrase = frame.split(separator: " ").map(String.init)
                guard phrase.count < words.count else { continue }
                let edge = leading
                    ? Array(words.prefix(phrase.count))
                    : Array(words.suffix(phrase.count))
                guard edge.map(folded) == phrase else { continue }
                words = leading
                    ? Array(words.dropFirst(phrase.count))
                    : Array(words.dropLast(phrase.count))
                again = true
                break
            }
        }
        return words
    }

    /// Every registered surface's own name, with the preposition that led to it.
    ///
    /// PIN: THE NAMES COME FROM THE INSTALLED PACKAGES, never from a list here —
    /// this function is given them. A word that is not a declared application's
    /// alias is content, whatever it looks like: "search youtube for boots" keeps
    /// youtube, because nothing installed answers to it.
    private static func strippingSurfaces(
        _ words: [String], surfaces: [[String]]
    ) -> [String] {
        guard !surfaces.isEmpty else { return words }
        var words = words
        for surface in surfaces.sorted(by: { $0.count > $1.count }) {
            guard !surface.isEmpty, surface.count < words.count else { continue }
            var index = 0
            while index + surface.count <= words.count {
                let window = words[index..<(index + surface.count)].map(folded)
                guard window == surface else {
                    index += 1
                    continue
                }
                var from = index
                // The preposition that introduced it goes too — otherwise
                // "on Google Chrome" leaves a dangling "on".
                if from > 0, surfacePrepositions.contains(folded(words[from - 1])) {
                    from -= 1
                }
                let removed = words.count - (index + surface.count)
                words.removeSubrange(from..<(index + surface.count))
                // WHAT IS LEFT MUST STILL BE A REQUEST. Stripping the surface out
                // of "open chrome" leaves "open", which is a different sentence.
                guard words.count > 1 else { return words }
                index = max(0, words.count - removed)
            }
        }
        return words
    }

    /// One word as the alias tables spell it: letters and digits only.
    static func folded(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A name as the word array `bareRequest` matches against — the same
    /// tokenizer `ApplicationProfile.isMentioned` uses, so a surface this drops
    /// is exactly a surface the arbitrator already read as named.
    public static func foldedWords(_ value: String) -> [String] {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The literal utterance out of a composed multi-line query — `compose`
    /// always puts it first. Measured with `MARY_EMBEDDING_CALIBRATION=1`
    /// against the real on-device model: a real sentence embedding dilutes
    /// badly once world/history lines are appended (a query that uniquely
    /// wins a Skill bare can drop below the floor once composed), so every
    /// embedding consumer scores against this, never the whole composed
    /// string. Corpus seeds are already single sentences and are unaffected.
    public static func firstLine(_ query: String) -> String {
        query.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? query
    }
}
