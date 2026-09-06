//
//  PagePerceptionPipeline.swift
//  MaryComputerUse
//
//  WHAT: How a page gets perceived — the lane list, and where the second lane joins.
//  IN:   BrowserEngine (never VisionPageReader directly)
//  OUT:  VisionPageReader.Reading
//  PIN:  THE STAGING SEAM. The browser engine asks the PIPELINE, not the reader, so
//        adding accessibility extraction is one enum case and one function body
//        rather than a change at every call site. That indirection is the whole reason
//        this file exists, and it is worth one hop.
//        LANES ARE ORDERED BY EVIDENCE, NOT BY PREFERENCE. When two lanes describe the
//        same rectangle the one with a live element wins, because a row you can press
//        by name outranks a row you can only click at.
//

import AppKit
import CoreGraphics
import Foundation

/// Where a page's elements come from.
public enum PageReaderLane: String, Sendable, Equatable, CaseIterable {
    /// Pixels, through VisionAX. Works on any page in any browser, names nothing it
    /// cannot see, and hands back places to click rather than elements to press.
    case vision

    /// The page's own accessibility tree, walked into rows with live handles.
    ///
    /// PIN: WHAT PIXELS CANNOT ANSWER, AND WHAT THEY ANSWER ALONE. Accessibility
    /// knows a row's ROLE — this is a link, that is a field — and its exact
    /// frame and its live element, so "the first link" is a question with an
    /// answer and pressing it is `AXPress` rather than a click at a guessed
    /// midpoint. MEASURED on one page, both lanes, back to back: the pixel lane
    /// read 108 rows and could offer four of them, naming the page's own menu
    /// "Diew Special" and its heading "1ooked first"; the walk found sixty with
    /// the words their author wrote. What the walk cannot see is a `<canvas>`
    /// player, an image with no description, or anything drawn rather than
    /// marked up — which is the whole reason `vision` is not replaced by it.
    ///
    /// COSTS A WAKE ON A CHROMIUM HOST. See `WebAXWakeup`: until an assistive
    /// client announces itself the walk returns nothing at all, and nothing is
    /// indistinguishable from an empty page.
    case accessibility
}

public enum PagePerceptionPipeline {

    /// Both lanes. What a page read asks for when it wants the page named.
    public static let bothLanes: [PageReaderLane] = [.vision, .accessibility]

    /// Read a page through the lanes given, merged.
    public static func read(
        pid: pid_t,
        windowID: CGWindowID?,
        pageFrame: CGRect,
        intent: VisionPageReader.Intent,
        appName: String,
        windowTitle: String,
        lanes: [PageReaderLane] = bothLanes,
        motionInterval: Duration = .milliseconds(180),
        previousFraction: Double? = nil,
        previousElapsed: TimeInterval? = nil
    ) async throws -> VisionPageReader.Reading {
        // THE PIXEL LANE IS NOT OPTIONAL. A caller that asks for no lane at all
        // gets a refusal rather than a silently empty page.
        guard lanes.contains(.vision) else {
            throw VisionPageReader.Failure.visionUnavailable("no perception lane was requested")
        }
        // THE WALK IS ASKED FOR FIRST AND WAITED FOR IN PARALLEL WITH NOTHING —
        // it is a bounded tree walk against a tree that is already built by the
        // time a second page read happens, and on the first read of a session it
        // is the wake's 2.3 seconds. Both are spent BEFORE the capture rather
        // than after it, so the two lanes describe the same instant of the page
        // as closely as two reads can.
        let walked = lanes.contains(.accessibility) && intent == .elements
            ? await walk(pid: pid, pageFrame: pageFrame)
            : []

        let reading = try await VisionPageReader.read(
            pid: pid,
            windowID: windowID,
            pageFrame: pageFrame,
            intent: intent,
            appName: appName,
            windowTitle: windowTitle,
            motionInterval: motionInterval,
            previousFraction: previousFraction,
            previousElapsed: previousElapsed)

        guard !walked.isEmpty else { return reading }
        return VisionPageReader.sealing(
            reading,
            merged: merge(vision: reading.rows, groups: reading.groups, walked: walked),
            pid: pid, appName: appName, windowTitle: windowTitle)
    }

    /// The page's own tree, woken if the host builds it lazily.
    ///
    /// PIN: A WALK THAT FINDS NOTHING IS NOT AN ERROR AND NOT AN EMPTY PAGE.
    /// Every rung here can honestly answer "no rows" — a host with no web
    /// content, a tree that never woke, a page still loading — and every one of
    /// them leaves the pixel lane as the whole answer, which is what this lane
    /// was added underneath rather than in front of.
    static func walk(pid: pid_t, pageFrame: CGRect) async -> [PageElement] {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let readiness = await BrowserAXReadiness.ensureWebContentAX(
            pid: pid, bundleID: bundleID,
            timeout: BrowserAXReadiness.readSettleTimeout)
        guard readiness.walkable else { return [] }
        let application = AXUIElementCreateApplication(pid)
        return PageElementReader.readWebContent(in: application, pageFrame: pageFrame)
    }

    // MARK: - The merge

    /// How two lanes' rows become one roster.
    ///
    /// PIN: THE WALKED ROW WINS THE RECTANGLE, THE SEEN ROW KEEPS THE PAGE'S
    /// SHAPE. An accessibility element that lands on a vision row replaces its
    /// name, role, kind and affordance — every one of those is a fact where the
    /// pixel lane had a guess — and INHERITS its group and hints, because
    /// grouping is geometry the tree does not publish and a duration badge is
    /// something only the pixels saw. A walked row that lands nowhere is added;
    /// a seen row nothing walked over stays exactly as it was.
    static func merge(
        vision: [PageRow], groups: [PageGroup], walked: [PageElement]
    ) -> (rows: [PageRow], groups: [PageGroup]) {
        var rows = vision
        var claimed = Set<Int>()
        var added: [PageRow] = []

        for element in walked {
            // ONE SEEN ROW PER WALKED ROW, and the best overlap wins it: a link
            // inside a card overlaps both, and replacing the card with the link
            // would lose the card.
            var best: (index: Int, score: Double)?
            let affordance = affordance(of: element)
            for (index, row) in rows.enumerated() where !claimed.contains(index) {
                let score = intersectionOverUnion(row.frame, element.frame)
                // A FIELD INSIDE A FIELD IS ONE FIELD.
                //
                // PIN: MEASURED on an encyclopedia's own search box, which came
                // back twice — the pixel lane drew a box around the magnifier
                // and the words ("Q Search Wikipedia Search"), the walk reported
                // the input itself ("Search Wikipedia") sitting inside it. Their
                // overlap is well under the threshold and their labels differ,
                // so neither this rule nor `collapsingNestedDuplicates` caught
                // them, and "the search box at the top" found two boxes and
                // asked which. Containment plus a SHARED NON-PRESS AFFORDANCE is
                // the safe form of this: a card containing a link is honestly two
                // things a person can point at, and a field containing a field
                // never is.
                let nested = affordance != .press && affordance != .none
                    && row.affordance == affordance
                    && row.frame.contains(element.frame)
                guard score >= sameElementThreshold || nested else { continue }
                let weight = nested ? max(score, sameElementThreshold) : score
                if best == nil || weight > best!.score { best = (index, weight) }
            }
            guard let best else {
                added.append(row(from: element, ordinal: 0, group: nil, hints: []))
                continue
            }
            claimed.insert(best.index)
            let seen = rows[best.index]
            rows[best.index] = row(
                from: element, ordinal: seen.ordinal,
                group: seen.group, hints: seen.hints)
        }

        guard !added.isEmpty || !claimed.isEmpty else { return (vision, groups) }

        // THE SEEN ROWS KEEP THEIR OLD ORDINALS UNTIL THE GROUPS HAVE BEEN
        // MOVED. `rows` is still index-aligned with `vision`, so position is the
        // identity here — a walked row that replaced one carries the label of a
        // different element, and matching on anything but position would lose it.
        let previousOrdinals = rows.map(\.ordinal)
        let order = readingOrder(rows + added)
        var moved: [Int: Int] = [:]
        for (place, source) in order.enumerated() where source < previousOrdinals.count {
            moved[previousOrdinals[source]] = place + 1
        }
        var final: [PageRow] = []
        let combined = rows + added
        for (place, source) in order.enumerated() {
            var row = combined[source]
            row.ordinal = place + 1
            final.append(row)
        }
        // A GROUP NAMES ITS MEMBERS BY ORDINAL, so the table moves with them.
        let regrouped = groups.map { group -> PageGroup in
            var group = group
            group.memberOrdinals = group.memberOrdinals.compactMap { moved[$0] }.sorted()
            return group
        }
        return (RowFactsDerivation.derive(rows: final, groups: regrouped), regrouped)
    }

    /// Reading order over the merged set — vertical band, then left to right —
    /// as positions into the array given. The same rule both lanes already order
    /// by, applied once over the union.
    static func readingOrder(_ rows: [PageRow]) -> [Int] {
        let band = PageElementReader.readingBandHeight
        return rows.indices.sorted { lhs, rhs in
            let a = rows[lhs], b = rows[rhs]
            let aBand = (a.frame.midY / band).rounded(.down)
            let bBand = (b.frame.midY / band).rounded(.down)
            if aBand != bBand { return aBand < bBand }
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            if a.label != b.label { return a.label < b.label }
            return lhs < rhs
        }
    }

    /// A walked element as a row. `ordinal` is assigned by `renumbered`.
    static func row(
        from element: PageElement, ordinal: Int, group: PageGroupRef?, hints: [String]
    ) -> PageRow {
        PageRow(
            ordinal: ordinal,
            frame: element.frame,
            label: element.label,
            // THE PAGE'S AUTHOR WROTE THIS. Not read off the screen, not
            // adjacent, not synthesized — the strongest rung there is.
            labelSource: .classifier,
            affordance: affordance(of: element),
            // THE ROLE SAID SO, which is what `classifier` means on this axis:
            // a recognition rather than a guess about layout.
            affordanceSource: .classifier,
            kind: element.kind,
            role: element.role,
            group: group,
            hints: hints,
            confidence: 1,
            isEnabled: element.isEnabled,
            // WALKED, NOT SEEN. There is an element behind this row to press by
            // name, and the frame is the one its own tree reports.
            provenance: .accessibility)
    }

    /// WHAT THE TREE SAYS CAN BE DONE TO IT, not what its role suggests.
    ///
    /// PIN: `AXPress` IS THE ANSWER FOR PRESSING, and it is the element's own.
    /// A heading and an image are collected because they are the page's WORDS —
    /// a listing and a read want them — and neither is pressable, so neither is
    /// offered. Deriving this from the role instead would offer every heading on
    /// the page as something to click.
    static func affordance(of element: PageElement) -> SeenAffordance {
        switch element.role {
        case "AXTextField", "AXTextArea", "AXComboBox": return .fill
        case "AXSlider": return .adjust
        default:
            return element.availableActions.contains(kAXPressAction as String)
                ? .press : .none
        }
    }

    /// Whether two frames describe the same thing.
    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let overlap = a.intersection(b)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return 0 }
        let intersection = Double(overlap.width * overlap.height)
        let union = Double(a.width * a.height) + Double(b.width * b.height) - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Above this, two lanes are describing the same element.
    static let sameElementThreshold = 0.6
}
