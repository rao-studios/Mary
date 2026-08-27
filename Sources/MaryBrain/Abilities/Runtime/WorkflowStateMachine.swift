import MaryFoundation
import Foundation

/// One typed value in a workflow's private port ledger. Existing Plugin
/// bindings accept string dictionaries, so `value` remains their transport;
/// `valueType` preserves the schema identity through every step that declares
/// one and makes the eventual adapter upgrade lossless.
struct WorkflowPortValue: Sendable, Equatable {
    var value: String
    var valueType: ValueTypeID?
    var envelope: ValueEnvelope?
    var producerStepID: String?

    init(
        value: String,
        valueType: ValueTypeID?,
        envelope: ValueEnvelope? = nil,
        producerStepID: String?
    ) {
        self.value = value
        self.valueType = valueType ?? envelope?.typeID
        self.envelope = envelope
        self.producerStepID = producerStepID
    }
}

struct WorkflowOperationResult: Sendable {
    var outcome: SkillOutcome
    var outputTypes: [ValueTypeID]
    var outputEnvelopes: [ValueEnvelope?]

    init(
        outcome: SkillOutcome,
        outputTypes: [ValueTypeID] = [],
        outputEnvelopes: [ValueEnvelope?] = []
    ) {
        self.outcome = outcome
        self.outputTypes = outputTypes
        self.outputEnvelopes = outputEnvelopes
    }
}

struct WorkflowMachineResult: Sendable {
    var outcome: SkillOutcome
    var visitedStepIDs: [String]
    var ports: [String: WorkflowPortValue]
}

/// Deterministic state-machine runner for `.mary` workflow Skills. It knows
/// nothing about plugins or models: resolution and execution are injected by
/// AbilityRuntime after its graph and safety checks succeed.
enum WorkflowStateMachine {
    static let maximumTransitions = 64

    static func run(
        skill: SkillSchema,
        arguments: [String: String],
        supplementalPorts: [String: WorkflowPortValue] = [:],
        maximumTransitions: Int = maximumTransitions,
        execute: @escaping @Sendable (
            WorkflowStepSchema,
            [String: WorkflowPortValue],
            [String: String]
        ) async -> WorkflowOperationResult
    ) async -> WorkflowMachineResult {
        guard skill.execution.kind == .stateMachine,
              let first = skill.execution.steps.first
        else {
            return failure(
                "The Skill does not contain an executable state machine.",
                ports: supplementalPorts)
        }

        let steps = Dictionary(
            skill.execution.steps.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        guard steps.count == skill.execution.steps.count else {
            return failure(
                "The workflow contains duplicate step identities.",
                ports: supplementalPorts)
        }

        var ports = supplementalPorts
        for (name, value) in arguments where ports[name] == nil {
            ports[name] = WorkflowPortValue(
                value: value,
                valueType: skill.inputs.first(where: { $0.name == name })?.valueType,
                producerStepID: nil)
        }

        // Model parameters and typed ports are independent schemas. Most
        // current Skills have one typed request port whose model projection is
        // named `task`, `question`, or `instruction`; preserve the type while
        // adapting that single value rather than throwing it away.
        if skill.inputs.count == 1,
           let input = skill.inputs.first,
           ports[input.name] == nil,
           let parameter = skill.modelExposure.parameters.first(where: {
               arguments[$0.name] != nil
           }),
           let value = arguments[parameter.name] {
            ports[input.name] = WorkflowPortValue(
                value: value,
                valueType: input.valueType,
                producerStepID: nil)
        }

        for required in skill.inputs where required.required && ports[required.name] == nil {
            return failure(
                "The workflow is missing required input port \(required.name).",
                ports: ports)
        }

        var currentID = first.id
        var visited: [String] = []
        let transitionLimit = max(1, min(maximumTransitions, Self.maximumTransitions))

        for _ in 0..<transitionLimit {
            guard !Task.isCancelled else {
                return failure(
                    "The workflow was cancelled before it completed.",
                    status: .cancelled,
                    ports: ports,
                    visited: visited)
            }
            guard let step = steps[currentID] else {
                return failure(
                    "The workflow transitioned to unknown step \(currentID).",
                    ports: ports,
                    visited: visited)
            }
            visited.append(step.id)

            let missing = step.consumes.filter { ports[$0] == nil }
            if !missing.isEmpty {
                let outcome = SkillOutcome(
                    ok: false,
                    summary: "Workflow step \(step.id) is missing port(s): \(missing.joined(separator: ", ")).",
                    status: .blocked,
                    archivePolicy: .none)
                if let recovery = step.onFailure {
                    currentID = recovery
                    continue
                }
                return WorkflowMachineResult(
                    outcome: outcome,
                    visitedStepIDs: visited,
                    ports: ports)
            }

            let result = await execute(step, ports, arguments)
            let outcome = result.outcome
            // Requested/deferred/cancelled operations do not represent a
            // settled value that later steps may consume. The workflow returns
            // that honest state instead of racing ahead (notably, a deferred
            // code edit must not immediately run its build step).
            if outcome.status == .requested
                || outcome.status == .deferred
                || outcome.status == .cancelled {
                return WorkflowMachineResult(
                    outcome: outcome,
                    visitedStepIDs: visited,
                    ports: ports)
            }

            if outcome.ok && !outcome.foundNothing {
                for (index, name) in step.produces.enumerated() {
                    let envelope = index < result.outputEnvelopes.count
                        ? result.outputEnvelopes[index] : nil
                    ports[name] = WorkflowPortValue(
                        value: envelope.flatMap(legacyString) ?? outcome.summary,
                        valueType: index < result.outputTypes.count
                            ? result.outputTypes[index] : nil,
                        envelope: envelope,
                        producerStepID: step.id)
                }
            }

            let succeeded = outcome.ok && !outcome.foundNothing
            let next = succeeded ? step.onSuccess : step.onFailure
            if let next {
                currentID = next
                continue
            }
            if succeeded,
               let sequential = sequentialSuccessor(after: step.id, in: skill.execution.steps) {
                currentID = sequential
                continue
            }

            if succeeded {
                let missingOutputs = skill.outputs
                    .filter(\.required)
                    .filter { ports[$0.name] == nil }
                    .map(\.name)
                if !missingOutputs.isEmpty {
                    return failure(
                        "The workflow completed without required output port(s): \(missingOutputs.joined(separator: ", ")).",
                        ports: ports,
                        visited: visited)
                }
            }
            return WorkflowMachineResult(
                outcome: outcome,
                visitedStepIDs: visited,
                ports: ports)
        }

        return failure(
            "The workflow exceeded its \(transitionLimit)-transition bound.",
            status: .blocked,
            ports: ports,
            visited: visited)
    }

    private static func sequentialSuccessor(
        after id: String,
        in steps: [WorkflowStepSchema]
    ) -> String? {
        guard let index = steps.firstIndex(where: { $0.id == id }),
              steps.indices.contains(index + 1)
        else { return nil }
        return steps[index + 1].id
    }

    private static func failure(
        _ summary: String,
        status: SkillRunStatus = .failed,
        ports: [String: WorkflowPortValue],
        visited: [String] = []
    ) -> WorkflowMachineResult {
        WorkflowMachineResult(
            outcome: SkillOutcome(
                ok: false,
                summary: summary,
                status: status,
                archivePolicy: .none),
            visitedStepIDs: visited,
            ports: ports)
    }

    private static func legacyString(_ envelope: ValueEnvelope) -> String? {
        switch envelope.value {
        case .string(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .null: return "null"
        case .object, .array, .data:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(envelope.value))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
