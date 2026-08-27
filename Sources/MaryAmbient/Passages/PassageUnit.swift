//
//  PassageUnit.swift
//  MaryBrain
//
//  THE STRUCTURE OF A DOCUMENT, said once for every world — a flat list of
//  named spans, produced by each world's own structure reader (`XcodeStructure`
//  over `SwiftSymbolLocator`, `PagesStructure` over `body text`,
//  `ProseStructure` under corpus rules, over a manuscript item's plain text).
//
//  Pure data, and it stays pure data. `PassageWidening` is the only thing that
//  reasons about these, and it is a testable function of (target, body, units)
//  — so a new world becomes "produce this array", never "add a case to the
//  matcher". A per-world matcher is exactly how the Pages read path and the
//  Scrivener read path came to disagree about what "the paragraph" means.
//
//  DELIBERATELY FLAT, not a tree. `level` carries the nesting a heading
//  hierarchy has, but the array is ordered by `range.lowerBound` and nothing
//  reads a parent pointer: containment is a range question, and a range answer
//  cannot go stale the way a rebuilt tree can.
//

import Foundation

/// WHAT KIND of thing a located span is. Decides an edit's separators (a
/// paragraph is surrounded by blank lines; a phrase sits inside a sentence)
/// and the noun the change is spoken with.
public enum PassageUnitKind: String, Sendable, Equatable, CaseIterable {
    /// A whole Swift declaration — `SwiftSymbolLocator`'s span, attributes and
    /// doc comment included.
    case declaration
    /// A heading and everything under it, up to the next heading of the same
    /// or higher level.
    case section
    /// One paragraph of prose.
    case paragraph
    /// A run of words INSIDE a sentence — the only inline kind, and the only
    /// one an edit must not wrap in blank lines.
    case phrase
    /// A bounded slice with no structural meaning of its own: what the user is
    /// looking at, a chunk of a document with no headings, the fallback when a
    /// world can locate but not parse. Named for what it is, so nothing
    /// mistakes it for a paragraph the document actually has.
    case window

    /// Does this kind stand ALONE between blank lines? Everything but
    /// `.phrase`. The one place block-vs-inline is decided, so `PassageEdit`'s
    /// four operations cannot each answer it differently.
    public var isBlock: Bool { self != .phrase }

    /// The noun a report uses for it out loud. `.window` speaks as "passage":
    /// "I replaced the window" would be heard as something about a UI window.
    public var spokenNoun: String {
        switch self {
        case .declaration: return "declaration"
        case .section:     return "section"
        case .paragraph:   return "paragraph"
        case .phrase:      return "phrase"
        case .window:      return "passage"
        }
    }
}

/// One named span of a document.
public struct PassageUnit: Sendable, Equatable {
    /// 0-based, half-open, in `PassageSpace.documentText` — the ONE space.
    public var range: Range<Int>
    /// What it is CALLED: a heading's own text, a symbol's name, "" for a unit
    /// with no name of its own (a bare paragraph). The structural rung of the
    /// widening ladder matches against exactly this.
    public var label: String
    /// Nesting depth — 1 for a top-level heading or a top-level declaration, 2
    /// for one inside it, and so on. 0 for something unnested and unnamed.
    public var level: Int
    public var kind: PassageUnitKind

    public init(range: Range<Int>, label: String = "", level: Int = 0, kind: PassageUnitKind) {
        self.range = range
        self.label = label
        self.level = level
        self.kind = kind
    }

    public var length: Int { range.count }

    /// Does this unit wholly contain `other`? An empty span at a unit's own
    /// upper bound counts as OUTSIDE — an insertion point at the end of a
    /// paragraph belongs to the seam, not to the paragraph, and treating it as
    /// inside is how "insert after this" lands inside the thing it was meant
    /// to follow.
    public func contains(_ other: Range<Int>) -> Bool {
        other.lowerBound >= range.lowerBound
            && other.upperBound <= range.upperBound
            && !(other.isEmpty && other.lowerBound == range.upperBound)
    }
}
