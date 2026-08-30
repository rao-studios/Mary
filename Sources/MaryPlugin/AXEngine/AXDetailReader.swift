//
//  AXDetailReader.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  THE DETAIL LANE — the third budget, alongside the walk's native and web
//  lanes. Where those two answer "what is on screen, at 60fps", this one
//  answers "what does THIS look like, close up" for exactly one zoomed
//  subtree, and pays prices the streamed diet refuses: `kAXValue`, control
//  ranges, and parameterized attributed-string reads for styled text. It is
//  the difference between a wireframe box and an inferred reconstruction of
//  what the box contains — built from Accessibility alone, no screen capture
//  anywhere.
//
//  IT DECORATES, IT DOES NOT WALK. Structure is already published: the
//  reader recurses the `AXNodeSnapshot` subtree it is handed (zero IPC), and
//  the ONLY door to live AX is a `lookup` from `AXNodeID` to element, which
//  the streamer backs with the same `ElementTable` the walk filled. So there
//  is no `children` closure in the source below, and that absence is
//  structural rather than a promise — this lane cannot read a child list
//  even by accident, and cannot disagree with what the renderer draws.
//
//  THE DETAIL DIET is role-FIRST, unlike the walk's category-first one:
//  `AXProgressIndicator`, `AXScrollBar` and friends all fall to `.other`
//  (`AXNodeCategory` maps what Clyde STROKES differently, and those stroke
//  like nothing), yet they are exactly the value-bearing nodes a close look
//  wants. Categories still gate the cheap annotations. A container or an
//  unknown role costs ZERO reads — the counting tests' central claim.
//

import ApplicationServices
import CoreGraphics
import Foundation

public enum AXDetailReader {

    /// The third budget. Detail reads are parameterized IPC — an order of
    /// magnitude dearer than the walk's attribute reads — so this caps the
    /// subtree, the text per node, and the whole payload. `.zoom` is sized
    /// for one focused element at Clyde's throttled cadence; `.probe` for a
    /// one-shot extraction where latency does not matter.
    public struct Budget: Sendable, Equatable {
        /// Nodes visited in the subtree before the read stops.
        public var maxNodes: Int
        /// Characters fetched per text-bearing node.
        public var textCap: Int
        /// Styled runs kept per node; the remainder coalesces unstyled.
        public var runCap: Int
        /// Ceiling across the whole payload, so a page of text areas cannot
        /// multiply `textCap` into megabytes.
        public var totalTextCap: Int

        public init(maxNodes: Int, textCap: Int, runCap: Int, totalTextCap: Int) {
            self.maxNodes = maxNodes
            self.textCap = textCap
            self.runCap = runCap
            self.totalTextCap = totalTextCap
        }

        public static let zoom = Budget(
            maxNodes: 400, textCap: 2048, runCap: 64, totalTextCap: 65_536)
        public static let probe = Budget(
            maxNodes: 2000, textCap: 8192, runCap: 128, totalTextCap: 262_144)
    }

    /// Everything the core needs to decorate one node, injected — the same
    /// pattern (and the same reason) as `AXSnapshotBuilder.AXNodeSource`: a
    /// test counts invocations and pins the diet, proving a container pays
    /// nothing and a secure field is never asked for its contents.
    ///
    /// Note the absence of a `children` closure — see the file header.
    struct AXDetailSource<Node> {
        var role: (Node) -> String?
        var stringValue: (Node) -> String?
        var numberValue: (Node) -> Double?
        var minValue: (Node) -> Double?
        var maxValue: (Node) -> Double?
        var placeholder: (Node) -> String?
        var help: (Node) -> String?
        var roleDescription: (Node) -> String?
        var url: (Node) -> String?
        var isSelected: (Node) -> Bool?
        var isExpanded: (Node) -> Bool?
        var characterCount: (Node) -> Int?
        var visibleRange: (Node) -> Range<Int>?
        var attributedText: (Node, Range<Int>) -> NSAttributedString?
    }

    // MARK: - The diet

    // PUBLIC because a reconstruction has to agree with the diet: a role
    // this lane reads a range for is the one a renderer must draw a track
    // for, and a second hand-written copy of these sets in Clyde is exactly
    // how the two drift apart.

    /// Roles whose contents are text worth reconstructing, beyond the
    /// `.text` category (which covers `AXStaticText`/`AXHeading`).
    public static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]
    /// Roles carrying a position within a range.
    public static let rangeRoles: Set<String> = [
        "AXSlider", "AXProgressIndicator", "AXLevelIndicator", "AXScrollBar",
        "AXIncrementor", "AXValueIndicator",
    ]
    /// Roles whose value is a state, not a magnitude (0 / 1 / 2-mixed).
    public static let toggleRoles: Set<String> = [
        "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle",
    ]
    /// Roles whose value is the CURRENT CHOICE, shown on the control itself.
    public static let popupRoles: Set<String> = ["AXPopUpButton", "AXMenuButton"]
    public static let urlRoles: Set<String> = ["AXLink", "AXImage", "AXWebArea"]
    /// Roles that carry selection/expansion state worth drawing.
    public static let stateRoles: Set<String> = ["AXRow", "AXCell", "AXTab", "AXOutline"]
    /// The role AND subrole spelling of a password field. Real apps expose
    /// role `AXTextField` + THIS subrole, so checking role alone (as the
    /// selection lane's `isSecureField` does) misses the common case — and a
    /// miss here means reading a password into a rendered reconstruction.
    public static let secureFieldRole = "AXSecureTextField"

    /// A node whose contents must never be read, however text-shaped it
    /// looks — public for the same reason as the role sets: the renderer
    /// must draw dots exactly where this refuses to read.
    public static func isSecure(role: String, subrole: String?) -> Bool {
        role == secureFieldRole || subrole == secureFieldRole
    }

    static func isSecure(_ node: AXNodeSnapshot) -> Bool {
        isSecure(role: node.role, subrole: node.subrole)
    }

    static func wantsText(_ node: AXNodeSnapshot) -> Bool {
        guard !isSecure(node) else { return false }
        return node.category == .text || textRoles.contains(node.role)
    }

    // MARK: - The core

    /// Decorate a published subtree. Pre-order, budget-bounded; a node the
    /// `lookup` cannot resolve is SKIPPED, not fatal — its siblings still
    /// decorate, which is what makes a `.scripted` node or one destroyed
    /// between walk and read cost nothing but a count.
    static func readCore<Node>(
        subtree: AXNodeSnapshot,
        lookup: (AXNodeID) -> Node?,
        source: AXDetailSource<Node>,
        budget: Budget,
        isCancelled: () -> Bool = { false }
    ) -> AXSubtreeDetail {
        var nodes: [AXNodeID: AXNodeDetail] = [:]
        var visited = 0
        var truncated = false
        var read = 0
        var skipped = 0
        var textBudgetLeft = budget.totalTextCap

        func visit(_ node: AXNodeSnapshot) {
            guard !truncated, !isCancelled() else { return }
            guard visited < budget.maxNodes else {
                truncated = true
                return
            }
            visited += 1

            if let element = lookup(node.id) {
                let detail = decorate(
                    node, element: element, source: source, budget: budget,
                    textBudgetLeft: &textBudgetLeft)
                read += 1
                if !detail.isEmpty { nodes[node.id] = detail }
            } else {
                skipped += 1
            }

            for child in node.children { visit(child) }
        }

        let clock = ContinuousClock()
        let started = clock.now
        visit(subtree)

        return AXSubtreeDetail(
            rootID: subtree.id,
            nodes: nodes,
            isTruncated: truncated,
            nodesRead: read,
            nodesSkipped: skipped,
            capturedAt: Date(),
            readDuration: clock.now - started)
    }

    /// One node's reads, gated by the diet. Every branch not taken is an
    /// AX round trip not paid for.
    private static func decorate<Node>(
        _ node: AXNodeSnapshot,
        element: Node,
        source: AXDetailSource<Node>,
        budget: Budget,
        textBudgetLeft: inout Int
    ) -> AXNodeDetail {
        var detail = AXNodeDetail(id: node.id)
        let role = node.role

        if wantsText(node) {
            detail.textValue = source.stringValue(element)

            // The attributed read is the expensive one, and it needs a range
            // to ask about. `kAXNumberOfCharacters` is what supplies it —
            // and `AXStaticText` very often declines to answer, which is why
            // the plain value above is fetched FIRST and stands alone as the
            // fallback rung rather than being a duplicate of the runs.
            if textBudgetLeft > 0, let count = source.characterCount(element), count > 0 {
                let cap = min(budget.textCap, textBudgetLeft)
                let visible = source.visibleRange(element)
                let slice = readableRange(count: count, visible: visible, cap: cap)
                if let attributed = source.attributedText(element, slice) {
                    detail.textRuns = AXTextRunParser.runs(from: attributed, runCap: budget.runCap)
                    textBudgetLeft -= slice.count
                }
                detail.textTruncated = slice.count < count
            }
        }

        if rangeRoles.contains(role) {
            detail.numericValue = source.numberValue(element)
            detail.minimumValue = source.minValue(element)
            detail.maximumValue = source.maxValue(element)
        } else if toggleRoles.contains(role) {
            detail.numericValue = source.numberValue(element)
        } else if popupRoles.contains(role) {
            detail.textValue = source.stringValue(element)
        }

        if urlRoles.contains(role) {
            detail.url = source.url(element)
        }

        if stateRoles.contains(role) {
            detail.isSelected = source.isSelected(element)
            detail.isExpanded = source.isExpanded(element)
        }

        // The cheap annotations: a placeholder only where one can exist, and
        // help/role-description only for the categories whose reconstruction
        // has room to show them.
        if textRoles.contains(role), !isSecure(node) {
            detail.placeholder = source.placeholder(element)
        }
        if node.category == .interactive || node.category == .image {
            detail.help = source.help(element)
            detail.roleDescription = source.roleDescription(element)
        }

        return detail
    }

    /// Which characters to ask for. A viewport-aware CENTRED slice, not a
    /// head slice — the lesson `PagesAX+Reads.centred` records: clipping
    /// from the head returns the top of a document while the user is looking
    /// at the middle of it. Falls back to the head of the whole content when
    /// the element reports no visible range.
    static func readableRange(count: Int, visible: Range<Int>?, cap: Int) -> Range<Int> {
        guard cap > 0, count > 0 else { return 0..<0 }
        guard let visible, !visible.isEmpty else {
            return 0..<min(cap, count)
        }
        let clamped = max(0, visible.lowerBound)..<min(count, visible.upperBound)
        guard !clamped.isEmpty else { return 0..<min(cap, count) }
        guard clamped.count > cap else { return clamped }

        let centre = clamped.lowerBound + clamped.count / 2
        var start = centre - cap / 2
        start = max(clamped.lowerBound, min(start, clamped.upperBound - cap))
        return start..<(start + cap)
    }

    /// A cheap re-attachment sanity check. `AXNodeID` is a `CFHash` and can
    /// recycle, so an element resolved from a table filled by an earlier
    /// walk might be a DIFFERENT node that happens to hash the same. Roles
    /// are stable and free to read; a mismatch means the id recycled and the
    /// decoration would be a lie.
    static func plausible(node: AXNodeSnapshot, liveRole: String?) -> Bool {
        guard let liveRole else { return false }
        return liveRole == node.role
    }
}

extension AXDetailReader.AXDetailSource where Node == AXUIElement {

    /// The live specialization: every closure is one AX read, and
    /// `attributedText` is the engine's first parameterized one.
    static var live: Self {
        Self(
            role: { AX.string($0, kAXRoleAttribute) },
            stringValue: { element in
                // A value can arrive as a string or as a number-shaped
                // string (a slider's value read as text); only the string
                // shape is content.
                AX.string(element, kAXValueAttribute).flatMap { $0.isEmpty ? nil : $0 }
            },
            numberValue: { AX.number($0, kAXValueAttribute)?.doubleValue },
            minValue: { AX.number($0, kAXMinValueAttribute)?.doubleValue },
            maxValue: { AX.number($0, kAXMaxValueAttribute)?.doubleValue },
            placeholder: {
                AX.string($0, kAXPlaceholderValueAttribute).flatMap { $0.isEmpty ? nil : $0 }
            },
            help: { AX.string($0, kAXHelpAttribute).flatMap { $0.isEmpty ? nil : $0 } },
            roleDescription: {
                AX.string($0, kAXRoleDescriptionAttribute).flatMap { $0.isEmpty ? nil : $0 }
            },
            url: { element in
                guard let raw = AX.attribute(element, kAXURLAttribute) else { return nil }
                if let url = raw as? URL { return url.absoluteString }
                return raw as? String
            },
            isSelected: { AX.attribute($0, kAXSelectedAttribute) as? Bool },
            isExpanded: { AX.attribute($0, kAXDisclosingAttribute) as? Bool },
            characterCount: { AX.number($0, kAXNumberOfCharactersAttribute)?.intValue },
            visibleRange: { AX.range($0, kAXVisibleCharacterRangeAttribute) },
            attributedText: { AX.attributedString($0, forRange: $1) })
    }
}

extension AXDetailReader {

    /// The live entry. Resolves ids through the walk's own element table,
    /// bounds each element's IPC with a short messaging timeout (a hung
    /// target must not wedge the lane), and refuses outright when the root's
    /// live role no longer matches what was published — an id that recycled
    /// describes some other node now.
    static func read(
        subtree: AXNodeSnapshot,
        table: AXSnapshotBuilder.ElementTable,
        budget: Budget = .zoom,
        isCancelled: () -> Bool = { false }
    ) -> AXSubtreeDetail? {
        let source = AXDetailSource<AXUIElement>.live
        guard let root = table[subtree.id] else { return nil }
        AXUIElementSetMessagingTimeout(root, Float(messagingTimeout))
        guard plausible(node: subtree, liveRole: source.role(root)) else { return nil }

        return readCore(
            subtree: subtree,
            lookup: { id in
                guard let element = table[id] else { return nil }
                AXUIElementSetMessagingTimeout(element, Float(messagingTimeout))
                return element
            },
            source: source,
            budget: budget,
            isCancelled: isCancelled)
    }

    /// Seconds. Long enough for a busy app to answer a parameterized read,
    /// short enough that a wedged one cannot hold the lane for a visible
    /// beat — the same trade `BrowserAXReadiness` settles for its polls.
    static let messagingTimeout: Double = 0.25
}
