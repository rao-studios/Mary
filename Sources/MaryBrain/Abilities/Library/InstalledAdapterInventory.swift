import MaryFoundation
import Foundation

/// The validated, machine-local side of the Ability compatibility join.
/// Manifests describe installed adapters; primitive bindings are the small
/// runtime-owned escape hatches (currently provider-neutral shell/script
/// primitives) that do not belong to a Plugin manifest.
struct InstalledAdapterInventory: Sendable {
    struct Candidate: Sendable {
        var binding: LocalSkillBinding
        var manifest: InstalledAdapterManifest?
    }

    let manifests: [InstalledAdapterManifest]
    let primitiveBindings: [LocalSkillBinding]
    let bindings: [LocalSkillBinding]

    private let candidatesByIdentity: [OperationIdentity: [Candidate]]
    private let providedInteractions: Set<InteractionID>
    private let providedPerceptions: Set<PerceptionID>

    init(
        manifests: [InstalledAdapterManifest],
        primitiveBindings: [LocalSkillBinding]
    ) {
        self.manifests = manifests.sorted { $0.adapterID.rawValue < $1.adapterID.rawValue }
        self.primitiveBindings = primitiveBindings

        var allBindings: [LocalSkillBinding] = []
        var candidates: [OperationIdentity: [Candidate]] = [:]
        var interactions: Set<InteractionID> = []
        var perceptions: Set<PerceptionID> = []

        for manifest in self.manifests {
            if manifest.isAvailable {
                interactions.formUnion(manifest.providesInteractions)
                perceptions.formUnion(manifest.providesPerceptions)
            }
            for declaredOperation in manifest.operations {
                var operation = declaredOperation
                if !manifest.isAvailable {
                    operation.isAvailable = false
                    operation.unavailableReason = manifest.unavailableReason
                        ?? "The \(manifest.title) adapter is unavailable."
                }
                let local = LocalSkillBinding(
                    adapter: operation,
                    ownerID: manifest.adapterID.rawValue,
                    ownerTitle: manifest.title)
                allBindings.append(local)
                let identity = OperationIdentity(operation)
                candidates[identity, default: []].append(.init(
                    binding: local,
                    manifest: manifest))
            }
        }

        for primitive in primitiveBindings {
            allBindings.append(primitive)
            candidates[OperationIdentity(primitive.adapter), default: []].append(.init(
                binding: primitive,
                manifest: nil))
        }
        self.bindings = allBindings
        self.candidatesByIdentity = candidates
        self.providedInteractions = interactions
        self.providedPerceptions = perceptions
    }

    static func validationIssues(
        manifests: [InstalledAdapterManifest],
        primitiveBindings: [LocalSkillBinding],
        capabilitySchemas: [CapabilityID: CapabilitySchema] = [:]
    ) -> [SchemaIssue] {
        var issues = AdapterManifestValidator.validate(manifests).issues

        let primitivesByAdapter = Dictionary(grouping: primitiveBindings) {
            $0.adapter.adapterID
        }
        let groupedPrimitives = primitivesByAdapter.keys
            .sorted { $0.rawValue < $1.rawValue }
            .map { adapterID in
                let bindings = primitivesByAdapter[adapterID] ?? []
                return InstalledAdapterManifest(
                    adapterID: adapterID,
                    title: bindings.first?.ownerTitle ?? adapterID.rawValue,
                    transport: .native,
                    operations: bindings.map(\.adapter))
            }
        issues.append(contentsOf: AdapterManifestValidator.validate(groupedPrimitives).issues.map {
            SchemaIssue(
                severity: $0.severity,
                code: "primitive-\($0.code)",
                path: $0.path.replacingOccurrences(of: "adapterManifests", with: "primitiveBindings"),
                message: $0.message)
        })

        let manifestedOperations = Set(manifests.flatMap { manifest in
            manifest.operations.map {
                OperationIdentity($0)
            }
        })
        for (index, primitive) in primitiveBindings.enumerated()
        where manifestedOperations.contains(OperationIdentity(primitive.adapter)) {
            issues.append(.init(
                severity: .error,
                code: "primitive-shadows-adapter-operation",
                path: "primitiveBindings[\(index)]",
                message: "Runtime primitive \(primitive.adapter.adapterID.rawValue)/\(primitive.adapter.operation) duplicates a manifest operation."))
        }
        if !capabilitySchemas.isEmpty {
            for (manifestIndex, manifest) in manifests.enumerated() {
                for (operationIndex, operation) in manifest.operations.enumerated() {
                    let path = "adapterManifests[\(manifestIndex)].operations[\(operationIndex)]"
                    // Adapters may arrive before the Ability package that owns
                    // their contract (notably Bluetooth devices). An attested
                    // claim becomes orphan-checkable only once every Capability
                    // named by this operation has a live schema owner.
                    if operation.capabilities.allSatisfy({ capabilitySchemas[$0] != nil }) {
                        let declaredConstraints = Set(operation.capabilities.flatMap {
                            capabilitySchemas[$0]?.constraints ?? []
                        })
                        for (claimIndex, claim) in operation.enforcedConstraints.enumerated()
                        where !declaredConstraints.contains(claim) {
                            issues.append(.init(
                                severity: .error,
                                code: "orphan-enforced-constraint",
                                path: "\(path).enforcedConstraints[\(claimIndex)]",
                                message: "Operation \(operation.operation) attests \(claim.kind.rawValue)=\(claim.value), but none of its claimed Capability schemas declares that exact constraint."))
                        }
                    }
                }
            }
        }
        return issues
    }

    func candidates(for reference: AdapterBindingReference) -> [Candidate] {
        candidatesByIdentity[OperationIdentity(reference)] ?? []
    }

    func publishes(_ interaction: InteractionID) -> Bool {
        providedInteractions.contains(interaction)
    }

    func publishes(_ perception: PerceptionID) -> Bool {
        if providedPerceptions.contains(perception) { return true }
        // A Perception Mary herself concludes counts as published whenever the
        // one she concludes it FROM is: the adapter sensed the evidence, and
        // the runtime performs the derivation on every turn. Reading only the
        // static claim here installed every Skill requiring
        // `code-workspace-focus` as `.blocked` — the whole coding lane, in
        // silence. See `DerivedPerceptions` for the table and for what a row
        // is allowed to promise.
        guard let base = DerivedPerceptions.base[perception] else { return false }
        return providedPerceptions.contains(base)
    }

    private struct OperationIdentity: Hashable, Sendable {
        var adapterID: AdapterID
        var operation: String

        init(_ binding: InstalledAdapterBinding) {
            adapterID = binding.adapterID
            operation = binding.operation
        }

        init(_ reference: AdapterBindingReference) {
            adapterID = reference.adapterID
            operation = reference.operation
        }
    }
}

/// Evaluates one Skill against exact adapter operations. Incremental manifests
/// use empty claim arrays as a migration wildcard; complete manifests use them
/// as an explicit empty set. Every non-empty claim is authoritative and the
/// package contract must be a compatible subset.
struct AbilityAdapterCompatibilityEvaluator {
    struct Result: Sendable {
        var selected: InstalledAdapterBinding?
        /// EVERY compatible candidate, preference-ordered (authored order on
        /// ties) — `selected` is always its first element. The per-turn
        /// application-aware provider resolver chooses among exactly these;
        /// keeping the full list here means the resolver can never admit a
        /// binding this evaluator refused.
        var compatible: [InstalledAdapterBinding] = []
        var missingCapabilities: [CapabilityID]
        var reasons: [String]
    }

    static func evaluate(
        skill: SkillSchema,
        capabilitySchemas: [CapabilityID: CapabilitySchema],
        inventory: InstalledAdapterInventory
    ) -> Result {
        let references = skill.execution.bindings.enumerated().sorted { left, right in
            if left.element.preference == right.element.preference {
                return left.offset < right.offset
            }
            return left.element.preference > right.element.preference
        }.map(\.element)

        var sawExactOperation = false
        var compatible: [InstalledAdapterBinding] = []
        var failureReasons: [String] = []
        var missingAcrossExactCandidates: Set<CapabilityID>?

        for reference in references {
            guard !RuntimePrimitiveOperations.contains(reference.operation) else {
                failureReasons.append(
                    "Mary-owned runtime primitive \(reference.operation) cannot satisfy a package-authored Skill binding.")
                continue
            }
            let exact = inventory.candidates(for: reference)
            guard !exact.isEmpty else {
                failureReasons.append(
                    "No installed adapter publishes \(reference.adapterID.rawValue)/\(reference.operation).")
                continue
            }
            sawExactOperation = true
            for candidate in exact {
                guard candidate.manifest != nil else {
                    failureReasons.append(
                        "Runtime primitive \(reference.adapterID.rawValue)/\(reference.operation) is host-owned and cannot satisfy a package-authored Skill binding.")
                    continue
                }
                let compatibility = compatibility(
                    of: candidate,
                    with: reference,
                    skill: skill,
                    capabilitySchemas: capabilitySchemas,
                    inventory: inventory)
                if compatibility.reasons.isEmpty {
                    // One binding per reference; keep walking the LOWER
                    // preferences too, so rival providers stay choosable.
                    compatible.append(candidate.binding.adapter)
                    break
                }
                failureReasons.append(contentsOf: compatibility.reasons)
                if let existing = missingAcrossExactCandidates {
                    missingAcrossExactCandidates = existing.intersection(
                        compatibility.missingCapabilities)
                } else {
                    missingAcrossExactCandidates = compatibility.missingCapabilities
                }
            }
        }

        if let first = compatible.first {
            return Result(
                selected: first,
                compatible: compatible,
                missingCapabilities: [],
                reasons: [])
        }

        var missingCapabilities = missingAcrossExactCandidates ?? []
        if references.isEmpty {
            failureReasons.append("The Skill declares no local adapter binding.")
        } else if !sawExactOperation {
            // A missing operation cannot satisfy any capability contract. Keep
            // this structured list useful to Ability Studio and route traces.
            missingCapabilities.formUnion(skill.requirements.capabilities)
        }
        return Result(
            selected: nil,
            missingCapabilities: missingCapabilities.sorted { $0.rawValue < $1.rawValue },
            reasons: orderedUnique(failureReasons))
    }

    private static func compatibility(
        of candidate: InstalledAdapterInventory.Candidate,
        with reference: AdapterBindingReference,
        skill: SkillSchema,
        capabilitySchemas: [CapabilityID: CapabilitySchema],
        inventory: InstalledAdapterInventory
    ) -> (reasons: [String], missingCapabilities: Set<CapabilityID>) {
        let operation = candidate.binding.adapter
        let claimsAreComplete = candidate.manifest?.claimCoverage == .complete
        var reasons: [String] = []
        var missingCapabilities: Set<CapabilityID> = []
        let requiredSchemas = skill.requirements.capabilities.compactMap {
            capabilitySchemas[$0]
        }
        let policy = CapabilityExecutionPolicy(capabilities: requiredSchemas)

        if !operation.isAvailable {
            return ([operation.unavailableReason
                ?? "Adapter operation \(operation.adapterID.rawValue)/\(operation.operation) is unavailable."], [])
        }

        if policy.requiresStage && !skill.usesStage {
            reasons.append("Skill \(skill.id.rawValue) does not claim the stage required by its Capability contract.")
        }
        if policy.requiresUserConfirmation && skill.access != .confirm {
            reasons.append("Skill \(skill.id.rawValue) does not require the user confirmation mandated by its Capability contract.")
        }
        let enforced = Set(operation.enforcedConstraints)
        let missingAttestations = policy.delegatedConstraints.subtracting(enforced)
        if !missingAttestations.isEmpty {
            let descriptions = missingAttestations.map {
                "\($0.kind.rawValue)=\($0.value)"
            }.sorted().joined(separator: ", ")
            reasons.append("Operation \(operation.operation) does not attest required source guarantees: \(descriptions).")
        }

        let requiredCapabilities = Set(skill.requirements.capabilities)
        let declaredCapabilities = Set(operation.capabilities)
        if claimsAreComplete || !declaredCapabilities.isEmpty {
            let missing = requiredCapabilities.subtracting(declaredCapabilities)
            missingCapabilities.formUnion(missing)
            if !missing.isEmpty {
                reasons.append("Operation \(operation.operation) does not claim required capabilities: \(list(missing)).")
            }
        }

        let inputTypes = Set(skill.inputs.map(\.valueType))
        let outputTypes = Set(skill.outputs.map(\.valueType))
        requireSubset(
            inputTypes,
            of: Set(operation.inputTypes),
            label: "input Value types",
            operation: operation.operation,
            emptyClaimsAreWildcard: !claimsAreComplete,
            reasons: &reasons)
        requireSubset(
            outputTypes,
            of: Set(operation.outputTypes),
            label: "output Value types",
            operation: operation.operation,
            emptyClaimsAreWildcard: !claimsAreComplete,
            reasons: &reasons)

        if let manifest = candidate.manifest {
            requireSubset(
                inputTypes.union(outputTypes),
                of: Set(manifest.supportedValueTypes),
                label: "adapter-supported Value types",
                operation: operation.operation,
                emptyClaimsAreWildcard: !claimsAreComplete,
                reasons: &reasons)

            let requiredPermissions = Set(skill.requirements.capabilities.flatMap { capabilityID in
                capabilitySchemas[capabilityID]?.permissions.map(\.kind) ?? []
            })
            requireSubset(
                requiredPermissions,
                of: Set(manifest.grantedPermissions),
                label: "granted permissions",
                operation: operation.operation,
                emptyClaimsAreWildcard: !claimsAreComplete,
                reasons: &reasons)
        }

        let requiredInteractions = Set(skill.requirements.interactions)
        let consumedInteractions = Set(operation.consumesInteractions)
        requireSubset(
            requiredInteractions,
            of: consumedInteractions,
            label: "consumed Interactions",
            operation: operation.operation,
            emptyClaimsAreWildcard: !claimsAreComplete,
            reasons: &reasons)
        if claimsAreComplete || !consumedInteractions.isEmpty {
            let unpublished = requiredInteractions.filter { !inventory.publishes($0) }
            if !unpublished.isEmpty {
                reasons.append("No available adapter publishes required Interactions: \(list(Set(unpublished))).")
            }
        }

        let requiredPerceptions = Set(skill.requirements.perceptions)
        let observedPerceptions = Set(operation.observesPerceptions)
        requireSubset(
            requiredPerceptions,
            of: observedPerceptions,
            label: "observed Perceptions",
            operation: operation.operation,
            emptyClaimsAreWildcard: !claimsAreComplete,
            reasons: &reasons)
        if claimsAreComplete || !observedPerceptions.isEmpty {
            let unpublished = requiredPerceptions.filter { !inventory.publishes($0) }
            if !unpublished.isEmpty {
                reasons.append("No available adapter publishes required Perceptions: \(list(Set(unpublished))).")
            }
        }

        let requiredTargets = Set(reference.targetClasses)
        let supportedTargets = Set(operation.targetClasses)
        if !requiredTargets.isEmpty,
           (claimsAreComplete || !supportedTargets.isEmpty),
           requiredTargets.isDisjoint(with: supportedTargets) {
            reasons.append(
                "Operation \(operation.operation) does not support target classes: \(requiredTargets.sorted().joined(separator: ", ")).")
        }
        if let allowedTargets = policy.allowedTargetClasses {
            if allowedTargets.isEmpty {
                reasons.append("Required Capability target-class allowlists have no common target.")
            } else {
                if requiredTargets.isEmpty || requiredTargets.isDisjoint(with: allowedTargets) {
                    reasons.append(
                        "Binding \(reference.adapterID.rawValue)/\(reference.operation) does not constrain execution to an allowed target class: \(allowedTargets.sorted().joined(separator: ", ")).")
                }
                if supportedTargets.isEmpty || supportedTargets.isDisjoint(with: allowedTargets) {
                    reasons.append(
                        "Operation \(operation.operation) does not implement an allowed target class: \(allowedTargets.sorted().joined(separator: ", ")).")
                }
            }
        }

        return (orderedUnique(reasons), missingCapabilities)
    }

    /// Incremental manifests treat an empty installed claim as unspecified.
    /// Complete manifests treat it as the closed, explicit empty set.
    private static func requireSubset<Element: Hashable>(
        _ required: Set<Element>,
        of claimed: Set<Element>,
        label: String,
        operation: String,
        emptyClaimsAreWildcard: Bool,
        reasons: inout [String]
    ) {
        guard !required.isEmpty else { return }
        if claimed.isEmpty && emptyClaimsAreWildcard { return }
        let missing = required.subtracting(claimed)
        guard !missing.isEmpty else { return }
        reasons.append("Operation \(operation) does not claim required \(label): \(list(missing)).")
    }

    private static func list<Element: Hashable>(_ values: Set<Element>) -> String {
        values.map { String(describing: $0) }.sorted().joined(separator: ", ")
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
