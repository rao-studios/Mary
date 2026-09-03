//
//  AbilityRuntime+Workflow.swift
//  MaryBrain
//
//  WHAT: Schema state machines — bounded, validated, step by step.
//  IN:   a `.stateMachine` Skill + its typed ports
//  OUT:  SkillOutcome with the machine's typed outputs
//  PIN:  Every step resolves to an installed Skill or a closed cognitive
//        primitive BEFORE execution begins, and none may cross a
//        user-confirmation boundary.
//
import Foundation

extension AbilityRuntime {

    func executeWorkflow(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        snapshot: AbilityRuntime.Snapshot,
        context: AbilityExecutionContext,
        signals: SchemaSignalTurnSnapshot,
        depth: Int = 0
    ) async -> SkillOutcome {
        guard depth < 8 else {
            return blockedOutcome(
                runtime: runtime,
                reason: "the nested workflow depth exceeded Mary's bound")
        }
        if let reason = workflowExecutionSafetyFailure(
            for: runtime,
            snapshot: snapshot) {
            return blockedOutcome(runtime: runtime, reason: reason)
        }
        let policy = snapshot.executionPolicy(for: runtime.skill)
        if let failure = payloadFailure(
            runtime: runtime,
            arguments: arguments,
            typedInputs: [:],
            signals: signals,
            policy: policy) {
            return failure
        }

        // Packages may shorten the budget, not enlarge Mary's ten-minute ceiling.
        let userCap = ordinarySkillTimeout.withLock { $0 }
        let budget = Self.effectiveBudget(
            bindingName: runtime.reference.invocationName,
            userCap: userCap,
            declaredTimeoutSeconds: runtime.skill.timeoutSeconds ?? 600,
            maximumDurationSeconds: min(policy.maximumDurationSeconds ?? 600, 600))
        let supplementalPorts = workflowSupplementalPorts(
            for: runtime,
            arguments: arguments,
            snapshot: snapshot)
        let worker = Task { [self] in
            await WorkflowStateMachine.run(
                skill: runtime.skill,
                arguments: arguments,
                supplementalPorts: supplementalPorts) { step, ports, originalArguments in
                    await self.executeWorkflowStep(
                        step,
                        owner: runtime,
                        ports: ports,
                        originalArguments: originalArguments,
                        snapshot: snapshot,
                        context: context,
                        signals: signals,
                        depth: depth)
                }
        }
        let runIdentity = registerInFlight { worker.cancel() }
        defer { releaseInFlight(runIdentity) }
        let result = await withTaskCancellationHandler {
            await bounded(budget) { await worker.value }
        } onCancel: {
            worker.cancel()
        }
        worker.cancel()
        // Same rule as `performExecute`: a requested stop is what the record says happened.
        if wasStopRequested(runIdentity) {
            let stopped = SkillOutcome(
                ok: false,
                summary: "You stopped \(runtime.reference.invocationName).",
                status: .cancelled,
                archivePolicy: .none,
                skillReference: runtime.reference)
            recordSchemaExecution(
                runtime: runtime, arguments: arguments, outcome: stopped)
            return stopped
        }

        guard let machineResult = result else {
            let timedOut = SkillOutcome(
                ok: false,
                summary: "\(runtime.reference.displayLabel) did not finish within \(Int(budget)) seconds.",
                status: .failed,
                archivePolicy: .none,
                skillReference: runtime.reference)
            recordSchemaExecution(
                runtime: runtime,
                arguments: arguments,
                outcome: timedOut)
            return timedOut
        }
        var outcome = machineResult.outcome
        outcome.skillReference = runtime.reference
        for output in runtime.skill.outputs {
            if let envelope = machineResult.ports[output.name]?.envelope {
                outcome.typedOutputs[output.name] = envelope
            }
        }
        if outcome.status == .deferred || outcome.status == .requested {
            outcome.archivePolicy = .none
        }
        outcome = enforceOutputPayload(
            outcome,
            runtime: runtime,
            policy: policy)
        recordSchemaExecution(
            runtime: runtime,
            arguments: arguments,
            outcome: outcome)
        return outcome
    }

    private func executeWorkflowStep(
        _ step: WorkflowStepSchema,
        owner: AbilityRuntimeSkill,
        ports: [String: WorkflowPortValue],
        originalArguments: [String: String],
        snapshot: AbilityRuntime.Snapshot,
        context: AbilityExecutionContext,
        signals: SchemaSignalTurnSnapshot,
        depth: Int
    ) async -> WorkflowOperationResult {
        if let target = snapshot.skill(invocationName: step.operation) {
            // A validated workflow is already an exact machine route.
            if let reason = dispatchEligibilityFailure(
                for: target,
                in: abilityRoutingContext(),
                snapshot: snapshot) {
                return WorkflowOperationResult(outcome: blockedOutcome(
                    runtime: target,
                    reason: reason))
            }
            let arguments = workflowArguments(
                for: target,
                step: step,
                ports: ports,
                originalArguments: originalArguments)
            switch target.skill.execution.kind {
            case .cognitive:
                let outcome = executeCognitive(
                    runtime: target,
                    arguments: arguments,
                    snapshot: snapshot,
                    typedInputs: Dictionary(
                        uniqueKeysWithValues: step.consumes.compactMap { name in
                            ports[name]?.envelope.map { (name, $0) }
                        }),
                    signals: signals)
                return WorkflowOperationResult(
                    outcome: outcome,
                    outputTypes: target.skill.outputs.map(\.valueType),
                    outputEnvelopes: target.skill.outputs.map {
                        outcome.typedOutputs[$0.name]
                    })
            case .stateMachine:
                let outcome = await executeWorkflow(
                    runtime: target,
                    arguments: arguments,
                    snapshot: snapshot,
                    context: context,
                    signals: signals,
                    depth: depth + 1)
                return WorkflowOperationResult(
                    outcome: outcome,
                    outputTypes: target.skill.outputs.map(\.valueType),
                    outputEnvelopes: target.skill.outputs.map {
                        outcome.typedOutputs[$0.name]
                    })
            case .binding:
                guard let operation = target.bindingOperation,
                      var binding = attributed.first(where: {
                          $0.binding.name == operation
                      })?.binding
                else {
                    return WorkflowOperationResult(outcome: blockedOutcome(
                        runtime: target,
                        reason: "its exact adapter implementation disappeared"))
                }
                if target.skill.access == .confirm { binding.access = .write }
                binding.stage = binding.stage || target.skill.usesStage
                guard binding.access != .write else {
                    return WorkflowOperationResult(outcome: blockedOutcome(
                        runtime: target,
                        reason: "a workflow cannot cross a user-confirmation boundary without a declared continuation"))
                }
                let reconciled = Self.reconcile(
                    arguments,
                    against: binding.parameters)
                let typedInputs = Dictionary(
                    uniqueKeysWithValues: step.consumes.compactMap { name in
                        ports[name]?.envelope.map { (name, $0) }
                    })
                let outcome = await execute(
                    binding: binding,
                    arguments: reconciled,
                    typedInputs: typedInputs,
                    context: context,
                    reference: target.reference,
                    runtime: target,
                    policy: snapshot.executionPolicy(for: target.skill),
                    signals: signals)
                return WorkflowOperationResult(
                    outcome: outcome,
                    outputTypes: target.skill.outputs.map(\.valueType),
                    outputEnvelopes: target.skill.outputs.map {
                        outcome.typedOutputs[$0.name]
                    })
            }
        }

        guard let contract = CognitivePrimitiveCatalog.contract(
            workflowOperation: step.operation,
            abilityID: owner.ability.id)
        else {
            return WorkflowOperationResult(outcome: SkillOutcome(
                ok: false,
                summary: "Workflow step \(step.id) has no executable operation.",
                status: .blocked,
                archivePolicy: .none,
                skillReference: owner.reference))
        }
        let arguments = workflowArguments(
            for: nil,
            step: step,
            ports: ports,
            originalArguments: originalArguments)
        return WorkflowOperationResult(outcome: SkillOutcome(
            ok: true,
            summary: activateWorkflowPrimitive(
                contract,
                arguments: arguments),
            archivePolicy: .none,
            skillReference: owner.reference))
    }

    /// Adapts the typed workflow ledger onto today's string-dictionary Plugin seam.
    private func workflowArguments(
        for target: AbilityRuntimeSkill?,
        step: WorkflowStepSchema,
        ports: [String: WorkflowPortValue],
        originalArguments: [String: String]
    ) -> [String: String] {
        var result = originalArguments
        let consumed = step.consumes.compactMap { name in
            ports[name].map { (name, $0) }
        }
        for (name, port) in consumed { result[name] = port.value }
        guard let target else { return result }

        for (index, input) in target.skill.inputs.enumerated()
        where result[input.name] == nil {
            let typed = consumed.first { $0.1.valueType == input.valueType }
            let positional = index < consumed.count ? consumed[index] : nil
            if let source = typed ?? positional {
                result[input.name] = source.1.value
            }
        }

        for (index, parameter) in target.skill.modelExposure.parameters.enumerated()
        where result[parameter.name] == nil {
            if target.skill.inputs.count == 1,
               let input = target.skill.inputs.first,
               let value = result[input.name] {
                result[parameter.name] = value
            } else if index < consumed.count {
                result[parameter.name] = consumed[index].1.value
            }
        }
        return result
    }

    private func workflowSupplementalPorts(
        for runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        snapshot: AbilityRuntime.Snapshot
    ) -> [String: WorkflowPortValue] {
        var ports: [String: WorkflowPortValue] = [:]
        let signals = routedSignalSnapshot()
        for interaction in signals.interactions(declaredBy: runtime.skill) {
            ports[interaction.reference.schemaID.rawValue] = WorkflowPortValue(
                value: Self.legacyString(interaction.value.value),
                valueType: interaction.value.typeID,
                envelope: interaction.value,
                producerStepID: nil)
        }
        for interactionID in runtime.skill.requirements.optionalInteractions
        where ports[interactionID.rawValue] == nil {
            guard let interaction = snapshot.interactionSchema(id: interactionID),
                  let valueSchema = snapshot.valueTypeSchema(id: interaction.valueType),
                  let envelope = Self.structuredEnvelope(
                      arguments: arguments,
                      schema: valueSchema,
                      registry: snapshot.valueTypeSchemas,
                      operation: runtime.reference.invocationName,
                      interactionID: interactionID)
            else { continue }
            ports[interactionID.rawValue] = WorkflowPortValue(
                value: Self.legacyString(envelope.value),
                valueType: envelope.typeID,
                envelope: envelope,
                producerStepID: nil)
        }
        for perceptionID in runtime.skill.requirements.perceptions
            + runtime.skill.requirements.optionalPerceptions {
            guard let perception = signals.perceptions.first(where: {
                $0.reference.schemaID == perceptionID
            }) else { continue }
            ports[perceptionID.rawValue] = WorkflowPortValue(
                value: Self.legacyString(perception.value.value),
                valueType: perception.value.typeID,
                envelope: perception.value,
                producerStepID: nil)
        }

        for (index, input) in runtime.skill.inputs.enumerated() {
            let projectedName = index < runtime.skill.modelExposure.parameters.count
                ? runtime.skill.modelExposure.parameters[index].name : input.name
            guard let value = arguments[input.name] ?? arguments[projectedName],
                  let schema = snapshot.valueTypeSchema(id: input.valueType),
                  let envelope = Self.legacyEnvelope(
                      value,
                      schema: schema,
                      registry: snapshot.valueTypeSchemas,
                      operation: runtime.reference.invocationName)
                    ?? Self.structuredEnvelope(
                        arguments: arguments,
                        schema: schema,
                        registry: snapshot.valueTypeSchemas,
                        operation: runtime.reference.invocationName)
            else { continue }
            ports[input.name] = WorkflowPortValue(
                value: value,
                valueType: input.valueType,
                envelope: envelope,
                producerStepID: nil)
        }
        return ports
    }

    private static func legacyEnvelope(
        _ value: String,
        schema: ValueTypeSchema,
        registry: [ValueTypeSchema],
        operation: String
    ) -> ValueEnvelope? {
        let payload: MaryValue
        switch schema.shape {
        case .string, .enumeration:
            payload = .string(value)
        case .boolean:
            guard let parsed = Bool(value.lowercased()) else { return nil }
            payload = .boolean(parsed)
        case .integer:
            guard let parsed = Int64(value) else { return nil }
            payload = .integer(parsed)
        case .number:
            guard let parsed = Double(value), parsed.isFinite else { return nil }
            payload = .number(parsed)
        case .object, .array:
            guard let data = value.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(MaryValue.self, from: data)
            else { return nil }
            payload = parsed
        case .data:
            guard let data = Data(base64Encoded: value) else { return nil }
            payload = .data(data)
        }
        let envelope = ValueEnvelope(
            typeID: schema.id,
            schemaVersion: schema.version,
            value: payload,
            provenance: .init(operation: operation),
            privacy: .private)
        return ValueEnvelopeValidator.validate(
            envelope,
            schemas: registry).isValid ? envelope : nil
    }

    private static func structuredEnvelope(
        arguments: [String: String],
        schema: ValueTypeSchema,
        registry: [ValueTypeSchema],
        operation: String,
        interactionID: InteractionID? = nil
    ) -> ValueEnvelope? {
        let schemas = Dictionary(
            registry.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        guard let value = structuredValue(
            arguments: arguments,
            schema: schema,
            schemas: schemas)
        else { return nil }
        let project = arguments["project"]
        let envelope = ValueEnvelope(
            typeID: schema.id,
            schemaVersion: schema.version,
            value: value,
            scope: SourceScope(projectID: project),
            provenance: .init(
                operation: operation,
                interactionID: interactionID),
            privacy: .sensitive)
        return ValueEnvelopeValidator.validate(
            envelope,
            schemas: registry).isValid ? envelope : nil
    }

    private static func structuredValue(
        arguments: [String: String],
        schema: ValueTypeSchema,
        schemas: [ValueTypeID: ValueTypeSchema]
    ) -> MaryValue? {
        if schema.shape != .object {
            guard let text = arguments[schema.id.rawValue]
                ?? arguments[schema.id.rawValue.split(separator: ".").last.map(String.init) ?? ""]
            else { return nil }
            return primitiveValue(text, shape: schema.shape)
        }
        var fields: [String: MaryValue] = [:]
        for field in schema.fields {
            guard let fieldSchema = schemas[field.valueType] else { return nil }
            guard let text = arguments[field.name] else {
                if field.required { return nil }
                continue
            }
            guard let value = primitiveValue(text, shape: fieldSchema.shape) else {
                return nil
            }
            fields[field.name] = value
        }
        return .object(fields)
    }

    private static func primitiveValue(
        _ text: String,
        shape: ValueShape
    ) -> MaryValue? {
        switch shape {
        case .string, .enumeration: return .string(text)
        case .boolean: return Bool(text.lowercased()).map(MaryValue.boolean)
        case .integer: return Int64(text).map(MaryValue.integer)
        case .number:
            guard let value = Double(text), value.isFinite else { return nil }
            return .number(value)
        case .object, .array:
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(MaryValue.self, from: data)
        case .data:
            return Data(base64Encoded: text).map(MaryValue.data)
        }
    }

    private static func legacyString(_ value: MaryValue) -> String {
        switch value {
        case .string(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .null: return "null"
        case .object, .array, .data:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    func recordSchemaExecution(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        outcome: SkillOutcome
    ) {
        // Recording lives in `dispatch` — one record per act, refusals included.
        _ = arguments
        _ = outcome
    }
}
