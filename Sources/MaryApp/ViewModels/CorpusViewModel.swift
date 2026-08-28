//
//  CorpusViewModel.swift
//  Mary
//
//  The Corpus pane's bridge to what indexing actually did.
//
//  `RouteTraceViewModel`'s shape, for its stated reasons: a 1 Hz poll of
//  lock-boxed stores, ONE impure `gather()`, a PURE `build(_:)` over an
//  `Inputs` value, and an Equatable diff before republishing so a quiet second
//  repaints nothing. The pure core is what makes the pane testable from
//  `Tests/MaryTests` with a frozen clock, which matters more here than
//  usual: the rows encode the promotion and conflict rules, and those are
//  exactly the things worth pinning.
//
//  Live data never round-trips through Granite's `@Store` — its 200 ms
//  debounce blurs precisely what this pane exists to show.
//

import MaryAmbient
import MaryAdapters
import MaryFoundation
import Foundation

// MARK: - Rows

struct CorpusUnitRow: Identifiable, Equatable {
    var id: String { record.unitKey }
    var record: UnitIndexRecord
    /// Rendered here rather than in the view, so the pure builder decides what
    /// the pane says about a unit's state.
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
    /// The scope this section IS. Carried rather than re-parsed out of `id`:
    /// a scope now has an identity, and reconstructing one from a display
    /// string is how the two would drift.
    var scope: StyleScope?
}

struct CorpusProjectRow: Identifiable, Equatable {
    var id: String
    var name: String
    var unitCount: Int
}

/// One Ability, and every rung of schema underneath it.
///
/// This is the chain rendered: the Ability is the craft, and the sections are
/// the language it is written in, the applications that realize it, and the
/// projects it has been practised on. A schema at the Ability rung is what
/// makes you use Sketch differently from anyone else using Sketch; the
/// application rung is what stays with Sketch.
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
    /// No producer files evidence for this Ability yet. Shown rather than
    /// hidden — the shape of the system should be legible before it is full.
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
        /// Who is registered to learn what. CARRIED, not read from the shared
        /// registry inside `build` — the whole point of the pure core is that
        /// the same inputs give the same pane, and a process-wide singleton
        /// read mid-build breaks that for tests and for parallel suites alike.
        var producers: [StyleProducer] = []
        /// Which applications DECLARE a corpus for which ability. In the build
        /// this ports from the same question was asked of `AmbientWorld` —
        /// which abilities a lane realizes — and Mary's lanes realize none:
        /// an application is a package, and a craft is something its package
        /// declares. Carried rather than read, for the reason above.
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
        // ONE weighted pass, shared three ways. `tenets`, `observed` and
        // `conflicts` each used to recompute it, so a pane left open re-weighted
        // every contribution in the corpus three times a second and discarded
        // the result unchanged nearly every time.
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
                // An hour without a re-index while its project keeps moving is
                // not stale by itself — a file you have not touched is simply
                // current. Staleness here means the deposit never landed.
                isStale: record.deposit == .failed)
        }
        built.operations = Array(inputs.operations.prefix(120))
        built.tiers = tiers(inputs)
        return built
    }

    /// The one place a unit's state becomes a sentence. Every branch names a
    /// distinguishable outcome — before `UnitAnnotationOutcome` existed, three
    /// of these were one indistinguishable empty label list.
    nonisolated static func statusLine(for record: UnitIndexRecord) -> String {
        switch record.annotation {
        case .pending: return "waiting to be summarised"
        case .ran: return "summarised"
        case .pinned: return "labels pinned by you"
        case .noAnnotator: return "structure only — no summariser installed"
        case .refusedExclusiveEngine:
            return "structure only — the on-device engine is reserved for your turns"
        case .failed: return "structure only — the summariser returned nothing"
        // Written by a newer build and decayed on the way in. Named rather
        // than hidden: an unrecognised state is still a state.
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

        // ONE SECTION PER OBSERVED SCOPE, broadest rung first. Built from the
        // scopes that actually exist rather than from a fixed list, so a
        // second language or a second application appears without this
        // function learning its name.
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

    /// Group every rung under the Ability it belongs to.
    ///
    /// The Ability→application edge comes from `AmbientWorld.ability`, the one
    /// mapping — not from a second table here that could disagree with the
    /// routing predicate it also feeds.
    /// One card per ABILITY — the thing being learned about — with the
    /// applications it is observed through named beneath it.
    ///
    /// THE ORDER OF THE QUESTION CHANGED. This used to start from
    /// `AmbientWorld.realizedAbilities` and re-derive each ability's owners and
    /// notations here, which was a fourth copy of a filter the store already
    /// owns. It now starts from the REGISTERED PRODUCERS: an ability appears
    /// because something is registered to learn it, which is the same fact the
    /// user sees — Xcode is there because the Xcode plugin is in use, Scrivener
    /// because its package is.
    nonisolated static func abilities(_ inputs: Inputs) -> [CorpusAbilitySection] {
        let allTiers = tiers(inputs)
        let producers = inputs.producers

        // Every ability a world realizes, whether or not anything learns it
        // yet — an instrument that showed only what it can already see would
        // hide the shape of the system.
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
                // A project belongs to whichever Ability was practised in it,
                // which its own units name.
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

    /// The dimensions a given craft can meaningfully hold.
    ///
    /// Derived from what its registered producer has ever observed, falling
    /// back to the notation-free set when nothing has been seen yet — a
    /// manuscript can carry a comment posture in the general sense, but not a
    /// concurrency primitive, and offering one is inviting a tenet that
    /// nothing will ever corroborate.
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

    /// WHY THIS APPEARS AT ALL. Xcode is at the top of the pane because an
    /// Xcode plugin is in use; Scrivener would be because its dynamic package
    /// is. Saying so is the difference between a list of applications and an
    /// account of what Mary is actually learning from.
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

    /// The notations an application's work is written in — asked of the
    /// registry rather than restated here. This was a second copy of the
    /// runtime's table, and two tables that must agree are one bug waiting.
    nonisolated static func notations(
        forApplication applicationID: String,
        producers: [StyleProducer] = StyleProducerRegistry.shared.all(),
        corpora: [CorpusRegistration] = CorpusSupport.shared.all
    ) -> [String] {
        if let learned = producers.first(where: { $0.observes(application: applicationID) }) {
            return learned.languages
        }
        // Nothing has learned this application yet, but its package still says
        // what its work is written in — which is the honest answer before the
        // first settle rather than an empty list.
        return corpora
            .filter { $0.applicationID == applicationID }
            .map(\.schema.notation)
    }

    // MARK: - The raw cut

    /// One profile per subject, encoded through the SAME codec the export path
    /// uses — so what the tab shows and what you could hand to someone else
    /// are the same bytes, digest included, rather than a debug rendering that
    /// merely resembles them.
    /// The document as it is actually written — one per ABILITY, matching
    /// `persistStyleProfile` exactly. It used to derive subjects from the
    /// `.application` rung, which meant the Raw tab and the durable documents
    /// could describe different things.
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
        // Age is the half of the story the pane could not previously tell: a
        // tenet that has gone quiet looks identical to a live one without it.
        line += " · \(AmbientAge.string(max(0, Date().timeIntervalSince(tenet.lastObservedAt)))) ago"
        return line
    }
}
