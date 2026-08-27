//
//  PluginValidator+Operations.swift
//  MaryFoundation
//
//  Admission for the exported adapter and for each declarative operation:
//  its inputs, its recipe shape, the postconditions it must prove, and the
//  semantics it declares about what it is for.
//

import Foundation

extension PluginValidator {
    static func validate(
        _ adapter: PluginAdapterSchema,
        pluginID: String,
        path: String,
        error: (String, String, String) -> Void,
        text: (String, String, String) -> Void
    ) {
        if !SchemaIdentifierValidation.isValid(adapter.id.rawValue) {
            error("invalid-plugin-adapter-id", "\(path).id", "Use a portable lower-case adapter identifier.")
        }
        if adapter.id.rawValue != pluginID
            && !adapter.id.rawValue.hasPrefix("\(pluginID).")
            && !adapter.id.rawValue.hasPrefix("\(pluginID)-") {
            error(
                "plugin-adapter-outside-namespace",
                "\(path).id",
                "A Plugin adapter id must equal or be namespaced beneath its Plugin id.")
        }
        if !SemanticVersion.isValid(adapter.version.rawValue) {
            error("invalid-plugin-adapter-version", "\(path).version", "Use semantic versioning such as 1.0.0.")
        }
        text(adapter.title, "\(path).title", "adapter-title")
        if adapter.title.utf8.count > maximumTitleBytes {
            error(
                "plugin-adapter-title-too-long",
                "\(path).title",
                "A Plugin adapter title may contain at most \(maximumTitleBytes) UTF-8 bytes.")
        }
        for duplicate in duplicates(adapter.permissions.map(\.rawValue)) {
            error(
                "duplicate-plugin-permission",
                "\(path).permissions",
                "Permission \(duplicate) appears more than once.")
        }
        let unsupportedPermissions = Set(adapter.permissions).subtracting([.accessibility])
        if !unsupportedPermissions.isEmpty {
            error(
                "plugin-permission-outside-native-interpreter",
                "\(path).permissions",
                "The current macUI interpreter may request only Accessibility; unsupported permissions: \(unsupportedPermissions.map(\.rawValue).sorted().joined(separator: ", ")).")
        }
        if adapter.engine == .macUI,
           !adapter.permissions.contains(.accessibility) {
            error(
                "missing-plugin-accessibility-permission",
                "\(path).permissions",
                "The macUI engine must explicitly request Accessibility permission.")
        }
    }

    static func validate(
        _ operation: PluginOperationSchema,
        path: String,
        error: (String, String, String) -> Void,
        text: (String, String, String) -> Void,
        designPlanInput: String? = nil,
        externalCoordinateSpaces: Set<String> = []
    ) {
        if !callableNameIsValid(operation.operation) {
            error(
                "invalid-plugin-operation",
                "\(path).operation",
                "Plugin operation names use lower-case snake_case.")
        }
        text(operation.title, "\(path).title", "operation-title")
        text(operation.summary, "\(path).summary", "operation-summary")
        if operation.title.utf8.count > maximumTitleBytes {
            error(
                "plugin-operation-title-too-long",
                "\(path).title",
                "A Plugin operation title may contain at most \(maximumTitleBytes) UTF-8 bytes.")
        }
        if operation.summary.utf8.count > maximumSummaryBytes {
            error(
                "plugin-operation-summary-too-long",
                "\(path).summary",
                "A Plugin operation summary may contain at most \(maximumSummaryBytes) UTF-8 bytes.")
        }
        if !operation.timeoutSeconds.isFinite
            || operation.timeoutSeconds < 0.25
            || operation.timeoutSeconds > maximumOperationSeconds {
            error(
                "invalid-plugin-operation-timeout",
                "\(path).timeoutSeconds",
                "A Plugin operation timeout must be between 0.25 and \(Int(maximumOperationSeconds)) seconds.")
        }
        if operation.inputs.count > maximumInputsPerOperation {
            error(
                "too-many-plugin-inputs",
                "\(path).inputs",
                "One Plugin operation may declare at most \(maximumInputsPerOperation) inputs.")
        }
        for duplicate in duplicates(operation.inputs.map(\.name)) {
            error("duplicate-plugin-input", "\(path).inputs", "Input \(duplicate) appears more than once.")
        }
        let inputs = Dictionary(
            operation.inputs.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        for (inputIndex, input) in operation.inputs.prefix(maximumInputsPerOperation).enumerated() {
            validate(input, path: "\(path).inputs[\(inputIndex)]", error: error)
        }
        for duplicate in duplicates(operation.postconditions.map(\.rawValue)) {
            error(
                "duplicate-plugin-postcondition",
                "\(path).postconditions",
                "Postcondition \(duplicate) appears more than once.")
        }

        if let designPlanInput {
            validateDesignPlanEntry(
                operation,
                planInput: designPlanInput,
                path: path,
                error: error)
        } else {
            validateSemantics(operation, path: path, error: error)
            validateManagedUIRecipe(
                operation,
                inputs: inputs,
                externalCoordinateSpaces: externalCoordinateSpaces,
                path: path,
                error: error)
        }
    }

    static func validateDesignPlanEntry(
        _ operation: PluginOperationSchema,
        planInput: String,
        path: String,
        error: (String, String, String) -> Void
    ) {
        if operation.semantics != nil {
            error(
                "plugin-design-entry-semantics",
                "\(path).semantics",
                "A Design plan entry delegates exact commands and cannot advertise direct artifact semantics.")
        }
        if !operation.steps.isEmpty || !operation.cleanupSteps.isEmpty {
            error(
                "plugin-design-entry-has-recipe",
                "\(path).steps",
                "The Design plan entry is compiler-owned; creation preludes and command actions belong to private templates.")
        }
        if !operation.postconditions.isEmpty {
            error(
                "plugin-design-entry-postcondition",
                "\(path).postconditions",
                "The Design plan entry itself emits no Remote Hands transaction; compiled templates own postconditions.")
        }
        let planInputs = operation.inputs.filter { $0.name == planInput }
        let auxiliaryInputs = operation.inputs.filter { $0.name != planInput }
        let surfaceIsClosed = auxiliaryInputs.isEmpty
            || (auxiliaryInputs.count == 1
                && auxiliaryInputs[0].name == "surface"
                && auxiliaryInputs[0].kind == .text
                && !auxiliaryInputs[0].required
                && auxiliaryInputs[0].defaultValue == "new-document"
                && auxiliaryInputs[0].enumValues
                    == ["new-document", "current-document"])
        guard planInputs.count == 1,
              planInputs[0].kind == .text,
              planInputs[0].required,
              planInputs[0].defaultValue == nil,
              surfaceIsClosed else {
            error(
                "invalid-plugin-design-entry-contract",
                "\(path).inputs",
                "The Design plan entry needs its declared required text plan input and may add only the closed optional current/new-document surface selector.")
            return
        }
    }

    static func validateSemantics(
        _ operation: PluginOperationSchema,
        path: String,
        error: (String, String, String) -> Void
    ) {
        guard let semantics = operation.semantics else { return }
        if semantics.aliases.count > maximumOperationAliases {
            error(
                "too-many-plugin-operation-aliases",
                "\(path).semantics.aliases",
                "One operation may declare at most \(maximumOperationAliases) exact creation aliases.")
        }
        for duplicate in duplicates(semantics.aliases) {
            error(
                "duplicate-plugin-operation-alias",
                "\(path).semantics.aliases",
                "Creation alias \(duplicate) appears more than once.")
        }
        for (index, alias) in semantics.aliases.enumerated() {
            let bytes = alias.utf8
            if bytes.count > maximumOperationAliasBytes {
                error(
                    "plugin-operation-alias-too-long",
                    "\(path).semantics.aliases[\(index)]",
                    "A creation alias may contain at most \(maximumOperationAliasBytes) UTF-8 bytes.")
            }
            let valid = !bytes.isEmpty
                && (97...122).contains(bytes.first ?? 0)
                && bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
            if !valid {
                error(
                    "invalid-plugin-operation-alias",
                    "\(path).semantics.aliases[\(index)]",
                    "Creation aliases are one lowercase ASCII machine token beginning with a letter.")
            }
        }
        let emitsInput = operation.steps.contains {
            ![.wait, .rebindFocusedWindow, .captureAccessibilityAnchor]
                .contains($0.kind)
        }
        switch semantics.role {
        case .createArtifact:
            if semantics.aliases.isEmpty {
                error(
                    "missing-plugin-create-alias",
                    "\(path).semantics.aliases",
                    "A creation operation needs at least one exact artifact alias.")
            }
            if !emitsInput {
                error(
                    "plugin-artifact-operation-without-native-input",
                    "\(path).steps",
                    "A creation operation must emit a remote-hand input action.")
            }
        case .mutateArtifact:
            if !semantics.aliases.isEmpty {
                error(
                    "plugin-aliases-require-create-role",
                    "\(path).semantics.aliases",
                    "Only creation operations may declare artifact aliases.")
            }
            if !emitsInput {
                error(
                    "plugin-artifact-operation-without-native-input",
                    "\(path).steps",
                    "A mutation operation must emit a remote-hand input action.")
            }
        case .observe:
            if !semantics.aliases.isEmpty {
                error(
                    "plugin-aliases-require-create-role",
                    "\(path).semantics.aliases",
                    "Only creation operations may declare artifact aliases.")
            }
            if emitsInput {
                error(
                    "plugin-observe-emits-native-input",
                    "\(path).steps",
                    "An observe operation cannot emit keyboard or pointer input.")
            }
        case .utility:
            if !semantics.aliases.isEmpty {
                error(
                    "plugin-aliases-require-create-role",
                    "\(path).semantics.aliases",
                    "Only creation operations may declare artifact aliases.")
            }
        }
    }

    static func validateManagedUIRecipe(
        _ operation: PluginOperationSchema,
        inputs: [String: PluginOperationInputSchema],
        externalCoordinateSpaces: Set<String>,
        path: String,
        error: (String, String, String) -> Void
    ) {
        if operation.steps.isEmpty {
            error("empty-plugin-recipe", "\(path).steps", "A Plugin operation needs at least one recipe step.")
        }
        if operation.steps.count > maximumStepsPerOperation {
            error(
                "too-many-plugin-operation-steps",
                "\(path).steps",
                "One Plugin operation may contain at most \(maximumStepsPerOperation) steps.")
        }
        if operation.cleanupSteps.count > maximumCleanupStepsPerOperation {
            error(
                "too-many-plugin-cleanup-steps",
                "\(path).cleanupSteps",
                "One Plugin operation may contain at most \(maximumCleanupStepsPerOperation) cleanup steps.")
        }
        for duplicate in duplicates(operation.steps.map(\.id)) {
            error("duplicate-plugin-step", "\(path).steps", "Recipe step \(duplicate) appears more than once.")
        }
        for duplicate in duplicates(operation.cleanupSteps.map(\.id)) {
            error(
                "duplicate-plugin-cleanup-step",
                "\(path).cleanupSteps",
                "Cleanup step \(duplicate) appears more than once.")
        }
        for duplicate in duplicates(operation.steps.compactMap(\.captureAnchor)) {
            error(
                "duplicate-plugin-capture-anchor",
                "\(path).steps",
                "Captured coordinate anchor \(duplicate) appears more than once.")
        }
        var referencedInputs = Set<String>()
        func record(_ scalar: PluginScalarExpression) {
            if let input = scalar.input { referencedInputs.insert(input) }
        }
        for step in operation.steps + operation.cleanupSteps {
            if let point = step.point {
                record(point.x)
                record(point.y)
            }
            if let rect = step.rect {
                record(rect.x)
                record(rect.y)
                record(rect.width)
                record(rect.height)
            }
            if let deltaX = step.deltaX { record(deltaX) }
            if let deltaY = step.deltaY { record(deltaY) }
            if let input = step.text?.input { referencedInputs.insert(input) }
        }
        for (inputIndex, input) in operation.inputs.enumerated()
        where !referencedInputs.contains(input.name) {
            error(
                "unused-plugin-input",
                "\(path).inputs[\(inputIndex)]",
                "Every imported operation input must drive a Mary-owned native recipe expression.")
        }
        for (stepIndex, step) in operation.steps.prefix(maximumStepsPerOperation).enumerated() {
            let priorAnchors = Set(operation.steps.prefix(stepIndex)
                .compactMap(\.captureAnchor))
                .union(externalCoordinateSpaces)
            validate(
                step,
                inputs: inputs,
                availableAnchors: priorAnchors,
                path: "\(path).steps[\(stepIndex)]",
                error: error)
        }
        for (stepIndex, step) in operation.cleanupSteps
            .prefix(maximumCleanupStepsPerOperation).enumerated() {
            let cleanupPath = "\(path).cleanupSteps[\(stepIndex)]"
            if ![.keyChord, .wait].contains(step.kind) {
                error(
                    "unsafe-plugin-cleanup-step",
                    cleanupPath,
                    "Cleanup may only release a tool with a closed key chord or bounded wait.")
            }
            validate(
                step,
                inputs: inputs,
                availableAnchors: [],
                path: cleanupPath,
                error: error)
        }
        if !operation.postconditions.contains(.applicationFrontmost) {
            error(
                "missing-plugin-frontmost-postcondition",
                "\(path).postconditions",
                "Every Plugin operation must prove that its exact application still owns the stage.")
        }
    }
}
