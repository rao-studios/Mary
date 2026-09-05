//
//  PageMapProjection.swift
//  MaryPlugin
//
//  WHAT: A page read, arranged for someone to LOOK at — rows with frames, names, and
//        what each one can be asked to do.
//  IN:   PageRoster (BrowserEngineSnapshot.lastRoster)
//  OUT:  PageMapRow — what Sand's stage draws over the wireframe
//  PIN:  THE DECIDABLE PART LIVES HERE, NOT IN THE APP. Sand has no test target, so a
//        rule written in its Canvas is a rule nobody can pin. Which rows are worth
//        drawing, what each is called, and what the caption claims are decisions — they
//        belong on this side of the seam. What stays in the view is colour and stroke.
//        NO COLOURS, EITHER. A row carries its `affordance` and lets the view choose;
//        the moment this file names a colour it stops being testable and starts being a
//        second opinion about the theme.
//        A SYNTHESIZED NAME IS NOT A NAME. `isNamed` is false when the reading had to
//        invent one from position, because "(unnamed)" drawn on the page is the single
//        most useful thing this overlay can say about a bad read.
//

import CoreGraphics
import Foundation
import MaryComputerUse

/// One drawable row of a page read, already in the view's coordinates.
public struct PageMapRow: Sendable, Equatable, Identifiable {
    /// The row's ordinal in the reading — the same number the listing spoke.
    public var id: Int
    /// VIEW space, converted through the plane the stage is drawing at.
    public var rect: CGRect
    /// What to write on it. Never empty: an unnamed row still needs a mark.
    public var label: String
    public var affordance: SeenAffordance
    /// Something actually named this row, rather than the reading inventing one.
    public var isNamed: Bool
    /// The group it belongs to — "Results", "toolbar" — or nil.
    public var caption: String?

    public init(
        id: Int, rect: CGRect, label: String, affordance: SeenAffordance,
        isNamed: Bool, caption: String? = nil
    ) {
        self.id = id
        self.rect = rect
        self.label = label
        self.affordance = affordance
        self.isNamed = isNamed
        self.caption = caption
    }
}

/// One thing a phrase could reach on the page as it was last read.
public struct PageOfferLine: Sendable, Equatable, Identifiable {
    /// The slate's own key for the row — role and name, never its position.
    public var id: String
    public var text: String
    public var isEnabled: Bool

    public init(id: String, text: String, isEnabled: Bool) {
        self.id = id
        self.text = text
        self.isEnabled = isEnabled
    }
}

public enum PageMapProjection {

    /// What an unnamed row is called on the stage.
    public static let unnamed = "(unnamed)"

    /// How long a read stays worth drawing. `AffordanceProbe.freshnessHorizon`'s number,
    /// for its reason: past this the page has almost certainly moved and a drawn row is
    /// a claim about a screen that is gone.
    public static let horizon: TimeInterval = AffordanceProbe.freshnessHorizon

    /// The read, as rows to draw over a stage of `size` showing `plane`.
    ///
    /// PIN: EVERY ROW, NOT ONLY THE ACTIONABLE ONES. A page whose rows all read as
    /// `.none` is the failure this overlay exists to make visible, and drawing nothing
    /// would look exactly like a page with nothing on it.
    public static func rows(
        for roster: PageRoster, plane: AXDesktopPlane, size: CGSize
    ) -> [PageMapRow] {
        roster.elements.compactMap { element in
            let rect = plane.viewRect(for: element.frame, in: size)
            // A row the plane places outside the stage, or with no area, cannot be
            // pointed at — and a zero-sized stroke is a dot in the corner.
            guard rect.width > 0, rect.height > 0 else { return nil }
            let annotation = roster.annotation(for: element)
            let named = annotation?.labelSource.isReal ?? !element.label.isEmpty
            return PageMapRow(
                id: element.ordinal,
                rect: rect,
                label: named && !element.label.isEmpty ? element.label : unnamed,
                affordance: annotation?.affordance ?? .none,
                isNamed: named && !element.label.isEmpty,
                caption: element.containerTrail.first)
        }
    }

    /// The rows that BECAME OFFERS — what a phrase can actually reach after this read.
    ///
    /// PIN: DERIVED FROM THE ROSTER, NOT READ BACK OUT OF THE SLATE. The two are written
    /// in one place (`BrowserEngine.publishSlate` / `retractSlate`) and pinned as
    /// agreeing by `BrowserPageTests`, so re-reading the process-wide store here would
    /// buy nothing and would make a debugger's panel depend on whatever else published
    /// last. The gap worth seeing is between the ROWS and the OFFERS — every row the
    /// reading could not name is a row no phrase can reach — and both sides of that are
    /// in the roster.
    public static func offerLines(for roster: PageRoster) -> [PageOfferLine] {
        AffordanceSlatePublisher.affordances(from: roster).map {
            PageOfferLine(
                id: $0.id,
                text: "\($0.ordinal) · \($0.roleWord) · \($0.label)",
                isEnabled: $0.isEnabled)
        }
    }

    /// "12 rows · 9 named · 4s ago" — what the read was, and how long ago, in one line.
    ///
    /// PIN: THE AGE IS THE HALF THAT MATTERS. Everything else on this overlay is a claim
    /// about a photograph; without its age nobody can tell a live page from a page that
    /// closed a minute ago.
    public static func caption(for roster: PageRoster, at now: Date = Date()) -> String {
        let named = roster.elements.filter {
            roster.annotation(for: $0)?.labelSource.isReal ?? false
        }.count
        let age = max(0, now.timeIntervalSince(roster.capturedAt))
        let stale = age > horizon ? " · STALE" : ""
        return "\(roster.elements.count) rows · \(named) named · \(Int(age.rounded()))s ago\(stale)"
    }
}
