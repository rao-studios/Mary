//
//  AmbientSelectionEnrichment.swift
//  MaryAmbient
//
//  WHAT: Context a plugin independently verified for an EXISTING source packet.
//  IN:   MaryPlugin adapters, via AmbientContextStore.enrichSelection
//  OUT:  a compare-and-swap merge into the standing AmbientSelectionHandoff
//  PIN:  A PATCH, NOT A PACKET — a strict subset on purpose. It may add document
//        identity and a validated range, never the text, source, or capture time.
//

import MaryFoundation
import Foundation

/// Context a plugin has independently verified for an existing source packet.
/// It may add document identity and a validated body range, but it never
/// changes the selected text, source process, surface, or capture time.
public struct AmbientSelectionEnrichment: Sendable, Equatable {
    /// A more specific scope independently proven for this exact interaction.
    /// `AmbientContextStore` merges it only when its application/process/
    /// surface identity agrees with the raw source packet.
    public var scope: SourceScope?
    public var subject: String?
    public var surroundingText: String?
    /// Bounds in the plugin document's own character coordinate system. They
    /// are never raw AX UTF-16 offsets; `range` keeps those source-local
    /// coordinates separately.
    public var documentBounds: Range<Int>?
    public var documentTotal: Int?
    public var documentTypedRange: TypedRange?

    public init(
        scope: SourceScope? = nil,
        subject: String? = nil,
        surroundingText: String? = nil,
        documentBounds: Range<Int>? = nil,
        documentTotal: Int? = nil,
        documentTypedRange: TypedRange? = nil
    ) {
        self.scope = scope
        self.subject = subject
        self.surroundingText = surroundingText
        self.documentBounds = documentBounds
        self.documentTotal = documentTotal
        self.documentTypedRange = documentTypedRange
    }
}
