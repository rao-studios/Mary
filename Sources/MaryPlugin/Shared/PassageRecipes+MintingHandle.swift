//
//  PassageRecipes+MintingHandle.swift
//  MaryPlugin
//
//  WHAT: Mint a passage handle from a recipe read.
//  IN:   PassageRecipes.swift (sibling split)
//  OUT:  PassageRegistry

import AppKit
import Foundation

extension PassageRecipes {

    // MARK: - Minting a handle for a READ

    /// One mint site for recipe reads. Nil if the place cannot hold passages or the range is nonsense.
    /// PIN: `body` is the whole document; `range` is measured in that string.
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
        attention: AmbientAttention,
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
            place: .lane(attention),
            documentKey: documentKey,
            documentTitle: documentTitle,
            body: body,
            range: range,
            kind: kind,
            locatorNote: locatorNote,
            registry: registry,
            at: now)
    }

    /// `"[S1] "`, or `""` when nothing was minted. The handle goes at the FRONT of a read's
    /// summary because that summary is the only place the model ever sees it.
    public static func handlePrefix(_ passage: Passage?) -> String {
        guard let passage else { return "" }
        return "[\(passage.handle)] "
    }

}
