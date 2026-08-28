//
//  WebPageText.swift
//  MaryPlugin
//
//  THE PAGE, AS PROSE — what a person would read if they read it aloud.
//
//  The predecessor got this from Safari's scripting dictionary, which vends a
//  tab's rendered `text` in one property. Mary sends no Apple Events, so the
//  text has to be assembled from the page's own accessibility tree instead.
//  That is a downgrade in convenience and an UPGRADE in reach: the scripting
//  road worked in exactly one browser (Chrome's dictionary has no equivalent,
//  and its only page-read channel is `execute javascript` behind a menu
//  toggle), so every Chrome page read came back "I can't read this one."
//  A web area is a web area, so this answers for both.
//
//  MEASURED 2026-08-28 (`mary-web-probe page-text`), macOS 26: the same
//  Wikipedia article read through Safari and through Chrome produced
//  BYTE-IDENTICAL prose — 145 ms and 125 ms respectively, ~35 lines. So this
//  is not a narrower substitute for the channel it replaces; it is the same
//  answer in a browser that never had one.
//
//  WHAT IT COLLECTS, and why the list is short. Static text carries the
//  page's words; headings, links and buttons carry the words a person would
//  say back to you ("click Sign in"); a field's value is what is in the box.
//  Everything else on a page is layout. A collector that took every node's
//  every string would return the same sentence three times — once from the
//  link, once from its inner static text, once from the group wrapping both —
//  which is why a node that HAS a text child does not also contribute its own
//  title. The child is the more specific reading.
//
//  IT IS NOT A READER FOR ACTING ON. `PageElementReader` answers "what can I
//  press", with ordinals, kinds and frames; this answers "what does it say".
//  They walk the same tree and deliberately do not share a result type — a
//  summary that carried press targets would invite acting on a snapshot, and
//  a page reflows.
//
//  BUDGETED TWICE, because the two limits fail differently: the node budget
//  bounds the WALK (a page with fifty thousand nodes must not stall a turn),
//  and the byte budget bounds the ANSWER (a model's context is not a place to
//  put a stylesheet). Truncation is reported, never silent — a summary of the
//  first half of a page, presented as the page, is a wrong answer that looks
//  like a right one.
//

import ApplicationServices
import Foundation

public enum WebPageText {

    /// Roles whose own label is part of what the page SAYS. Anything not
    /// named here contributes only through its descendants.
    static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLink", "AXButton", "AXTextField",
        "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuItem", "AXCell", "AXColumnHeader", "AXRowHeader",
    ]

    /// The walk's own budget. Wider than `AXTreeWalker.Budget.standard`
    /// because this one is deliberately reading a whole page rather than
    /// finding one thing in it — the same reasoning that gives the snapshot
    /// builder a separate web lane.
    public static let budget = AXTreeWalker.Budget(maxDepth: 40, maxNodes: 6000)

    /// What a page read hands back. `truncated` is part of the answer, not a
    /// diagnostic: a caller that summarizes must be able to say "the first
    /// part of the page" when that is what it saw.
    public struct Reading: Sendable, Equatable {
        public var text: String
        public var truncated: Bool
        /// How many nodes carried words. Zero with a web area present is a
        /// real state — a canvas app, or a page whose tree has not filled in
        /// — and is worth telling apart from "no page".
        public var contributingNodes: Int

        public init(text: String, truncated: Bool, contributingNodes: Int) {
            self.text = text
            self.truncated = truncated
            self.contributingNodes = contributingNodes
        }
    }

    /// Read the page under one application's focused-or-main window.
    /// `nil` when there is no web area at all — which the caller must tell
    /// apart from an empty reading, and `BrowserAXReadiness` is how it does.
    public static func read(
        inApp application: AXUIElement,
        byteLimit: Int = 8000
    ) -> Reading? {
        guard let area = WebAreaLocator.firstWebArea(inApp: application) else { return nil }
        return read(webArea: area, byteLimit: byteLimit)
    }

    public static func read(webArea: AXUIElement, byteLimit: Int = 8000) -> Reading {
        readCore(
            from: webArea,
            children: { AX.children($0) },
            role: { AX.string($0, kAXRoleAttribute) },
            text: { element in
                // TITLE, THEN VALUE, THEN DESCRIPTION — and the order is the
                // measured one. Chrome names its controls in description
                // while Safari uses title, and a page's static text carries
                // its words as a VALUE. A single-attribute reader is silently
                // empty in one browser or the other.
                for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                    if let found = AX.string(element, attribute), !found.isEmpty { return found }
                }
                return nil
            },
            byteLimit: byteLimit)
    }

    /// The generic core over any node type, so the collection rules —
    /// deduplication, the parent-defers-to-child rule, both budgets — are
    /// pinned on synthetic trees without a live browser. The same doctrine
    /// `AXTreeWalker.walkCore` and `WebAreaLocator.webAreasCore` follow.
    ///
    /// DEPTH-FIRST, AND THAT IS THE WHOLE REASON IT DOES NOT CALL
    /// `AXTreeWalker.walkCore`. That walk is breadth-first, which is right
    /// for finding one thing (the shallowest match wins, and the budget is
    /// spent near the root where the answer usually is) and wrong for reading
    /// prose: breadth-first returns every heading on the page, then every
    /// paragraph, then every caption — the words of the page in an order the
    /// page never had. A summary built from that is confidently
    /// unintelligible. Document order is depth-first, so this walk is.
    static func readCore<Node>(
        from root: Node,
        children: (Node) -> [Node],
        role: (Node) -> String?,
        text: (Node) -> String?,
        byteLimit: Int
    ) -> Reading {
        var lines: [String] = []
        var seen: Set<String> = []
        var bytes = 0
        var truncated = false
        var visited = 0

        // An explicit stack rather than recursion: a page nests deeply enough
        // that a recursive read is a stack-depth question, and the budget
        // should be the only limit that decides anything here.
        var stack: [(node: Node, depth: Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            visited += 1
            if visited > budget.maxNodes { truncated = true; break }

            let nodeChildren = depth < budget.maxDepth ? children(node) : []
            // Reversed, because popping from the end of the stack would
            // otherwise read every element's children right-to-left — which
            // is document order backwards, and looks like a working reader.
            for child in nodeChildren.reversed() { stack.append((child, depth + 1)) }

            guard let nodeRole = role(node), textRoles.contains(nodeRole) else { continue }

            // A NODE WITH A TEXT CHILD DEFERS TO IT. A link wrapping a static
            // text publishes the same words twice, and the child is the more
            // specific reading. Checked one level down only: that is where
            // the duplication lives, and a deeper search would cost a walk
            // per node to remove nothing.
            let hasTextChild = nodeChildren.contains { child in
                role(child).map(textRoles.contains) == true && text(child)?.isEmpty == false
            }
            guard !hasTextChild else { continue }

            guard let raw = text(node) else { continue }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // A page repeats itself — the same nav label in a header, a
            // footer and a skip link. The reading is what the page SAYS, and
            // it says each of those once.
            guard seen.insert(line).inserted else { continue }

            let cost = line.utf8.count + 1
            guard bytes + cost <= byteLimit else { truncated = true; break }
            bytes += cost
            lines.append(line)
        }

        return Reading(
            text: lines.joined(separator: "\n"),
            truncated: truncated,
            contributingNodes: lines.count)
    }
}
