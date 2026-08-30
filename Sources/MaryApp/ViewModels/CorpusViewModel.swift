//
//  CorpusViewModel.swift
//  Mary
//
//  WHAT: Corpus pane bridge — 1 Hz poll, one impure gather(), pure build(_:).
//  OUT:  Corpus*View. Equatable diff before republish.
//  PIN:  Live data never through Granite @Store (200 ms debounce).
//

import MaryAmbient
import MaryPlugin
import MaryFoundation
import Foundation

// MARK: - Rows

struct CorpusUnitRow: Identifiable, Equatable {
    var id: String { record.unitKey }
    var record: UnitIndexRecord
    /// Rendered here so the builder decides the pane's sentence.
    var statusLine: String
    var isStale: Bool
}

struct CorpusTenetRow: Identifiable, Equatable {
    var id: String { "\(tenet.tenetKey)|\(tenet.provenance.isAsserted ? "a" : "o")" }
    var tenet: StyleTenet
    /// Mary's own sentence, or nil when this tenet may not speak.
    var sentence: String?
    var evidence: String
    /// The observed tenet this assertion overrides, when they disagree.
    var conflictsWith: StyleTenet?
    var isVetoed: Bool
}

struct CorpusTierSection: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var rows: [CorpusTenetRow]
    /// Scope identity (not re-parsed from `id`).
    var scope: StyleScope?
}

struct CorpusProjectRow: Identifiable, Equatable {
    var id: String
    var name: String
    var unitCount: Int
}

/// One Ability and every schema rung under it (craft → language → apps → projects).
struct CorpusAbilitySection: Identifiable, Equatable {
    var id: String
    var ability: AbilityID
    var title: String
    /// The applications that realize this Ability, observed or not.
    var applications: [String]
    /// Why this card exists — which plugin or package is doing the learning.
    var providedBy: String
    var sections: [CorpusTierSection]
    var tenetCount: Int
    /// No producer yet. Shown so the system's shape is visible while empty.
    var isUnobserved: Bool
}

/// One subject's portable profile, as the bytes the export path produces.
struct CorpusRawProfile: Identifiable, Equatable {
    var id: String { subject }
    var subject: String
    var title: String
    var json: String
    var digest: String?
    var tenetCount: Int
}

@MainActor
final class CorpusViewModel: ObservableObject {

    @Published private(set) var units: [CorpusUnitRow] = []
    @Published private(set) var tiers: [CorpusTierSection] = []
    @Published private(set) var abilities: [CorpusAbilitySection] = []
    @Published private(set) var rawProfiles: [CorpusRawProfile] = []
    /// Carried so the assert picker can ask what a craft may hold without
    /// reaching into the shared registry from a view body.
    @Published private(set) var producers: [StyleProducer] = []
    @Published private(set) var operations: [UnitIndexOperation] = []
    @Published private(set) var projects: [CorpusProjectRow] = []
    @Published private(set) var isIndexingEnabled = true
    @Published var notice: String?

    private var pollTask: Task<Void, Never>?

    struct Inputs {
        var units: [UnitIndexRecord] = []
        var operations: [UnitIndexOperation] = []
        var projects: [(id: String, name: String, unitCount: Int)] = []
        var tenets: [StyleTenet] = []
        var observed: [StyleTenet] = []
        var conflicts: [(asserted: StyleTenet, observed: StyleTenet)] = []
        var vetoed: Set<String> = []
        /// Who learns what. Carried (not a singleton read inside `build`).
        var producers: [StyleProducer] = []
        /// Which applications declare a corpus for which ability. Carried, not read.
        var corpora: [(applicationID: String, ability: AbilityID?, notation: String)] = []
        var selectedProjectID: String?
        var now: Date = Date()
    }

    func start() {
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    var selectedProjectID: String? {
        didSet { if selectedProjectID != oldValue { refresh() } }
    }

    func refresh() {
        let built = Self.build(gather())
        if built.units != units { units = built.units }
        if built.tiers != tiers { tiers = built.tiers }
        if built.abilities != abilities { abilities = built.abilities }
        if built.rawProfiles != rawProfiles { rawProfiles = built.rawProfiles }
        if built.producers != producers { producers = built.producers }
        if built.operations != operations { operations = built.operations }
        if built.projects != projects { projects = built.projects }
    }

    private func gather() -> Inputs {
        let store = StyleEvidenceStore.shared
        let now = Date()
        // One weighted pass shared by tenets / observed / conflicts.
        let observed = store.observedTenets(at: now)
        return Inputs(
            units: UnitIndexLedger.shared.allUnits(),
            operations: UnitIndexLedger.shared.recentOperations(),
            projects: UnitIndexLedger.shared.projects(),
            tenets: store.tenets(observed: observed),
            observed: observed,
            conflicts: store.conflicts(observed: observed),
            vetoed: store.vetoed(),
            producers: StyleProducerRegistry.shared.all(),
            corpora: CorpusSupport.shared.all.map { registration in
                (applicationID: registration.applicationID,
                 ability: AmbientPlace.application(registration.applicationID).ability,
                 notation: registration.schema.notation)
            },
            selectedProjectID: selectedProjectID,
            now: now)
    }

    // MARK: - The pure core

    struct Built: Equatable {
        var units: [CorpusUnitRow] = []
        var tiers: [CorpusTierSection] = []
        var abilities: [CorpusAbilitySection] = []
        var rawProfiles: [CorpusRawProfile] = []
        var producers: [StyleProducer] = []
        var operations: [UnitIndexOperation] = []
        var projects: [CorpusProjectRow] = []
    }

    nonisolated static func build(_ inputs: Inputs) -> Built {
        var built = Built()
        built.abilities = abilities(inputs)
        built.rawProfiles = rawProfiles(inputs)
        built.producers = inputs.producers
        built.projects = inputs.projects.map {
            CorpusProjectRow(id: $0.id, name: $0.name, unitCount: $0.unitCount)
        }
        let scoped = inputs.selectedProjectID.map { id in
            inputs.units.filter { $0.projectID == id }
        } ?? inputs.units
        built.units = scoped.map { record in
            CorpusUnitRow(
                record: record,
                statusLine: statusLine(for: record),
                // Stale = deposit never landed (not "file untouched").
                isStale: record.deposit == .failed)
        }
        built.operations = Array(inputs.operations.prefix(120))
        built.tiers = tiers(inputs)
        return built
    }

    /// Unit state as a sentence. Each branch is a distinguishable outcome.
    nonisolated static func statusLine(for record: UnitIndexRecord) -> String {
        switch record.annotation {
        case .pending: return "waiting to be summarised"
        case .ran: return "summarised"
        case .pinned: return "labels pinned by you"
        case .noAnnotator: return "structure only — no summariser installed"
        case .refusedExclusiveEngine:
            return "structure only — the on-device engine is reserved for your turns"
        case .failed:
            if let note = record.annotationNote, !note.isEmpty {
                return "structure only — \(note)"
            }
            return "structure only — the summariser returned nothing"
        case .seerUnavailable: return "structure only — Seer is not signed in"
        case .empty: return "structure only — the summariser returned an empty reply"
        case .unparsable: return "structure only — the summariser did not return a précis"
        // Named: an unrecognised state is still a state.
        case .unknown: return "in a state this version doesn't recognise"
        }
    }

    nonisolated static func tiers(_ inputs: Inputs) -> [CorpusTierSection] {
        let conflictsByKey = Dictionary(
            inputs.conflicts.map { ($0.asserted.tenetKey, $0.observed) },
            uniquingKeysWith: { first, _ in first })

        func rows(_ tenets: [StyleTenet]) -> [CorpusTenetRow] {
            tenets
                .sorted {
                    $0.confidence == $1.confidence
                        ? $0.dimension.rawValue < $1.dimension.rawValue
                        : $0.confidence > $1.confidence
                }
                .map { tenet in
                    CorpusTenetRow(
                        tenet: tenet,
                        sentence: StyleRendering.sentence(for: tenet),
                        evidence: evidenceLine(for: tenet),
                        conflictsWith: conflictsByKey[tenet.tenetKey],
                        isVetoed: inputs.vetoed.contains(tenet.tenetKey))
                }
        }

        // One section per observed scope, broadest first (not a fixed list).
        var seen: [StyleScope] = []
        for tenet in inputs.tenets where !seen.contains(tenet.scope) {
            seen.append(tenet.scope)
        }
        let ordered: [StyleScope] = seen.sorted { left, right in
            if left.kind.breadth != right.kind.breadth {
                return left.kind.breadth < right.kind.breadth
            }
            return (left.identity ?? "") < (right.identity ?? "")
        }
        var sections: [CorpusTierSection] = []
        for scope in ordered {
            let matching: [StyleTenet] = inputs.tenets.filter { $0.scope == scope }
            sections.append(CorpusTierSection(
                id: scope.keyComponent,
                title: sectionTitle(scope, projects: inputs.projects),
                subtitle: sectionSubtitle(scope),
                rows: rows(matching),
                scope: scope))
        }

        return sections
    }

    nonisolated static func sectionTitle(
        _ scope: StyleScope, projects: [(id: String, name: String, unitCount: Int)]
    ) -> String {
        switch scope.kind {
        case .ability: return "How you do \(scope.identity ?? "this work")"
        case .language: return "How you write \(scope.displayName)"
        case .application: return "How you work in \(scope.displayName)"
        case .project:
            return projects.first { $0.id == scope.identity }?.name ?? scope.displayName
        case .unknown: return scope.displayName
        }
    }

    nonisolated static func sectionSubtitle(_ scope: StyleScope) -> String {
        switch scope.kind {
        case .ability:
            return "The craft itself — travels to any application that does it."
        case .language:
            return "Travels with you to any project in this language."
        case .application:
            return "Travels between projects in this application."
        case .project:
            return "Specific to this repository — stays home."
        case .unknown:
            return "From a newer version of Mary."
        }
    }

    // MARK: - The Ability cut

    /// One card per Ability from registered producers. Ability→application from AmbientAttention.ability.
    nonisolated static func abilities(_ inputs: Inputs) -> [CorpusAbilitySection] {
        let allTiers = tiers(inputs)
        let producers = inputs.producers

        // Every realized ability, observed or not — empty producers still show the shape.
        var abilities: [AbilityID] = producers.map(\.ability)
        for declared in inputs.corpora {
            guard let ability = declared.ability, !abilities.contains(ability) else { continue }
            abilities.append(ability)
        }

        return abilities.map { ability in
            let producer = producers.first { $0.ability == ability }
            let declaring = inputs.corpora.filter { $0.ability == ability }
            let owners = Set(producer?.applications ?? declaring.map(\.applicationID))
            let languages = Set(producer?.languages ?? declaring.map(\.notation))

            let mine = allTiers.filter { section in
                guard let scope = section.scope else { return false }
                switch scope.kind {
                case .ability: return scope.identity == ability.rawValue
                case .application: return owners.contains(scope.identity ?? "")
                case .language: return languages.contains(scope.identity ?? "")
                // Project belongs to the Ability practised in its units.
                case .project:
                    let producedBy = Set(
                        inputs.units
                            .filter { $0.projectID == scope.identity }
                            .map(\.applicationID))
                    return !producedBy.isDisjoint(with: owners)
                case .unknown: return false
                }
            }
            let count = mine.reduce(0) { $0 + $1.rows.count }
            return CorpusAbilitySection(
                id: ability.rawValue,
                ability: ability,
                title: ability.rawValue.prefix(1).uppercased() + ability.rawValue.dropFirst(),
                applications: (producer?.applications ?? declaring.map(\.applicationID))
                    .map { AmbientPlace.application($0).displayName },
                providedBy: providedBy(
                    ability: ability, producer: producer,
                    declaring: declaring.map(\.applicationID)),
                sections: mine,
                tenetCount: count,
                isUnobserved: producer == nil)
        }
    }

    /// Dimensions this craft can hold. From producer observations; notation-free fallback if unseen.
    nonisolated static func assertableDimensions(
        for ability: AbilityID,
        producers: [StyleProducer] = StyleProducerRegistry.shared.all()
    ) -> [StyleDimension] {
        let notationBound: Set<StyleDimension> = [
            .concurrencyPrimitive, .stateExposure, .bindingStyle,
            .accessDefault, .testFramework, .testNaming, .errorPosture,
        ]
        let producer = producers.first { $0.ability == ability }
        let readsANotation = !(producer?.languages.isEmpty ?? true)
        return StyleDimension.known
            .filter { $0 != .roleVocabulary }
            .filter { readsANotation || !notationBound.contains($0) }
    }

    /// Why this Ability appears (plugin/package in use), not just a list of apps.
    nonisolated static func providedBy(
        ability: AbilityID,
        producer: StyleProducer?,
        declaring: [String]
    ) -> String {
        func spoken(_ ids: [String]) -> String {
            ids.map { AmbientPlace.application($0).displayName }
                .joined(separator: ", ")
        }
        guard let producer else {
            return declaring.isEmpty
                ? "Nothing watches this work yet."
                : "Declared by \(spoken(declaring)) — nothing has settled in it yet."
        }
        return "Observed through \(spoken(producer.applications))."
    }

    /// Notations for an application's work — from the registry, not a second table here.
    nonisolated static func notations(
        forApplication applicationID: String,
        producers: [StyleProducer] = StyleProducerRegistry.shared.all(),
        corpora: [CorpusRegistration] = CorpusSupport.shared.all
    ) -> [String] {
        if let learned = producers.first(where: { $0.observes(application: applicationID) }) {
            return learned.languages
        }
        // Package still names the notation before anything has settled.
        return corpora
            .filter { $0.applicationID == applicationID }
            .map(\.schema.notation)
    }

    // MARK: - The raw cut

    /// One profile per Ability through the same codec as export (digest included).
    nonisolated static func rawProfiles(_ inputs: Inputs) -> [CorpusRawProfile] {
        inputs.producers.compactMap { producer in
            let subject = producer.ability.rawValue
            let tenets = inputs.tenets.filter { tenet in
                switch tenet.scope.kind {
                case .ability: return tenet.scope.identity == subject
                case .application:
                    return producer.applications.contains(tenet.scope.identity ?? "")
                case .language:
                    return producer.languages.contains(tenet.scope.identity ?? "")
                case .project, .unknown: return true
                }
            }
            guard !tenets.isEmpty else { return nil }

            let profile = StyleProfile(
                profile: .init(
                    subject: subject,
                    version: SemanticVersion("1.0.0"),
                    publisher: "",
                    summary: "How this person does \(subject) work.",
                    createdAt: inputs.now,
                    updatedAt: inputs.now),
                tenets: tenets)
            guard let data = try? StyleProfileCodec.encoded(profile),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return CorpusRawProfile(
                subject: subject,
                title: subject.prefix(1).uppercased() + subject.dropFirst(),
                json: json,
                digest: try? StyleProfileCodec.digest(of: profile),
                tenetCount: tenets.count)
        }
    }

    nonisolated static func evidenceLine(for tenet: StyleTenet) -> String {
        // An assertion has no age — it is a statement, not an observation.
        if tenet.provenance.isAsserted { return "you said so" }
        if case .imported(let origin) = tenet.provenance {
            return "from \(origin) — inert until your own work agrees"
        }
        let agreement = Int((tenet.agreement * 100).rounded())
        var line = "\(tenet.support) for · \(tenet.counter) against · \(agreement)% agreement"
        // Age: a quiet tenet looked identical to a live one without it.
        line += " · \(AmbientAge.string(max(0, Date().timeIntervalSince(tenet.lastObservedAt)))) ago"
        return line
    }
}
