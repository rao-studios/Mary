//
//  PluginManagedUIExecutor+Roster.swift
//  PACKAGE OPERATIONS → RUNTIME SKILL BINDINGS: materializes a callable Skill
//  for exactly the operations owned by a READY semantic skill in one immutable
//  snapshot, and for nothing else.
//
//  THE "OWNED BY A READY SKILL" CLAUSE IS THE POLICY GATE. An operation is an
//  implementation, never a standalone model tool: without it a package could
//  ship a raw application command with no Ability deciding when it may run,
//  what it costs, or whether it needs confirming. Every candidate the
//  evaluator finds compatible materializes — not just the statically
//  preferred one — so the per-turn resolver has rivals to choose among.
//
import AppKit
import ApplicationServices
import MaryAmbient
import MaryAdapters
import MaryFoundation
import Foundation

extension PluginManagedUIExecutor {
    func runtimeBindings(
        in snapshot: AbilityRuntimeSnapshot
    ) -> [PluginManagedUIRuntimeBinding] {
        snapshot.records
            .sorted { $0.package.package.id.rawValue < $1.package.package.id.rawValue }
            .flatMap { record -> [PluginManagedUIRuntimeBinding] in
                guard let plugin = record.package.plugin else { return [] }
                // Every imported application operation enters this Mary-owned
                // native interpreter. Packages carry recipes, never executable
                // code or an alternate runtime.
                return plugin.adapters
                    .filter { $0.engine == .macUI }
                    .flatMap { adapter -> [PluginManagedUIRuntimeBinding] in
                        bindings(
                            for: adapter,
                            plugin: plugin,
                            record: record,
                            snapshot: snapshot)
                    }
            }
    }

    func bindings(
        for adapter: PluginAdapterSchema,
        plugin: PluginSchema,
        record: AbilityPackageRecord,
        snapshot: AbilityRuntimeSnapshot
    ) -> [PluginManagedUIRuntimeBinding] {
        guard let manifest = snapshot.adapterManifest(id: adapter.id),
              manifest.isAvailable,
              manifest.resolvedProvider.pluginClass == .package,
              manifest.resolvedProvider.originPackageID == record.package.package.id
        else { return [] }

        // Dynamic operations are implementations, never standalone
        // model tools. Materialize only operations OWNED by a ready
        // semantic Skill in this immutable snapshot — every compatible
        // candidate now, not just the statically preferred one, so the
        // per-turn provider resolver has rivals to choose among. An
        // unavailable provider or an otherwise unrealized recipe still
        // cannot fall through as a raw adapter command with no Ability
        // policy owner: only the evaluator's compatible set materializes.
        let selectedOperations = Set(snapshot.skills.flatMap { runtime -> [String] in
            guard runtime.availability.readiness == .ready else { return [] }
            return snapshot.compatibleBindings(for: runtime.skill.id)
                .filter { $0.adapterID == adapter.id }
                .compactMap { candidate in
                    snapshot.plugins.realization(
                        skillID: runtime.skill.id,
                        adapterID: candidate.adapterID,
                        operation: candidate.operation)
                        .flatMap {
                            $0.originPackageID == record.package.package.id
                                ? candidate.operation : nil
                        }
                }
        })

        return plugin.operations
            .filter { operation in
                selectedOperations.contains(operation.operation)
                    && plugin.adapter(for: operation)?.id == adapter.id
            }
            .sorted { $0.operation < $1.operation }
            .map { operation in
                let access = runtimeAccess(
                    for: operation.operation,
                    plugin: plugin,
                    snapshot: snapshot)
                let binding = SkillBinding(
                    name: operation.operation,
                    description: """
                        Operate the already-running target application through one \
                        validated foreground transaction: Mary brings it to the \
                        front, performs the declared keystrokes, and reports. \
                        Physical input is not suppressed and may interleave. The \
                        application must already be open.
                        """,
                    parameters: operation.inputs.map(Self.modelParameter),
                    access: access,
                    backing: .native { [self, plugin, operation] arguments, context in
                        await execute(
                            plugin: plugin,
                            operation: operation,
                            arguments: arguments,
                            context: context,
                            providerIdentity: manifest.resolvedProvider
                                .originPackageDigest.map {
                                    .init(packageDigest: $0)
                                })
                    },
                    // Argument, target, cancellation, and Accessibility errors
                    // already carry their own exact diagnosis. A blanket
                    // permission hint would misdescribe preflight failures.
                    spokenFailureHint: nil,
                    stage: true)
                return PluginManagedUIRuntimeBinding(
                    owner: plugin.application.id,
                    binding: binding)
            }
    }

    func runtimeAccess(
        for operation: String,
        plugin: PluginSchema,
        snapshot: AbilityRuntimeSnapshot
    ) -> SkillAccessPolicy {
        let access = plugin.realizations
            .filter { $0.operation == operation }
            .compactMap { snapshot.skill(id: $0.skillID)?.skill.access }
        if access.contains(.confirm) { return .write }
        return .tweak
    }

    static func modelParameter(
        _ input: PluginOperationInputSchema
    ) -> ModelSkillSchema.Parameter {
        let type: String
        switch input.kind {
        case .text: type = "string"
        case .number: type = "number"
        case .integer: type = "integer"
        case .boolean: type = "boolean"
        }
        let range: String
        switch (input.minimum, input.maximum) {
        case (.some(let minimum), .some(let maximum)):
            range = " It must be between \(minimum) and \(maximum), inclusive."
        case (.some(let minimum), nil):
            range = " It must be at least \(minimum)."
        case (nil, .some(let maximum)):
            range = " It must be no more than \(maximum)."
        case (nil, nil):
            range = ""
        }
        return ModelSkillSchema.Parameter(
            name: input.name,
            type: type,
            description: "Validated input \(input.name) for the selected application operation.\(range)",
            required: input.required && input.defaultValue == nil,
            enumValues: input.enumValues.isEmpty ? nil : input.enumValues,
            minimum: input.minimum,
            maximum: input.maximum)
    }
}
