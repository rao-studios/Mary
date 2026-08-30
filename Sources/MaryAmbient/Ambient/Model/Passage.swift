//
//  Passage.swift
//  MaryBrain
//
//  WHAT: A located piece of a document, named by an opaque handle — what a revision acts on.
//  OUT:  PassageRegistry / PassageEdit. Mary never sees a character offset again.
//  PIN:  Identity is world|documentKey|hash(text).
//

import Foundation

/// THE COORDINATE SPACE a passage's `range` is expressed in. ONE CASE, ON PURPOSE. A
/// one-case enum is not a placeholder for a future second case.
public enum PassageSpace: String, Sendable, Equatable, CaseIterable {
    /// Offsets into the document's plain body text as this process read it:
    /// 0-based, half-open, `String`-index counted (Characters, not UTF-16).
    case documentText
}

/// One located passage. Value semantics on purpose: a `Passage` is a claim about a document
/// at a moment, and `PassageResolver` is what decides whether that claim still holds.
/// Nothing here mutates itself to stay true.
public struct Passage: Sendable, Equatable, Identifiable {

    /// The opaque handle the model holds and passes back — `[S1]`.
    public var handle: String
    /// WHICH PLACE the document lives in. Eyes-bearing only (see `init?`). A REALM AND NOT A
    /// WORLD, since 2026-08-15. It was an `AmbientWorld` while every document Mary could cut a
    /// passage from belonged to a compiled plugin.
    public var place: AmbientPlace
    /// The document's stable identity in its own world's terms — Pages'
    /// `PagesContext.documentIdentity`, Xcode's `BufferSnapshot.path`, Scrivener's
    /// `projectPath#uuid`.
    public var documentKey: String
    /// What to CALL it when speaking. Display only — never an identity.
    public var documentTitle: String
    /// THE IDENTITY, first half: the passage's own words, verbatim.
    public var text: String
    /// THE IDENTITY, second half: `ContentUndoStore.hash` of the WHOLE body this passage was
    /// cut from.
    public var bodyHash: String
    /// How long that body was. Carried so a re-anchor can say how far things
    /// drifted, and so nothing has to re-read a document to sanity-check a
    /// range against its end.
    public var bodyLength: Int
    /// WHERE it sat when it was minted — a HINT for disambiguation, never a write address.
    public var range: Range<Int>
    /// Which space `range` is in. One case; see `PassageSpace`.
    public var space: PassageSpace
    /// What KIND of thing was located — decides an edit's separators and how
    /// the change is spoken about.
    public var unitKind: PassageUnitKind
    /// How it was found, in words, for the report and the debugger: "the section headed
    /// Purpose", "matched on 3 of 4 words you used". Prose, deliberately — an offset in this
    /// field would leak straight back into the speech the read persona already forbids.
    public var locatorNote: String
    public var mintedAt: Date
    /// The freshness claim the passage's WORDS are entitled to make, in the
    /// vocabulary the ambient store already uses, so a passage and the fact
    /// beside it can never claim different ages for the same read.
    public var provenance: AmbientProvenance

    public var id: String { handle }

    /// PLACES WITH EYES ONLY, and failable rather than trusting a comment. A passage is a
    /// located piece of A DOCUMENT THE USER IS WORKING INSIDE.
    public init?(
        handle: String,
        place: AmbientPlace,
        documentKey: String,
        documentTitle: String,
        text: String,
        bodyHash: String,
        bodyLength: Int,
        range: Range<Int>,
        space: PassageSpace = .documentText,
        unitKind: PassageUnitKind,
        locatorNote: String = "",
        mintedAt: Date = Date(),
        provenance: AmbientProvenance
    ) {
        guard Self.canHold(place) else { return nil }
        self.handle = handle
        self.place = place
        self.documentKey = documentKey
        self.documentTitle = documentTitle
        self.text = text
        self.bodyHash = bodyHash
        self.bodyLength = bodyLength
        self.range = range
        self.space = space
        self.unitKind = unitKind
        self.locatorNote = locatorNote
        self.mintedAt = mintedAt
        self.provenance = provenance
    }

    /// Can this place hold passages at all? Bridges to `AmbientPlace.hasEyes` rather than
    /// re-listing the workspace apps. A PLACE.
    public static func canHold(_ place: AmbientPlace) -> Bool { place.hasEyes }

    /// The built-in spelling, kept so every existing caller and pinned test
    /// reads exactly as it did.
    public static func canHold(_ world: AmbientWorld) -> Bool {
        canHold(AmbientPlace.lane(world))
    }

    /// THE IDENTITY KEY minting is idempotent on: `place|documentKey|hash(text)`. Deliberately
    /// NOT including `range`. Re-reading the same paragraph after the user typed a line above
    /// it produces the same words at a different offset, and that is THE SAME PASSAGE.
    public static func identity(
        place: AmbientPlace, documentKey: String, text: String
    ) -> String {
        "\(place.token)|\(documentKey)|\(ContentUndoStore.hash(text))"
    }

    /// The built-in spelling, unchanged byte for byte — `token` IS `rawValue`
    /// for a native place, so no previously minted handle moves.
    public static func identity(
        world: AmbientWorld, documentKey: String, text: String
    ) -> String {
        identity(place: .lane(world), documentKey: documentKey, text: text)
    }

    public var identity: String {
        Self.identity(place: place, documentKey: documentKey, text: text)
    }

    /// The first few words, for a spoken refusal or an edge report. Bounded
    /// because this ends up in a sentence a person hears.
    public func opening(_ limit: Int = 40) -> String {
        let flattened = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(flattened.prefix(limit))
    }
}

/// What a handle the model just used still means. THREE CASES, because two would produce
/// the blank failure this replaces. A handle whose passage was EDITED is not unknown.
public enum PassageResolution: Sendable, Equatable {
    /// Still held, still nameable. Whether the DOCUMENT still matches is
    /// `PassageResolver`'s question, not this one.
    case live(Passage)
    /// Superseded by an edit — the handle that replaced it.
    case superseded(replacedBy: String)
    /// Never minted, or pruned. See `PassageRegistry.retention`: pruning is
    /// keyed to the ambient store's own read window precisely so the prompt
    /// can never show a handle that lands here.
    case unknown
}
