//
//  AbilityPackageValidator+Skills.swift
//  MaryFoundation
//
//  WHAT: Skill ports, execution kind, model exposure, bindings, workflow, semantics.
//  IN:   AbilityPackageValidator.validate.
//  OUT:  PackageIssueSink. Graph: +Graph; Plugin: PluginValidator.
//

import Foundation

extension AbilityPackageValidator {
    static func validateSkills(
        _ package: MaryAbilityPackage,
        _ sink: PackageIssueSink
    ) {
        let skillIDs = package.skills.map(\.id)
        duplicates(skillIDs.map(\.rawValue)).forEach {
            sink.error("duplicate-skill", "skills", "Skill id \($0) appears more than once.")
        }
        package.skills.enumerated().forEach { index, skill in
            let path = "skills[\(index)]"
            sink.checkID(skill.id.rawValue, "\(path).id")
            if !skill.id.rawValue.hasPrefix("\(package.ability.id.rawValue).") {
                sink.error("skill-outside-namespace", "\(path).id", "Skill ids are namespaced beneath their owning Ability id.")
            }
            if !semanticVersionIsValid(skill.version.rawValue) {
                sink.error("invalid-version", "\(path).version", "Use semantic versioning such as 1.0.0.")
            }
            sink.checkText(skill.title, "\(path).title", "skill-title")
            sink.checkText(skill.summary, "\(path).summary", "skill-summary")
            if let timeout = skill.timeoutSeconds,
               (!timeout.isFinite || timeout <= 0) {
                sink.error("invalid-timeout", "\(path).timeoutSeconds", "A Skill timeout must be a finite number greater than zero.")
            }
            duplicates(skill.inputs.map(\.name)).forEach {
                sink.error("duplicate-input-port", "\(path).inputs", "Input port \($0) appears more than once.")
            }
            duplicates(skill.outputs.map(\.name)).forEach {
                sink.error("duplicate-output-port", "\(path).outputs", "Output port \($0) appears more than once.")
            }
            for (portIndex, port) in skill.inputs.enumerated() {
                sink.checkText(port.name, "\(path).inputs[\(portIndex)].name", "port-name")
                sink.checkText(port.summary, "\(path).inputs[\(portIndex)].summary", "port-summary")
            }
            for (portIndex, port) in skill.outputs.enumerated() {
                sink.checkText(port.name, "\(path).outputs[\(portIndex)].name", "port-name")
                sink.checkText(port.summary, "\(path).outputs[\(portIndex)].summary", "port-summary")
            }
            switch skill.execution.kind {
            case .binding:
                if skill.kind != .effectful {
                    sink.error("skill-execution-mismatch", "\(path).execution.kind", "Binding execution requires an effectful Skill kind.")
                }
                if skill.execution.bindings.isEmpty,
                   skill.execution.realizationPolicy != .pluginRealizations {
                    sink.error(
                        "missing-binding",
                        "\(path).execution.bindings",
                        "A binding Skill needs an authored adapter operation or an explicit pluginRealizations realization policy.")
                }
            case .stateMachine:
                if skill.kind != .workflow {
                    sink.error("skill-execution-mismatch", "\(path).execution.kind", "State-machine execution requires a workflow Skill kind.")
                }
                if skill.execution.steps.isEmpty {
                    sink.error("missing-workflow", "\(path).execution.steps", "A state-machine skill must declare its steps.")
                }
                if skill.access == .confirm {
                    sink.error(
                        "unsupported-workflow-confirmation",
                        "\(path).access",
                        "Confirmable state-machine Skills require a resumable workflow confirmation boundary, which this format version does not support.")
                }
            case .cognitive:
                if skill.kind != .cognitive {
                    sink.error("skill-execution-mismatch", "\(path).execution.kind", "Cognitive execution requires a cognitive Skill kind.")
                }
                if !skill.execution.bindings.isEmpty {
                    sink.error("cognitive-binding", "\(path).execution.bindings", "A cognitive skill cannot directly bind an effectful adapter operation.")
                }
            }
            if skill.execution.kind != .binding,
               skill.execution.realizationPolicy != .authoredBindings {
                sink.error(
                    "invalid-realization-policy",
                    "\(path).execution.realizationPolicy",
                    "Only binding Skills can accept Plugin realizations.")
            }
            if skill.modelExposure.enabled && skill.invocationName == nil {
                sink.error("missing-invocation", "\(path).modelExposure", "An exposed skill needs an invocation name or binding operation.")
            }
            if let invocation = skill.invocationName, !callableNameIsValid(invocation) {
                sink.error("invalid-invocation", "\(path).modelExposure.invocationName", "Callable names use lower-case snake_case.")
            }
            if let invocation = skill.modelExposure.invocationName,
               RuntimePrimitiveOperations.contains(invocation) {
                sink.error(
                    "reserved-runtime-invocation",
                    "\(path).modelExposure.invocationName",
                    "Mary runtime primitive \(invocation) is host-owned and cannot be claimed by a package Skill.")
            }
            duplicates(skill.modelExposure.parameters.map(\.name)).forEach {
                sink.error("duplicate-model-parameter", "\(path).modelExposure.parameters", "Parameter \($0) appears more than once.")
            }
            let modelTypes: Set<String> = ["string", "boolean", "integer", "number", "object", "array"]
            for (parameterIndex, parameter) in skill.modelExposure.parameters.enumerated() {
                let parameterPath = "\(path).modelExposure.parameters[\(parameterIndex)]"
                if !callableNameIsValid(parameter.name) {
                    sink.error("invalid-model-parameter", "\(parameterPath).name", "Model parameter names use lower-case snake_case.")
                }
                if !modelTypes.contains(parameter.type) {
                    sink.error("invalid-model-parameter-type", "\(parameterPath).type", "Use a JSON parameter type: string, boolean, integer, number, object, or array.")
                }
                sink.checkText(parameter.summary, "\(parameterPath).summary", "parameter-summary")
                if !parameter.enumValues.isEmpty && parameter.type != "string" {
                    sink.error("invalid-model-enum", "\(parameterPath).enumValues", "Enum values are supported only for string parameters.")
                }
                duplicates(parameter.enumValues).forEach {
                    sink.error("duplicate-model-enum-value", "\(parameterPath).enumValues", "Enum value \($0) appears more than once.")
                }
                for (enumIndex, value) in parameter.enumValues.enumerated()
                where !machineTokenIsValid(value) {
                    sink.error(
                        "invalid-model-enum-token",
                        "\(parameterPath).enumValues[\(enumIndex)]",
                        "Model enum values must be bounded machine tokens, not prose.")
                }
            }
            // A SKILL THAT TAKES AN APPLICATION NEEDS SOMEWHERE TO PUT IT.
            // `resolvesApplication` buys a resolved application id at routing
            // time; a Skill exposing no parameter that names one would have the
            // whole reverse lookup run and its answer dropped on the floor,
            // silently and on every turn.
            if skill.requirements.resolvesApplication {
                let names = skill.modelExposure.parameters.map(\.name)
                if ApplicationParameterNames.receiver(in: names) == nil {
                    sink.error(
                        "missing-application-parameter",
                        "\(path).requirements.resolvesApplication",
                        "A Skill that resolves an application must expose a parameter to receive it, named one of: \(ApplicationParameterNames.all.sorted().joined(separator: ", ")).")
                }
                if !skill.modelExposure.enabled {
                    sink.error(
                        "unexposed-application-resolution",
                        "\(path).requirements.resolvesApplication",
                        "An unexposed Skill has no parameters to receive a resolved application.")
                }
            }
            duplicates(skill.execution.bindings.map {
                "\($0.adapterID.rawValue)/\($0.operation)/\($0.targetClasses.sorted().joined(separator: ","))"
            }).forEach {
                sink.error("duplicate-binding", "\(path).execution.bindings", "Adapter binding \($0) appears more than once.")
            }
            for (bindingIndex, binding) in skill.execution.bindings.enumerated() {
                sink.checkID(binding.adapterID.rawValue, "\(path).execution.bindings[\(bindingIndex)].adapterID")
                if !callableNameIsValid(binding.operation) {
                    sink.error("invalid-binding-operation", "\(path).execution.bindings[\(bindingIndex)].operation", "Adapter operation names use lower-case snake_case.")
                }
                if RuntimePrimitiveOperations.contains(binding.operation) {
                    sink.error(
                        "reserved-runtime-operation",
                        "\(path).execution.bindings[\(bindingIndex)].operation",
                        "Mary runtime primitive \(binding.operation) cannot satisfy a package-authored Skill binding.")
                }
                duplicates(binding.targetClasses).forEach {
                    sink.error("duplicate-target-class", "\(path).execution.bindings[\(bindingIndex)].targetClasses", "Target class \($0) appears more than once.")
                }
            }
            let stepIDs = skill.execution.steps.map(\.id)
            let stepIDSet = Set(stepIDs)
            duplicates(stepIDs).forEach {
                sink.error("duplicate-workflow-step", "\(path).execution.steps", "Workflow step \($0) appears more than once.")
            }
            for (stepIndex, step) in skill.execution.steps.enumerated() {
                let stepPath = "\(path).execution.steps[\(stepIndex)]"
                sink.checkID(step.id, "\(stepPath).id")
                for target in [step.onSuccess, step.onFailure].compactMap({ $0 })
                where !stepIDSet.contains(target) {
                    sink.error("unknown-workflow-transition", stepPath, "Workflow transition \(target) does not name a step in this state machine.")
                }
                duplicates(step.consumes).forEach {
                    sink.error("duplicate-workflow-input", "\(stepPath).consumes", "Workflow input \($0) appears more than once.")
                }
                duplicates(step.produces).forEach {
                    sink.error("duplicate-workflow-output", "\(stepPath).produces", "Workflow output \($0) appears more than once.")
                }
            }
            for (stepIndex, step) in skill.execution.steps.enumerated()
            where !callableNameIsValid(step.operation) {
                sink.error("invalid-workflow-operation", "\(path).execution.steps[\(stepIndex)].operation", "Workflow operations use lower-case snake_case.")
            }
            for (stepIndex, step) in skill.execution.steps.enumerated()
            where RuntimePrimitiveOperations.contains(step.operation) {
                sink.error(
                    "reserved-runtime-operation",
                    "\(path).execution.steps[\(stepIndex)].operation",
                    "Mary runtime primitive \(step.operation) cannot be composed by a package-authored workflow.")
            }
            sink.validateRouting(skill.routing, path: "\(path).routing")
            // PIN: create names reference output; mutate names aim parameters.
            if let semantics = skill.semantics {
                let semanticsPath = "\(path).semantics"
                switch semantics.artifactRole {
                case .create, .mutate, .plan:
                    if skill.kind != .effectful {
                        sink.error(
                            "invalid-skill-semantics-role",
                            "\(semanticsPath).artifactRole",
                            "A \(semantics.artifactRole.rawValue) artifact role requires an effectful Skill.")
                    }
                case .observe, .utility:
                    break
                }
                if semantics.artifactRole == .create {
                    if let reference = semantics.producesReference {
                        if !skill.outputs.contains(where: { $0.valueType == reference }) {
                            sink.error(
                                "artifact-create-without-reference",
                                "\(semanticsPath).producesReference",
                                "Reference type \(reference.rawValue) is not among this Skill's output value types.")
                        }
                    } else {
                        sink.error(
                            "artifact-create-without-reference",
                            "\(semanticsPath).producesReference",
                            "A create artifact role must name the reference value type its output carries.")
                    }
                } else if semantics.producesReference != nil {
                    sink.error(
                        "semantics-reference-outside-create",
                        "\(semanticsPath).producesReference",
                        "Only a create artifact role declares a produced reference.")
                }
                if semantics.artifactRole == .mutate {
                    if semantics.targetParameters.isEmpty {
                        sink.error(
                            "artifact-mutate-without-target",
                            "\(semanticsPath).targetParameters",
                            "A mutate artifact role must name the parameters that aim it at existing artifacts.")
                    }
                    let aimNames = Set(skill.modelExposure.parameters.map(\.name))
                        .union(skill.inputs.map(\.name))
                    duplicates(semantics.targetParameters).forEach {
                        sink.error(
                            "duplicate-semantics-target-parameter",
                            "\(semanticsPath).targetParameters",
                            "Target parameter \($0) appears more than once.")
                    }
                    for target in semantics.targetParameters {
                        if !callableNameIsValid(target) {
                            sink.error(
                                "invalid-target-parameter",
                                "\(semanticsPath).targetParameters",
                                "Target parameter names use lower-case snake_case.")
                        } else if !aimNames.contains(target) {
                            sink.error(
                                "artifact-mutate-without-target",
                                "\(semanticsPath).targetParameters",
                                "Target parameter \(target) is not declared by this Skill's model exposure or inputs.")
                        }
                    }
                } else if !semantics.targetParameters.isEmpty {
                    sink.error(
                        "semantics-target-outside-mutate",
                        "\(semanticsPath).targetParameters",
                        "Only a mutate artifact role declares target parameters.")
                }
            }
            duplicates(skill.requirements.capabilities.map(\.rawValue)).forEach {
                sink.error("duplicate-skill-capability", "\(path).requirements.capabilities", "Capability \($0) appears more than once.")
            }
            duplicates(skill.requirements.interactions.map(\.rawValue)).forEach {
                sink.error("duplicate-skill-interaction", "\(path).requirements.interactions", "Interaction \($0) appears more than once.")
            }
            duplicates(skill.requirements.perceptions.map(\.rawValue)).forEach {
                sink.error("duplicate-skill-perception", "\(path).requirements.perceptions", "Perception \($0) appears more than once.")
            }
            duplicates(skill.requirements.optionalInteractions.map(\.rawValue)).forEach {
                sink.error("duplicate-optional-skill-interaction", "\(path).requirements.optionalInteractions", "Optional Interaction \($0) appears more than once.")
            }
            duplicates(skill.requirements.optionalPerceptions.map(\.rawValue)).forEach {
                sink.error("duplicate-optional-skill-perception", "\(path).requirements.optionalPerceptions", "Optional Perception \($0) appears more than once.")
            }
            Set(skill.requirements.interactions)
                .intersection(skill.requirements.optionalInteractions)
                .forEach {
                    sink.error("required-and-optional-interaction", "\(path).requirements", "Interaction \($0.rawValue) cannot be both required and optional.")
                }
            Set(skill.requirements.perceptions)
                .intersection(skill.requirements.optionalPerceptions)
                .forEach {
                    sink.error("required-and-optional-perception", "\(path).requirements", "Perception \($0.rawValue) cannot be both required and optional.")
                }
            duplicates(skill.requirements.supportingAbilities.map(\.rawValue)).forEach {
                sink.error("duplicate-supporting-ability", "\(path).requirements.supportingAbilities", "Supporting Ability \($0) appears more than once.")
            }
            if skill.usesStage,
               !skill.requirements.capabilities.contains(where: { capabilityID in
                   package.capabilities.first(where: { $0.id == capabilityID })?
                       .constraints.contains(where: { $0.kind == .requiresStage }) == true
               }) {
                sink.warning("implicit-stage", "\(path).usesStage", "The skill claims the stage but none of its declared capabilities states that constraint.")
            }
            let requiredCapabilitySchemas = skill.requirements.capabilities.compactMap { id in
                package.capabilities.first(where: { $0.id == id })
            }
            let requiredConstraints = requiredCapabilitySchemas.flatMap(\.constraints)
            if requiredConstraints.contains(where: { $0.kind == .requiresStage }),
               !skill.usesStage {
                sink.error(
                    "missing-required-stage",
                    "\(path).usesStage",
                    "A Skill using a stage-constrained Capability must declare usesStage so Mary can arbitrate foreground ownership.")
            }
            if requiredConstraints.contains(where: { $0.kind == .requiresUserConfirmation }),
               skill.access != .confirm {
                sink.error(
                    "missing-required-confirmation",
                    "\(path).access",
                    "A Skill using a confirmation-constrained Capability must require confirmation.")
            }
            let targetSets = requiredCapabilitySchemas.compactMap { capability -> Set<String>? in
                let targets = Set(capability.constraints.compactMap {
                    $0.kind == .allowedTargetClass ? $0.value : nil
                })
                return targets.isEmpty ? nil : targets
            }
            if !targetSets.isEmpty {
                let allowedTargets = targetSets.dropFirst().reduce(targetSets[0]) {
                    $0.intersection($1)
                }
                if allowedTargets.isEmpty {
                    sink.error(
                        "conflicting-target-constraints",
                        "\(path).requirements.capabilities",
                        "Required Capability target-class allowlists have no common target.")
                }
                for (bindingIndex, binding) in skill.execution.bindings.enumerated()
                where allowedTargets.isEmpty
                    || Set(binding.targetClasses).isDisjoint(with: allowedTargets) {
                    sink.error(
                        "binding-outside-allowed-target",
                        "\(path).execution.bindings[\(bindingIndex)].targetClasses",
                        "The binding must name at least one target class allowed by every required Capability.")
                }
            }
            if skill.access != .confirm {
                let destructive = skill.requirements.capabilities.contains { id in
                    package.capabilities.first(where: { $0.id == id })?.effect == .destructive
                }
                if destructive {
                    sink.error("destructive-without-confirmation", "\(path).access", "Destructive capability use must require confirmation.")
                }
            }
        }

        let declared = Set(package.ability.skills)
        let supplied = Set(skillIDs)
        for missing in declared.subtracting(supplied) {
            sink.error("missing-skill-schema", "ability.skills", "No Skill schema was supplied for \(missing.rawValue).")
        }
        for orphan in supplied.subtracting(declared) {
            sink.error("orphan-skill-schema", "skills", "\(orphan.rawValue) is not listed by the Ability schema.")
        }
    }

    /// Unowned requirements, routing fallbacks, fixtures.
    static func validateRequirementsAndFixtures(
        _ package: MaryAbilityPackage,
        _ sink: PackageIssueSink
    ) {
        let skillIDs = package.skills.map(\.id)
        let localSkillIDs = Set(skillIDs)
        // Expertise may realize a dependency-owned Skill; graph still proves the contract.
        let fixtureSkillIDs = localSkillIDs.union(
            package.plugin?.realizations.map(\.skillID) ?? [])
        for (index, skill) in package.skills.enumerated() {
            for fallback in skill.routing.fallbacks where !localSkillIDs.contains(fallback) {
                sink.error("missing-routing-fallback", "skills[\(index)].routing.fallbacks", "Fallback \(fallback.rawValue) is not a Skill in this Ability.")
            }
        }

        let localCapabilities = Set(package.capabilities.map(\.id))
        let localInteractions = Set(package.interactions.map(\.id))
        let localPerceptions = Set(package.perceptions.map(\.id))
        for (index, skill) in package.skills.enumerated() {
            for id in skill.requirements.capabilities where !localCapabilities.contains(id) {
                sink.warning("external-capability", "skills[\(index)].requirements", "Capability \(id.rawValue) must be supplied by a dependency or installed adapter.")
            }
            for id in skill.requirements.interactions where !localInteractions.contains(id) {
                sink.warning("external-interaction", "skills[\(index)].requirements", "Interaction \(id.rawValue) must be supplied by a dependency or installed adapter.")
            }
            for id in skill.requirements.perceptions where !localPerceptions.contains(id) {
                sink.warning("external-perception", "skills[\(index)].requirements", "Perception \(id.rawValue) must be supplied by a dependency or installed adapter.")
            }
            for id in skill.requirements.optionalInteractions where !localInteractions.contains(id) {
                sink.warning("external-optional-interaction", "skills[\(index)].requirements", "Optional Interaction \(id.rawValue) may be supplied by a dependency or installed adapter.")
            }
            for id in skill.requirements.optionalPerceptions where !localPerceptions.contains(id) {
                sink.warning("external-optional-perception", "skills[\(index)].requirements", "Optional Perception \(id.rawValue) may be supplied by a dependency or installed adapter.")
            }
        }
        duplicates(package.fixtures.map(\.id)).forEach {
            sink.error("duplicate-fixture", "fixtures", "Fixture \($0) appears more than once.")
        }
        for (index, fixture) in package.fixtures.enumerated() {
            let path = "fixtures[\(index)]"
            sink.checkText(fixture.id, "\(path).id", "fixture-id")
            sink.checkText(fixture.utterance, "\(path).utterance", "fixture-utterance")
            // No emptiness check on the disposition any more: `FixtureDisposition`
            // is an enum, so decode already refused anything that is not one of
            // the four. What DOES need saying is that a probe with no Skill to
            // reach grades nothing — it is the exam with no answer key, and it
            // would sit in the package looking like coverage.
            if fixture.expectedDisposition == .probe, fixture.expectedSkill == nil {
                sink.error(
                    "probe-without-skill",
                    "\(path).expectedSkill",
                    "A probe is graded, never taught, so it must name the Skill it should reach — otherwise it asserts nothing.")
            }
            if let skill = fixture.expectedSkill,
               !fixtureSkillIDs.contains(skill) {
                sink.error(
                    "missing-fixture-skill",
                    "\(path).expectedSkill",
                    "Fixture skill \(skill.rawValue) is neither owned nor explicitly realized by this Ability package.")
            }
            duplicates(fixture.interactions.map(\.rawValue)).forEach {
                sink.error("duplicate-fixture-interaction", "\(path).interactions", "Interaction \($0) appears more than once.")
            }
            checkPlaceholders(fixture.utterance, "\(path).utterance", sink)
        }
        // The same pragma, in the three trigger fields that also become corpus.
        for (index, phrase) in package.ability.triggers.phrases.enumerated() {
            checkPlaceholders(phrase, "ability.triggers.phrases[\(index)]", sink)
        }
        // TOKENS ARE EXPANDED TOO, and were the one expanded field nothing
        // checked. `EmbeddingRouting.expandedTriggers` fills a slot in BOTH
        // phrases and tokens before handing them to the peeler, so a misspelled
        // brace here survives into a literal phrase match and reaches nobody —
        // the exact silence the phrase check exists to break.
        for (index, token) in package.ability.triggers.tokens.enumerated() {
            checkPlaceholders(token, "ability.triggers.tokens[\(index)]", sink)
        }
        for (key, seeds) in package.ability.triggers.intentSeeds.sorted(by: {
            $0.key < $1.key
        }) {
            for (index, seed) in seeds.enumerated() {
                checkPlaceholders(
                    seed, "ability.triggers.intentSeeds.\(key)[\(index)]", sink)
            }
        }
    }

    /// AN UNFILLED PLACEHOLDER REACHES NOBODY.
    ///
    /// The identical rule `PluginValidator+Corpus` states for a document URL
    /// template: a brace that names no declared slot is not expanded by
    /// anything, so the braces survive into the corpus and match no sentence a
    /// person would ever say. Failing the package is the only way an author
    /// finds out — the symptom is silence.
    static func checkPlaceholders(
        _ text: String, _ path: String, _ sink: PackageIssueSink
    ) {
        let unknown = UtteranceTemplate.unknownPlaceholders(in: text)
        guard !unknown.isEmpty else { return }
        let known = UtteranceSlot.allCases
            .map { "{\($0.rawValue)}" }
            .joined(separator: ", ")
        sink.error(
            "unknown-utterance-placeholder",
            path,
            "\(unknown.joined(separator: ", ")) is not a placeholder this format fills; an unfilled one stays in the sentence and reaches nobody. Available: \(known).")
    }
}
