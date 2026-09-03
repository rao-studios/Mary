//
//  PluginManagedUIExecutor.swift
//  MaryBrain
//
//  WHAT: One foreground transaction: compile, bring forward, perform, report.
//  IN:   PluginSchema (data only) + MaryHands
//  OUT:  SkillOutcome
//  PIN:  Compile the full sequence before the first keystroke.
//
import AppKit
import ApplicationServices
import Foundation
import MaryPlugin
import MaryAmbient
import MaryComputerUse
import MaryFoundation

final class PluginManagedUIExecutor: @unchecked Sendable {

    static let shared = PluginManagedUIExecutor()

    let applicationLocator: PluginApplicationLocator

    init(applicationLocator: PluginApplicationLocator = .live) {
        self.applicationLocator = applicationLocator
    }

    // MARK: - The transaction

    func execute(
        plugin: PluginSchema,
        operation: PluginOperationSchema,
        arguments: [String: String],
        context: AbilityExecutionContext,
        providerIdentity: PluginManagedUIProviderIdentity? = nil
    ) async -> SkillOutcome {
        // The tighter of the operation's own budget and whatever the turn has
        // left — a Skill cannot buy itself more time than the turn owns.
        let outerRemaining = context.deadline.map { max(0, $0.timeIntervalSinceNow) }
            ?? operation.timeoutSeconds
        let budget = min(operation.timeoutSeconds, outerRemaining)
        guard budget > 0 else { return refusal(.noTimeRemaining) }

        return await withTaskGroup(of: PluginManagedUIExecutionRace.self) { group in
            group.addTask { [self] in
                .execution(await run(
                    plugin: plugin, operation: operation,
                    arguments: arguments, providerIdentity: providerIdentity))
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                } catch {
                    return .deadline(Self.refusalOutcome(.cancelled))
                }
                return .deadline(Self.refusalOutcome(.timedOut(seconds: budget)))
            }
            guard let first = await group.next() else {
                return Self.refusalOutcome(.stepFailed("nothing came back"))
            }
            group.cancelAll()
            switch first {
            case .execution(let outcome): return outcome
            case .deadline(let outcome): return outcome
            }
        }
    }

    /// WHICH PACKAGE REVISION ACTED is not recorded here, deliberately.
    private func run(
        plugin: PluginSchema,
        operation: PluginOperationSchema,
        arguments: [String: String],
        providerIdentity: PluginManagedUIProviderIdentity?
    ) async -> SkillOutcome {
        _ = providerIdentity
        let application = plugin.application

        // 1. COMPILE. Nothing is touched until the whole sequence resolves.
        let compiled: [PluginCompiledStep]
        switch Self.compile(operation.steps, inputs: operation.inputs, arguments: arguments) {
        case .success(let steps): compiled = steps
        case .failure(let error): return refusal(error)
        }

        // 2. FIND THE APPLICATION.
        let resolution = await MainActor.run { applicationLocator.resolve(application) }
        // AMBIGUOUS IS NOT ABSENT. Two processes answering one declaration means there is no single target, which the user fixes by closing one
        if resolution.status == .ambiguous {
            return refusal(.applicationAmbiguous(resolution.displayName))
        }
        guard resolution.status == .running, let pid = resolution.processIdentifier
        else {
            return refusal(.applicationNotRunning(resolution.displayName))
        }

        // 3. TAKE THE STAGE, and verify it was taken.
        let activation = await VerifiedActivation.bringForward(pid: pid)
        guard activation.succeeded else {
            return refusal(.activationRefused(
                application.title,
                reason: activation.reason(app: application.title)))
        }

        // 4. PERFORM. Pointer spaces are per-transaction; a captured
        // Accessibility frame from the last recipe must not aim this one —
        // which is why they are a value that dies with this call, not a static.
        var spaces = PointerDriver.Spaces()
        for step in compiled {
            if Task.isCancelled { return refusal(.cancelled) }
            let result = await MaryHands.perform(
                step, pid: pid, application: application.title, spaces: &spaces)
            if case .failure(let error) = result { return refusal(error) }
        }

        let outcome = SkillOutcome(
            ok: true,
            summary: operation.summary.isEmpty
                ? "Done in \(application.title)."
                : operation.summary,
            // THE ELEMENT THAT WAS ACTED ON, for the behavioral record.
            target: ActedElementReader.focusedElement(pid: pid),
            adapterTrail: ["managed-ui"])
        return outcome
    }

    // MARK: - Compilation

    /// Resolve every step's expressions against the turn's arguments.
    static func compile(
        _ steps: [PluginRecipeStepSchema],
        inputs: [PluginOperationInputSchema],
        arguments: [String: String]
    ) -> Result<[PluginCompiledStep], PluginManagedUIError> {
        var compiled: [PluginCompiledStep] = []
        for step in steps {
            switch step.kind {
            case .keyChord:
                guard let key = step.key else {
                    return .failure(.unsupportedStep("a shortcut with no key"))
                }
                compiled.append(.keyChord(key: key, modifiers: step.modifiers))

            case .typeText:
                guard let expression = step.text else {
                    return .failure(.unsupportedStep("a typing step with no text"))
                }
                switch resolve(expression, inputs: inputs, arguments: arguments) {
                case .success(let text):
                    // THE STRUCTURAL LIMIT, enforced before the stage is taken.
                    guard !text.contains(where: \.isNewline) else {
                        return .failure(.textContainsNewline)
                    }
                    compiled.append(.typeText(text))
                case .failure(let error):
                    return .failure(error)
                }

            case .wait:
                compiled.append(.wait(seconds: step.durationSeconds ?? 0.5))

            case .rebindFocusedWindow:
                compiled.append(.rebindFocusedWindow(
                    requiresChange: step.requiresWindowChange ?? false))

            case .pointerMove:
                switch resolvePoint(step.point, inputs: inputs, arguments: arguments) {
                case .failure(let error): return .failure(error)
                case .success(let point):
                    compiled.append(.pointerMove(
                        x: point.x, y: point.y, space: step.coordinateSpace ?? "content"))
                }

            case .pointerClick:
                switch resolvePoint(step.point, inputs: inputs, arguments: arguments) {
                case .failure(let error): return .failure(error)
                case .success(let point):
                    compiled.append(.pointerClick(
                        x: point.x, y: point.y,
                        space: step.coordinateSpace ?? "content",
                        button: step.button ?? .left,
                        count: step.clickCount ?? 1))
                }

            case .pointerDrag:
                switch resolveDrag(step, inputs: inputs, arguments: arguments) {
                case .failure(let error): return .failure(error)
                case .success(let drag): compiled.append(drag)
                }

            case .pointerSquareDrag:
                switch resolveSquareDrag(step, inputs: inputs, arguments: arguments) {
                case .failure(let error): return .failure(error)
                case .success(let drag): compiled.append(drag)
                }

            case .scroll:
                switch resolveScroll(step, inputs: inputs, arguments: arguments) {
                case .failure(let error): return .failure(error)
                case .success(let scroll): compiled.append(scroll)
                }

            case .captureAccessibilityAnchor:
                guard let locator = step.accessibilityLocator,
                      let name = step.captureAnchor, !name.isEmpty
                else {
                    return .failure(.unsupportedStep(
                        "an Accessibility capture with no locator or name"))
                }
                compiled.append(.captureAccessibilityAnchor(locator: locator, name: name))
            }
        }
        return .success(compiled)
    }

    /// A text expression is a literal or one declared input, with an optional
    /// fallback. Anything else would be an interpreter for package-authored
    /// instructions, which is the thing this whole design exists to avoid.
    static func resolve(
        _ expression: PluginTextExpression,
        inputs: [PluginOperationInputSchema],
        arguments: [String: String]
    ) -> Result<String, PluginManagedUIError> {
        if let literal = expression.value { return .success(literal) }
        guard let name = expression.input else {
            return .failure(.unsupportedStep("a text step with neither a value nor an input"))
        }
        if let supplied = arguments[name], !supplied.isEmpty {
            return .success(supplied)
        }
        if let fallback = expression.defaultValue { return .success(fallback) }
        if let declared = inputs.first(where: { $0.name == name })?.defaultValue {
            return .success(declared)
        }
        return .failure(.missingArgument(name))
    }

    static func resolve(
        _ expression: PluginScalarExpression,
        inputs: [PluginOperationInputSchema],
        arguments: [String: String]
    ) -> Result<Double, PluginManagedUIError> {
        let offset = expression.offset ?? 0
        if let literal = expression.value { return .success(literal + offset) }
        guard let name = expression.input else {
            return .failure(.unsupportedStep("a number with neither a value nor an input"))
        }
        let raw: String?
        if let supplied = arguments[name], !supplied.isEmpty {
            raw = supplied
        } else if let fallback = expression.defaultValue {
            return .success(fallback + offset)
        } else if let declared = inputs.first(where: { $0.name == name })?.defaultValue {
            raw = declared
        } else {
            return .failure(.missingArgument(name))
        }
        guard let raw, let number = Double(raw) else {
            return .failure(.argumentNotANumber(name))
        }
        return .success(number + offset)
    }

    static func resolvePoint(
        _ expression: PluginPointExpression?,
        inputs: [PluginOperationInputSchema],
        arguments: [String: String]
    ) -> Result<(x: Double, y: Double), PluginManagedUIError> {
        guard let expression else {
            return .success((0.5, 0.5))
        }
        switch (resolve(expression.x, inputs: inputs, arguments: arguments),
                resolve(expression.y, inputs: inputs, arguments: arguments)) {
        case (.failure(let error), _), (_, .failure(let error)):
            return .failure(error)
        case (.success(let x), .success(let y)):
            return .success((x, y))
        }
    }

    static func resolveDrag(
        _ step: PluginRecipeStepSchema,
        inputs: [PluginOperationInputSchema],
        arguments: [String: String]
    ) -> Result<PluginCompiledStep, PluginManagedUIError> {
        guard let rect = step.rect else {
            return .failure(.unsupportedStep("a drag with no rectangle"))
        }
        switch (
            resolve(rect.x, inputs: inputs, arguments: arguments),
            resolve(rect.y, inputs: inputs, arguments: arguments),
            resolve(rect.width, inputs: inputs, arguments: arguments),
            resolve(rect.height, inputs: inputs, arguments: arguments)
        ) {
        case (.failure(let error), _, _, _),
             (_, .failure(let error), _, _),
             (_, _, .failure(let error), _),
             (_, _, _, .failure(let error)):
            return .failure(error)
        case (.success(let x), .success(let y), .success(let width), .success(let height)):
            return .success(.pointerDrag(
                fromX: x, fromY: y, toX: x + width, toY: y + height,
                space: step.coordinateSpace ?? "content"))
        }
    }

    static func resolveSquareDrag(
        _ step: PluginRecipeStepSchema,
        inputs: [PluginOperationInputSchema],
        arguments: [String: String]
    ) -> Result<PluginCompiledStep, PluginManagedUIError> {
        guard let rect = step.rect else {
            return .failure(.unsupportedStep("a square drag with no rectangle"))
        }
        switch (
            resolve(rect.x, inputs: inputs, arguments: arguments),
            resolve(rect.y, inputs: inputs, arguments: arguments),
            resolve(rect.width, inputs: inputs, arguments: arguments)
        ) {
        case (.failure(let error), _, _),
             (_, .failure(let error), _),
             (_, _, .failure(let error)):
            return .failure(error)
        case (.success(let x), .success(let y), .success(let side)):
            return .success(.pointerSquareDrag(
                x: x, y: y, side: side, space: step.coordinateSpace ?? "content"))
        }
    }

    static func resolveScroll(
        _ step: PluginRecipeStepSchema,
        inputs: [PluginOperationInputSchema],
        arguments: [String: String]
    ) -> Result<PluginCompiledStep, PluginManagedUIError> {
        let point: (x: Double, y: Double)
        switch resolvePoint(step.point, inputs: inputs, arguments: arguments) {
        case .failure(let error): return .failure(error)
        case .success(let resolved): point = resolved
        }
        var deltaX = 0.0
        var deltaY = 0.0
        if let expression = step.deltaX {
            switch resolve(expression, inputs: inputs, arguments: arguments) {
            case .failure(let error): return .failure(error)
            case .success(let value): deltaX = value
            }
        }
        if let expression = step.deltaY {
            switch resolve(expression, inputs: inputs, arguments: arguments) {
            case .failure(let error): return .failure(error)
            case .success(let value): deltaY = value
            }
        }
        return .success(.scroll(
            x: point.x, y: point.y,
            space: step.coordinateSpace ?? "content",
            deltaX: deltaX, deltaY: deltaY))
    }

    // MARK: - Refusals

    private func refusal(_ error: PluginManagedUIError) -> SkillOutcome {
        Self.refusalOutcome(error)
    }

    static func refusalOutcome(_ error: PluginManagedUIError) -> SkillOutcome {
        SkillOutcome(
            ok: false,
            summary: error.errorDescription ?? "That didn't work.",
            status: error == .cancelled ? .cancelled : .failed,
            archivePolicy: .none)
    }
}
