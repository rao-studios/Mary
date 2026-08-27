//
//  Passage.swift
//  MaryBrain
//
//  A LOCATED PIECE OF A DOCUMENT, named by an opaque handle — the thing a
//  revision acts on. Mary never sees or invents a character offset again.
//
//  THE TWO FAILURES THIS TYPE EXISTS TO PREVENT, both from one live session:
//
//  1. The user, in Pages: "replace the Purpose section with the tighter
//     version." The only write verb in the tree was `type_at_cursor`, so she
//     typed the new prose at the caret and left the Purpose section standing.
//     The user's own diagnosis: "intended for live writing behavior rather
//     than revision behavior."
//  2. Asked to fix it, she was handed `characters 68–916 of 916` in her
//     prompt — `PagesPlugin.regionOutcome` prints it, `AmbientBridge.parseBounds`
//     re-ingests it, `AmbientFact.boundsPhrase` re-renders it under "I know
//     exactly where each one sits" — and NO primitive anywhere accepted an end
//     offset. So she hand-wrote AppleScript against `document 1`, hit the
//     ghost document, and got `-1728 errAENoSuchObject`.
//
//  THE DECISION THAT DISSOLVES BOTH: **a passage's identity is its TEXT plus a
//  BODY HASH, never its integers.** `range` is a DISAMBIGUATION HINT — the
//  answer to "which of the three places these words appear did I mean" — and
//  nothing else. Every write re-locates `text` in whatever coordinate space it
//  can actually write in, so the two live coordinate hazards can never be hit:
//
//    - our bounds are 0-based half-open Swift ranges; AppleScript
//      `character N of body text` is 1-BASED INCLUSIVE. `68..<916` handed
//      straight to AppleScript is off by one at the head and by one at the
//      tail, silently, in a document that happens to be long enough to accept
//      it;
//    - AX offsets (`kAXNumberOfCharacters`, UTF-16, and they COUNT headers,
//      footers and text boxes) are a DIFFERENT SPACE from AppleScript
//      `body text` offsets. `ViewportProvenance.diverged` exists because that
//      disagreement has already been observed in this tree.
//
//  Neither hazard is documented to the model, and neither ever needs to be:
//  the model holds `[S1]`, and the conversion — if a world needs one at all —
//  happens once, locally, at the write site that owns that space.
//

import Foundation

/// THE COORDINATE SPACE a passage's `range` is expressed in.
///
/// ONE CASE, ON PURPOSE. A one-case enum is not a placeholder for a future
/// second case — it is how "there is exactly one coordinate space in this
/// system" becomes a fact the compiler enforces rather than a paragraph in a
/// header that a later writer skims past.
///
/// The two spaces DELIBERATELY NOT REPRESENTABLE here:
///
///   - **AppleScript `character N of body text`** — 1-based, inclusive, and
///     scoped to `body text`, which excludes headers, footers, text boxes and
///     table cells.
///   - **Accessibility offsets** — UTF-16 code units, and they INCLUDE the
///     header/footer/text-box runs that `body text` omits, so the same
///     character has two different numbers depending on who you ask.
///
/// Making them unrepresentable is the point. A world that needs one converts
/// LOCALLY, inside the single function that talks to that API, from the
/// passage's TEXT (via `range(of:)` on the string that API itself just
/// handed back) — never from a number that travelled here from somewhere
/// else. A number that crosses a space boundary is the `-1728`.
public enum PassageSpace: String, Sendable, Equatable, CaseIterable {
    /// Offsets into the document's plain body text as this process read it:
    /// 0-based, half-open, `String`-index counted (Characters, not UTF-16).
    case documentText
}

/// One located passage.
///
/// Value semantics on purpose: a `Passage` is a claim about a document at a
/// moment, and `PassageResolver` is what decides whether that claim still
/// holds. Nothing here mutates itself to stay true.
public struct Passage: Sendable, Equatable, Identifiable {

    /// The opaque handle the model holds and passes back — `[S1]`.
    public var handle: String
    /// WHICH PLACE the document lives in. Eyes-bearing only (see `init?`).
    ///
    /// A REALM AND NOT A WORLD, since 2026-08-15. It was an `AmbientWorld`
    /// while every document Mary could cut a passage from belonged to a
    /// compiled plugin — and that is exactly the assumption a taught
    /// application breaks. A registered corpus rides `.applications` as its host
    /// lane, so a world-typed field would have answered "other apps" for a
    /// manuscript: `canHold` would refuse it (the host lane is eyeless), the
    /// identity key would collide with every other taught application's, and
    /// the write site would look up a backing for the host rather than the
    /// guest. `AmbientRealm.token` is `rawValue` for a native world, so this
    /// is a widening and not a migration — every previously minted native
    /// identity string is byte-identical.
    public var place: AmbientRealm
    /// The document's stable identity in its own world's terms — Pages'
    /// `PagesContext.documentIdentity`, Xcode's `BufferSnapshot.path`,
    /// Scrivener's `projectPath#uuid`. REUSED, never re-invented: a second
    /// spelling of "which document" is how `document 1` and the front window
    /// came to disagree.
    public var documentKey: String
    /// What to CALL it when speaking. Display only — never an identity.
    public var documentTitle: String
    /// THE IDENTITY, first half: the passage's own words, verbatim.
    public var text: String
    /// THE IDENTITY, second half: `ContentUndoStore.hash` of the WHOLE body
    /// this passage was cut from. A match means the document has not moved at
    /// all and `range` is still exactly right; a mismatch sends the resolver
    /// looking for `text` instead of trusting a stale integer.
    public var bodyHash: String
    /// How long that body was. Carried so a re-anchor can say how far things
    /// drifted, and so nothing has to re-read a document to sanity-check a
    /// range against its end.
    public var bodyLength: Int
    /// WHERE it sat when it was minted — a HINT for disambiguation, never an
    /// address to write to. See this file's header.
    public var range: Range<Int>
    /// Which space `range` is in. One case; see `PassageSpace`.
    public var space: PassageSpace
    /// What KIND of thing was located — decides an edit's separators and how
    /// the change is spoken about.
    public var unitKind: PassageUnitKind
    /// How it was found, in words, for the report and the debugger: "the
    /// section headed Purpose", "matched on 3 of 4 words you used". Prose,
    /// deliberately — an offset in this field would leak straight back into
    /// the speech the read persona already forbids.
    public var locatorNote: String
    public var mintedAt: Date
    /// The freshness claim the passage's WORDS are entitled to make, in the
    /// vocabulary the ambient store already uses, so a passage and the fact
    /// beside it can never claim different ages for the same read.
    public var provenance: AmbientProvenance

    public var id: String { handle }

    /// PLACES WITH EYES ONLY, and failable rather than trusting a comment. A
    /// passage is a located piece of A DOCUMENT THE USER IS WORKING INSIDE —
    /// somewhere with a watcher, a live body, and something to write back to.
    /// `.calendar` has no body text, `.typer` is a pair of hands rather than a
    /// place, and a `Passage` over either would be a handle the prompt could
    /// show and no writer could ever satisfy.
    ///
    /// The gate is `hasEyes` — the single spelling of that set, which now
    /// answers for a taught application through its registration as readily as
    /// for a compiled world — and not a fourth list of app names.
    public init?(
        handle: String,
        place: AmbientRealm,
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

    /// Can this place hold passages at all? Bridges to `AmbientRealm.hasEyes`
    /// rather than re-listing the workspace apps.
    ///
    /// A PLACE, because a registered application that earned eyes can hold them
    /// and its host world (`.applications`) cannot. Asking the world would answer
    /// for the host and refuse the guest.
    public static func canHold(_ place: AmbientRealm) -> Bool { place.hasEyes }

    /// The built-in spelling, kept so every existing caller and pinned test
    /// reads exactly as it did.
    public static func canHold(_ world: AmbientWorld) -> Bool {
        canHold(AmbientRealm.world(world))
    }

    /// THE IDENTITY KEY minting is idempotent on: `place|documentKey|hash(text)`.
    ///
    /// Deliberately NOT including `range`. Re-reading the same paragraph after
    /// the user typed a line above it produces the same words at a different
    /// offset, and that is THE SAME PASSAGE — the whole point of identifying by
    /// text. Keying on the range would mint `[P5]` for something the
    /// conversation is already calling `[S1]`, which is the drift the opaque
    /// handle was introduced to end.
    ///
    /// `AmbientRealm.token` and not `memoryToken`: two taught applications must
    /// never share an identity namespace, and `other_apps:manuscripts` is the
    /// spelling that cannot collide with a world's own `rawValue`.
    public static func identity(
        place: AmbientRealm, documentKey: String, text: String
    ) -> String {
        "\(place.token)|\(documentKey)|\(ContentUndoStore.hash(text))"
    }

    /// The built-in spelling, unchanged byte for byte — `token` IS `rawValue`
    /// for a native realm, so no previously minted handle moves.
    public static func identity(
        world: AmbientWorld, documentKey: String, text: String
    ) -> String {
        identity(place: .native(world), documentKey: documentKey, text: text)
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

/// What a handle the model just used still means.
///
/// THREE CASES, because two would produce the blank failure this replaces. A
/// handle whose passage was EDITED is not unknown — Mary knows exactly what
/// happened to it, and "that was [S1]; I replaced it, it's [S4] now" is an
/// answer the conversation can carry on from. "I don't know what [S1] is" is
/// not.
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
