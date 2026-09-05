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
        for rows: [PageRosterRow], scope: AmbientElementScope
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
                displaySummary: row.groupTitle ?? label)
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
}

/// One row of a page read, flattened out of the roster.
///
/// PIN: FLATTENED ONCE, READ MANY TIMES. The roster keeps rows and their annotations in
/// two structures joined by ordinal, and the router asks five questions of every row for
/// every goal. Doing that join per question was the shape that made the old ladders read
/// `annotation(for:)` in four places and disagree in one of them.
/// IT IS SPOKEN-REFERABLE, so the naming ladder runs over exactly these rows rather than
/// over a parallel array that could fall out of step with them.
public struct PageRosterRow: Sendable, Equatable, SpokenReferable {
    public var ordinal: Int
    public var label: String
    /// Nil when the reading named no kind — a text row, reachable but uncounted.
    public var kind: PageElementKind?
    public var affordance: SeenAffordance
    public var affordanceSource: SeenAffordanceSource
    public var labelSource: SeenLabelSource
    /// A duration badge, a promotion marker.
    public var hints: [String]
    /// How sure the reading is of this row, 0...1. Zero means "not said".
    public var confidence: Double
    public var isEnabled: Bool
    public var groupTitle: String?

    public init(
        ordinal: Int,
        label: String,
        kind: PageElementKind? = nil,
        affordance: SeenAffordance = .none,
        affordanceSource: SeenAffordanceSource = .unknown,
        labelSource: SeenLabelSource = .textInside,
        hints: [String] = [],
        confidence: Double = 0,
        isEnabled: Bool = true,
        groupTitle: String? = nil
    ) {
        self.ordinal = ordinal
        self.label = label
        self.kind = kind
        self.affordance = affordance
        self.affordanceSource = affordanceSource
        self.labelSource = labelSource
        self.hints = hints
        self.confidence = confidence
        self.isEnabled = isEnabled
        self.groupTitle = groupTitle
    }

    /// The word a person would say for this row's kind.
    public var kindWord: String { kind?.spokenWord ?? "text" }

    /// Something wrote this name; the reading did not invent it from a position.
    public var isNamed: Bool { labelSource.isReal && !label.isEmpty }

    public var spokenLabel: String { label }
    public var spokenKind: PageElementKind? { kind }
}

public extension PageRoster {

    /// Every row, flattened for the ruleset and the router — in reading order.
    var rows: [PageRosterRow] {
        elements.map { element in
            let annotation = annotation(for: element)
            return PageRosterRow(
                ordinal: element.ordinal,
                label: element.label,
                kind: element.spokenKind,
                affordance: annotation?.affordance ?? .none,
                affordanceSource: annotation?.affordanceSource ?? .unknown,
                // NO ANNOTATION IS NOT A GUESSED NAME. A row the map said nothing about
                // still carries whatever the reading put in its label, and the fixtures
                // that build rosters by hand rely on that reading the same way.
                labelSource: annotation?.labelSource ?? .textInside,
                hints: annotation?.hints ?? [],
                confidence: annotation?.confidence ?? 0,
                isEnabled: element.isEnabled,
                groupTitle: element.containerTrail.first)
        }
    }
}
