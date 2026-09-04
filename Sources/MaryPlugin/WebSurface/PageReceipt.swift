//
//  PageReceipt.swift
//  MaryPlugin
//
//  WHAT: Did that do anything — judged by looking again, and ranked by how sure it is.
//  IN:   the shell and the roster, before and after
//  OUT:  PageCommandReceipt
//  PIN:  A PAGE CHANGES BY ITSELF. Adverts rotate, images arrive late, a clock ticks —
//        so "the rows differ" is the weakest evidence there is and it must not carry
//        `landed`. What can: the browser went somewhere, the thing itself changed, or
//        the text that was typed is now in the field.
//        A TOOLTIP IS NOT AN EFFECT. Something appears under the pointer after almost
//        every click, and counting it makes every click look successful. Boxes that
//        turn up beside the pointer are excluded from the roster diff, which is why the
//        pointer is put back BEFORE the second look for everything except the player.
//

import CoreGraphics
import Foundation
import MaryComputerUse
import MaryFoundation

public enum PageReceipts {

    /// A roster diff smaller than this is noise on any real page.
    public static let rosterChangeFloor = 2
    /// A new box this close to where the click landed is a tooltip.
    public static let tooltipRadius: CGFloat = 40
    /// How much of the typed text must appear before the field is believed.
    public static let typedPrefix = 8

    public struct Look: Sendable {
        public var shell: WebSurfaceAX.Reading?
        public var roster: PageRoster

        public init(shell: WebSurfaceAX.Reading?, roster: PageRoster) {
            self.shell = shell
            self.roster = roster
        }
    }

    /// The evidence for one command, strongest first.
    public static func judge(
        command: PageInteractionPlanCommand,
        before: Look,
        after: Look,
        target: AXScreenElement?,
        clickPoint: CGPoint?,
        typedText: String? = nil
    ) -> PageEffectState {
        // 1 — the browser went somewhere, and stayed.
        if let navigation = navigation(before.shell, after.shell) {
            return .verified(.navigation(title: navigation))
        }

        // 2 — the thing itself.
        if let target, let change = targetChange(target, in: after.roster) {
            return .verified(change)
        }

        // 3 — the words are in the field.
        if let typedText, let target,
           typed(typedText, appearedIn: target, roster: after.roster) {
            return .verified(.textAppeared(in: ScreenElementResolver.shortened(target.label, limit: 40)))
        }

        // 4 — the page is different. A sign, not proof.
        let (added, removed) = difference(
            before.roster, after.roster, ignoringNear: clickPoint)
        if added + removed >= rosterChangeFloor {
            return .weak(.rosterChanged(added: added, removed: removed))
        }
        return .unverified
    }

    /// Did the browser go somewhere and stay there? The caller has already settled.
    public static func navigation(
        _ before: WebSurfaceAX.Reading?, _ after: WebSurfaceAX.Reading?
    ) -> String? {
        guard let after else { return nil }
        guard let before else { return after.title }
        guard after.url != before.url || after.title != before.title else { return nil }
        return after.title ?? after.siteName ?? "a different page"
    }

    /// The row that was acted on, looked up again: changed, or gone.
    static func targetChange(
        _ target: AXScreenElement, in roster: PageRoster
    ) -> PageEffectEvidence? {
        guard let now = relocate(target, in: roster) else {
            return .targetChanged(before: target.label, after: "")
        }
        let was = SpokenReference.normalized(target.label)
        let is_ = SpokenReference.normalized(now.label)
        guard was != is_ else { return nil }
        return .targetChanged(before: target.label, after: now.label)
    }

    /// The same thing, in a fresh reading.
    ///
    /// PIN: BY NAME FIRST, THEN BY PLACE. Ids do not survive a re-read — every reading
    /// builds its own tree — so identity is the label and the role, and where two rows
    /// share both, the one nearest to where it was.
    public static func relocate(
        _ element: AXScreenElement, in roster: PageRoster, overlap: CGFloat = 0.6
    ) -> AXScreenElement? {
        let label = SpokenReference.normalized(element.label)
        let sameName = roster.elements.filter {
            SpokenReference.normalized($0.label) == label && $0.role == element.role
        }
        if sameName.count == 1 { return sameName[0] }
        if !sameName.isEmpty {
            return sameName.max { intersection($0.frame, element.frame) < intersection($1.frame, element.frame) }
        }
        // Nothing by that name: the nearest box that mostly covers where it was.
        return roster.elements
            .filter { intersection($0.frame, element.frame) >= overlap }
            .max { intersection($0.frame, element.frame) < intersection($1.frame, element.frame) }
    }

    static func intersection(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let area = max(a.width * a.height, b.width * b.height)
        guard area > 0 else { return 0 }
        return (overlap.width * overlap.height) / area
    }

    /// Is what was typed now visible where it was typed?
    static func typed(
        _ text: String, appearedIn target: AXScreenElement, roster: PageRoster
    ) -> Bool {
        let wanted = SpokenReference.normalized(text)
        guard wanted.count >= 1 else { return false }
        let prefix = String(wanted.prefix(max(typedPrefix, min(wanted.count, typedPrefix))))
        return roster.elements.contains { row in
            guard row.frame.intersects(target.frame) else { return false }
            return SpokenReference.normalized(row.label).contains(prefix)
        }
    }

    /// How many rows came and went, ignoring anything that appeared under the pointer.
    public static func difference(
        _ before: PageRoster, _ after: PageRoster, ignoringNear point: CGPoint?
    ) -> (added: Int, removed: Int) {
        func identities(_ roster: PageRoster, ignoring point: CGPoint?) -> Set<String> {
            Set(roster.elements.compactMap { row -> String? in
                if let point, row.frame.insetBy(dx: -tooltipRadius, dy: -tooltipRadius)
                    .contains(point) {
                    return nil
                }
                return "\(row.role)|\(SpokenReference.normalized(row.label))"
            })
        }
        let was = identities(before, ignoring: point)
        let now = identities(after, ignoring: point)
        return (added: now.subtracting(was).count, removed: was.subtracting(now).count)
    }
}
