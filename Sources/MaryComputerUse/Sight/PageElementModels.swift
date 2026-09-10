//
//  PageElementModels.swift
//  MaryComputerUse
//
//  WHAT: PageElement and listing shapes.
//  IN:   PageElementReader.swift (sibling split)
//  OUT:  PageElementResolver | PageElementActions

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One interactive thing on a page, as Accessibility describes it.
public struct PageElement: Equatable {
    /// 1-based position in reading order. "The third video" is a filter over
    /// `kind` followed by this.
    public var ordinal: Int
    /// The raw AX role, e.g. `AXLink`.
    public var role: String
    /// The AX subrole when present — Chrome/Safari use it for text-field
    /// flavors and some landmark groups.
    public var subrole: String?
    /// Mary's derived category — see `PageElementKind`. Mechanical, never a
    /// per-site table.
    public var kind: PageElementKind
    /// What the element calls itself, resolved through the label ladder.
    public var label: String
    /// Screen frame. Present for everything published (a zero-size element is
    /// dropped), and re-read immediately before any action — never reused.
    public var frame: CGRect
    /// The destination of a link, when AX exposes one. HELD, NEVER SPOKEN — the browser
    /// lane's URL doctrine applies to page elements exactly as it applies to tabs.
    public var url: String?
    public var isEnabled: Bool
    public var isFocused: Bool
    /// Numeric state for an adjustable control, when AX publishes it as a
    /// number. Text values are deliberately not coerced into a range: a
    /// timestamp-shaped string is a description, not proof of arithmetic.
    public var numericValue: Double?
    /// The inclusive numeric range AX publishes for an adjustable control.
    /// Both bounds must be finite and ordered before an action may use them.
    public var minimumValue: Double?
    public var maximumValue: Double?
    /// Axis along which the control changes, when AX says. `nil` means the
    /// page did not prove an orientation; callers must not guess one from a
    /// site's appearance.
    public var orientation: PageElementOrientation?
    /// Whether AX reported `AXValue` settable during this read. Actions query
    /// it again immediately before setting so this is capability metadata,
    /// never a durable permission.
    public var isValueSettable: Bool
    /// The AX actions this element admits — `AXPress`, `AXShowMenu`, and the
    /// rest. This is how Mary learns that a context menu EXISTS without ever
    /// opening one in front of the user.
    public var availableActions: [String]
    /// `AXHelp` — the tooltip text a sighted user would get by hovering. Same
    /// principle: hover becomes understanding, not a performed gesture.
    public var help: String?
    /// The live node. Valid only for as long as the page holds still; see the
    /// type's own note.
    public var axElement: AXUIElement

    /// Identity is what the element IS, never the handle it happens to have —
    /// two reads of the same page produce different handles for the same
    /// thing.
    public static func == (lhs: PageElement, rhs: PageElement) -> Bool {
        lhs.ordinal == rhs.ordinal && lhs.role == rhs.role
            && lhs.kind == rhs.kind && lhs.label == rhs.label
            && lhs.frame == rhs.frame && lhs.url == rhs.url
    }

    public init(
        ordinal: Int,
        role: String,
        subrole: String? = nil,
        kind: PageElementKind,
        label: String,
        frame: CGRect,
        url: String? = nil,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        numericValue: Double? = nil,
        minimumValue: Double? = nil,
        maximumValue: Double? = nil,
        orientation: PageElementOrientation? = nil,
        isValueSettable: Bool = false,
        availableActions: [String] = [],
        help: String? = nil,
        axElement: AXUIElement
    ) {
        self.ordinal = ordinal
        self.role = role
        self.subrole = subrole
        self.kind = kind
        self.label = label
        self.frame = frame
        self.url = url
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.numericValue = numericValue
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.orientation = orientation
        self.isValueSettable = isValueSettable
        self.availableActions = availableActions
        self.help = help
        self.axElement = axElement
    }

    /// Whether a context menu is available without performing anything.
    public var offersContextMenu: Bool {
        availableActions.contains("AXShowMenu")
    }

    /// Whether pressing is the element's own declared action.
    public var offersPress: Bool {
        availableActions.contains("AXPress")
    }

    /// Whether AX itself offers one bounded step in either direction.
    public var offersIncrement: Bool {
        availableActions.contains("AXIncrement")
    }

    public var offersDecrement: Bool {
        availableActions.contains("AXDecrement")
    }
}

/// The two directions AX assigns to adjustable controls. Optional metadata, rather than a
/// guessed third case, keeps a missing AX orientation distinguishable from a proven
/// horizontal or vertical track.
public enum PageElementOrientation: String, Sendable, Equatable, CaseIterable {
    case horizontal
    case vertical
}

/// Mary's derived category for a page element. DERIVED, NEVER TABULATED.
public enum PageElementKind: String, Sendable, Equatable, CaseIterable {
    case video
    case link
    case button
    case slider
    case field
    case image
    case heading
    case option
    case row

    /// The word a person would say for this kind. The resolution gate matches
    /// spoken phrases against these.
    public var spokenWord: String { rawValue }

    /// Words that admit this kind when the user says them. Kept small and
    /// generic — anything site-specific belongs to the page's own labels,
    /// which the semantic gate already searches.
    public var admittingWords: [String] {
        switch self {
        case .video:   return ["video", "clip", "episode", "movie"]
        case .link:    return ["link", "result", "item", "post"]
        case .button:  return ["button", "control"]
        case .slider:  return ["slider", "range", "timeline", "scrubber"]
        case .field:   return ["field", "box", "input", "search box", "search bar"]
        case .image:   return ["image", "picture", "photo", "thumbnail"]
        case .heading: return ["heading", "title", "section"]
        case .option:  return ["option", "choice", "menu item"]
        case .row:     return ["row", "entry", "cell"]
        }
    }
}

/// "The third video" — the spoken position, parsed. `ReferenceResolver` already owns a
/// spoken-ordinal table, but it answers a different question (which of several PRESENTED
/// CONTAINERS did they mean) and its rule is that a counting ordinal without a live listing
public enum SpokenOrdinal {
    static let words: [String: Int] = [
        "first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3,
        "fourth": 4, "4th": 4, "fifth": 5, "5th": 5, "sixth": 6, "6th": 6,
        "seventh": 7, "7th": 7, "eighth": 8, "8th": 8, "ninth": 9, "9th": 9,
        "tenth": 10, "10th": 10,
    ]

    /// Terminal positions have no number — "the last one" counts from the end.
    public static let lastWords = ["last", "final", "bottom"]

    /// Every word that names a position, for a caller stripping them out.
    public static var allWords: [String] { Array(words.keys) + lastWords }

    /// The 1-based position a phrase names, or nil. Negative one means "last".
    public static func value(in phrase: String) -> Int? {
        let tokens = phrase.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for token in tokens {
            if let value = words[token] { return value }
            if lastWords.contains(token) { return -1 }
        }
        return nil
    }
}
