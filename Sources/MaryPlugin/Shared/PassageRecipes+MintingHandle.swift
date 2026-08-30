//
//  PassageRecipes+MintingHandle.swift
//

import AppKit
import Foundation

extension PassageRecipes {

    // MARK: - Minting a handle for a READ

    /// THE ONE PLACE A READ MINTS A HANDLE, called by Pages', Xcode's and
    /// Scrivener's own read Skills.
    ///
    /// It exists so that "a read hands back something the edit verbs accept" is
    /// implemented once. The alternative — each plugin assembling a
    /// `PassageRegistry.mint` call — is six chances to key on a title instead
    /// of an identity, or to hash the excerpt instead of the body, and either
    /// mistake produces a handle that resolves to the wrong prose rather than
    /// failing loudly.
    ///
    /// `body` is the WHOLE document and `range` is where the read's text sits
    /// inside it. Both are required and neither can be derived from the other:
    /// the hash has to describe the whole body (that is what `PassageResolver`
    /// compares against) and the range has to be measured in that same string.
    ///
    /// Nil when the place cannot hold passages or the range is nonsense — a
    /// caller that gets nil simply reports its read without a handle, which is
    /// exactly how every read behaved before this existed.
    @discardableResult
    public static func mintRead(
        place: AmbientPlace,
        documentKey: String,
        documentTitle: String,
        body: String,
        range: Range<Int>,
        kind: PassageUnitKind,
        locatorNote: String = "",
        registry: PassageRegistry = .shared,
        at now: Date = Date()
    ) -> Passage? {
        guard !documentKey.isEmpty, !body.isEmpty else { return nil }
        let length = body.count
        guard range.lowerBound >= 0, range.upperBound <= length,
              !range.isEmpty else { return nil }
        return registry.mint(
            place: place,
            documentKey: documentKey,
            documentTitle: documentTitle,
            text: PassageWidening.substring(of: body, range),
            bodyHash: ContentUndoStore.hash(body),
            bodyLength: length,
            range: range,
            unitKind: kind,
            locatorNote: locatorNote,
            provenance: .recipeRead,
            at: now)
    }

    /// The built-in spelling, so Pages', Xcode's and TextEdit's read Skills
    /// mint exactly as they did.
    @discardableResult
    public static func mintRead(
        world: AmbientWorld,
        documentKey: String,
        documentTitle: String,
        body: String,
        range: Range<Int>,
        kind: PassageUnitKind,
        locatorNote: String = "",
        registry: PassageRegistry = .shared,
        at now: Date = Date()
    ) -> Passage? {
        mintRead(
            place: .lane(world),
            documentKey: documentKey,
            documentTitle: documentTitle,
            body: body,
            range: range,
            kind: kind,
            locatorNote: locatorNote,
            registry: registry,
            at: now)
    }

    /// `"[S1] "`, or `""` when nothing was minted.
    ///
    /// The handle goes at the FRONT of a read's summary because that summary is
    /// the only place the model ever sees it. `AmbientBridge.parseBounds`
    /// strips exactly this prefix before reading the document name out of the
    /// same line, so the bounds contract — `Name — characters N–M of T` — is
    /// untouched by it.
    public static func handlePrefix(_ passage: Passage?) -> String {
        guard let passage else { return "" }
        return "[\(passage.handle)] "
    }

}
