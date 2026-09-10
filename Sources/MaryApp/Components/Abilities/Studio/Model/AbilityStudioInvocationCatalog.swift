//
//  AbilityStudioInvocationCatalog.swift
//  Mary
//
//  WHAT: What a recipe step may call — this draft's skills, dependencies,
//        everything installed, then this ability's workflow primitives.
//  IN:   Recipe row autocomplete.
//  OUT:  pure over (draft, snapshot).
//  PIN:  Snapshot invocation lookup is first-wins. A draft name that shadows an
//        installed one is flagged here, because nothing downstream will say so.
//

import MaryBrain
import SwiftUI

struct AbilityStudioInvocationCatalog {

    enum Group: Int, Comparable {
        case thisAbility
        case dependencies
        case installed
        case primitives

        static func < (lhs: Group, rhs: Group) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .thisAbility: return "This ability"
            case .dependencies: return "What it builds on"
            case .installed: return "Everything installed"
            case .primitives: return "Mary's own"
            }
        }
    }

    struct Entry: Identifiable, Hashable {
        let invocation: String
        let title: String
        let summary: String
        let ownerTitle: String
        let ownerTint: String?
        let ownerPackageID: PackageID?
        let group: Group
        let readiness: SkillReadiness?
        let access: SkillAccess?
        let kind: SkillKind?
        /// This draft's name hides an installed one of the same spelling.
        let shadowsInstalled: Bool

        var id: String { "\(group.rawValue)/\(invocation)" }

        /// A recipe may not call something that stops to ask the user.
        var isComposable: Bool { access != .confirm }
    }

    let entries: [Entry]

    init(
        draft: MaryAbilityPackage,
        excludingRecipe recipeID: SkillID?,
        snapshot: AbilityRuntime.Snapshot
    ) {
        var entries: [Entry] = []
        let dependencyIDs = Set(draft.dependencies.map(\.packageID))
        let installedNames = Set(snapshot.skills.compactMap { runtime -> String? in
            guard runtime.packageID != draft.package.id else { return nil }
            return runtime.skill.modelExposure.invocationName
        })

        for skill in draft.skills {
            guard skill.id != recipeID,
                  skill.modelExposure.enabled,
                  let invocation = skill.modelExposure.invocationName
            else { continue }
            entries.append(Entry(
                invocation: invocation,
                title: skill.title,
                summary: skill.summary,
                ownerTitle: draft.ability.title,
                ownerTint: draft.ability.tint,
                ownerPackageID: nil,
                group: .thisAbility,
                readiness: nil,
                access: skill.access,
                kind: skill.kind,
                shadowsInstalled: installedNames.contains(invocation)))
        }

        for runtime in snapshot.skills {
            guard runtime.packageID != draft.package.id,
                  runtime.skill.modelExposure.enabled,
                  let invocation = runtime.skill.modelExposure.invocationName,
                  !AbilityStudioInvocationName.isReserved(invocation)
            else { continue }
            entries.append(Entry(
                invocation: invocation,
                title: runtime.skill.title,
                summary: runtime.skill.summary,
                ownerTitle: runtime.ability.title,
                ownerTint: runtime.ability.tint,
                ownerPackageID: runtime.packageID,
                group: dependencyIDs.contains(runtime.packageID) ? .dependencies : .installed,
                readiness: runtime.availability.readiness,
                access: runtime.skill.access,
                kind: runtime.skill.kind,
                shadowsInstalled: false))
        }

        for primitive in CognitivePrimitiveCatalog.workflowPrimitives(for: draft.ability.id) {
            entries.append(Entry(
                invocation: primitive.operation,
                title: primitive.operation.replacingOccurrences(of: "_", with: " "),
                summary: primitive.summary,
                ownerTitle: "Mary",
                ownerTint: nil,
                ownerPackageID: nil,
                group: .primitives,
                readiness: .ready,
                access: .seamless,
                kind: nil,
                shadowsInstalled: false))
        }

        self.entries = entries.sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            return $0.invocation < $1.invocation
        }
    }

    /// Prefix on the callable name first — that is what the author is typing —
    /// then anything whose words contain the query.
    func matches(_ query: String, limit: Int = 8) -> [Entry] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return Array(entries.prefix(limit)) }

        var prefixed: [Entry] = []
        var contained: [Entry] = []
        for entry in entries {
            if entry.invocation.hasPrefix(needle) {
                prefixed.append(entry)
            } else if entry.invocation.contains(needle)
                        || entry.title.lowercased().contains(needle)
                        || entry.ownerTitle.lowercased().contains(needle) {
                contained.append(entry)
            }
        }
        return Array((prefixed + contained).prefix(limit))
    }

    func entry(for invocation: String) -> Entry? {
        entries.first { $0.invocation == invocation }
    }
}
