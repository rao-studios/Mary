//
//  CognitivePrimitiveRuntime.swift
//  MaryBrain
//
//  WHAT: Mary's closed cognitive instruction set.
//  IN:   exact built-in Skill identity from a package
//  OUT:  typed activation + Mary-owned guidance for the next model round
//  PIN:  Packages cannot inject a new reasoning procedure through prose.
//
import MaryFoundation
import Foundation

/// Mary's closed cognitive instruction set. Ability packages may select one of these contracts by exporting the exact built-in Skill identity
/// The activation is deliberately small and provider-neutral.
enum MaryCognitivePrimitive: String, Sendable, CaseIterable {
    case composeDraft = "mary.cognition.compose-draft"
    case reviseSelection = "mary.cognition.revise-selection"
    case reviseCodeSelection = "mary.cognition.revise-code-selection"
    case frameProblem = "mary.cognition.frame-problem"
    case compareOptions = "mary.cognition.compare-options"
    case reviewDesign = "mary.cognition.review-design"

    // Workflow-only primitives. These names are never projected as model
    // calls; a validated state machine may activate them as deterministic
    // transformations between effectful steps.
    case planMinimalCodeChange = "mary.cognition.plan-minimal-code-change"
    case explainCodeChange = "mary.cognition.explain-code-change"
    case selectDesignOption = "mary.cognition.select-design-option"
    case deriveSafeSequence = "mary.cognition.derive-safe-sequence"
    case synthesizeProjectMap = "mary.cognition.synthesize-project-map"
    case identifyMaterialUnknowns = "mary.cognition.identify-material-unknowns"
    case requestProjectScope = "mary.cognition.request-project-scope"
    case structureDecisionRecord = "mary.cognition.structure-decision-record"
    case resolveProjectScope = "mary.cognition.resolve-project-scope"
    case recordProjectRationale = "mary.cognition.record-project-rationale"
    case retrieveProjectContext = "mary.cognition.retrieve-project-context"
    case searchProjectKnowledge = "mary.cognition.search-project-knowledge"
}

struct CognitivePrimitiveContract: Sendable {
    var primitive: MaryCognitivePrimitive
    var allowedAbility: AbilityID
    var directSkillID: SkillID?
    var invocationName: String?
    var workflowOperation: String?
    var description: String
    var parameters: [ModelSkillSchema.Parameter]
}

/// One workflow-only primitive, named for an authoring surface. Read-only: the
/// contracts themselves stay internal, because only the runtime may execute one.
public struct WorkflowPrimitiveDescriptor: Hashable, Sendable {
    public let operation: String
    public let summary: String
}

public enum CognitivePrimitiveCatalog {
    private static let contracts: [CognitivePrimitiveContract] = [
        .init(
            primitive: .composeDraft,
            allowedAbility: .writing,
            directSkillID: "writing.compose-draft",
            invocationName: "compose_draft",
            workflowOperation: nil,
            description: "Activate Mary's bounded drafting procedure. Use it when the user wants new prose; it produces text but does not type into an application.",
            parameters: [
                .init(name: "request", type: "string", description: "The outcome the draft must accomplish.", required: true),
                .init(name: "audience", type: "string", description: "The intended reader, when known.", required: false),
                .init(name: "tone", type: "string", description: "The requested tone, when known.", required: false),
            ]),
        .init(
            primitive: .reviseSelection,
            allowedAbility: .writing,
            directSkillID: "writing.revise-selection",
            invocationName: "revise_selection",
            workflowOperation: nil,
            description: "Activate Mary's selection-bounded revision procedure. It drafts a replacement for the current verified selection but does not mutate the source application.",
            parameters: [
                .init(name: "instruction", type: "string", description: "The requested change to the verified selection.", required: true),
            ]),
        // THE CODING HALF OF THE SAME PROCEDURE, and a separate contract rather than a widened `allowedAbility` on the one above: the catalog's lookup is exact-match on…
        .init(
            primitive: .reviseCodeSelection,
            allowedAbility: .coding,
            directSkillID: "coding.revise-selection",
            invocationName: "revise_code_selection",
            workflowOperation: nil,
            description: "Activate Mary's selection-bounded code revision procedure. Use it when the user asks for the selected code — a comment, a line, a function — to be reworded, tightened, simplified or rewritten. It drafts a replacement for the verified selection but does not itself write to the file.",
            parameters: [
                .init(name: "instruction", type: "string", description: "The requested change to the selected code.", required: true),
            ]),
        .init(
            primitive: .frameProblem,
            allowedAbility: .architect,
            directSkillID: "architect.frame-problem",
            invocationName: "frame_problem",
            workflowOperation: "frame_problem",
            description: "Activate Mary's architecture framing procedure: identify the goal, constraints, non-goals, material unknowns, and success signals.",
            parameters: [
                .init(name: "question", type: "string", description: "The architecture or product question to frame.", required: true),
            ]),
        .init(
            primitive: .compareOptions,
            allowedAbility: .architect,
            directSkillID: "architect.compare-options",
            invocationName: "compare_design_options",
            workflowOperation: "compare_design_options",
            description: "Activate Mary's design comparison procedure: compare distinct mechanisms by constraints, failure modes, cost, and reversibility.",
            parameters: [
                .init(name: "goal", type: "string", description: "The framed design goal.", required: true),
                .init(name: "constraints", type: "array", description: "Constraints every option must respect.", required: false),
            ]),
        .init(
            primitive: .reviewDesign,
            allowedAbility: .architect,
            directSkillID: "architect.review-design",
            invocationName: "review_design",
            workflowOperation: nil,
            description: "Activate Mary's design review procedure: test a proposal against its constraints, boundaries, failure modes, and readability.",
            parameters: [
                .init(name: "proposal", type: "string", description: "The design proposal to review.", required: true),
            ]),
        .init(
            primitive: .planMinimalCodeChange,
            allowedAbility: .coding,
            directSkillID: "coding.plan-minimal-code-change",
            invocationName: nil,
            workflowOperation: "plan_minimal_code_change",
            description: "Form a minimal implementation plan from the typed request and grounded source evidence.",
            parameters: []),
        .init(
            primitive: .explainCodeChange,
            allowedAbility: .coding,
            directSkillID: "coding.explain-code-change",
            invocationName: nil,
            workflowOperation: "explain_code_change",
            description: "Summarize the concrete change result and verification result without overstating either.",
            parameters: []),
        .init(
            primitive: .selectDesignOption,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "select_design_option",
            description: "Choose the option that best satisfies the framed constraints and state the tradeoff.",
            parameters: []),
        .init(
            primitive: .deriveSafeSequence,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "derive_safe_sequence",
            description: "Order a design into bounded, verifiable implementation stages.",
            parameters: []),
        .init(
            primitive: .synthesizeProjectMap,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "synthesize_project_map",
            description: "Combine live and retained project evidence into one source-attributed project map.",
            parameters: []),
        .init(
            primitive: .identifyMaterialUnknowns,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "identify_material_unknowns",
            description: "Identify only unknowns that could change the proposed design.",
            parameters: []),
        .init(
            primitive: .requestProjectScope,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "request_project_scope",
            description: "Return a bounded request for the missing project identity.",
            parameters: []),
        .init(
            primitive: .structureDecisionRecord,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "structure_decision_record",
            description: "Normalize an explicit decision into decision, rationale, alternatives, and consequences fields.",
            parameters: []),
        .init(
            primitive: .resolveProjectScope,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "resolve_project_scope",
            description: "Resolve an explicit or source-owned project identity without guessing.",
            parameters: []),
        .init(
            primitive: .recordProjectRationale,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "record_project_rationale",
            description: "Return the explicit structured decision as the workflow's durable projection payload.",
            parameters: []),
        .init(
            primitive: .retrieveProjectContext,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "retrieve_project_context",
            description: "Retrieve source-attributed live project facts already held by Mary.",
            parameters: []),
        .init(
            primitive: .searchProjectKnowledge,
            allowedAbility: .architect,
            directSkillID: nil,
            invocationName: nil,
            workflowOperation: "search_project_knowledge",
            description: "Search Mary's bounded held project knowledge for facts relevant to the request.",
            parameters: []),
    ]

    static func contract(for runtime: AbilityRuntimeSkill) -> CognitivePrimitiveContract? {
        guard runtime.skill.execution.kind == .cognitive else { return nil }
        if let match = contracts.first(where: {
            $0.allowedAbility == runtime.ability.id
                && $0.directSkillID == runtime.skill.id
                && $0.invocationName == runtime.reference.invocationName
        }) {
            return match
        }
        // Workflow-only primitives: the package Skill is not model-exposed, so
        // the reference identity is the Skill id rather than an invocation.
        return contracts.first {
            $0.allowedAbility == runtime.ability.id
                && $0.directSkillID == runtime.skill.id
                && $0.invocationName == nil
        }
    }

    static func contract(
        workflowOperation: String,
        abilityID: AbilityID
    ) -> CognitivePrimitiveContract? {
        contracts.first {
            $0.allowedAbility == abilityID
                && $0.workflowOperation == workflowOperation
        }
    }

    /// The primitives a recipe owned by this ability may name as a step. Ability
    /// Studio offers these alongside installed skills; they resolve at dispatch
    /// through `contract(workflowOperation:abilityID:)`.
    public static func workflowPrimitives(
        for abilityID: AbilityID
    ) -> [WorkflowPrimitiveDescriptor] {
        contracts
            .filter { $0.allowedAbility == abilityID }
            .compactMap { contract in
                contract.workflowOperation.map {
                    WorkflowPrimitiveDescriptor(
                        operation: $0,
                        summary: contract.description)
                }
            }
            .sorted { $0.operation < $1.operation }
    }

    static func modelSchema(for runtime: AbilityRuntimeSkill) -> ModelSkillSchema? {
        guard let contract = contract(for: runtime),
              let invocationName = contract.invocationName
        else { return nil }
        return ModelSkillSchema(
            name: invocationName,
            description: contract.description,
            parameters: contract.parameters)
    }

    /// Capabilities implemented inside Mary's closed machine primitives.
    /// The lookup is Ability- and operation-scoped so a package cannot grant
    /// itself an arbitrary capability merely by listing its identifier.
    static func internalCapabilities(for runtime: AbilityRuntimeSkill) -> Set<CapabilityID> {
        guard runtime.ability.id == .architect,
              runtime.skill.execution.kind == .stateMachine
        else { return [] }
        var capabilities: Set<CapabilityID> = []
        for step in runtime.skill.execution.steps {
            guard let primitive = contract(
                workflowOperation: step.operation,
                abilityID: runtime.ability.id)?.primitive
            else { continue }
            switch primitive {
            case .recordProjectRationale:
                capabilities.insert("project.rationale.record")
            case .retrieveProjectContext:
                capabilities.insert("project.context.retrieve")
            case .searchProjectKnowledge:
                capabilities.insert("project.knowledge.search")
            default:
                break
            }
        }
        return capabilities
    }

    /// THE ONE FUNCTION THAT NAMES compose_draft's DELIVERY TARGET
    static func composePlacementClause(
        stagedApplicationName: String?,
        namedWritingApplication: String?
    ) -> String? {
        if let staged = stagedApplicationName {
            return " A writing surface (\(staged)) is already staged in front — deliver the draft there with type_at_cursor in this same response."
        }
        if let named = namedWritingApplication {
            return " The user named \(named) — deliver the draft there with type_at_cursor in this same response."
        }
        return nil
    }

    /// THE REVISE→PLACE SEAM, mirroring `composePlacementClause`'s shape for a different premise: revise-selection's destination is never chosen
    static func revisionPlacementClause(hasRoutedSelection: Bool) -> String? {
        guard hasRoutedSelection else { return nil }
        return " Deliver it now — in this same response, call type_at_cursor with mode: \"replace_selection\" to replace exactly what's selected, and never claim the selection was replaced until that call returns ok."
    }

    /// The code lane's mirror of `revisionPlacementClause`, differing in the one place the two lanes genuinely differ: the call that places the result.
    static func codeRevisionPlacementClause(hasRoutedCodeSelection: Bool) -> String? {
        guard hasRoutedCodeSelection else { return nil }
        return " Deliver it now — in this same response, call replace_selection with the revised code as `text`, and never claim the file changed until that call returns ok."
    }

    static func missingRequiredArgument(
        for contract: CognitivePrimitiveContract,
        arguments: [String: String]
    ) -> String? {
        contract.parameters.first {
            $0.required
                && arguments[$0.name]?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }?.name
    }

    /// Provider-facing text is generated only here, from Mary-owned closed
    /// contracts. Package summaries, operating-policy prose, and workflow
    /// operation strings never become instructions.
    static func activate(
        _ contract: CognitivePrimitiveContract,
        arguments: [String: String]
    ) -> String {
        func value(_ keys: String...) -> String? {
            for key in keys {
                if let candidate = arguments[key]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !candidate.isEmpty {
                    return candidate
                }
            }
            return nil
        }
        func section(_ title: String, _ content: String?) -> String? {
            content.map { "\(title): \($0)" }
        }

        switch contract.primitive {
        case .composeDraft:
            // THE COMPOSE→PLACE SEAM, CLOSED. The old text — "write the requested prose directly … do not claim it was inserted"
            return "Drafting procedure activated. Write the requested prose, preserving the requested audience and tone. If the user asked for it to go into a document or app, do not read it aloud — in this same response, call type_at_cursor (creating or opening the document first with its create Skill if needed) with the complete draft as text, and never claim it was inserted until that call returns ok. If no destination was asked for, present the draft in your response."
        case .reviseSelection:
            return "Selection revision procedure activated. Draft a bounded replacement for the verified selection, preserving its intent and register, and do not claim the source was mutated until it is."
        case .reviseCodeSelection:
            // THE CORPUS IS REACHABLE, NOT ATTACHED. Nothing wires a selection-driven coding turn to the project corpus — the two lanes share no code path
            return "Code revision procedure activated. Draft a bounded replacement for the selected code, preserving its surrounding style, indentation and intent, and changing nothing the request did not ask for. If you need the code around it first, read_selection, read_buffer and search_corpus are the tools that reach it. Do not claim the file changed until it has."
        case .frameProblem:
            return "Problem-framing procedure activated. In the next response, state Goal, Constraints, Non-goals, Material unknowns, and Success signals. Separate evidence from assumptions."
        case .compareOptions:
            return "Design-comparison procedure activated. In the next response, compare genuinely distinct mechanisms by constraint fit, cost, failure mode, and reversibility, then recommend one with its tradeoff."
        case .reviewDesign:
            return "Design-review procedure activated. In the next response, test the proposal against its stated constraints, ownership boundaries, failure modes, migration surface, and code readability."
        case .planMinimalCodeChange:
            let request = value("request", "task") ?? "the requested change"
            return "Implement the smallest compilable change that satisfies this request, preserve existing interfaces and style, and verify the narrowest relevant target. Request: \(request)"
        case .explainCodeChange:
            return [
                section("Change", value("change")),
                section("Verification", value("verification")),
            ].compactMap { $0 }.joined(separator: "\n")
        case .selectDesignOption:
            return "Choose the option with the strongest constraint fit and smallest irreversible surface; state the rejected tradeoff explicitly."
        case .deriveSafeSequence:
            return "Sequence the recommendation into independently verifiable stages, placing schema contracts before adapters, routing, UI, and migration-sensitive integration."
        case .synthesizeProjectMap:
            return [
                section("Live project evidence", value("ambientContext")),
                section("Retained project evidence", value("threadContext")),
            ].compactMap { $0 }.joined(separator: "\n")
        case .identifyMaterialUnknowns:
            return "List only unknowns that could change a boundary, data contract, safety decision, or implementation order."
        case .requestProjectScope:
            return "The project identity is unresolved. Ask the user for the project or workspace to use before continuing."
        case .structureDecisionRecord:
            return [
                section("Decision", value("decision", "request")),
                section("Rationale", value("rationale")),
                section("Alternatives", value("alternatives")),
                section("Consequences", value("consequences")),
            ].compactMap { $0 }.joined(separator: "\n")
        case .resolveProjectScope:
            return value("project", "interaction.project-reference", "scope")
                ?? "The source-owned project scope could not be resolved."
        case .recordProjectRationale:
            return value("record") ?? [
                section("Decision", value("decision", "request")),
                section("Rationale", value("rationale")),
                section("Alternatives", value("alternatives")),
                section("Consequences", value("consequences")),
            ].compactMap { $0 }.joined(separator: "\n")
        case .retrieveProjectContext:
            return value("ambientContext")
                ?? "No source-attributed live project facts are currently held."
        case .searchProjectKnowledge:
            return value("threadContext")
                ?? "No matching held project knowledge was found."
        }
    }
}

/// Finalizes non-binding readiness after the adapter join has been evaluated.
/// This is a graph pass: a workflow is ready only when every operation reaches
/// a ready package Skill or an Ability-scoped cognitive primitive.
enum SkillExecutionAvailabilityEvaluator {
    static func finalize(_ input: [AbilityRuntimeSkill]) -> [AbilityRuntimeSkill] {
        let abilityIDs = Set(input.map { $0.ability.id })
        var skills = input

        for index in skills.indices where skills[index].skill.execution.kind == .cognitive {
            let runtime = skills[index]
            var reasons = missingSupportingAbilities(
                for: runtime, installed: abilityIDs)
            if runtime.skill.access != .seamless {
                reasons.append("Cognitive primitives are non-effectful and must use seamless access.")
            }
            if CognitivePrimitiveCatalog.contract(for: runtime) == nil {
                reasons.append("No Mary cognitive primitive is registered for this exact Ability and Skill identity.")
            }
            skills[index].availability = SkillAvailability(
                skillID: runtime.skill.id,
                readiness: reasons.isEmpty ? .ready : .blocked,
                reasons: orderedUnique(reasons))
        }

        let invocationIndex = Dictionary(
            skills.indices.compactMap { index -> (String, Int)? in
                let name = skills[index].skill.invocationName
                    ?? skills[index].bindingOperation
                return name.map { ($0, index) }
            },
            uniquingKeysWith: { first, _ in first })
        let bindingIndex = Dictionary(
            skills.indices.compactMap { index in
                skills[index].bindingOperation.map { ($0, index) }
            },
            uniquingKeysWith: { first, _ in first })

        var memo: [Int: [String]] = [:]
        var visiting: Set<Int> = []
        func workflowFailures(_ index: Int) -> [String] {
            if let cached = memo[index] { return cached }
            guard visiting.insert(index).inserted else {
                return ["The workflow contains a recursive Skill cycle."]
            }
            defer { visiting.remove(index) }

            let runtime = skills[index]
            var reasons = missingSupportingAbilities(for: runtime, installed: abilityIDs)
            if runtime.skill.access == .confirm {
                reasons.append(
                    "Confirmable workflows require a resumable confirmation boundary, which this runtime does not implement.")
            }
            for step in runtime.skill.execution.steps {
                if let targetIndex = invocationIndex[step.operation]
                    ?? bindingIndex[step.operation] {
                    let target = skills[targetIndex]
                    if targetIndex == index {
                        reasons.append("Workflow step \(step.id) recursively invokes itself.")
                        continue
                    }
                    switch target.skill.execution.kind {
                    case .binding, .cognitive:
                        if target.availability.readiness != .ready {
                            reasons.append(
                                "Workflow step \(step.id) cannot resolve \(step.operation): \(target.availability.reasons.first ?? "the target Skill is unavailable").")
                        }
                    case .stateMachine:
                        let nested = workflowFailures(targetIndex)
                        if !nested.isEmpty {
                            reasons.append(
                                "Workflow step \(step.id) cannot resolve nested workflow \(step.operation): \(nested[0])")
                        }
                    }
                    if target.skill.access == .confirm {
                        reasons.append(
                            "Workflow step \(step.id) requires a resumable confirmation boundary that this state machine does not declare.")
                    }
                } else if CognitivePrimitiveCatalog.contract(
                    workflowOperation: step.operation,
                    abilityID: runtime.ability.id) == nil {
                    reasons.append(
                        "Workflow step \(step.id) names unresolved operation \(step.operation).")
                }
            }
            let result = orderedUnique(reasons)
            memo[index] = result
            return result
        }

        for index in skills.indices where skills[index].skill.execution.kind == .stateMachine {
            let reasons = workflowFailures(index)
            let runtime = skills[index]
            skills[index].availability = SkillAvailability(
                skillID: runtime.skill.id,
                readiness: reasons.isEmpty ? .ready : .blocked,
                reasons: reasons)
        }
        return skills
    }

    private static func missingSupportingAbilities(
        for runtime: AbilityRuntimeSkill,
        installed: Set<AbilityID>
    ) -> [String] {
        let wanted = Set(
            runtime.skill.requirements.supportingAbilities
                + runtime.ability.operatingPolicy.defaultSupportingAbilities)
        return wanted.subtracting(installed)
            .sorted { $0.rawValue < $1.rawValue }
            .map { "Supporting Ability \($0.rawValue) is not installed." }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
