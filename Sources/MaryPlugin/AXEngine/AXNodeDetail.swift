//
//  AXNodeDetail.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  THE DETAIL LANE'S PUBLISHED SHAPE. The streamed walk pays for eight
//  fields per node and nothing more — that diet is what keeps the wireframe
//  at 60fps, and it is deliberately starved of everything a CLOSE look
//  wants: text content, control values, styled runs. `AXDetailReader` is
//  the lane that pays for those, on demand, for ONE zoomed subtree at a
//  time; these are the value types it publishes. Same doctrine as
//  `AXNodeSnapshot`: plain Sendable values, no `AXUIElement` anywhere —
//  detail decorates ids the snapshot already carries, so a renderer joins
//  the two by `AXNodeID` and never touches AX itself.
//

import CoreGraphics
import Foundation

/// An sRGB color as AX reported it — decoded once at read time so no
/// CoreGraphics color object crosses the seam. A provider color is a claim
/// about the TARGET app's canvas, not Clyde's; presentation decides whether
/// it survives (`AXDetailPresentation.usableForeground`).
public struct AXTextRunColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// One maximal same-styled slice of a text element's content, decoded from
/// the AX text-attribute keys (`AXFont`, `AXForegroundColor`, …) that
/// `kAXAttributedStringForRange` answers with. Every styling field is
/// optional-or-false because every provider omits a different subset —
/// Chromium commonly answers the plain string with no attributes at all.
public struct AXTextRun: Sendable, Equatable {
    public var text: String
    public var fontName: String?
    public var fontFamily: String?
    public var fontSize: Double?
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool
    public var isStrikethrough: Bool
    public var foreground: AXTextRunColor?
    public var background: AXTextRunColor?

    public init(
        text: String,
        fontName: String? = nil,
        fontFamily: String? = nil,
        fontSize: Double? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isStrikethrough: Bool = false,
        foreground: AXTextRunColor? = nil,
        background: AXTextRunColor? = nil
    ) {
        self.text = text
        self.fontName = fontName
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStrikethrough = isStrikethrough
        self.foreground = foreground
        self.background = background
    }
}

/// One node's detail decoration — everything the streamed walk's diet
/// refuses at 60fps. Every field nil/empty means "the provider declined",
/// never "asked and got an answer of nothing"; the reader's diet decides
/// which fields were even asked for (a checkbox is never asked for text
/// runs, a container is never asked for anything).
public struct AXNodeDetail: Sendable, Equatable {
    public var id: AXNodeID
    /// `kAXValue` as a string — static text content, field contents, a
    /// popup's current selection.
    public var textValue: String?
    public var placeholder: String?
    public var help: String?
    public var roleDescription: String?
    public var url: String?
    /// `kAXValue` as a number — slider/progress position, checkbox 0|1|2.
    public var numericValue: Double?
    public var minimumValue: Double?
    public var maximumValue: Double?
    /// `kAXSelected` — rows, cells, tabs.
    public var isSelected: Bool?
    /// `kAXDisclosing` — outline rows and disclosure triangles.
    public var isExpanded: Bool?
    /// Styled slices, in order. Empty when the provider declined the
    /// attributed read — `textValue` is the fallback rung, not a duplicate.
    public var textRuns: [AXTextRun]
    /// True when a text cap trimmed what the element actually holds.
    public var textTruncated: Bool

    public init(
        id: AXNodeID,
        textValue: String? = nil,
        placeholder: String? = nil,
        help: String? = nil,
        roleDescription: String? = nil,
        url: String? = nil,
        numericValue: Double? = nil,
        minimumValue: Double? = nil,
        maximumValue: Double? = nil,
        isSelected: Bool? = nil,
        isExpanded: Bool? = nil,
        textRuns: [AXTextRun] = [],
        textTruncated: Bool = false
    ) {
        self.id = id
        self.textValue = textValue
        self.placeholder = placeholder
        self.help = help
        self.roleDescription = roleDescription
        self.url = url
        self.numericValue = numericValue
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.isSelected = isSelected
        self.isExpanded = isExpanded
        self.textRuns = textRuns
        self.textTruncated = textTruncated
    }

    /// Whether decorating this node yielded anything a renderer could show
    /// beyond what the snapshot already draws.
    public var isEmpty: Bool {
        textValue == nil && placeholder == nil && help == nil
            && roleDescription == nil && url == nil && numericValue == nil
            && minimumValue == nil && maximumValue == nil && isSelected == nil
            && isExpanded == nil && textRuns.isEmpty
    }
}

/// The detail lane's answer for one focused subtree — decorations keyed by
/// the SAME ids the published snapshot carries, so the renderer's existing
/// recursion joins them for free. A node absent from `nodes` either fell
/// outside the budget, vanished between walk and read, or is synthesized
/// (`.scripted`) and has no live element to ask.
public struct AXSubtreeDetail: Sendable, Equatable {
    public var rootID: AXNodeID
    public var nodes: [AXNodeID: AXNodeDetail]
    /// True when `Budget.maxNodes` ended the read before the subtree did.
    public var isTruncated: Bool
    /// Nodes that had a live table entry and were decorated.
    public var nodesRead: Int
    /// Nodes visited but undecoratable — scripted, vanished, or recycled.
    public var nodesSkipped: Int
    public var capturedAt: Date
    public var readDuration: Duration

    public init(
        rootID: AXNodeID,
        nodes: [AXNodeID: AXNodeDetail],
        isTruncated: Bool = false,
        nodesRead: Int = 0,
        nodesSkipped: Int = 0,
        capturedAt: Date = Date(),
        readDuration: Duration = .zero
    ) {
        self.rootID = rootID
        self.nodes = nodes
        self.isTruncated = isTruncated
        self.nodesRead = nodesRead
        self.nodesSkipped = nodesSkipped
        self.capturedAt = capturedAt
        self.readDuration = readDuration
    }
}
