//
//  AXElementRoster.swift
//  MaryAdapter
//
//  WHAT: Nameable things in reading order from an AXAppSnapshot.
//  IN:   AXAppSnapshot  OUT: AXScreenElement list
//  PIN:  Same shape as PageElementReader.publish; constants duplicated —
//        AXEngine must not import Shared/. Windows grouped, then front-to-back.

import CoreGraphics
import Foundation

public enum AXElementRoster {

    /// Which category of node counts as "on offer" for a given question.
    /// Automation wants the things a person can act on; reading a screen
    /// aloud wants its text; a scene description wants everything nameable.
    public enum Scope: String, Sendable, Equatable, CaseIterable {
        /// `.interactive` plus `.scripted` — the scripting sub-engine's grafts are
        /// countable and nameable even though.
        case actionable
        /// `.text` — static text and headings.
        case readable
        /// Everything except `.window` — windows are containers, not
        /// elements a phrase would resolve to.
        case all
    }

    /// Which of a snapshot's windows to enumerate.
    public enum WindowScope: Sendable, Equatable {
        /// The first non-minimized window, in the snapshot's own front-to-back order — the
        /// same "the window is the honest root" doctrine.
        case front
        /// Every non-minimized window, front-to-back.
        case all
    }

    /// What one call publishes. Kept close to the page lane's `publishedLimit` (60) but
    /// roomier: a desktop app's whole front window, with toolbars and a sidebar besides its
    /// content, offers more nameable things than one web area's fold.
    public static let publishedLimit = 120

    /// Vertical tolerance for "same row" when assigning reading order.
    /// Ported from `PageElementReader.readingBandHeight` — see this file's
    /// header for why it is duplicated rather than shared.
    static let readingBandHeight: CGFloat = 24

    /// Ported from `PageElementReader.minimumInteractiveSide`. Below this on
    /// either side, an `.interactive`/`.scripted` element is a chrome
    /// artifact, not something a person points at.
    static let minimumInteractiveSide: CGFloat = 8

    /// Labeled ancestors kept in `containerTrail`, innermost last.
    static let containerTrailLimit = 4

    /// Enumerate one snapshot's elements, in reading order.
    public static func elements(
        in snapshot: AXAppSnapshot,
        scope: Scope = .actionable,
        windows windowScope: WindowScope = .front,
        limit: Int = publishedLimit
    ) -> [AXScreenElement] {
        let visible = snapshot.windows.filter { !$0.isMinimized }
        let selected: [AXWindowSnapshot]
        switch windowScope {
        case .front: selected = Array(visible.prefix(1))
        case .all: selected = visible
        }

        var published: [AXScreenElement] = []
        for window in selected {
            guard let root = window.root else { continue }
            var candidates: [Candidate] = []
            root.forEachNode(withAncestors: { node, ancestors in
                guard included(category: node.category, scope: scope) else { return }
                guard let label = node.label, !label.isEmpty else { return }
                guard let frame = publishableFrame(
                    measured: node.frame, window: window.frame,
                    role: node.role, category: node.category
                ) else { return }
                let trail = ancestors
                    .filter {
                        $0.category == .container || $0.category == .scrollArea
                            || $0.category == .webArea
                    }
                    .compactMap(\.label)
                candidates.append(Candidate(
                    id: node.id, role: node.role, subrole: node.subrole,
                    category: node.category, label: label, frame: frame,
                    isEnabled: node.isEnabled, isFocused: node.isFocused,
                    containerTrail: Array(trail.suffix(containerTrailLimit))))
            })
            let ordered = deduplicated(candidates).sorted(by: precedes)
            published += ordered.map { candidate in
                AXScreenElement(
                    ordinal: 0, // reassigned below, once, over the final list
                    id: candidate.id, pid: snapshot.pid, appName: snapshot.appName,
                    windowID: window.id, windowTitle: window.title,
                    role: candidate.role, subrole: candidate.subrole,
                    category: candidate.category, label: candidate.label,
                    frame: candidate.frame, isEnabled: candidate.isEnabled,
                    isFocused: candidate.isFocused, containerTrail: candidate.containerTrail)
            }
        }

        return published.prefix(limit).enumerated().map { index, element in
            var element = element
            element.ordinal = index + 1
            return element
        }
    }

    // MARK: - Candidates

    struct Candidate {
        var id: AXNodeID
        var role: String
        var subrole: String?
        var category: AXNodeCategory
        var label: String
        var frame: CGRect
        var isEnabled: Bool
        var isFocused: Bool
        var containerTrail: [String]
    }

    static func included(category: AXNodeCategory, scope: Scope) -> Bool {
        switch scope {
        case .actionable: return category == .interactive || category == .scripted
        case .readable: return category == .text
        case .all: return category != .window
        }
    }

    /// The geometry a snapshot's element may publish. Ported from
    /// `PageElementReader.actionableFrame`: nil frame drops ("walked but not placeable",
    /// `AXNodeSnapshot`'s own convention); clip to the window that held it; a range track
    static func publishableFrame(
        measured: CGRect?, window: CGRect?, role: String, category: AXNodeCategory
    ) -> CGRect? {
        guard let measured,
              measured.origin.x.isFinite, measured.origin.y.isFinite,
              measured.width.isFinite, measured.height.isFinite,
              hasActionableSize(measured, role: role, category: category)
        else { return nil }
        guard let window else { return measured }
        guard window.origin.x.isFinite, window.origin.y.isFinite,
              window.width.isFinite, window.height.isFinite,
              window.intersects(measured) else { return nil }
        if role == "AXSlider", !window.contains(measured) { return nil }
        let visible = measured.intersection(window)
        guard !visible.isNull,
              hasActionableSize(visible, role: role, category: category) else { return nil }
        return visible
    }

    /// Ported from `PageElementReader.hasActionableSize`, generalized by category rather
    /// than a fixed role list: `.interactive`/`.scripted` need the 8pt human-sized floor
    /// (with the same AXSlider long/short exception.
    static func hasActionableSize(
        _ frame: CGRect, role: String, category: AXNodeCategory
    ) -> Bool {
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width >= 0, frame.height >= 0 else { return false }
        guard category == .interactive || category == .scripted else {
            return frame.width >= AXHitTest.minimumExtent
                && frame.height >= AXHitTest.minimumExtent
        }
        if role == "AXSlider" {
            return max(frame.width, frame.height) >= minimumInteractiveSide
                && min(frame.width, frame.height) > AXHitTest.minimumExtent
        }
        return frame.width >= minimumInteractiveSide
            && frame.height >= minimumInteractiveSide
    }

    // MARK: - Dedup and ordering

    /// Ported from `PageElementReader.deduplicated`: one thing published once, even when a
    /// container echoes its own interactive child's label (a card whose group and its inner
    /// button share a name).
    static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in candidates {
            let duplicateIndex = kept.firstIndex { existing in
                existing.frame.intersects(candidate.frame)
                    && overlapRatio(existing.frame, candidate.frame) > 0.6
                    && existing.label.caseInsensitiveCompare(candidate.label) == .orderedSame
            }
            guard let duplicateIndex else {
                kept.append(candidate)
                continue
            }
            let existing = kept[duplicateIndex]
            let candidateRank = rank(candidate)
            let existingRank = rank(existing)
            if candidateRank > existingRank {
                kept[duplicateIndex] = candidate
            } else if candidateRank == existingRank {
                let candidateArea = candidate.frame.width * candidate.frame.height
                let existingArea = existing.frame.width * existing.frame.height
                if candidateArea < existingArea { kept[duplicateIndex] = candidate }
            }
        }
        return kept
    }

    /// Which of two overlapping, identically-labeled presentations a person would point at:
    /// the actionable one, over the container that merely carries its name.
    static func rank(_ candidate: Candidate) -> Int {
        switch candidate.category {
        case .interactive: return 2
        case .scripted: return 1
        default: return 0
        }
    }

    /// Ported verbatim from `PageElementReader.overlapRatio`.
    static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smaller > 0 else { return 0 }
        return (intersection.width * intersection.height) / smaller
    }

    /// READING ORDER: band by vertical position, then left-to-right inside the band, then
    /// label as a total-order tiebreak.
    static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let lhsBand = (lhs.frame.midY / readingBandHeight).rounded(.down)
        let rhsBand = (rhs.frame.midY / readingBandHeight).rounded(.down)
        if lhsBand != rhsBand { return lhsBand < rhsBand }
        if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
        return lhs.label < rhs.label
    }
}
