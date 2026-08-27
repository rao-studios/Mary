//
//  AbilityParadigmPresentation.swift
//  Mary
//
//  ONE VOCABULARY FOR "WHAT KIND OF ABILITY IS THIS", shared by every surface
//  that shows one.
//
//  The words and the icon live here rather than at each call site because the
//  alternative already went wrong: `shippingbox.fill` meant DYNAMIC in the
//  transcript chip and NATIVE in Ability Studio, two files apart, so the same
//  glyph told a user opposite things depending on where they looked. A
//  vocabulary that is defined once cannot disagree with itself.
//
//  Paradigm and realization are separate questions and are answered
//  separately. Design and Writing are both disciplines though one waits for
//  dynamic providers and the other binds native plugins; Sketch is
//  application expertise AND package-taught. Collapsing the two axes into one
//  badge is what made "is Sketch a dynamic plugin or an Ability?" feel like a
//  trick question.
//

import MaryFoundation
import SwiftUI

/// How one Ability's role is said and drawn.
struct AbilityParadigmPresentation {
    let paradigm: AbilityParadigm

    init(_ paradigm: AbilityParadigm) {
        self.paradigm = paradigm
    }

    /// The noun, from the schema — never re-worded here, so the package
    /// format and the interface always agree.
    var label: String { paradigm.label }

    /// One sentence for help text and empty states.
    var explanation: String { paradigm.explanation }

    /// DISTINCT GLYPHS, chosen so no two roles share one and none collides
    /// with the generic `shippingbox` that means "an Ability" everywhere.
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

/// HOW an Ability's Skills are implemented — the second axis, kept apart from
/// the role on purpose.
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

    /// `shippingbox.fill` is reserved for the DYNAMIC case across the whole
    /// app: a package-taught plugin arrives in a box. Native code is built in,
    /// so it gets the hammer. These two were previously swapped between the
    /// chip and the Studio.
    var symbol: String {
        switch pluginClass {
        case .runtime: return "hammer.fill"
        case .package: return "shippingbox.fill"
        }
    }

    /// The tiny capsule word for a transcript chip.
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
