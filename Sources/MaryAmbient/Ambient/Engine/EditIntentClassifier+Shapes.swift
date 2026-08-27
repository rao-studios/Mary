//
//  EditIntentClassifier+Shapes.swift
//  MaryAmbient
//
//  Split out of EditIntentClassifier.swift (docs/DECOMPOSITION.md
//  Wave 4) — pure relocation, no declaration changed.
//

import Foundation

extension EditIntentClassifier {

    // MARK: - Shapes

    /// `<verb> <TARGET> <split> <PAYLOAD>`, and with no split word the whole
    /// tail is the target and there is no payload ("tighten the intro" is a
    /// perfectly complete instruction — the model writes the replacement).
    static func replaceIntent(_ text: String) -> EditIntent? {
        let verbs = alternation(replaceVerbs)
        // THE WHOLE TAIL FIRST, and every question below asked of IT rather
        // than of whatever survives a split.
        //
        // THE CORRUPTION THIS ORDERING FIXES. The split branch used to run
        // first, and `"for"` is a `splitWord`. So "revise that section for me"
        // decomposed as target `"that section"` / split `"for"` / payload
        // `"me"` — `clean` dropped the demonstrative and the intent came out as
        // REPLACE THE LITERAL WORD "section" WITH THE WORD "me". Not a missed
        // revision: a search-and-destroy against the user's prose, and the same
        // shape hit "reword the whole thing for me". `isAnaphoricTail` already
        // knew better — it reads "for"/"me" as trailers that name nothing — but
        // it sat in a branch the split had already consumed.
        //
        // Asking it of the whole tail is safe because it is precise rather than
        // permissive: one word carrying identity of its own and it says no, so
        // "replace the Purpose section with the tighter version" fails it on
        // "purpose" and falls through to the split exactly as before.
        guard let tailParts = captures(
            in: text, pattern: "^(?:\(verbs))\\b\\s+(.+)$"),
              tailParts.count == 1 else { return nil }
        let tail = trimCourtesyTail(tailParts[0])
        guard !tail.isEmpty else { return nil }

        // THE ANAPHORIC RUNG. The failure it answers is not that `candidates`
        // comes back empty, it is that it comes back USELESS: "reword that
        // paragraph" cleans down to the single word "paragraph", a perfectly
        // well-formed search for the literal word "paragraph" in their prose.
        if isAnaphoricTail(tail) {
            return EditIntent(shape: .replace, target: [], isAnaphoric: true)
        }

        // The split is asked of the TAIL, which is the same span the verb
        // pattern already consumed — non-greedy from the same position, so
        // this decomposes identically to the old whole-string pattern, minus
        // the courtesy `trimCourtesyTail` removed.
        let splits = alternation(splitWords)
        if let parts = captures(
            in: tail, pattern: "^(.+?)\\s+(?:\(splits))\\s+(.+)$"),
           parts.count == 2 {
            let target = candidates(forTarget: parts[0])
            guard !target.isEmpty else { return nil }
            return EditIntent(
                shape: .replace, target: target, payload: payload(parts[1]))
        }
        let target = candidates(forTarget: tail)
        guard !target.isEmpty else { return nil }
        return EditIntent(shape: .replace, target: target)
    }

    /// How a request ENDS politely, which is never what it asks for.
    ///
    /// `"for"` is a `splitWord`, so without this "reword the whole thing for
    /// me" decomposes as target "the whole thing" / payload **"me"** — the
    /// beneficiary read as the replacement text. `isAnaphoricTail` catches the
    /// demonstrative forms ("that section for me") but not this one, because
    /// "whole" carries identity of its own and correctly fails it.
    ///
    /// MATCHED AS WHOLE TRAILING PHRASES, never as words. Stripping a bare
    /// "me" would eat a legitimate payload — "replace the intro with a note
    /// about me" — so only these exact endings are removed, and only from the
    /// end.
    public static let courtesyTails = ["for me", "for us", "please"]

    public static func trimCourtesyTail(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimming = true
        while trimming {
            trimming = false
            for phrase in courtesyTails where text.lowercased().hasSuffix(" " + phrase) {
                text = String(text.dropLast(phrase.count + 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                trimming = true
            }
        }
        return text
    }

    /// Words that trail a request without naming anything — "tighten it UP",
    /// "reword that FOR ME".
    public static let anaphoricTrailers: Set<String> = [
        "up", "please", "for", "me", "us", "again", "quickly", "a", "bit",
        "little", "now", "instead",
    ]

    /// Determiners that can stand in for a name.
    public static let anaphoricHeads: Set<String> = [
        "it", "that", "this", "those", "these", "the", "one", "thing", "them",
    ]

    /// Does this tail refer BACK to something rather than name it?
    ///
    /// Deliberately narrow, and narrow in the direction this file always errs:
    /// a false positive turns an ordinary sentence into an edit of the last
    /// passage Mary touched, which is the expensive way to be wrong. It
    /// accepts only words that carry no identity of their own — a pronoun, a
    /// demonstrative, and optionally a PART NOUN the read classifier already
    /// recognises ("that paragraph", "this section"). One word with meaning in
    /// it ("that Purpose section") and the tail is a name, not a reference.
    public static func isAnaphoricTail(_ raw: String) -> Bool {
        let words = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        var sawReference = false
        for word in words {
            if anaphoricHeads.contains(word) {
                sawReference = true
                continue
            }
            // A part noun is only ever a reference BEHIND a demonstrative:
            // "that paragraph" refers, "paragraph" alone is a target the
            // candidate ladder should have taken.
            if sawReference, NamedPartClassifier.partNouns.contains(word) { continue }
            if anaphoricTrailers.contains(word) { continue }
            return false
        }
        return sawReference
    }

    static func deleteIntent(_ text: String) -> EditIntent? {
        guard let parts = captures(
            in: text, pattern: "^(?:\(alternation(deleteVerbs)))\\b\\s+(.+)$"),
              parts.count == 1 else { return nil }
        let target = candidates(forTarget: parts[0])
        guard !target.isEmpty else { return nil }
        return EditIntent(shape: .delete, target: target)
    }

    /// `<verb> <PAYLOAD> <anchor> <TARGET>` — note the inversion. In a
    /// replacement the target leads; in an insertion the payload does, because
    /// that is how the sentence is spoken ("add a line after the Purpose
    /// section").
    ///
    /// THE NIL THAT PROTECTS LIVE WRITING. No anchor clause, no intent —
    /// "write a paragraph about the budget", "type the opening line", "add a
    /// scene break here" all fall out of this function with nothing, and go on
    /// typing at the caret exactly as they do today. This is the one place
    /// where a fix for a revision bug could quietly eat composition, so the
    /// requirement is structural rather than a heuristic: without a phrase
    /// naming something already on the page, there is nothing to insert
    /// relative TO, and an "insert" with no relatum is just typing.
    static func insertIntent(_ text: String) -> EditIntent? {
        let verbs = alternation(insertVerbs)
        let anchors = alternation([inPlaceOfPhrase] + anchorVocabulary.map(\.phrase))
        guard let parts = captures(
            in: text,
            pattern: "^(?:\(verbs))\\b\\s+(.+?)\\s+(\(anchors))\\s+(.+)$"),
              parts.count == 3 else { return nil }
        // COMPOSITION INTO A FRESH SURFACE IS NOT A REVISION. "Write those
        // sections into a fresh Pages document" parses as `<verb> <payload>
        // into <anchor>`, and before this guard the anchor phrase went to the
        // target ladder — so the caret-write veto redirected the whole draft
        // to replace_passage against a document that does not exist yet. A
        // fresh/new/blank surface as the anchor object means "compose there":
        // no intent, no veto, the compose lane owns it. Anchors naming real
        // passages ("after the intro") are untouched.
        guard !isFreshSurfacePhrase(parts[2]) else { return nil }
        let target = candidates(forTarget: parts[2])
        guard !target.isEmpty else { return nil }
        let marker = parts[1].lowercased()
        if marker == inPlaceOfPhrase {
            return EditIntent(
                shape: .replace, target: target, payload: payload(parts[0]))
        }
        return EditIntent(
            shape: .insert, target: target, payload: payload(parts[0]),
            anchor: anchor(for: marker))
    }

    /// A FRESH SURFACE named as an anchor object — "a fresh Pages document",
    /// "a new note", "this blank page". Pure and public so the veto's tests
    /// can pin the boundary. The freshness adjective is REQUIRED: "the Pages
    /// document" names an existing thing and stays a legitimate anchor.
    public static func isFreshSurfacePhrase(_ phrase: String) -> Bool {
        let pattern = "^(?:a|an|this|that|the)?\\s*(?:brand\\s+)?"
            + "(?:new|fresh|blank|empty)\\s+"
            // ONE OPTIONAL WORD, not a list of products. The slot used to
            // hold five application names, so "a new Obsidian note" read as
            // a fresh surface and "a new Bear note" did not — a distinction
            // drawn by which brands somebody had thought of. Any single word
            // may sit here; the FRESHNESS ADJECTIVE above is what carries the
            // meaning, and it is required.
            + "(?:[a-z]+\\s+)?"
            + "(?:documents?|notes?|pages?|files?|docs?)\\b"
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    /// `<verb> <TARGET> <anchor|to> <DESTINATION>`. A move with no destination
    /// is not a passage move at all ("move the file to the desktop" is the
    /// filesystem's business), so the destination is required.
    static func moveIntent(_ text: String) -> EditIntent? {
        let verbs = alternation(moveVerbs)
        let markers = alternation(anchorVocabulary.map(\.phrase) + ["to"])
        guard let parts = captures(
            in: text,
            pattern: "^(?:\(verbs))\\b\\s+(.+?)\\s+(\(markers))\\s+(.+)$"),
              parts.count == 3 else { return nil }
        let target = candidates(forTarget: parts[0])
        let destination = candidates(forTarget: parts[2])
        guard !target.isEmpty, !destination.isEmpty else { return nil }
        return EditIntent(
            shape: .move, target: target,
            anchor: anchor(for: parts[1].lowercased()), destination: destination)
    }

}
