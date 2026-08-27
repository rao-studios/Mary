import MaryFoundation
import Foundation

/// Immutable for the life of a turn. Ability Studio may activate another
/// revision concurrently, but calls, badges, and diagnostics inside this turn
/// keep resolving against this exact snapshot.
public struct AbilityRuntimeSnapshot: Sendable {
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
    /// EVERY binding the compatibility evaluator admitted per Skill,
    /// preference-ordered — `selectedBinding` is always the first. The
    /// per-turn provider resolver chooses among exactly these, so it can
    /// never manufacture an availability the evaluator refused.
    private let compatibleBySkill: [SkillID: [InstalledAdapterBinding]]
    /// Optional embedding recall for `requestedAbilities(in:)`. Nil — every
    /// direct construction and every test that does not opt in — means
    /// exact-only matching, today's behavior byte for byte.
    private let semanticIndex: SemanticAbilityRequestIndex?

    public init(
        revision: UUID = UUID(),
        loadedAt: Date = Date(),
        records: [AbilityPackageRecord],
        validation: AbilityPackageValidation,
        adapterManifests: [InstalledAdapterManifest],
        primitiveBindings: [LocalSkillBinding] = [],
        plugins: PluginCompilation = .init(),
        semanticIndex: SemanticAbilityRequestIndex? = nil
    ) {
        self.semanticIndex = semanticIndex
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
        self.skillsByID = Dictionary(
            finalizedSkills.map { ($0.skill.id, $0) },
            uniquingKeysWith: { first, _ in first })
        self.invocations = Dictionary(
            finalizedSkills.compactMap { runtime in
                runtime.skill.modelExposure.enabled
                    ? (runtime.reference.invocationName, runtime) : nil
            },
            uniquingKeysWith: { first, _ in first })
        // SELECTED operations register first and keep first-wins semantics
        // byte-for-byte; every other compatible candidate's operation maps to
        // its skill afterwards, so a rival provider's operation resolves to
        // the same owning Skill instead of falling into the raw-binding
        // fallback below.
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
            // Native adapters predate portable Skill ownership and retain the
            // compatibility fallback. Dynamic operations are declarative
            // implementations of explicit realizations; exposing one without
            // its Skill would bypass routing, capability, and provider policy.
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

    public static let empty = AbilityRuntimeSnapshot(
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
        records.contains { $0.package.ability.id == abilityID }
    }

    public func bindingOperation(forInvocation name: String) -> String {
        // A name that is not a model-visible invocation resolves to ITSELF.
        // Every compatible candidate's operation is indexed now, so routing
        // an exact operation name through its owning Skill would substitute
        // the selected provider's operation — a silent cross-application
        // redirect no exact call may suffer. (Selected operations mapped to
        // themselves before, so this is behavior-identical for them.)
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

    /// Every binding the compatibility evaluator admitted for this Skill,
    /// preference-ordered; `selectedBinding` is always the first element.
    /// This list is the resolver's whole universe — a manifest the evaluator
    /// refused (consent, permissions, missing capability) is not in it.
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

    public func requestedAbilities(in utterance: String) -> Set<AbilityID> {
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
        // ADDITIVE RECALL, never veto: the semantic index widens what the
        // words request — "draw a circle" reaches Design without the literal
        // ability name — and structurally cannot remove an exact match.
        // Nil index (every direct construction) is exact-only, unchanged.
        return requested.union(
            semanticIndex?.requestedAbilities(in: utterance) ?? [])
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
