//
//  AbilityRuntime+Cognitive.swift
//  MaryBrain
//
//  WHAT: Cognitive primitives — instruction, not effect.
//  IN:   a closed CognitivePrimitiveContract
//  OUT:  the activated instruction, plus its placement clause
//  PIN:  No application is touched. Placement is a SENTENCE about where the
//        work would land, never a write.
//
import Foundation

extension AbilityRuntime {

    // MARK: - Cognitive and workflow execution

    /// Cognitive primitives and schema state machines intentionally keep their internal steps out of memory.
    static func applyingTotemArchivePolicy(
        _ input: SkillOutcome,
        reference: AbilitySkillReference,
        snapshot: AbilityRuntime.Snapshot
    ) -> SkillOutcome {
        guard input.archivePolicy == .none,
              input.status == .succeeded || input.status == .failed,
              snapshot.totemProjectionPlan(for: reference)?.permitsDurableStorage == true
        else { return input }
        var output = input
        output.archivePolicy = .episodic
        return output
    }

    func executeCognitive(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        snapshot: AbilityRuntime.Snapshot,
        typedInputs: [String: ValueEnvelope] = [:],
        signals: SchemaSignalTurnSnapshot
    ) -> SkillOutcome {
        let policy = snapshot.executionPolicy(for: runtime.skill)
        if let failure = payloadFailure(
            runtime: runtime,
            arguments: arguments,
            typedInputs: typedInputs,
            signals: signals,
            policy: policy) {
            return failure
        }
        guard let contract = CognitivePrimitiveCatalog.contract(for: runtime) else {
            return blockedOutcome(
                runtime: runtime,
                reason: "no closed Mary cognitive primitive is registered")
        }
        if let missing = CognitivePrimitiveCatalog.missingRequiredArgument(
            for: contract,
            arguments: arguments) {
            return SkillOutcome(
                ok: false,
                summary: "\(runtime.reference.displayLabel) needs \(missing).",
                status: .blocked,
                archivePolicy: .none,
                skillReference: runtime.reference)
        }
        var summary = CognitivePrimitiveCatalog.activate(
            contract,
            arguments: arguments)
        // compose_draft placement: staged surface, else a writing world the utterance named.
        if contract.primitive == .composeDraft {
            let staged = StagedWritingSurface.shared.fresh()
            // Named writing place — not a compiled editor list (that dropped other apps).
            let namedWriting = world.store.route()?.namedPlaces
                .first(where: { $0.focus == .writing })
            if let clause = CognitivePrimitiveCatalog.composePlacementClause(
                stagedApplicationName: staged.map { $0.spokenName ?? $0.bundleID },
                namedWritingApplication: namedWriting?.displayName) {
                summary += clause
            }
        } else if contract.primitive == .reviseSelection {
            // revise_selection: whether the routed selection is still there to write into.
            if let clause = CognitivePrimitiveCatalog.revisionPlacementClause(
                hasRoutedSelection: world.store.routedSelectionHandoff(
                    requiringWritingTarget: true) != nil) {
                summary += clause
            }
        } else if contract.primitive == .reviseCodeSelection {
            // Code-lane mirror, gated on the predicate that lane's placing Skill uses.
            if let clause = CognitivePrimitiveCatalog.codeRevisionPlacementClause(
                hasRoutedCodeSelection:
                    world.store.routedSelectionHandoff()?.place.focus == .coding) {
                summary += clause
            }
        }
        var typedOutputs: [String: ValueEnvelope] = [:]
        for output in runtime.skill.outputs {
            guard let schema = snapshot.valueTypeSchema(id: output.valueType),
                  schema.shape == .string
            else { continue }
            typedOutputs[output.name] = ValueEnvelope(
                    typeID: output.valueType,
                    schemaVersion: schema.version,
                    value: .string(summary),
                    provenance: .init(operation: runtime.reference.invocationName),
                    privacy: .private)
        }
        let outcome = enforceOutputPayload(
            SkillOutcome(
            ok: true,
            summary: summary,
            archivePolicy: .none,
            skillReference: runtime.reference,
            typedOutputs: typedOutputs),
            runtime: runtime,
            policy: policy)
        recordSchemaExecution(
            runtime: runtime,
            arguments: arguments,
            outcome: outcome)
        return outcome
    }

    func activateWorkflowPrimitive(
        _ contract: CognitivePrimitiveContract,
        arguments: [String: String]
    ) -> String {
        switch contract.primitive {
        case .retrieveProjectContext:
            return renderProjectFacts(
                arguments: arguments,
                retainedOnly: false)
        case .searchProjectKnowledge:
            return renderProjectFacts(
                arguments: arguments,
                retainedOnly: true)
        default:
            return CognitivePrimitiveCatalog.activate(
                contract,
                arguments: arguments)
        }
    }

    /// Concrete Architect retrieval over Mary's source-attributed ambient ledger.
    private func renderProjectFacts(
        arguments: [String: String],
        retainedOnly: Bool
    ) -> String {
        let project = Self.projectName(in: arguments)?.lowercased()
        let requestTokens = Set(
            (arguments["request"] ?? arguments["question"] ?? "")
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count > 2 }
                .map(String.init))
        // Same immutable route as prompt assembly — Architect is an Ability path.
        let routedFacts = world.store.route().map { route in
            world.store.facts().filter(route.admitsHeldFact)
        } ?? world.store.facts()
        let candidates = routedFacts.filter { fact in
            if retainedOnly && fact.registration != .askedFor
                && !fact.slot.isRead
                && fact.slot != .project
                && fact.slot != .git {
                return false
            }
            if let project {
                let identity = [fact.subject, fact.content]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")
                guard identity.contains(project) else { return false }
            }
            guard retainedOnly, !requestTokens.isEmpty else { return true }
            let searchable = "\(fact.subject ?? "") \(fact.content)".lowercased()
            let words = Set(searchable
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init))
            return !words.isDisjoint(with: requestTokens)
        }
        let selected = candidates
            .sorted { left, right in left.capturedAt > right.capturedAt }
            .prefix(8)
        guard !selected.isEmpty else {
            return retainedOnly
                ? "No matching source-attributed project knowledge is currently held."
                : "No source-attributed live context is currently held for that project."
        }
        return selected.map { fact in
            let subject = fact.subject.map { " · \($0)" } ?? ""
            let content = String(fact.content.prefix(700))
            return "\(fact.attention.rawValue)/\(fact.slot.token)\(subject): \(content)"
        }.joined(separator: "\n")
    }

    private static func projectName(in arguments: [String: String]) -> String? {
        if let explicit = arguments["project"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        for key in ["scope", "interaction.project-reference", "request"] {
            guard let text = arguments[key],
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let project = object["project"] as? String,
                  !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return project
        }
        return nil
    }
}
