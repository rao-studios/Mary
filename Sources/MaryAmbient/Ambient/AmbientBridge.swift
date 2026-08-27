//
//  AmbientBridge.swift
//  MaryBrain
//
//  THE WATCHERS' WRITE PATH into the ambient store — pure functions from a
//  watcher snapshot to the facts it implies, so the mapping is table-testable
//  and the poll loops keep exactly one new line each.
//
//  WHY PURE, AND WHY HERE: the watchers already publish a Sendable snapshot
//  into a lock box on every tick. Turning that snapshot into `(world, slot)`
//  facts is a data shape question, not a polling question, and putting it in
//  the poll loop is how the prompt and the pane drifted apart in the first
//  place. Document facts are produced by one function below. A direct
//  `.selection` is different: it is an interaction packet authored by the
//  source application's selection ability and registered through
//  `AmbientContextStore.recordSelection`, so a document poll cannot erase it.
//
//  PROVENANCE IS NOT DECORATION. `PerceptionAnchor.isLiveRead` already decides
//  which anchors earned the LIVE claim; the mapping reads THAT rather than
//  re-deciding, so a cached excerpt can never announce itself as
//  read-this-second in the store any more than it can in the prompt.
//
//  THE BACKSTOP THAT HAD TO EXIST ANYWAY. `AmbientFact.boundsPhrase` renders
//  "characters 40–120 of 120" out of `bounds` and `documentTotal`, and for the
//  whole life of the traced Pages failure `documentTotal` was fed
//  `PagesContext.totalCharacters` — an ACCESSIBILITY number, off an element
//  that turned out to be a 120-character title field. Every Pages fact below
//  now takes its total from `PagesBody.characters`, which can only have been
//  computed from the document's own text, so the RENDERING is structurally
//  incapable of speaking an AX number even if some future caller wanted it to.
//

import Foundation

public enum AmbientBridge {

    /// Cap on a stored excerpt.
    ///
    /// IT NO LONGER TRACKS `PagesContextWatcher.excerptCap`, and the split is
    /// deliberate. That number just dropped 800 → 400 because the PROMPT's
    /// excerpt changed job — it is the neighbourhood of the cursor now, under
    /// a complete outline. A stored FACT is a different thing: it is what she
    /// is still holding two turns later, when the live excerpt has moved on,
    /// and halving it would quietly halve the memory to pay for a change that
    /// was about the prompt.
    public static let excerptCap = 800

    // MARK: - Pages

    // MARK: - TextEdit

    // MARK: - Reads (the dispatcher's write path)

    /// A READ RESULT, registered instead of vanishing. THE fix for the user's
    /// complaint: "I continued the conversation and mary has lost the
    /// context of the page and the paragraph it found earlier."
    ///
    /// `phrase` is what the read was targeted at — it becomes the slot key, so
    /// re-reading the same phrase SUPERSEDES rather than accumulating, and a
    /// different phrase gets its own slot (up to `namedReadCap` per world).
    ///
    /// The bounds are parsed back out of the binding's own label rather than
    /// re-derived: `PagesPlugin.regionOutcome` is the one place that words
    /// "characters 12927–13835 of 15775", and a second implementation of the
    /// same numbers is how the prompt and the pane learn to disagree.
    /// `passageHandle` arrives STRUCTURALLY, from `SkillOutcome`, and never
    /// by scraping it back out of `summary`. That distinction is the same one
    /// the bounds below get wrong-side-up if anybody is careless: bounds are
    /// PARSED because `PagesPlugin.regionOutcome` is their single author and a
    /// second computation of the same numbers is how the prompt and the pane
    /// learn to disagree — but a HANDLE recovered from prose is a handle a
    /// model could invent by typing `[S9]` into a sentence, and the registry
    /// would then be asked about something nobody minted.
    /// `document` DISCRIMINATES A WORLD THAT HOLDS SEVERAL AT ONCE, and nil is
    /// the answer for every world that does not.
    ///
    /// THE FAILURE IT PREVENTS, and TextEdit is the first world where it is
    /// reachable: two notes both read for "the todo list" would key the same
    /// `(textedit, read:the todo list)` slot, so the second read SUPERSEDES the
    /// first and the surviving fact names one note while the conversation is
    /// still about the other. That is not a lost fact — it is a fact that
    /// answers confidently about the wrong document, which is strictly worse.
    ///
    /// The value is the world's own `Passage.documentKey`, reused rather than
    /// re-invented; the dispatcher already resolves the passage to find the
    /// world, so it costs nothing to carry. It never reaches the user: only
    /// `phrase` is rendered (`AmbientFact.slotPhrase`), so a path never ends up
    /// spoken aloud inside "the part about …".
    ///
    /// `application` NAMES THE REGISTERED APPLICATION when the world holds more
    /// than one. It is the discriminator that keeps two packages sharing
    /// `.applications` from superseding each other's reads, and it is nil for every
    /// built-in world — see `AmbientKey.application`.
    public static func readFact(
        world: AmbientWorld,
        application: String? = nil,
        phrase: String,
        summary: String,
        document: String? = nil,
        passageHandle: String? = nil,
        at now: Date = Date()
    ) -> AmbientFact? {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !wanted.isEmpty else { return nil }
        let parsed = parseBounds(in: text)
        return AmbientFact(
            world: world, application: application,
            slot: .read(wanted, in: document),
            content: text,
            subject: parsed.subject,
            bounds: parsed.bounds,
            documentTotal: parsed.total,
            provenance: .recipeRead,
            registration: .askedFor,
            capturedAt: now,
            passageHandle: passageHandle)
    }

    /// Pull `Name — characters 12927–13835 of 15775` back out of a read's own
    /// bounds label. Total by design: a summary with no label still becomes a
    /// fact, just one that says "about N characters" instead of a range —
    /// which is exactly the honest degradation `AmbientFact.boundsPhrase`
    /// renders. These numbers are safe where the watcher's were not: they were
    /// produced by `PagesPlugin.regionOutcome` over the document's own text,
    /// never by an Accessibility element.
    public static func parseBounds(
        in summary: String
    ) -> (subject: String?, bounds: Range<Int>?, total: Int?) {
        // DEFENSIVE, and it defends the SUBJECT rather than the numbers. A
        // read that minted a passage now names it first — "[S1] Essay —
        // characters 68–916 of 916" — and the subject is whatever sits before
        // the em dash, so without this the document would be filed as
        // "[S1] Essay" and every later comparison against the real name would
        // miss. The regex below is anchored on "characters …" and never saw
        // the prefix at all; only the subject was ever at risk.
        let head = stripLeadingHandle(summary.components(separatedBy: "\n").first ?? summary)
        var subject: String?
        if let dash = head.range(of: " — ") {
            let name = String(head[head.startIndex..<dash.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { subject = name }
        }
        guard let regex = try? NSRegularExpression(
            pattern: "characters\\s+(\\d+)[–-](\\d+)\\s+of\\s+(\\d+)"),
            let match = regex.firstMatch(
                in: head, range: NSRange(head.startIndex..<head.endIndex, in: head)),
            match.numberOfRanges == 4,
            let lowerRange = Range(match.range(at: 1), in: head),
            let upperRange = Range(match.range(at: 2), in: head),
            let totalRange = Range(match.range(at: 3), in: head),
            let lower = Int(head[lowerRange]), let upper = Int(head[upperRange]),
            let total = Int(head[totalRange]),
            lower <= upper
        else { return (subject, nil, nil) }
        return (subject, lower..<upper, total)
    }

    /// `"[S1] Essay — …"` → `"Essay — …"`. Only a WELL-FORMED handle at the
    /// very front is removed: the prefix letter `PassageRegistry.handlePrefix`
    /// followed by digits, in brackets, followed by a space.
    ///
    /// Deliberately not "drop everything up to the first `]`". A document
    /// legitimately called "[Draft] Chapter 3" would lose its own name to that
    /// rule, and a fact whose subject silently changed shape is worse than one
    /// carrying a prefix it did not expect.
    public static func stripLeadingHandle(_ line: String) -> String {
        let prefix = PassageRegistry.handlePrefix.lowercased()
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              line.index(after: close) < line.endIndex,
              line[line.index(after: close)] == " "
        else { return line }
        let inner = line[line.index(after: line.startIndex)..<close]
        guard inner.lowercased().hasPrefix(prefix),
              !inner.dropFirst(prefix.count).isEmpty,
              inner.dropFirst(prefix.count).allSatisfy(\.isNumber)
        else { return line }
        return String(line[line.index(close, offsetBy: 2)...])
    }
}
