//
//  AbilityRuntime+Confirmation.swift
//  MaryBrain
//
//  WHAT: The write held until a spoken go-ahead.
//  IN:   a `.write` binding, frozen with its context
//  OUT:  the preview question, then the replay on confirm
//  PIN:  Nothing has happened yet. The parked call keeps its own frozen
//        context so the replay is the act the user was actually asked about.
//
import Foundation

extension AbilityRuntime {

    public var hasPendingSkillConfirmation: Bool {
        pendingStore.current() != nil
    }

    public var pendingSkillConfirmationID: UUID? {
        pendingStore.current()?.id
    }

    /// Stored preview, verbatim. `current()` already enforces TTL and the turn window.
    public var pendingSkillConfirmationPreview: String? {
        pendingStore.current()?.preview
    }

    /// Preview-question budget — the second bounded wait; nothing has run yet.
    static let previewBudget: TimeInterval = 15

    func previewQuestion(
        binding: SkillBinding,
        arguments: [String: String],
        context: AbilityExecutionContext
    ) async -> String {
        let generic = "About to run \(binding.name). Should I go ahead?"
        guard let previewProvider = binding.confirmationPreview else { return generic }
        let described = await bounded(Self.previewBudget) {
            await previewProvider(arguments, context)
        }
        return described ?? generic
    }

    // MARK: - Primitives

    func executePending() async -> SkillOutcome {
        guard let pending = pendingStore.take() else {
            return SkillOutcome(
                ok: false,
                summary: "There's nothing waiting for confirmation — it may have expired. Ask me again.")
        }
        guard let binding = pending.binding else {
            return SkillOutcome(
                ok: false,
                summary: "The confirmed Skill no longer has a frozen binding.",
                archivePolicy: .none,
                skillReference: pending.reference)
        }
        return await execute(
            binding: binding,
            arguments: pending.arguments,
            context: pending.context,
            reference: pending.reference,
            policy: pending.executionPolicy,
            signals: pending.signalSnapshot)
    }
}
