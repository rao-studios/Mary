//
//  AbilityParadigm.swift
//
//  WHAT KIND OF THING AN ABILITY IS — the distinction the package format could
//  not previously express.
//
//  The model, in the author's words: "One can be good in design and an expert
//  in Sketch, while being good in design but an amateur in Figma." Design is a
//  DISCIPLINE — portable craft that outlives any one application. Sketch is
//  EXPERTISE IN ONE TOOL within that discipline: it knows what is unique about
//  the application, and it depends on the discipline rather than replacing it.
//  The two compose; they are not alternatives.
//
//  The structure follows: a discipline package holds portable Skills with no
//  bindings, awaiting a provider; an application package declares
//  `dependencies: [that discipline]`, carries a Plugin bound to one bundle
//  identifier, and realizes the subset Mary's interaction grammar can execute
//  honestly. Naming the role is what lets a view show it and a validator
//  protect it.
//
//  DECLARED, NOT DERIVED — for one specific reason. Three of the four cases
//  ARE recoverable from structure, but "controls the computer" is not:
//  `window-management` announces its nature by the ABSENCE of everything else,
//  which is indistinguishable from a package somebody under-specified. A fact
//  that can only be inferred from a hole is a fact worth stating out loud.
//  Every declaration is then cross-checked against the structure by the
//  validator, so it cannot drift into a comfortable lie.
//

import Foundation

/// The role an Ability plays. One per Ability, and orthogonal to HOW it is
/// implemented — a discipline may wait for a Plugin to realize its Skills or
/// bind a generic adapter directly, and is a discipline either way.
public enum AbilityParadigm: String, Codable, Hashable, Sendable, CaseIterable {
    /// A CRAFT. Portable semantics that outlive any one application — design,
    /// writing, coding. Its Skills describe what the work IS; which
    /// application performs it is somebody else's business.
    case discipline

    /// EXPERTISE IN ONE APPLICATION, extending a discipline. Knows what is
    /// unique about this tool: its vocabulary, visible workflows, and quirks.
    /// An application Ability extends a discipline rather than replacing it.
    case applicationExpertise

    /// OPERATES THE COMPUTER ITSELF rather than a document inside it —
    /// windows, processes, the desktop. Not a craft, and not bound to any one
    /// application's contents.
    case systemControl

    /// THINKS, AND HAS NO HANDS. Planning and analysis with no effectful
    /// bindings at all.
    case reasoning

    /// The noun a person would use, for any surface that shows this.
    public var label: String {
        switch self {
        case .discipline: return "Discipline"
        case .applicationExpertise: return "Application expertise"
        case .systemControl: return "Computer control"
        case .reasoning: return "Reasoning"
        }
    }

    /// One sentence of what the role means, for help text and empty states.
    public var explanation: String {
        switch self {
        case .discipline:
            return "Portable craft that outlives any one application. Other Abilities can teach an application to perform it."
        case .applicationExpertise:
            return "Knows one application's vocabulary, visible workflows, and quirks — and extends a discipline rather than replacing it."
        case .systemControl:
            return "Operates the computer itself: windows, processes, the desktop, rather than the contents of a document."
        case .reasoning:
            return "Plans and analyses. It has no hands and changes nothing on its own."
        }
    }
}

/// AN APPLICATION AN ABILITY IS EXPERT IN, declarable by ANY Ability.
///
/// A plugin-plugin Ability already says this through
/// `PluginSchema.application`. A native one had no way to say it at
/// all: Writing's Pages/Scrivener/TextEdit orientation lived only inside a
/// model-call parameter's `enumValues` and in hardcoded Swift, and Coding's
/// Xcode orientation leaked through `PermissionRequirement.target` — an
/// untyped string that also legitimately holds "active-project". So the
/// question "which Abilities know which applications" could not be asked
/// uniformly. Now it can.
public struct ApplicationAffinity: Codable, Hashable, Sendable, Identifiable {
    /// Logical identity ("pages"), matching a registered application where
    /// one exists. Never a bundle identifier.
    public var id: String
    public var title: String
    /// Exact bundle identities. The authority for recognizing a process;
    /// empty is legal for an application Mary knows only by name.
    public var bundleIdentifiers: [String]

    public init(id: String, title: String, bundleIdentifiers: [String] = []) {
        self.id = id
        self.title = title
        self.bundleIdentifiers = bundleIdentifiers
    }
}

// MARK: - Reading the paradigm off a whole package

extension MaryAbilityPackage {

    /// The role this Ability plays: what it declared, or what its structure
    /// says when it declared nothing.
    public var paradigm: AbilityParadigm {
        ability.paradigm ?? derivedParadigm
    }

    /// True when this Ability teaches Mary one specific application. It does
    /// so through package-carried, data-only recipes and declarations — there
    /// is no other channel, since no compiled Swift in Mary names an
    /// application.
    public var isPluginBearingAbility: Bool {
        plugin != nil
    }

    /// Every application this Ability claims expertise in, from whichever of
    /// the two channels carries it — the Plugin's own application block when
    /// the package brings one, the declared affinities otherwise.
    public var applicationAffinities: [ApplicationAffinity] {
        if let plugin = plugin {
            return [ApplicationAffinity(
                id: plugin.application.id,
                title: plugin.application.title,
                bundleIdentifiers: plugin.application.bundleIdentifiers)]
        }
        return ability.applications ?? []
    }

    /// The disciplines this Ability extends — the "in conjunction" relation,
    /// read from the operating policy that already declares it.
    public var extendedDisciplines: [AbilityID] {
        ability.operatingPolicy.defaultSupportingAbilities
    }

    /// STRUCTURE, WHEN NOTHING WAS DECLARED. Three of the four roles are
    /// legible from shape; `.systemControl` is NOT — a package that operates
    /// the computer looks exactly like a discipline whose author forgot to
    /// say so. That asymmetry is the whole reason the field is declared, and
    /// this fallback exists only so a package written before the field, or by
    /// somebody who did not care, still gets a sensible answer.
    public var derivedParadigm: AbilityParadigm {
        // A plugin bound to an application identity is expertise in it.
        if let plugin = plugin, !plugin.application.bundleIdentifiers.isEmpty {
            return .applicationExpertise
        }
        // Hands or no hands. An Ability with no Skills at all is not
        // "reasoning" — it is a provider carrying only a plugin, already
        // caught above; here it means an empty package, and calling that
        // reasoning would be flattering it.
        if !skills.isEmpty, skills.allSatisfy({ $0.execution.kind != .binding }) {
            return .reasoning
        }
        return .discipline
    }
}
