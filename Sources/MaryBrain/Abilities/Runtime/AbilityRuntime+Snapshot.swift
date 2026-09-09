//
//  AbilityRuntime+Snapshot.swift
//  MaryBrain
//
//  WHAT: Immutable Ability graph for the life of a turn, plus the two windows
//        onto it that other layers read — MaryAmbient's capability index and
//        the backwards dependency graph routing asks for expertise.
//  IN:   AbilityLibrary snapshot swap
//  OUT:  skills / bindings / plugins for dispatch and schema
//  PIN:  Studio may activate another revision; this turn keeps this snapshot.
//  PIN:  MaryAmbient must not name AbilityRuntime.Snapshot — it sees only the
//        AbilityCapabilityIndex window installed below.
//  PIN:  DEPENDENCIES ARE AUTHORED FORWARDS AND ASKED BACKWARDS. A package
//        names the discipline it extends (`apple-music` -> `multimedia`);
//        routing needs the opposite question — "which player answers a
//        multimedia skill" — and no authored field states it. Inverting the
//        edges is the only way to get it without asking every package to
//        repeat itself, which would drift the moment one of them was wrong.
//        NON-OPTIONAL EDGES ONLY, so an optional support (window-management)
//        never makes an ability look like somebody's player.
//  PIN:  TWO BACKWARDS INDEXES, ASKING DIFFERENT QUESTIONS. The expertise index
//        above answers "which player answers this discipline's skill" and reads
//        required edges onto disciplines. `applicationsBySupport` answers "which
//        applications can this system-control ability be pointed at" and reads
//        OPTIONAL edges onto systemControl — which is precisely the edge the
//        first one must throw away. They are not a widening of each other; the
//        discipline election was measured against the first one's exact shape.
//
import MaryAmbient
import MaryFoundation
import Foundation

extension AbilityRuntime {

    /// Immutable for the life of a turn. Ability Studio may activate another
    /// revision concurrently, but calls, badges, and diagnostics inside this turn
    /// keep resolving against this exact snapshot.
    public struct Snapshot: Sendable {
        public let revision: UUID
        public let loadedAt: Date
        public let records: [AbilityPackageRecord]
        public let validation: AbilityPackageValidation
        public let skills: [AbilityRuntimeSkill]
        public let adapterManifests: [InstalledAdapterManifest]
        public let primitiveBindings: [LocalSkillBinding]
        public let bindings: [LocalSkillBinding]
        /// Ability-carried providers compiled for this exact registry revision.
        /// The authored package records stay untouched; their realizations are
        /// joined into effective Skills only inside this immutable snapshot.
        public let plugins: PluginCompilation

        private let packagesByID: [PackageID: AbilityPackageRecord]
        private let manifestsByID: [AdapterID: InstalledAdapterManifest]
        private let capabilitySchemasByID: [CapabilityID: CapabilitySchema]
        private let skillsByID: [SkillID: AbilityRuntimeSkill]
        private let invocations: [String: AbilityRuntimeSkill]
        private let bindingOperations: [String: AbilityRuntimeSkill]
        private let fallbackReferences: [String: AbilitySkillReference]
        /// EVERY binding the compatibility evaluator admitted per Skill, preference-ordered — `selectedBinding` is always the first.
        private let compatibleBySkill: [SkillID: [InstalledAdapterBinding]]
        /// Every activated Ability id. `containsAbility` is asked once per
        /// supporting-ability edge per skill per arbitration, so it is a set
        /// membership rather than a scan of every record.
        let abilityIDs: Set<AbilityID>
        /// Execution policy per DISTINCT capability list. The policy is a pure
        /// function of `skill.requirements.capabilities` against this
        /// snapshot's capability schemas, so one entry per distinct list is
        /// exact — not a cache with an invalidation rule, and not keyed by
        /// SkillID, which two packages may share.
        let policiesByCapabilities: [[CapabilityID]: CapabilityExecutionPolicy]
        /// Discipline → the application-expertise Abilities that REQUIRE it,
        /// preference-ordered. Inverted from authored dependencies once per
        /// revision; see the expertise section below — internal rather
        /// than private because that extension is its only reader.
        let expertiseByDiscipline: [AbilityID: [AbilityID]]
        /// System-control Ability → the application-bearing Abilities that name
        /// it as a dependency, OPTIONAL EDGES INCLUDED, preference-ordered.
        /// A second index rather than a widening of `expertiseByDiscipline`,
        /// which answers a different question and whose exact shape the
        /// discipline election was measured against.
        let applicationsBySupport: [AbilityID: [AbilityID]]
        /// Optional embedding recall for `requestedAbilities(in:)`. Nil — lexical
        /// fallback for tests and hosts with no OS embedding asset.
        private let semanticIndex: SemanticAbilityRequestIndex?
        /// Optional embedding recall one tier down. When present, affinity is the
        /// Skill offer gate; nil keeps lexical eligibility.
        public let semanticSkillIndex: SemanticSkillRequestIndex?
        /// Optional embedding operate/perceive/compose/ask/converse classifier,
        /// built from every installed package's own `intentSeeds`. Nil keeps
        /// the lexical ladder in `AmbientEngine.classify`.
        public let semanticIntentIndex: SemanticIntentIndex?
        /// Named seed families — see `SemanticSeedFamilyIndex`.
        public let semanticSeedFamilyIndex: SemanticSeedFamilyIndex?
        /// Optional embedding recall over applications a system-control Skill
        /// may be pointed at. Nil leaves `ApplicationReferenceResolution` with
        /// only its exact-naming tier, which is a narrower answer, not a wrong one.
        public let semanticApplicationIndex: SemanticApplicationIndex?

        public init(
            revision: UUID = UUID(),
            loadedAt: Date = Date(),
            records: [AbilityPackageRecord],
            validation: AbilityPackageValidation,
            adapterManifests: [InstalledAdapterManifest],
            primitiveBindings: [LocalSkillBinding] = [],
            plugins: PluginCompilation = .init(),
            semanticIndex: SemanticAbilityRequestIndex? = nil,
            semanticSkillIndex: SemanticSkillRequestIndex? = nil,
            semanticIntentIndex: SemanticIntentIndex? = nil,
            semanticSeedFamilyIndex: SemanticSeedFamilyIndex? = nil,
            semanticApplicationIndex: SemanticApplicationIndex? = nil
        ) {
            self.semanticIndex = semanticIndex
            self.semanticSkillIndex = semanticSkillIndex
            self.semanticIntentIndex = semanticIntentIndex
            self.semanticSeedFamilyIndex = semanticSeedFamilyIndex
            self.semanticApplicationIndex = semanticApplicationIndex
            let inventory = InstalledAdapterInventory(
                manifests: adapterManifests + plugins.adapterManifests,
                primitiveBindings: primitiveBindings)
            self.revision = revision
            self.loadedAt = loadedAt
            self.records = records.sorted { $0.package.ability.title < $1.package.ability.title }
            self.validation = validation
            self.adapterManifests = inventory.manifests
            self.primitiveBindings = inventory.primitiveBindings
            self.bindings = inventory.bindings
            self.plugins = plugins
            let manifestsByID = Dictionary(
                inventory.manifests.map { ($0.adapterID, $0) },
                uniquingKeysWith: { first, _ in first })
            self.manifestsByID = manifestsByID
            self.packagesByID = Dictionary(
                records.map { ($0.package.package.id, $0) },
                uniquingKeysWith: { _, latest in latest })
            self.expertiseByDiscipline = Self.buildExpertiseIndex(records: records)
            self.applicationsBySupport = Self.buildApplicationSupportIndex(records: records)

            let capabilitySchemas = Dictionary(
                records.flatMap { $0.package.capabilities }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            self.capabilitySchemasByID = capabilitySchemas

            var runtimeSkills: [AbilityRuntimeSkill] = []
            var compatibleBySkill: [SkillID: [InstalledAdapterBinding]] = [:]
            for record in records {
                let package = record.package
                let digest = package.integrity?.digest
                    ?? (try? AbilityPackageCodec.digest(of: package))
                for authoredSkill in package.skills {
                    var skill = authoredSkill
                    let realizedBindings = plugins.bindings(for: skill.id)
                    if !realizedBindings.isEmpty {
                        let authoredIdentities = Set(skill.execution.bindings.map {
                            "\($0.adapterID.rawValue)|\($0.operation)"
                        })
                        skill.execution.bindings.append(contentsOf: realizedBindings.filter {
                            !authoredIdentities.contains("\($0.adapterID.rawValue)|\($0.operation)")
                        })
                    }
                    let compatibility = AbilityAdapterCompatibilityEvaluator.evaluate(
                        skill: skill,
                        capabilitySchemas: capabilitySchemas,
                        inventory: inventory)
                    let selected = compatibility.selected
                    if compatibleBySkill[skill.id] == nil {
                        compatibleBySkill[skill.id] = compatibility.compatible
                    }
                    let readiness: SkillReadiness
                    var reasons = compatibility.reasons
                    var missingCapabilities = compatibility.missingCapabilities
                    switch skill.execution.kind {
                    case .cognitive:
                        readiness = .ready
                        reasons = []
                        missingCapabilities = []
                    case .binding, .stateMachine:
                        if selected != nil {
                            readiness = .ready
                        } else if !skill.execution.bindings.isEmpty {
                            readiness = .blocked
                            if reasons.isEmpty {
                                reasons = ["No installed adapter satisfies this Skill's binding contract."]
                            }
                        } else if skill.execution.kind == .stateMachine {
                            readiness = .partial
                            reasons = ["The workflow is installed but one or more effectful steps have no binding."]
                        } else {
                            readiness = .blocked
                            reasons = ["The Skill has no local binding."]
                        }
                    }
                    let preferred = selected.map { ($0.adapterID, $0.operation) }
                        ?? skill.execution.bindings.sorted { $0.preference > $1.preference }.first.map {
                            ($0.adapterID, $0.operation)
                        }
                    let invocation = skill.invocationName ?? skill.id.rawValue
                    let reference = AbilitySkillReference(
                        packageID: package.package.id,
                        packageVersion: package.package.version,
                        packageDigest: digest,
                        abilityID: package.ability.id,
                        abilityTitle: package.ability.title,
                        abilityTint: package.ability.tint,
                        skillID: skill.id,
                        skillTitle: skill.title,
                        invocationName: invocation,
                        adapterID: preferred?.0,
                        bindingOperation: preferred?.1,
                        provider: selected.flatMap {
                            manifestsByID[$0.adapterID]?.resolvedProvider
                        })
                    runtimeSkills.append(AbilityRuntimeSkill(
                        packageID: package.package.id,
                        ability: package.ability,
                        skill: skill,
                        availability: SkillAvailability(
                            skillID: skill.id,
                            readiness: readiness,
                            selectedBinding: selected,
                            missingCapabilities: missingCapabilities,
                            reasons: reasons),
                        reference: reference))
                }
            }
            let finalizedSkills = SkillExecutionAvailabilityEvaluator.finalize(runtimeSkills)
            self.skills = finalizedSkills
            self.abilityIDs = Set(records.map(\.package.ability.id))
            var policies: [[CapabilityID]: CapabilityExecutionPolicy] = [:]
            for runtime in finalizedSkills {
                let wanted = runtime.skill.requirements.capabilities
                guard policies[wanted] == nil else { continue }
                policies[wanted] = CapabilityExecutionPolicy(
                    capabilities: wanted.compactMap { capabilitySchemas[$0] })
            }
            self.policiesByCapabilities = policies
            self.skillsByID = Dictionary(
                finalizedSkills.map { ($0.skill.id, $0) },
                uniquingKeysWith: { first, _ in first })
            self.invocations = Dictionary(
                finalizedSkills.compactMap { runtime in
                    runtime.skill.modelExposure.enabled
                        ? (runtime.reference.invocationName, runtime) : nil
                },
                uniquingKeysWith: { first, _ in first })
            // SELECTED operations register first and keep first-wins semantics byte-for-byte
            var operationsIndex = Dictionary(
                finalizedSkills.compactMap { runtime in
                    runtime.bindingOperation.map { ($0, runtime) }
                },
                uniquingKeysWith: { first, _ in first })
            for runtime in finalizedSkills {
                for candidate in compatibleBySkill[runtime.skill.id] ?? []
                where operationsIndex[candidate.operation] == nil {
                    operationsIndex[candidate.operation] = runtime
                }
            }
            self.bindingOperations = operationsIndex
            self.compatibleBySkill = compatibleBySkill

            var fallback: [String: AbilitySkillReference] = [:]
            for binding in self.bindings
            where self.bindingOperations[binding.adapter.operation] == nil
                // Native adapters predate portable Skill ownership and retain the compatibility fallback.
                && manifestsByID[binding.adapter.adapterID]?
                    .resolvedProvider.pluginClass != .package {
                let abilityToken = Self.portableID(binding.ownerID)
                let abilityID = AbilityID(abilityToken)
                fallback[binding.adapter.operation] = AbilitySkillReference(
                    packageID: PackageID(abilityToken),
                    packageVersion: "0.0.0",
                    abilityID: abilityID,
                    abilityTitle: binding.ownerTitle,
                    abilityTint: Self.fallbackTint(for: abilityToken),
                    skillID: SkillID(binding.adapter.operation),
                    skillTitle: binding.adapter.operation,
                    invocationName: binding.adapter.operation,
                    adapterID: binding.adapter.adapterID,
                    bindingOperation: binding.adapter.operation,
                    source: .adapterFallback,
                    provider: manifestsByID[binding.adapter.adapterID]?.resolvedProvider)
            }
            self.fallbackReferences = fallback
        }

        public static let empty = AbilityRuntime.Snapshot(
            records: [], validation: .init(), adapterManifests: [])

        public var packages: [MaryAbilityPackage] { records.map(\.package) }
        public var valueTypeSchemas: [ValueTypeSchema] {
            records.flatMap { $0.package.valueTypes }
        }
        public func valueTypeSchema(id: ValueTypeID) -> ValueTypeSchema? {
            records.lazy.compactMap { record in
                record.package.valueTypes.first { $0.id == id }
            }.first
        }
        public func interactionSchema(id: InteractionID) -> InteractionSchema? {
            records.lazy.compactMap { record in
                record.package.interactions.first { $0.id == id }
            }.first
        }
        public func perceptionSchema(id: PerceptionID) -> PerceptionSchema? {
            records.lazy.compactMap { record in
                record.package.perceptions.first { $0.id == id }
            }.first
        }
        public func capabilitySchema(id: CapabilityID) -> CapabilitySchema? {
            capabilitySchemasByID[id]
        }
        public func capabilitySchemas(requiredBy skill: SkillSchema) -> [CapabilitySchema] {
            skill.requirements.capabilities.compactMap { capabilitySchemasByID[$0] }
        }
        public var availableInteractions: Set<InteractionID> {
            Set(adapterManifests.filter(\.isAvailable).flatMap(\.providesInteractions))
        }
        public var availablePerceptions: Set<PerceptionID> {
            Set(adapterManifests.filter(\.isAvailable).flatMap(\.providesPerceptions))
        }
        public var exposedSkills: [AbilityRuntimeSkill] {
            skills.filter { $0.skill.modelExposure.enabled && $0.availability.readiness != .blocked }
        }

        public func package(id: PackageID) -> AbilityPackageRecord? { packagesByID[id] }
        public func adapterManifest(id: AdapterID) -> InstalledAdapterManifest? { manifestsByID[id] }
        public func skill(id: SkillID) -> AbilityRuntimeSkill? { skillsByID[id] }
        public func skill(invocationName: String) -> AbilityRuntimeSkill? {
            invocations[invocationName] ?? bindingOperations[invocationName]
        }
        public func skill(bindingOperation: String) -> AbilityRuntimeSkill? {
            bindingOperations[bindingOperation]
        }

        public func containsAbility(_ abilityID: AbilityID) -> Bool {
            abilityIDs.contains(abilityID)
        }

        public func bindingOperation(forInvocation name: String) -> String {
            // A name that is not a model-visible invocation resolves to ITSELF.
            guard let runtime = invocations[name] else { return name }
            return runtime.bindingOperation ?? name
        }

        public func reference(forInvocation name: String) -> AbilitySkillReference {
            if let reference = skill(invocationName: name)?.reference { return reference }
            if let reference = fallbackReferences[name] { return reference }
            let token = Self.portableID("mary")
            return AbilitySkillReference(
                packageID: PackageID(token),
                packageVersion: "0.0.0",
                abilityID: AbilityID(token),
                abilityTitle: "Mary",
                abilityTint: Self.fallbackTint(for: token),
                skillID: SkillID(name),
                skillTitle: name,
                invocationName: name,
                bindingOperation: name,
                source: .runtime)
        }

        public func effect(forInvocation name: String) -> CapabilityEffect {
            guard let runtime = skill(invocationName: name) else { return .none }
            let effects = runtime.skill.requirements.capabilities.compactMap { wanted in
                capabilitySchemasByID[wanted]?.effect
            }
            return effects.max(by: { Self.effectRank($0) < Self.effectRank($1) }) ?? .none
        }

        public func inputTypes(forInvocation name: String) -> [ValueTypeID] {
            skill(invocationName: name)?.skill.inputs.map(\.valueType) ?? []
        }

        public func outputTypes(forInvocation name: String) -> [ValueTypeID] {
            skill(invocationName: name)?.skill.outputs.map(\.valueType) ?? []
        }

        /// Every binding the compatibility evaluator admitted for this Skill, preference-ordered; `selectedBinding` is always the first element.
        public func compatibleBindings(for id: SkillID) -> [InstalledAdapterBinding] {
            compatibleBySkill[id] ?? []
        }

        /// The application a package-realized skill drives, via the package
        /// whose plugin declared its selected adapter. Pass `binding` to ask
        /// about a specific compatible candidate instead of the static selection.
        public func applicationID(
            of runtime: AbilityRuntimeSkill,
            binding: InstalledAdapterBinding? = nil
        ) -> String? {
            guard let adapterID = (binding ?? runtime.availability.selectedBinding)?.adapterID
            else { return nil }
            return records.lazy
                .compactMap(\.package.plugin)
                .first { plugin in plugin.adapters.contains { $0.id == adapterID } }?
                .application.id
        }

        /// The model-visible input names of the skill's selected dynamic
        /// operation — the parameters the executor actually projects. Pass
        /// `binding` to project a specific compatible candidate's operation.
        func selectedOperationInputNames(
            of runtime: AbilityRuntimeSkill,
            binding: InstalledAdapterBinding? = nil
        ) -> [String] {
            guard let selected = binding ?? runtime.availability.selectedBinding else { return [] }
            return records.lazy
                .compactMap(\.package.plugin)
                .flatMap(\.operations)
                .first { $0.operation == selected.operation }?
                .inputs.map(\.name) ?? []
        }

        private static func effectRank(_ effect: CapabilityEffect) -> Int {
            switch effect {
            case .none: return 0
            case .read: return 1
            case .reversibleMutation: return 2
            case .mutation: return 3
            case .externalCommunication: return 4
            case .destructive: return 5
            }
        }

        /// SCORED ability recall — the ranked sibling of `requestedAbilities`,
        /// for callers that must compare two Abilities rather than admit a set.
        /// Empty without an index: there is no lexical way to produce a score.
        public func abilityAffinities(in utterance: String) -> [AbilityID: Float] {
            semanticIndex?.affinities(in: utterance) ?? [:]
        }

        public func requestedAbilities(in utterance: String) -> Set<AbilityID> {
            if let semanticIndex {
                return semanticIndex.requestedAbilities(in: utterance)
            }
            let words = Self.searchWords(in: utterance)
            let wordSet = Set(words)
            var requested: Set<AbilityID> = []
            for record in records {
                let ability = record.package.ability
                let trigger = ability.triggers
                if trigger.negativeTokens.contains(where: {
                    Self.containsSearchTerm($0, in: words)
                }) { continue }
                let tokenMatch = trigger.tokens.contains { token in
                    let candidate = Self.searchWords(in: token)
                    return candidate.count == 1 && wordSet.contains(candidate[0])
                }
                let phraseMatch = trigger.phrases.contains {
                    Self.containsSearchTerm($0, in: words)
                }
                let aliasMatch = ability.aliases.contains {
                    Self.containsSearchTerm($0, in: words)
                }
                if tokenMatch || phraseMatch || aliasMatch { requested.insert(ability.id) }
            }
            return requested
        }

        private static func searchWords(in value: String) -> [String] {
            value.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }

        /// Matches a complete token sequence, never an arbitrary substring. Empty
        /// or malformed package terms therefore fail closed even if a caller has
        /// constructed a snapshot without running package validation first.
        private static func containsSearchTerm(
            _ term: String,
            in utteranceWords: [String]
        ) -> Bool {
            let candidate = searchWords(in: term)
            guard !candidate.isEmpty, candidate.count <= utteranceWords.count else {
                return false
            }
            if candidate.count == 1 {
                return utteranceWords.contains(candidate[0])
            }
            let lastStart = utteranceWords.count - candidate.count
            for start in 0...lastStart
            where Array(utteranceWords[start..<(start + candidate.count)]) == candidate {
                return true
            }
            return false
        }

        private static func portableID(_ value: String) -> String {
            let token = value.lowercased().map { character -> Character in
                if character.isLetter || character.isNumber || character == "." || character == "-" {
                    return character
                }
                return "-"
            }
            let collapsed = String(token).replacingOccurrences(of: "--", with: "-")
            return collapsed.first?.isLetter == true ? collapsed : "ability-\(collapsed)"
        }

        private static func fallbackTint(for value: String) -> String {
            let palette = ["#B7791F", "#2B6CB0", "#2F855A", "#805AD5", "#C05621", "#B83280"]
            let index = value.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
            return palette[index]
        }
    }
}

// MARK: - The capability window MaryAmbient reads

extension AbilityRuntime.Snapshot: AbilityCapabilityIndex {
    public func paradigm(of abilityID: AbilityID) -> AbilityParadigm? {
        records.first { $0.package.ability.id == abilityID }?.package.paradigm
    }

    /// Every installed Ability whose paradigm is `.discipline`. ORDERED BY
    /// PACKAGE ID so the axis is stable across launches — arbitration reads
    /// "first" off this, and a set's iteration order would make the lead
    /// wobble between runs for no reason the user could see.
    public var disciplines: [AbilityID] {
        records
            .filter { $0.package.paradigm == .discipline }
            .map(\.package.ability.id)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// THE DISCIPLINE THE WORDS NAME. Scores the utterance against each
    /// discipline Ability's own authored corpus and takes the leader, provided
    /// it clears the floor and beats the runner-up by the margin.
    ///
    /// The margin IS the old rule that cues from both sides cancel: a sentence
    /// that names two crafts equally is contested, and a contested turn defers
    /// to window truth rather than picking. What changed is that the crafts are
    /// no longer two, and the cues are no longer fifty hand-written words.
    public func discipline(in utterance: String) -> WorkspaceFocus? {
        let installed = Set(disciplines)
        guard !installed.isEmpty else { return nil }
        let ranked = abilityAffinities(in: utterance)
            .filter { installed.contains($0.key) }
            .sorted { $0.value > $1.value }
        guard let best = ranked.first,
              best.value >= SemanticAbilityRequestIndex.defaultPositiveThreshold
        else { return nil }
        if let runnerUp = ranked.dropFirst().first,
           best.value - runnerUp.value < SemanticIntentIndex.margin {
            return nil
        }
        return WorkspaceFocus(best.key)
    }

    /// The `transform` seed family, asked of whichever packages authored it.
    public func namesTransform(in text: String) -> Bool {
        semanticSeedFamilyIndex?
            .matches(SemanticSeedFamilyIndex.transform, in: text) ?? false
    }
}

public enum AmbientCapabilityBridge {
    /// Points MaryAmbient at the live registry. Called once at configuration;
    /// before it runs, ambient routing reads an empty index rather than block.
    public static func install() {
        AmbientCapabilityIndexProvider.install {
            AbilityLibrary.shared.snapshotEnsuringLoaded()
        }
    }
}

// MARK: - The dependency graph read BACKWARDS — who inherits a discipline

extension AbilityRuntime.Snapshot {

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
                // Same guard as `abilityThreadTargets`: only a discipline is a
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

// MARK: - The same graph read backwards for a system-control Ability

extension AbilityRuntime.Snapshot {

    /// Application-bearing Abilities that name this one as a dependency.
    ///
    /// THE OPTIONAL EDGE IS THE WHOLE POINT. `buildExpertiseIndex` keeps only
    /// REQUIRED edges onto disciplines, because inheriting a craft is not
    /// optional — you either extend `writing` or you do not. Being operable by
    /// the window manager is the other kind of relationship entirely, and every
    /// application package already declares it exactly that way
    /// (`window-management, optional`). Nine such edges were sitting in the
    /// shipped packages, thrown away by the only index that read dependencies.
    public func applicationsSupporting(_ ability: AbilityID) -> [AbilityID] {
        applicationsBySupport[ability] ?? []
    }

    /// The applications a Skill may be pointed at, or empty when it did not ask.
    ///
    /// OPT-IN, NEVER AMBIENT. A Skill that did not declare
    /// `resolvesApplication` gets nothing here even though its Ability may have
    /// dependents — "bring all my windows forward" names no application and
    /// must not be handed one.
    public func applicationCandidates(for skill: AbilityRuntimeSkill) -> [AbilityID] {
        guard skill.skill.requirements.resolvesApplication else { return [] }
        return applicationsSupporting(skill.ability.id)
    }

    /// The logical application an Ability drives, whatever declares it.
    /// `plugin.application.id` or the first `ability.applications` entry —
    /// the same join `applicationAffinities` already makes.
    public func applicationID(ofAbility abilityID: AbilityID) -> String? {
        records.first { $0.package.ability.id == abilityID }?
            .package.applicationAffinities.first?.id
    }

    /// Inverted dependency edges for support, built once per revision.
    ///
    /// Deliberately NOT restricted to `.applicationExpertise` dependents: what
    /// qualifies a candidate is that it carries an application affinity, which
    /// is the thing being resolved. A package that names an application without
    /// declaring the paradigm still answers "which app did they mean".
    static func buildApplicationSupportIndex(
        records: [AbilityPackageRecord]
    ) -> [AbilityID: [AbilityID]] {
        var paradigms: [PackageID: AbilityParadigm] = [:]
        var abilityIDs: [PackageID: AbilityID] = [:]
        for record in records {
            paradigms[record.package.package.id] = record.package.paradigm
            abilityIDs[record.package.package.id] = record.package.ability.id
        }
        var index: [AbilityID: [(ability: AbilityID, preference: Int)]] = [:]
        for record in records {
            let package = record.package
            // No affinity, nothing to resolve TO.
            guard !package.applicationAffinities.isEmpty else { continue }
            for dependency in package.dependencies {
                // Only a system-control Ability operates other applications.
                // An absent dependency cannot be shown to be one, so it is
                // skipped rather than assumed — same rule as the expertise index.
                guard paradigms[dependency.packageID] == .systemControl else { continue }
                let host = abilityIDs[dependency.packageID]
                    ?? AbilityID(dependency.packageID.rawValue)
                index[host, default: []].append((
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
