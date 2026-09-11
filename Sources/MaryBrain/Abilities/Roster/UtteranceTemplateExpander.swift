//
//  UtteranceTemplateExpander.swift
//  MaryBrain
//
//  WHAT: One definition of what `{application}` expands to, for every corpus.
//  IN:   the loaded records (which applications point at which Ability)
//  OUT:  the five semantic index builders; the routing fixture suite
//  PIN:  ONE EXPANDER, NOT FIVE. Three index builders read `fixture.utterance`
//        straight into a vectorizer today. If each learned the pragma
//        separately they would drift, and a builder that forgot would embed
//        the literal string "open a new {application} window" — a term no
//        person will ever say, silently poisoning that corpus.
//  PIN:  THE AUTHORED PACKAGE IS NEVER REWRITTEN. Expansion produces strings
//        for corpora; `fixtures` and `triggers` keep their braces, so Studio
//        saves and `mary-package-probe seal` round-trip the TEMPLATE rather
//        than baking today's roster into the file.
//
import Foundation
import MaryFoundation

/// Built once per registry reload, beside the indexes it feeds.
public struct UtteranceTemplateExpander: Sendable {

    /// Ability → the applications it can be pointed at, in roster order.
    private let applicationsByAbility: [AbilityID: [ApplicationAffinity]]

    public init(applicationsByAbility: [AbilityID: [ApplicationAffinity]]) {
        self.applicationsByAbility = applicationsByAbility
    }

    /// Built from the RECORDS, not from a snapshot.
    ///
    /// The corpus builders this feeds run *inside* `AbilityRuntime.Snapshot`'s
    /// own construction, so there is no snapshot to ask yet. It reads the same
    /// two backwards indexes the snapshot does, from the same static builders,
    /// so the two can never disagree about what `{application}` means.
    public init(records: [AbilityPackageRecord]) {
        let expertise = AbilityRuntime.Snapshot.buildExpertiseIndex(records: records)
        let supporting = AbilityRuntime.Snapshot.buildApplicationSupportIndex(
            records: records)
        var affinities: [AbilityID: ApplicationAffinity] = [:]
        for record in records {
            guard let affinity = record.package.applicationAffinities.first
            else { continue }
            affinities[record.package.ability.id] = affinity
        }
        var table: [AbilityID: [ApplicationAffinity]] = [:]
        for ability in Set(expertise.keys).union(supporting.keys) {
            var seen = Set<String>()
            let pointable = ((expertise[ability] ?? []) + (supporting[ability] ?? []))
                .compactMap { affinities[$0] }
                .filter { seen.insert($0.id).inserted }
            guard !pointable.isEmpty else { continue }
            table[ability] = pointable
        }
        self.init(applicationsByAbility: table)
    }

    /// What `{application}` currently means for this Ability. Empty is a real
    /// answer — a package can ship before anything points at it.
    public func applications(for ability: AbilityID) -> [ApplicationAffinity] {
        applicationsByAbility[ability] ?? []
    }

    /// One authored string, as many concrete sentences as the roster supports.
    ///
    /// A string with no slot passes through as itself — the overwhelmingly
    /// common case, and it must cost nothing.
    ///
    /// A TEMPLATE THAT EXPANDS TO NOTHING YIELDS NOTHING, never itself. With
    /// no applications installed, returning the raw text would put the braces
    /// into the corpus, which is the one outcome this type exists to prevent.
    public func expand(_ text: String, for ability: AbilityID) -> [String] {
        guard UtteranceTemplate.hasSlots(text) else { return [text] }
        return applications(for: ability).map {
            UtteranceTemplate.expand(text, application: $0.title)
        }
    }

    /// The same, flattened over many authored strings.
    public func expand(_ texts: [String], for ability: AbilityID) -> [String] {
        texts.flatMap { expand($0, for: ability) }
    }

    /// Each expansion paired with the application that produced it, for callers
    /// that must ASSERT which one a sentence names — the routing fixture suite
    /// checks the resolution, not only the route.
    public func expansions(
        _ text: String, for ability: AbilityID
    ) -> [(utterance: String, application: ApplicationAffinity)] {
        guard UtteranceTemplate.hasSlots(text) else { return [] }
        return applications(for: ability).map {
            (UtteranceTemplate.expand(text, application: $0.title), $0)
        }
    }
}
