//
//  PluginManagedUIExecutor.swift
//  MaryBrain
//
//  ONE FOREGROUND TRANSACTION: compile, bring forward, perform, report.
//
//  A package contributes only the bounded data in `PluginSchema` — never
//  executable code. Every operation it declares enters THIS interpreter, which
//  keeps all the authority a recipe must not have: which process, whether it
//  may be brought forward, how long the whole thing gets, and when to stop.
//
//  COMPILE BEFORE TOUCHING ANYTHING. The full step sequence resolves against
//  the turn's arguments first, so a recipe whose third step is missing an
//  input fails before the first keystroke rather than halfway through the
//  user's document. A half-performed recipe is worse than a refused one:
//  the refusal is a sentence, the half is a mess someone has to find.
//
//  THE DEADLINE IS A RACE, NOT A CHECK. Steps are `await`s into other
//  processes and an application that hangs would hang the turn with it, so the
//  work runs against a sleeping twin and whichever finishes first wins. The
//  loser is cancelled.
//

import AppKit
import ApplicationServices
import Foundation
import MaryPlugin
import MaryAmbient
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

    /// WHICH PACKAGE REVISION ACTED is not recorded here, deliberately. The
    /// behavioral record's `skill: AbilitySkillReference` already carries the
    /// package, ability, skill, adapter and provider for the action, frozen at
    /// the turn that ran it — a digest stapled to the outcome as well would be
    /// a second answer to the same question, free to disagree with the first.
    /// `providerIdentity` stays in the signature because the binding site
    /// knows it and a future receipt may want it at this exact moment.
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

        // 2. FIND THE APPLICATION. Running only — Mary does not launch an
        // application to run a recipe against it, because "it wasn't open" is
        // an answer the user can act on and a surprise launch is not.
        // ON THE MAIN ACTOR because `NSWorkspace.runningApplications` is, and
        // because process identity must not be read on one thread and acted on
        // from another: between a background read and the activation below,
        // the application could quit and the pid be reused.
        let resolution = await MainActor.run { applicationLocator.resolve(application) }
        // AMBIGUOUS IS NOT ABSENT. Two processes answering one declaration
        // means there is no single target, which the user fixes by closing
        // one — telling them the application is not running sends them to
        // open a third.
        if resolution.status == .ambiguous {
            return refusal(.applicationAmbiguous(resolution.displayName))
        }
        guard resolution.status == .running, let pid = resolution.processIdentifier
        else {
            return refusal(.applicationNotRunning(resolution.displayName))
        }

        // 3. TAKE THE STAGE, and verify it was taken. `activate()` returning
        // true means the request was accepted, not that the application is in
        // front; typing into an application that never came forward is how
        // text lands in the wrong window.
        let activation = await VerifiedActivation.bringForward(pid: pid)
        guard activation.succeeded else {
            return refusal(.activationRefused(
                application.title,
                reason: activation.reason(app: application.title)))
        }

        // 4. PERFORM.
        for step in compiled {
            if Task.isCancelled { return refusal(.cancelled) }
            let result = await MaryHands.perform(
                step, pid: pid, application: application.title)
            if case .failure(let error) = result { return refusal(error) }
        }

        let outcome = SkillOutcome(
            ok: true,
            summary: operation.summary.isEmpty
                ? "Done in \(application.title)."
                : operation.summary,
            // THE ELEMENT THAT WAS ACTED ON, for the behavioral record. A
            // recipe acts through focus, so the focused element after the last
            // step IS what it touched — read here, at the one place that knows
            // the transaction finished.
            target: ActedElementReader.focusedElement(pid: pid),
            adapterTrail: ["managed-ui"])
        return outcome
    }

    // MARK: - Compilation

    /// Resolve every step's expressions against the turn's arguments.
    ///
    /// THIS IS WHERE THE POINTER LANE IS REFUSED — at compile time, with the
    /// step named, before the application has been brought forward. A recipe
    /// that cannot run should not first steal the user's focus to find out.
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
                    // A newline in synthetic typing is a Return, and Return in
                    // a dialog is a button press — a recipe cannot be allowed
                    // to smuggle one in through an argument.
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

            case .pointerMove, .pointerClick, .pointerDrag,
                 .pointerSquareDrag, .scroll, .captureAccessibilityAnchor:
                return .failure(.pointerUnavailable(step.kind.rawValue))
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
