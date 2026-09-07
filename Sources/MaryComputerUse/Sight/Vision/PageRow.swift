//
//  PageRow.swift
//  MaryComputerUse
//
//  WHAT: One thing a page offers, in Mary's own vocabulary — the page's row,
//        not an accessibility element wearing one's clothes.
//  IN:   VisionPageReader (the seal)   OUT: the browsing lane, the slate, a bench
//  PIN:  THE PAGE MAP'S SHAPE, NOT THE AX TREE'S. A row used to cross the seal as
//        an `AXScreenElement` with a side-car annotation keyed by ordinal, which
//        forced two things that were both wrong: a ROLE had to be invented for
//        every row (`AXLink` if it looked pressable, `AXStaticText` otherwise) so
//        an AX-shaped type could be filled, and the kind was then re-derived FROM
//        that invented role — a guess laundered into a fact. Everything the map
//        actually knows (what it affords, where its name came from, which group
//        it sits in) rode in the side-car because it did not fit. One type now
//        carries all of it, and `role` is nil unless a classifier really named one.
//        MARY'S TYPE, NOT VISIONAX'S. Nothing above the seal may name a VisionAX
//        type; the map is exactly the rich value that would leak one, so it is
//        rebuilt here with spelled-out conversions.
//        A GUESS SAYS SO. `labelSource` is the difference between a name the page
//        wrote and a position said out loud, and a caller that cannot tell them
//        apart will offer "button 4" as though somebody had written it there.
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
/// PIN: THE OTHER HALF OF `labelSource`, AND IT ARRIVES FOR THE SAME REASON. One
/// says how sure the reading is of the row's NAME; this says how sure it is that
/// the row can be acted on at all. "The classifier recognized a button" and
/// "geometry promoted the lead line of a repeated band" are both `.press`, and
/// anything ranking rows has to tell them apart — the second is a guess about
/// layout, the first is a recognition.
public enum SeenAffordanceSource: String, Sendable, Equatable, Codable, CaseIterable {
    /// The model named the role, and the role says what it affords.
    case classifier
    /// Its place in a group said so — the title line of a result row.
    case grouping
    /// Its shape said so — a long thin two-tone run is a track.
    case shape
    case unknown
}

/// What a run of rows amounts to. Geometry, never a site's markup.
///
/// PIN: TYPED, BECAUSE EIGHT FILES USED TO MATCH THESE AS STRINGS. VisionAX has
/// always had this as an enum; the seal flattened it to `String` and every
/// consumer re-spelled the members by hand — `"toolbar"`, `"form"`, `"band"` —
/// with no compiler anywhere to catch a typo or a member nobody handled.
public enum SeenGroupKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// One horizontal band that reads as a unit — a search result, a table row.
    case row
    /// A picture with its words below or beside it.
    case card
    /// Rows of a shape, repeated. The thing "the third one" counts.
    case list
    /// Fields with their labels, and something to press.
    case form
    /// A run of small controls side by side.
    case toolbar
    /// A box over the page, with the page dimmed behind it.
    case overlay
    /// A horizontal strip that is not any of the above — a header, a footer.
    case band

    /// The kinds a page lays its ANSWERS out in.
    public static let results: Set<SeenGroupKind> = [.row, .card, .list]

    /// The kinds that are the page's own furniture rather than its content.
    public static let furniture: Set<SeenGroupKind> = [.toolbar, .form]
}

/// The group a row sits in, as much of it as a row needs to carry.
public struct PageGroupRef: Sendable, Equatable {
    public var id: Int
    public var kind: SeenGroupKind
    /// The heading above it, when there is one.
    public var title: String?

    public init(id: Int, kind: SeenGroupKind, title: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

/// One group and the rows in it, in reading order.
public struct PageGroup: Sendable, Equatable {
    public var id: Int
    public var kind: SeenGroupKind
    public var title: String?
    /// Ordinals of the rows inside it, in reading order.
    public var memberOrdinals: [Int]

    public init(
        id: Int, kind: SeenGroupKind, title: String? = nil, memberOrdinals: [Int] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.memberOrdinals = memberOrdinals
    }
}

/// One row of a page read.
public struct PageRow: Sendable, Equatable, Identifiable {

    /// The row's place in reading order, 1-based. THE ordinal — the number a
    /// listing speaks and a resolver counts.
    public var ordinal: Int
    public var id: Int { ordinal }

    /// Global, top-left screen points. Projected once, at the seal.
    public var frame: CGRect

    public var label: String
    public var labelSource: SeenLabelSource
    public var affordance: SeenAffordance
    public var affordanceSource: SeenAffordanceSource

    /// What a person would call this — video, link, field. Nil when the reading
    /// named no kind, which is an ordinary state for a row of prose.
    public var kind: PageElementKind?

    /// The accessibility role, ONLY when something really named one.
    ///
    /// PIN: NIL IS THE COMMON CASE AND IT IS HONEST. This used to be synthesized
    /// (`AXLink` when the row looked pressable, `AXStaticText` otherwise) so an
    /// AX-shaped type could be filled — and the kind was then derived back out of
    /// the invention. A row whose role nobody named says so.
    public var role: String?

    public var group: PageGroupRef?

    /// What else the page said around the row: a duration badge, a "sponsored"
    /// marker. Never folded into the label, so a caller can rank on them.
    public var hints: [String]

    /// How sure the reading is of this row, 0...1. ZERO IS "NOT SAID", NOT
    /// "CERTAINLY WRONG" — anything ranking on this must degrade to neutral at
    /// zero rather than treating it as evidence against.
    public var confidence: Double

    public var isEnabled: Bool

    /// What is true of this row, decided once. See `RowFacts`.
    public var facts: RowFacts

    /// WHERE ON THE PAGE IT SITS — the header, a side column, the body itself.
    /// Nil until the seal assigns one; see `PageRegionDerivation`.
    public var region: PageRegion?

    /// Whether this row was SEEN or WALKED — a place to click, or an element to
    /// press by name. The accessibility lane will produce `.accessibility` rows;
    /// today every row is `.seen`.
    public var provenance: AXElementProvenance

    /// THE SITE THIS ROW LEADS TO, as a person would say it — "youtube",
    /// "wikipedia". Nil for a row that is not a link, and for a link within
    /// the page's own site whose address the tree did not publish.
    ///
    /// PIN: THE SITE, NEVER THE ADDRESS. A row's own link is how "watch it on
    /// youtube" tells one result from another, and the whole lane speaks site
    /// names and holds no URLs — so what crosses the seal is the name.
    public var site: String?

    /// An adjustable control's numeric state and range, when the page publishes
    /// them — a slider's value and bounds. A player's progress bar is a slider
    /// whose range is the video's length, which is how a spoken time becomes a
    /// place on the track. Nil for everything that is not a control.
    public var value: Double?
    public var minimumValue: Double?
    public var maximumValue: Double?

    public init(
        ordinal: Int,
        frame: CGRect,
        label: String,
        labelSource: SeenLabelSource = .textInside,
        affordance: SeenAffordance = .none,
        affordanceSource: SeenAffordanceSource = .unknown,
        kind: PageElementKind? = nil,
        role: String? = nil,
        group: PageGroupRef? = nil,
        hints: [String] = [],
        confidence: Double = 0,
        isEnabled: Bool = true,
        facts: RowFacts = [],
        region: PageRegion? = nil,
        provenance: AXElementProvenance = .seen,
        site: String? = nil,
        value: Double? = nil,
        minimumValue: Double? = nil,
        maximumValue: Double? = nil
    ) {
        self.site = site
        self.value = value
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.ordinal = ordinal
        self.frame = frame
        self.label = label
        self.labelSource = labelSource
        self.affordance = affordance
        self.affordanceSource = affordanceSource
        self.kind = kind
        self.role = role
        self.group = group
        self.hints = hints
        self.confidence = confidence
        self.isEnabled = isEnabled
        self.facts = facts
        self.region = region
        self.provenance = provenance
    }

    /// Something wrote this name; the reading did not invent it from a position.
    public var isNamed: Bool { labelSource.isReal && !label.isEmpty }

    /// Can a person do anything with this, or is it only there to be read?
    public var isActionable: Bool { affordance != .none }

    /// The word a person would say for this row's kind.
    ///
    /// PIN: ONE FALLBACK, SAID ONCE. There used to be two — a listing counted an
    /// unkinded row as a `link` while the slate called it `text` — so the number
    /// a listing spoke and the number a resolver counted could disagree about the
    /// same page.
    public var kindWord: String { kind?.spokenWord ?? "text" }
}
