//
//  PageMapSummary.swift
//  MaryComputerUse
//
//  WHAT: What the page map said about a roster, in Mary's own vocabulary.
//  IN:   VisionPageReader (the seal)  OUT: the browsing lane's listing and receipts
//  PIN:  MARY'S TYPE, NOT VISIONAX'S. Nothing above the seal may name a VisionAX type,
//        and the map is exactly the sort of rich value that would leak one. It is
//        rebuilt here, keyed by the ORDINAL of the row it describes, so a caller holds
//        rows and this side by side without a second identity to keep in step.
//        A GUESS SAYS SO. `labelSource` is the difference between a name the classifier
//        read and a position said out loud, and a caller that cannot tell them apart
//        will offer "button 4" as though somebody had written it there.
//

import CoreGraphics
import Foundation

/// What a row can have done to it.
public enum SeenAffordance: String, Sendable, Equatable, Codable, CaseIterable {
    case press
    case fill
    case adjust
    case scroll
    case none
}

/// Where a row's name came from, weakest last.
public enum SeenLabelSource: String, Sendable, Equatable, Codable, CaseIterable {
    case classifier
    case textInside
    case textAdjacent
    case icon
    case synthesized

    /// Did anything actually name this, or is the name a position?
    public var isReal: Bool { self != .synthesized }
}

/// WHY a row carries the affordance it does, weakest last.
///
/// PIN: THE OTHER HALF OF `labelSource`, AND IT ARRIVES FOR THE SAME REASON. One says how
/// sure the reading is of the row's NAME; this says how sure it is that the row can be
/// acted on at all. "The classifier recognized a button" and "geometry promoted the lead
/// line of a repeated band" are both `.press`, and anything ranking rows has to be able
/// to tell them apart — the second is a guess about layout, the first is a recognition.
public enum SeenAffordanceSource: String, Sendable, Equatable, Codable, CaseIterable {
    /// The model named the role, and the role says what it affords.
    case classifier
    /// Its place in a group said so — the title line of a result row.
    case grouping
    /// Its shape said so — a long thin two-tone run is a track.
    case shape
    case unknown
}

/// One row's extra facts.
public struct SeenElementAnnotation: Sendable, Equatable {
    public var affordance: SeenAffordance
    public var affordanceSource: SeenAffordanceSource
    public var labelSource: SeenLabelSource
    /// A duration badge, a promotion marker — what the page said around the row.
    public var hints: [String]
    public var groupID: Int?
    /// How sure the reading is of this row, 0...1. ZERO IS "NOT SAID", NOT "CERTAINLY
    /// WRONG" — the reader below has not populated it yet, so anything ranking on this
    /// must degrade to neutral at zero rather than treating it as evidence against.
    public var confidence: Double

    public init(
        affordance: SeenAffordance,
        affordanceSource: SeenAffordanceSource = .unknown,
        labelSource: SeenLabelSource,
        hints: [String] = [],
        groupID: Int? = nil,
        confidence: Double = 0
    ) {
        self.affordance = affordance
        self.affordanceSource = affordanceSource
        self.labelSource = labelSource
        self.hints = hints
        self.groupID = groupID
        self.confidence = confidence
    }
}

public struct SeenGroup: Sendable, Equatable {
    public var id: Int
    /// row, card, list, form, toolbar, overlay, band.
    public var kind: String
    public var title: String?
    /// Ordinals of the rows inside it, in reading order.
    public var memberOrdinals: [Int]

    public init(id: Int, kind: String, title: String? = nil, memberOrdinals: [Int] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.memberOrdinals = memberOrdinals
    }
}

public struct PageMapSummary: Sendable, Equatable {
    public var groups: [SeenGroup]
    /// Keyed by the row's ordinal in the reading.
    public var annotations: [Int: SeenElementAnnotation]
    /// How many rows carry a name something actually wrote.
    public var labeledFraction: Double

    public init(
        groups: [SeenGroup] = [], annotations: [Int: SeenElementAnnotation] = [:],
        labeledFraction: Double = 0
    ) {
        self.groups = groups
        self.annotations = annotations
        self.labeledFraction = labeledFraction
    }

    public var isEmpty: Bool { groups.isEmpty && annotations.isEmpty }

    public func annotation(forOrdinal ordinal: Int) -> SeenElementAnnotation? {
        annotations[ordinal]
    }

    /// The dialog covering the page, when one is up. Offered FIRST, because nothing
    /// behind it can be reached while it is there.
    public var overlay: SeenGroup? {
        groups.first { $0.kind == "overlay" }
    }
}
