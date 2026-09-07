//
//  PageRowRule.swift
//  MaryPlugin
//
//  WHAT: A page read, serialized as embeddable rows — every one the page NAMED, not only
//        the ones it offered.
//  IN:   PageRoster  OUT: AmbientElementIndexStore, for PageRouter and AffordanceProbe
//  PIN:  THE PAGE'S OWN RULESET, BESIDE THE NATIVE WINDOW'S. `AffordanceRule` reads an
//        `AmbientAffordance` and derives what a row can do from its ROLE WORD, which is
//        right for an Accessibility tree that only ever publishes controls. A page is not
//        that: the reading returns everything it could see and says separately, per row,
//        whether it believes the row is actionable. Deriving from the role word threw
//        that judgement away — a field whose kind the classifier could not name was
//        published as a "button" and could never be filled.
//        WHAT WAS NAMED, NOT WHAT WAS OFFERED. Measured: a results page read as 71 rows,
//        65 of them carrying a name something wrote, and 7 marked actionable — the search
//        box, two sign-in buttons and four icons. Publishing only the 7 put every real
//        answer out of reach of meaning entirely, which is why the map's misses used to
//        be unrecoverable. The other 58 arrive as `.candidate`: named, not offered, and
//        never handed to a lane that acts without asking.
//        A SYNTHESIZED NAME IS NOT A NAME. "button 3" is a position; a goal that landed
//        on it would be landing on the reading's own invention, so those rows are not
//        published at all — the router still sees them in the roster and says why.
//        TWO CLAIMS PER ROW, NOT FOUR. Every uncached claim is one embedding, and a page
//        is up to 160 rows where a window is a dozen. The label carries the meaning; the
//        kind sentence carries what a person calls it. The group title is worth reading
//        and not worth a vector, so it is the display summary.
//

import Foundation
import MaryAmbient
import MaryComputerUse

public enum PageRowRule: AmbientElementRuleset {

    /// What a row of this affordance can be asked to do.
    ///
    /// PIN: FROM THE READING'S JUDGEMENT, NEVER FROM THE ROLE WORD. `.fill` is both,
    /// because clicking a field is how a person focuses it and typing is what they came
    /// for — the same reason `AffordanceRule` says so for a native field.
    static func capabilities(
        for affordance: SeenAffordance, isEnabled: Bool
    ) -> AmbientElementCapabilities {
        // A DISABLED CONTROL IS PERCEIVED BUT NOT OFFERED. It keeps its record so a
        // listing can still say it is there, and loses every capability so nothing can
        // try it.
        guard isEnabled else { return [] }
        switch affordance {
        case .press: return [.pressable]
        case .fill: return [.pressable, .fillable]
        case .adjust: return [.adjustable]
        case .scroll: return [.candidate]
        case .none: return [.candidate]
        }
    }

    public static func records(
        for rows: [PageRow], scope: AmbientElementScope
    ) -> [AmbientElementRecord] {
        rows.compactMap { row in
            let label = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, row.isNamed else { return nil }
            let kind = row.kindWord
            return AmbientElementRecord(
                scope: scope,
                elementID: identity(ordinal: row.ordinal),
                kindWord: kind,
                name: label,
                embedTexts: [label.lowercased(), "\(kind) labelled \(label.lowercased())"],
                capabilities: capabilities(
                    for: row.affordance, isEnabled: row.isEnabled),
                displaySummary: row.group?.title ?? label)
        }
    }

    /// The key a row keeps between this publish and the router's lookup.
    ///
    /// PIN: THE ORDINAL, AND ONLY WITHIN ONE READ. The old key was role and name, chosen
    /// so it would survive a re-read — but a results page carries four rows called
    /// "Watch" and one called by the same words as another, and a shared key collapsed
    /// them into a single addressable thing. Nothing needs a key to survive a read: the
    /// slate is replaced wholesale by the read that publishes it, and the router only
    /// ever scores the roster it was handed. Identity across reads is
    /// `PageReceipts.relocate`'s job, by name and place, and it stays there.
    public static func identity(ordinal: Int) -> String { "r\(ordinal)" }

    /// …and back. The slate answers by key; the arbitration scores by ordinal.
    public static func ordinal(fromIdentity identity: String) -> Int? {
        guard identity.hasPrefix("r") else { return nil }
        return Int(identity.dropFirst())
    }
}

/// `PageRow` is spoken-referable, so the naming ladder runs over exactly the
/// rows the router scores rather than over a parallel array that could fall out
/// of step with them.
extension PageRow: SpokenReferable {
    public var spokenLabel: String { label }
    public var spokenKind: PageElementKind? { kind }
    public var spokenRegion: PageRegion? { region }
}
