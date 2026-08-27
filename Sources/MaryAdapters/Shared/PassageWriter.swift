//
//  PassageWriter.swift
//  MaryBrain
//
//  THE SEAM EACH WORLD IMPLEMENTS. Everything above this line is pure and
//  tested; everything below it talks to an application and can fail in ways no
//  test will ever reproduce. Keeping that boundary sharp is why the ladder,
//  the resolver and the edit math never learned what an app is.
//
//  ONE WRITE VERB, AND IT TAKES TEXT, NOT OFFSETS. `replace(_:with:hint:in:)`
//  is the whole protocol. Insert and delete are expressed through it by
//  `PassageEdit`, which computes the `anchorText` → `replacement` pair — so
//  there is exactly one place per world where a document is mutated, and it is
//  handed WORDS TO FIND rather than a number to write at.
//
//  That is the contract's load-bearing decision, restated as a function
//  signature. The hazards it makes unreachable, both live in this tree:
//
//    - AppleScript `character N of body text` is 1-BASED INCLUSIVE while our
//      ranges are 0-based half-open. A writer that never receives an offset
//      cannot get that conversion wrong.
//    - Accessibility offsets are UTF-16 and COUNT headers, footers and text
//      boxes; `body text` offsets do neither. A writer that re-locates the
//      passage text in the string its OWN API just returned is, by
//      construction, in the right space — and it is the only way to be sure it
//      is, because the two spaces disagree silently
//      (`ViewportProvenance.diverged`).
//
//  `hint` is passed anyway, and it is passed as a HINT: the only thing it is
//  ever allowed to do is break a tie between two identical occurrences.
//
//  `writer: nil` IS THE HONEST DEGRADATION SLOT — a world that can find a
//  passage and cannot change it says exactly that, with the reason, and routes
//  to the verb that does work there. Scrivener ships that way on evidence: its
//  own header says Mary NEVER edits .scriv files on disk because autosave
//  clobbers a raced write, its sdef is empty, and its read side is a different
//  string from the live editor. A refusal on evidence is a feature; a write
//  that might silently lose a manuscript is not.
//

import Foundation

/// The document body as one read saw it, with the hash everything downstream
/// compares against.
public struct BodySnapshot: Sendable, Equatable {
    public var text: String
    /// `ContentUndoStore.hash(text)`. Computed HERE rather than accepted, so
    /// no caller can hand over a hash that does not describe its own text —
    /// the one input that would make every guard in the chain agree while
    /// being wrong.
    public let hash: String
    public var documentKey: String
    public var documentTitle: String
    public var capturedAt: Date

    public init(
        text: String, documentKey: String, documentTitle: String,
        capturedAt: Date = Date()
    ) {
        self.text = text
        self.hash = ContentUndoStore.hash(text)
        self.documentKey = documentKey
        self.documentTitle = documentTitle
        self.capturedAt = capturedAt
    }

    public var length: Int { text.count }
}

/// WHICH PATH actually wrote. Reported, because "it worked" and "it worked by
/// typing the characters in one at a time after Accessibility refused" are
/// different facts about how much to trust the result.
public enum PassageWriteMethod: String, Sendable, Equatable, CaseIterable {
    /// `set paragraph N of body text to "…"` — Pages' primary route, where the
    /// document the edit was computed against and the document being written
    /// are the same string reached through the same API. Reported separately
    /// from `.accessibility` because the two differ in what they can even
    /// address: AX sees one page of a page-partitioned document, and this sees
    /// all of it.
    case appleScript
    /// `AXUIElementSetAttributeValue` over a selected range.
    case accessibility
    /// Synthesised keystrokes, after Accessibility selected the range. Works
    /// BECAUSE the selection already landed — it is a fallback for the setter,
    /// not for the locating.
    case keystrokes
    /// An atomic write to the file on disk (Xcode's proven chain).
    case diskWrite

    public var displayName: String {
        switch self {
        case .appleScript:   return "paragraph assignment"
        case .accessibility: return "accessibility range set"
        case .keystrokes:    return "keystrokes into the selection"
        case .diskWrite:     return "atomic disk write"
        }
    }
}

/// What a writer reports back. The runner verifies against this; nothing here
/// is taken on trust.
public struct WriteReceipt: Sendable, Equatable {
    /// Where the new text ended up, in the writer's own reading of the
    /// document afterwards. INFORMATIONAL — same rule as
    /// `PassageEditResult.changedRange`: never sent to Xcode as a selection.
    public var appliedRange: Range<Int>?
    /// The body hash the writer read back. The runner compares this against
    /// what `PassageEdit` computed; a disagreement is `.verificationFailed`,
    /// not a success.
    public var newBodyHash: String?
    /// The body TEXT the writer read back, when the tier could carry it. On
    /// the AppleScript tier this was captured in the SAME Apple-event session
    /// as the writes — the only evidence in the system with no
    /// check-to-write gap — and the runner treats it as the post-write
    /// snapshot instead of spending a later, racier read.
    public var newBody: String?
    /// Did the writer read the document back at all? False means the change
    /// was sent and nothing confirmed it — reportable, never silent.
    public var readBack: Bool
    public var method: PassageWriteMethod

    public init(
        appliedRange: Range<Int>? = nil,
        newBodyHash: String? = nil,
        newBody: String? = nil,
        readBack: Bool,
        method: PassageWriteMethod
    ) {
        self.appliedRange = appliedRange
        self.newBodyHash = newBodyHash
        self.newBody = newBody
        self.readBack = readBack
        self.method = method
    }
}

/// The refusals, SPOKEN. In `XcodeEditError`'s exact style — a sentence a
/// person hears, naming what went wrong and what would work instead ("There
/// are 3 things called resolveFocus — tell me which, or I can add a new one",
/// "\"foo\" appears 4 times — be more specific so I change the right one").
///
/// Every one of these is a case where the user asked for a CHANGE and the
/// change did not happen, so every one of them rides `ok: false` and gets
/// spoken. See `PassageResolver.refusal` for why `foundNothing` is the wrong
/// flag here.
///
/// AND NONE OF THEM MAY READ AS AN ERRAND. "Bring it back up", "point me at it
/// again", "name the heading" — a Skill-invoking model reads an imperative in a
/// Skill result as a thing to go and do, and the live transcript shows
/// `OPEN_IN_PAGES` firing off the back of a passage refusal that never mentions
/// Pages. Every sentence below states the CONDITION and stops; the tree settled
/// this once already, in its own words, at `PagesPlugin.regionOutcome`: "A
/// SIZE, NOT AN ERRAND … which a Skill-invoking model takes as fetch it."
/// `PassageTests.noPassageRefusalReadsAsAnErrand` pins the class rather than
/// these seven instances.
public enum PassageWriteError: LocalizedError, Equatable {
    /// The document the passage belongs to is not the one in front of us any
    /// more. The `-1728` in its preventable form: `document 1` is element
    /// order, the front window is front-ness, and `open_in_pages` reorders one
    /// and not the other.
    case documentMoved(expected: String, found: String?)
    /// THE WRITER'S OWN MISS, WHICH IS NOT THE RESOLVER'S. The runner re-located
    /// this passage in the body a few milliseconds ago (step 4) and confirmed
    /// the body had not moved since (step 6); then the writer looked for the
    /// same words in the string ITS OWN surface can address and did not find
    /// them. So the words are in the document and the channel could not reach
    /// them — a different fact from `AnchorOutcome.gone`, which means they are
    /// not in the body at all.
    ///
    /// THE TWO WERE CHARACTER-FOR-CHARACTER IDENTICAL, and that is why the
    /// transcript could not tell them apart: `find_passage` located the
    /// Background section over AppleScript `body text`, `insert_passage` handed
    /// it to a writer re-locating in an Accessibility string built from at most
    /// two elements of a page-partitioned document (page 1 = 3635 characters,
    /// page 2 = 1627, measured), the anchor was two paragraphs starting at
    /// offset 916 — past the seam, unreachable by construction — and Mary
    /// said "the insertions didn't take, the passage wasn't found" about a
    /// document she had just read in full and quoted accurately.
    case passageGone(opening: String, document: String)
    /// A widened span above `PassageWidening.maxSpan`.
    case spanTooLarge(characters: Int, limit: Int)
    /// This place can locate but not write. `PassageBacking.writer == nil`.
    ///
    /// A REALM, so a taught application refuses in its OWN name. Keyed on a
    /// world it would have said "I can find it in Other apps" about a
    /// manuscript — the host lane's display name standing in for the guest's.
    case worldCannotWrite(AmbientPlace, why: String)
    /// Accessibility said no — permission, a locked document, a setter the app
    /// does not implement.
    case axRefused(detail: String)
    /// THE WORDS APPEAR MORE THAN ONCE and the hint could not separate them by
    /// `PassageResolver.driftMargin`.
    ///
    /// `PagesPassageWriter` already named this gap in its own words — "
    /// `PassageWriteError` wants a case for it; until it has one the DETAIL
    /// below carries the whole meaning" — and routed it through `axRefused`,
    /// whose sentence opens "the app wouldn't let me set the text". That was
    /// survivable while the only writer had an Accessibility tier to blame.
    /// TextEdit has none, so the sentence would have been a flat lie about an
    /// app that refused nothing: the ambiguity is OURS, and the user is the
    /// only one who can settle it.
    case ambiguousInDocument(count: Int, document: String)
    /// It was written and it does not read back right. The runner reverts;
    /// this says so.
    case verificationFailed(document: String)
    /// THE WRITER'S OWN IN-SESSION GUARD FIRED ON CONTENT: the document's
    /// words changed between the runner's checks and the writer's own —
    /// somebody typed. Distinct from `.documentMoved` (identity) because the
    /// repair is different: same document, try again, no re-pointing needed.
    case raced(document: String)

    public var errorDescription: String? {
        switch self {
        case .documentMoved(let expected, let found):
            if let found, !found.isEmpty {
                return "That passage is in \(expected), and \(found) is what's in front of "
                    + "me now, so I've left them both alone."
            }
            return "That passage is in \(expected), and \(expected) isn't what I can see "
                + "right now, so I've left it alone."
        case .passageGone(let opening, let document):
            // NOT `PassageResolver.driftedSentence`, and the difference is the
            // whole point of the split — see this case's own comment above. The
            // words are in the document; the surface that writes could not reach
            // them, and saying "it isn't in your document any more" about that
            // is both false and the exact claim the prompt doctrine bans.
            return "I could see \"\(opening)\" in \(document) a moment ago, and the way I "
                + "write there couldn't reach it, so nothing has changed."
        case .spanTooLarge(let characters, let limit):
            return "That comes to \(characters) characters, and I won't rewrite more than "
                + "\(limit) on my own. A heading, or the exact words, is enough for me to "
                + "change just that piece."
        case .worldCannotWrite(let place, let why):
            return "I can find it in \(place.displayName), but I can't change it there — \(why)"
        case .axRefused(let detail):
            return "I found it, and the app wouldn't let me set the text — \(detail)"
        case .ambiguousInDocument(let count, let document):
            // A QUESTION, NOT AN ERRAND — `PassageRecipes.noWorldMessage`'s
            // repair, applied here. It states what is ambiguous and what would
            // settle it, and stops; a Skill-invoking model reads an imperative in a
            // Skill result as a thing to go and do.
            return "Those exact words appear \(count) times in \(document), so I've left "
                + "them alone rather than guess which one you meant. The heading above it, "
                + "or a few more words either side, is enough to tell them apart."
        case .verificationFailed(let document):
            return "I made the change and \(document) doesn't read back the way it should, "
                + "so I've put it back the way it was."
        case .raced(let document):
            // A statement, not an errand — the condition and the standing
            // repair, then stop.
            return "You changed \(document) while I was working, so I stopped — "
                + "nothing was written. The same request will land once the "
                + "typing has settled."
        }
    }
}

/// The one thing a world implements to become editable.
public protocol PassageWriter: Sendable {

    /// Find `passageText` in the live document and put `replacement` in its
    /// place.
    ///
    /// THE IMPLEMENTER'S CONTRACT, and it is short because every clause of it
    /// was a bug first:
    ///
    ///   1. RE-LOCATE `passageText` in the string YOUR OWN API just returned.
    ///      Do not use `hint` to address anything. Do not convert an offset
    ///      that arrived from somewhere else into your space.
    ///   2. ACCEPT ONLY AN UNAMBIGUOUS LOCATION. Exactly one occurrence, or
    ///      `hint` picks between identical ones. Anything less certain throws
    ///      `.passageGone` — containment IS the validation.
    ///   3. VERIFY THE DOCUMENT FIRST. `snapshot.documentKey` is the document
    ///      this edit was computed against; if the app is now showing another
    ///      one, throw `.documentMoved` rather than writing to whatever is in
    ///      front of you.
    ///   4. READ BACK if you can, and say in the receipt whether you did.
    ///
    /// `replacement` may be empty (a delete) and may be longer than
    /// `passageText` (an insert) — both arrive here as a substitution, by
    /// design. See `PassageEdit`.
    func replace(
        _ passageText: String,
        with replacement: String,
        hint: Range<Int>,
        in snapshot: BodySnapshot
    ) async throws -> WriteReceipt
}

/// EVERYTHING ONE WORLD SUPPLIES. Three closures and an optional writer — a
/// struct rather than a protocol on purpose: a world's structure reader, its
/// body reader and its writer already live in three different files, and a
/// protocol would force them into one type that has no other reason to exist.
public struct PassageBacking: Sendable {

    /// WHICH PLACE this backing answers for. A place rather than a world since
    /// 2026-08-15: a registered corpus projects onto no built-in world, and a
    /// world-keyed backing is why it could hold containers and ambient facts
    /// and never a passage.
    public var place: AmbientPlace
    /// The document's structure, from its plain body text. Pure and
    /// synchronous — it is a parse, not a read.
    public var units: @Sendable (String) -> [PassageUnit]
    /// The live body of the document IN FRONT, right now. Nil when it cannot
    /// be read at all (the app is not running, the permission is missing,
    /// nothing is open).
    public var body: @Sendable () async -> BodySnapshot?
    /// THE LIVE BODY OF A NAMED DOCUMENT — nil for every world that has only
    /// ever had one.
    ///
    /// ADDED RATHER THAN WIDENING `body`, and the choice is the isolation
    /// guarantee made mechanical. Giving `body` a parameter would have edited
    /// every construction site in Xcode, Pages, Scrivener and four test files
    /// for a capability none of them has — and "the Pages tests still pass
    /// unedited" is the only proof available that a fourth writing world did
    /// not disturb the other three. A world that cannot address a second
    /// document leaves this nil and is bit-identical to what it was.
    ///
    /// TextEdit supplies it because TextEdit alone can: `window id` is a stable
    /// handle its scripting layer publishes, so `text of document of window
    /// id N` reaches a background window with no focus change (measured — a
    /// write landed in window 1406 while Pages was frontmost and TextEdit's own
    /// front window was 1425). Pages has no such handle; `front document` is
    /// the only door it opens.
    ///
    /// The key is `BodySnapshot.documentKey` in that world's own terms, and a
    /// world that does not recognise the key must answer NIL rather than
    /// falling back to the front document. Falling back is how "revise the todo
    /// note" would edit whatever happened to be in front instead — the precise
    /// failure a multi-window world exists to avoid.
    public var bodyForDocument: (@Sendable (String) async -> BodySnapshot?)?
    /// THE HASH OF THE BODY THE PROMPT LAST SHOWED THE MODEL — the watcher's
    /// last published snapshot, nil when the world publishes none (the check
    /// abstains; every other world is bit-identical, `bodyForDocument`'s own
    /// isolation argument).
    ///
    /// This is the stale-recompose tripwire's evidence: a TARGET-resolved
    /// `.replace` recomposes from prose the prompt carried, and the prompt's
    /// snapshot can be a full watcher-window old while labelled fresh. When
    /// this hash and the live snapshot's disagree, the replacement was
    /// composed against words that have since changed — and `minimalChange`
    /// (a two-ended trim, not a diff) would write one span covering the
    /// revision AND everything that changed underneath, silently reverting
    /// the user's own typing with verify confirming it.
    public var promptedBodyHash: (@Sendable () async -> String?)?
    /// Nil = THIS WORLD CANNOT WRITE. Not an oversight and not a TODO: see the
    /// file header, and give `cannotWriteBecause` the evidence.
    public var writer: (any PassageWriter)?
    /// Why not, in the words the refusal will speak. Required in spirit
    /// whenever `writer` is nil — a bare "I can't" is the blank failure this
    /// whole design replaces.
    public var cannotWriteBecause: String?

    public init(
        place: AmbientPlace,
        units: @escaping @Sendable (String) -> [PassageUnit],
        body: @escaping @Sendable () async -> BodySnapshot?,
        bodyForDocument: (@Sendable (String) async -> BodySnapshot?)? = nil,
        promptedBodyHash: (@Sendable () async -> String?)? = nil,
        writer: (any PassageWriter)? = nil,
        cannotWriteBecause: String? = nil
    ) {
        self.place = place
        self.units = units
        self.body = body
        self.bodyForDocument = bodyForDocument
        self.promptedBodyHash = promptedBodyHash
        self.writer = writer
        self.cannotWriteBecause = cannotWriteBecause
    }

    /// THE BODY OF THE DOCUMENT THIS TURN MEANS.
    ///
    /// `key` is the document a handle or a resolver already named; nil means
    /// "whatever is in front", which is every turn in a single-document world
    /// and the abstaining turn in a multi-document one.
    ///
    /// The fallback when a world has no keyed reader is `body()` — correct,
    /// because a world without one has exactly one document and the key can
    /// only ever have named it. The fallback when a world DOES have one is
    /// nothing: it answers nil for a key it does not recognise, and a nil body
    /// is a spoken refusal rather than an edit to the wrong window.
    public func body(for key: String?) async -> BodySnapshot? {
        guard let key, !key.isEmpty, let keyed = bodyForDocument else {
            return await body()
        }
        return await keyed(key)
    }

    /// The built-in spelling, so the three native worlds construct exactly as
    /// they did.
    public init(
        world: AmbientWorld,
        units: @escaping @Sendable (String) -> [PassageUnit],
        body: @escaping @Sendable () async -> BodySnapshot?,
        bodyForDocument: (@Sendable (String) async -> BodySnapshot?)? = nil,
        promptedBodyHash: (@Sendable () async -> String?)? = nil,
        writer: (any PassageWriter)? = nil,
        cannotWriteBecause: String? = nil
    ) {
        self.init(
            place: .lane(world),
            units: units,
            body: body,
            bodyForDocument: bodyForDocument,
            promptedBodyHash: promptedBodyHash,
            writer: writer,
            cannotWriteBecause: cannotWriteBecause)
    }

    public var canWrite: Bool { writer != nil }

    /// The refusal a locate-only world answers with, built from its own
    /// evidence rather than a generic apology.
    public var writeRefusal: PassageWriteError? {
        guard writer == nil else { return nil }
        return .worldCannotWrite(
            place,
            why: cannotWriteBecause ?? "there's no safe way for me to write there yet.")
    }
}
