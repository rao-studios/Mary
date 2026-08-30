//
//  AbilityParadigmPresentation.swift
//  Mary
//
//  WHAT: Shared vocabulary for "what kind of Ability" (label, glyph, tint).
//  OUT:  AbilityBadgeRow / Ability Studio / transcript chips
//  PIN:  Paradigm and realization are separate axes. One glyph per role; never `shippingbox`.
//

import MaryFoundation
import SwiftUI

/// How one Ability's role is said and drawn.
struct AbilityParadigmPresentation {
    let paradigm: AbilityParadigm

    init(_ paradigm: AbilityParadigm) {
        self.paradigm = paradigm
    }

    /// Schema noun — never re-worded here.
    var label: String { paradigm.label }

    /// One sentence for help text and empty states.
    var explanation: String { paradigm.explanation }

    /// Distinct glyphs; none is the generic `shippingbox` ("an Ability").
    var symbol: String {
        switch paradigm {
        case .discipline: return "book.closed.fill"
        case .applicationExpertise: return "macwindow.badge.plus"
        case .systemControl: return "desktopcomputer"
        case .reasoning: return "brain"
        }
    }

    /// The short form for a dense row: "Discipline", "Sketch expertise".
    /// Naming the application is the point of the expertise role — "expert in
    /// Sketch" is the claim, not "expert generally".
    func shortLabel(applications: [ApplicationAffinity]) -> String {
        guard paradigm == .applicationExpertise,
              let first = applications.first
        else { return label }
        return "\(first.title) expertise"
    }

    /// The full sentence a row's secondary line carries, including what it
    /// extends — "Sketch expertise · extends Design".
    func detailLabel(
        applications: [ApplicationAffinity],
        extending disciplines: [String]
    ) -> String {
        var parts = [shortLabel(applications: applications)]
        if !disciplines.isEmpty {
            parts.append("extends \(disciplines.map(\.capitalizedFirst).joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }
}

/// How Skills are implemented — second axis, kept apart from role.
struct AbilityRealizationPresentation {
    let pluginClass: PluginProviderClass

    init(_ pluginClass: PluginProviderClass) {
        self.pluginClass = pluginClass
    }

    var label: String {
        switch pluginClass {
        case .runtime: return "Runtime · Built into Mary"
        case .package: return "Package · Taught by an Ability"
        }
    }

    /// `shippingbox.fill` = package-taught. Native is `hammer.fill`.
    var symbol: String {
        switch pluginClass {
        case .runtime: return "hammer.fill"
        case .package: return "shippingbox.fill"
        }
    }

    /// Tiny capsule word for a transcript chip.
    var badgeWord: String {
        switch pluginClass {
        case .runtime: return "BUILT IN"
        case .package: return "ABILITY"
        }
    }

    var help: String {
        switch pluginClass {
        case .runtime:
            return "A Native Plugin compiled into Mary."
        case .package:
            return "A Dynamic Plugin installed by an Ability, not built into Mary."
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
