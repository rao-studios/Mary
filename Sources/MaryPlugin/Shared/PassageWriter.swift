//
//  PassageWriter.swift
//  MaryBrain
//
//  WHAT: World seam — one write verb, words to find, not offsets.
//  IN:   PassageEditRunner APPLY  OUT: CodeSurfaceWriter | ProseSurfaceWriter
//  PIN:  hint only breaks identical-occurrence ties. writer: nil is honest refusal.

import Foundation

/// The document body as one read saw it, with the hash everything downstream
/// compares against.
public struct BodySnapshot: Sendable, Equatable {
    public var text: String
    /// `ContentUndoStore.hash(text)`. Computed HERE rather than accepted, so no caller can
    /// hand over a hash that does not describe its own text.
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
    /// `set paragraph N of body text to "…"` — Pages' primary route, where the document the
    /// edit was computed against and the.
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
    /// The body TEXT the writer read back, when the tier could carry it.
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

/// The refusals, SPOKEN. In `XcodeEditError`'s exact style — a sentence a person hears,
/// naming what went wrong and what would work instead.
public enum PassageWriteError: LocalizedError, Equatable {
    /// The document the passage belongs to is not the one in front of us any more.
    case documentMoved(expected: String, found: String?)
    /// The runner re-located this passage in the body a few milliseconds ago (step 4) and
    /// confirmed the body had not moved since (step 6); then the writer looked for the same
    /// words in the string ITS OWN surface can address and did not find them.
    case passageGone(opening: String, document: String)
    /// A widened span above `PassageWidening.maxSpan`.
    case spanTooLarge(characters: Int, limit: Int)
    /// This place can locate but not write. `PassageBacking.writer == nil`.
    case worldCannotWrite(AmbientPlace, why: String)
    /// Accessibility said no — permission, a locked document, a setter the app
    /// does not implement.
    case axRefused(detail: String)
    /// THE WORDS APPEAR MORE THAN ONCE and the hint could not separate them by
    /// `PassageResolver.driftMargin`.
    case ambiguousInDocument(count: Int, document: String)
    /// It was written and it does not read back right. The runner reverts;
    /// this says so.
    case verificationFailed(document: String)
    /// Document words changed between the runner's checks and the writer's own.
    case raced(document: String)
    /// XCODE'S OWN HAZARD, AND THE ONE `.diskWrite` EXISTS TO REFUSE RATHER THAN RISK: the
    /// live buffer holds words the file on disk does not.
    case unsavedChanges(document: String)
    /// The document has never been saved, so its key is not a real path —
    /// there is nowhere on disk yet to write the change.
    case noDiskLocation(document: String)
    /// The write reached the filesystem and failed there — permissions, a
    /// full disk, a path that moved mid-write.
    case diskWriteFailed(document: String, reason: String)

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
            // NOT `PassageResolver.driftedSentence`, and the difference is the whole point
            // of the split — see this case's own comment above.
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
            // A QUESTION, NOT AN ERRAND — `PassageRecipes.noWorldMessage`'s repair, applied
            // here.
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
        case .unsavedChanges(let document):
            return "\(document) has changes in the editor that aren't saved to disk yet, "
                + "so I've left the file alone — once it's saved, I can make this change."
        case .noDiskLocation(let document):
            return "\(document) hasn't been saved to disk yet, so there's nowhere for me "
                + "to write this — once it's saved, I'll be able to."
        case .diskWriteFailed(let document, let reason):
            return "I couldn't write to \(document) — \(reason)."
        }
    }
}

/// The one thing a world implements to become editable.
public protocol PassageWriter: Sendable {

    /// Find `passageText` in the live document and put `replacement` in its place.
    func replace(
        _ passageText: String,
        with replacement: String,
        hint: Range<Int>,
        in snapshot: BodySnapshot
    ) async throws -> WriteReceipt
}

/// EVERYTHING ONE WORLD SUPPLIES. Three closures and an optional writer — a struct rather
/// than a protocol on purpose: a world's structure reader, its.
public struct PassageBacking: Sendable {

    /// WHICH PLACE this backing answers for. A place rather than a world since 2026-08-15:
    /// a registered corpus projects onto no built-in world, and a world-keyed backing is
    /// why it could hold containers and ambient facts and never a passage.
    public var place: AmbientPlace
    /// The document's structure, from its plain body text. Pure and
    /// synchronous — it is a parse, not a read.
    public var units: @Sendable (String) -> [PassageUnit]
    /// The live body of the document IN FRONT, right now. Nil when it cannot
    /// be read at all (the app is not running, the permission is missing,
    /// nothing is open).
    public var body: @Sendable () async -> BodySnapshot?
    /// THE LIVE BODY OF A NAMED DOCUMENT — nil for every world that has only ever had one.
    public var bodyForDocument: (@Sendable (String) async -> BodySnapshot?)?
    /// THE HASH OF THE BODY THE PROMPT LAST SHOWED THE MODEL — the watcher's last published
    /// snapshot, nil when the world publishes none (the.
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

    /// `key` is the document a handle or a resolver already named; nil means "whatever is
    /// in front", which is every turn in a single-document world and the abstaining turn in
    /// a multi-document one.
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
