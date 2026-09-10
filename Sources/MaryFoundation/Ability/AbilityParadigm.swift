//
//  AbilityParadigm.swift
//  MaryFoundation
//
//  WHAT: Role of an Ability — discipline, application expertise, system, reasoning.
//  IN:   AbilitySchema.paradigm (optional) → MaryAbilityPackage.paradigm.
//  OUT:  AbilityPackageValidator+Paradigm, AbilityThreadTarget.
//  PIN:  Declared, not derived: `.systemControl` looks like an underspecified
//        discipline. Validator cross-checks structure.
//

import Foundation

/// Role an Ability plays. Orthogonal to how it is implemented.
public enum AbilityParadigm: String, Codable, Hashable, Sendable, CaseIterable {
    /// Portable craft (design, writing, coding). Skills describe the work, not the app.
    case discipline

    /// Expertise in one application, extending a discipline rather than replacing it.
    case applicationExpertise

    /// Operates the computer (windows, processes, desktop), not a document.
    case systemControl

    /// Planning/analysis. No effectful bindings.
    case reasoning

    /// UI noun.
    public var label: String {
        switch self {
        case .discipline: return "Discipline"
        case .applicationExpertise: return "Application expertise"
        case .systemControl: return "Computer control"
        case .reasoning: return "Reasoning"
        }
    }

    /// Help / empty-state sentence.
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

/// Application an Ability is expert in. Plugin packages also say this via PluginSchema.application.
public struct ApplicationAffinity: Codable, Hashable, Sendable, Identifiable {
    /// Logical id (`pages`). Never a bundle identifier.
    public var id: String
    public var title: String
    /// Exact bundle ids for process recognition. Empty = known by name only.
    public var bundleIdentifiers: [String]

    public init(id: String, title: String, bundleIdentifiers: [String] = []) {
        self.id = id
        self.title = title
        self.bundleIdentifiers = bundleIdentifiers
    }
}

// MARK: - Reading the paradigm off a whole package

extension MaryAbilityPackage {

    /// Declared role, else `derivedParadigm`.
    public var paradigm: AbilityParadigm {
        ability.paradigm ?? derivedParadigm
    }

    /// Package carries a Plugin (data-only recipes). No compiled Swift names an app.
    public var isPluginBearingAbility: Bool {
        plugin != nil
    }

    /// Plugin.application when present, else ability.applications.
    public var applicationAffinities: [ApplicationAffinity] {
        if let plugin = plugin {
            return [ApplicationAffinity(
                id: plugin.application.id,
                title: plugin.application.title,
                bundleIdentifiers: plugin.application.bundleIdentifiers)]
        }
        return ability.applications ?? []
    }

    /// Required dependencies as AbilityIDs. Optional supports (window-management) omitted.
    public var extendedDisciplines: [AbilityID] {
        dependencies.compactMap { dependency in
            guard !dependency.optional else { return nil }
            return AbilityID(dependency.packageID.rawValue)
        }
    }

    /// Thread groups for durable projections: this Ability, plus required discipline deps.
    public func abilityThreadTargets(
        paradigmOfPackage: (PackageID) -> AbilityParadigm?
    ) -> [AbilityThreadTarget] {
        var seen = Set<AbilityThreadTarget>()
        var targets: [AbilityThreadTarget] = []
        func add(_ target: AbilityThreadTarget) {
            if seen.insert(target).inserted {
                targets.append(target)
            }
        }
        add(AbilityThreadTarget(abilityID: ability.id, paradigm: paradigm))
        if paradigm == .applicationExpertise {
            for dependency in dependencies where !dependency.optional {
                guard paradigmOfPackage(dependency.packageID) == .discipline else {
                    continue
                }
                add(AbilityThreadTarget(
                    abilityID: AbilityID(dependency.packageID.rawValue),
                    paradigm: .discipline))
            }
        }
        return targets
    }

    /// Fallback when paradigm is omitted. `.systemControl` is not recoverable from shape.
    public var derivedParadigm: AbilityParadigm {
        // Plugin + bundle ids → application expertise.
        if let plugin = plugin, !plugin.application.bundleIdentifiers.isEmpty {
            return .applicationExpertise
        }
        // Non-empty skills, none binding → reasoning. Empty package stays discipline.
        if !skills.isEmpty, skills.allSatisfy({ $0.execution.kind != .binding }) {
            return .reasoning
        }
        return .discipline
    }
}
