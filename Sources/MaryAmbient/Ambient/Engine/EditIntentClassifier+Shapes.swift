//
//  EditIntentClassifier+Shapes.swift
//  MaryAmbient
//
//  WHAT: Sentence shapes (replace / cut / move / insert).
//  IN:   EditIntentClassifier.swift (split)
//  OUT:  EditIntent
//

import Foundation

extension EditIntentClassifier {

    // MARK: - Shapes

    /// `<verb> <TARGET> <split> <PAYLOAD>`, and with no split word the whole
    /// tail is the target and there is no payload ("tighten the intro" is a
    /// perfectly complete instruction — the model writes the replacement).
    static func replaceIntent(_ text: String) -> EditIntent? {
        let verbs = alternation(replaceVerbs)
        // THE WHOLE TAIL FIRST, and every question below asked of IT rather than of whatever
        // survives a split. THE CORRUPTION THIS ORDERING FIXES. The split branch used to run
        // first, and `"for"` is a `splitWord`.
        guard let tailParts = captures(
            in: text, pattern: "^(?:\(verbs))\\b\\s+(.+)$"),
              tailParts.count == 1 else { return nil }
        let tail = trimCourtesyTail(tailParts[0])
        guard !tail.isEmpty else { return nil }

        // THE ANAPHORIC RUNG.
        if isAnaphoricTail(tail) {
            return EditIntent(shape: .replace, target: [], isAnaphoric: true)
        }

        // The split is asked of the TAIL, which is the same span the verb pattern already consumed
        // — non-greedy from the same position, so this decomposes identically to the old
        // whole-string pattern, minus the courtesy `trimCourtesyTail` removed.
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

    /// How a request ENDS politely, which is never what it asks for. `"for"` is a `splitWord`,
    /// so without this "reword the whole thing for me" decomposes as target "the whole thing" /
    /// payload **"me"** — the beneficiary read as the replacement text.
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

    /// Does this tail refer BACK to something rather than name it? Deliberately narrow.
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

    /// `<verb> <PAYLOAD> <anchor> <TARGET>`.
    static func insertIntent(_ text: String) -> EditIntent? {
        let verbs = alternation(insertVerbs)
        let anchors = alternation([inPlaceOfPhrase] + anchorVocabulary.map(\.phrase))
        guard let parts = captures(
            in: text,
            pattern: "^(?:\(verbs))\\b\\s+(.+?)\\s+(\(anchors))\\s+(.+)$"),
              parts.count == 3 else { return nil }
        // COMPOSITION INTO A FRESH SURFACE IS NOT A REVISION.
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

    /// A FRESH SURFACE named as an anchor object — "a fresh Pages document", "a new note",
    /// "this blank page". Pure and public so the veto's tests can pin the boundary.
    public static func isFreshSurfacePhrase(_ phrase: String) -> Bool {
        let pattern = "^(?:a|an|this|that|the)?\\s*(?:brand\\s+)?"
            + "(?:new|fresh|blank|empty)\\s+"
            // ONE OPTIONAL WORD, not a list of products. The slot used to hold five application names,
            // so "a new Obsidian note" read as a fresh surface and "a new Bear note" did not — a
            // distinction drawn by which brands somebody had thought of.
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
