//
//  AbilityRuntimeSnapshot+Expertise.swift
//  MaryBrain
//
//  WHAT: The dependency graph read BACKWARDS — who inherits a discipline.
//  IN:   AbilityRuntimeSnapshot.init (index built once per registry revision)
//  OUT:  ExpertiseResolution / Ability Studio's rehearsal
//  PIN:  DEPENDENCIES ARE AUTHORED FORWARDS AND ASKED BACKWARDS. A package
//        names the discipline it extends (`apple-music` → `multimedia`);
//        routing needs the opposite question — "which player answers a
//        multimedia skill" — and no authored field states it. Inverting the
//        edges is the only way to get it without asking every package to
//        repeat itself, which would drift the moment one of them was wrong.
//        NON-OPTIONAL EDGES ONLY, so an optional support (window-management)
//        never makes an ability look like somebody's player.
//
import MaryFoundation
import Foundation

extension AbilityRuntimeSnapshot {

    /// Application-expertise Abilities whose REQUIRED dependencies name this
    /// discipline. Ordered by the packages' own static preference, then id, so
    /// a cold start with no history is still deterministic across launches
    /// (the same reason `disciplines` sorts).
    public func expertiseAbilities(extending discipline: AbilityID) -> [AbilityID] {
        expertiseByDiscipline[discipline] ?? []
    }

    /// The logical application an expertise drives. `plugin.application.id`
    /// when it carries a Plugin, else its first declared affinity — the same
    /// two sources `applicationAffinities` already joins.
    public func applicationID(ofExpertise abilityID: AbilityID) -> String? {
        guard let package = records.first(where: {
            $0.package.ability.id == abilityID
        })?.package else { return nil }
        return package.applicationAffinities.first?.id
    }

    /// The dependents of a Skill's OWNING ability, and only when that owner is
    /// a discipline. A skill owned by an application-expertise package already
    /// names its application; there is nothing to resolve.
    public func expertiseAbilities(for skill: AbilityRuntimeSkill) -> [AbilityID] {
        guard paradigm(of: skill.ability.id) == .discipline else { return [] }
        return expertiseAbilities(extending: skill.ability.id)
    }

    /// Inverted dependency edges, built once per revision.
    static func buildExpertiseIndex(
        records: [AbilityPackageRecord]
    ) -> [AbilityID: [AbilityID]] {
        // Paradigm per PackageID — `extendedDisciplines` yields package ids and
        // the discipline test has to be answered about the DEPENDENCY, not the
        // dependent.
        var paradigms: [PackageID: AbilityParadigm] = [:]
        var abilityIDs: [PackageID: AbilityID] = [:]
        for record in records {
            paradigms[record.package.package.id] = record.package.paradigm
            abilityIDs[record.package.package.id] = record.package.ability.id
        }
        var index: [AbilityID: [(ability: AbilityID, preference: Int)]] = [:]
        for record in records {
            let package = record.package
            guard package.paradigm == .applicationExpertise else { continue }
            for dependency in package.dependencies where !dependency.optional {
                // Same guard as `abilityTotemTargets`: only a discipline is a
                // thing to inherit. An installed dependency answers from its
                // own record; an absent one cannot be shown to be a discipline
                // and is skipped rather than assumed.
                guard paradigms[dependency.packageID] == .discipline else { continue }
                let discipline = abilityIDs[dependency.packageID]
                    ?? AbilityID(dependency.packageID.rawValue)
                index[discipline, default: []].append((
                    ability: package.ability.id,
                    preference: package.ability.routing.preference))
            }
        }
        return index.mapValues { rows in
            rows.sorted {
                $0.preference != $1.preference
                    ? $0.preference > $1.preference
                    : $0.ability.rawValue < $1.ability.rawValue
            }.map(\.ability)
        }
    }
}
