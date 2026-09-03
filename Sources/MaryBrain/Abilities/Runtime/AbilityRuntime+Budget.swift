//
//  AbilityRuntime+Budget.swift
//  MaryBrain
//
//  WHAT: The wait one dispatch gets, and the worker it bounds.
//  IN:   named long jobs, the package's own ceiling, the user slider
//  OUT:  a deadline, and an honest sentence when it expires
//  PIN:  EVERY ORDINARY DISPATCH WAITS AT LEAST `ordinaryLandingFloor`. The
//        slider can raise that ceiling; it can never lower it below a real
//        act's actual landing time. Silence on timeout is never acceptable.
//
import Foundation
import MaryComputerUse
import os

extension AbilityRuntime {

    // MARK: - The dispatch budget

    /// Named jobs that legitimately outlive an ordinary dispatch, and say so
    /// themselves — everything else gets `ordinaryLandingFloor`.
    static let skillBudgets: [String: TimeInterval] = [
        "run_tests":    330,   // Subprocess.run(timeout: 300) — `swift test`
        "build_check":  330,   // BuildVerifier's `swift build`, the same 300
        "complete_coding_change": 280, // above Vibe's 240 s session cap
        "run_shortcut": 150,   // Subprocess.run(timeout: 120) — `shortcuts run`
        "zip_folder":   150,   // Subprocess.run(timeout: 120) — `ditto -c -k`
    ]

    public static let ordinarySkillTimeoutMinimum: TimeInterval = 1
    public static let ordinarySkillTimeoutMaximum: TimeInterval = 30
    public static let ordinarySkillTimeoutDefault: TimeInterval = 2

    public static func clampedOrdinarySkillTimeout(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, ordinarySkillTimeoutMinimum), ordinarySkillTimeoutMaximum)
    }

    /// EVERY ORDINARY DISPATCH WAITS AT LEAST THIS LONG TO LAND — real enough
    /// for an Accessibility walk through a large app (a collapsed Apple Music
    /// sidebar folder needs an AX expand + 700ms settle re-walk before the
    /// title match even starts). Below it, nothing was ever finishing in time
    /// anyway, only failing to say so honestly. The slider can raise this
    /// ceiling for someone willing to wait longer; it can never lower it below
    /// a real act's actual landing time.
    static let ordinaryLandingFloor: TimeInterval = 20

    /// The wait one dispatch gets. A WORKFLOW passes its own package-declared
    /// ceiling, which wins outright — a package that states its work takes
    /// up to ten minutes has made a claim the slider must not override. A
    /// plain binding has no such declaration to read (`SkillSchema.timeoutSeconds`
    /// is a workflow-only field); named long jobs are Mary's own accounting
    /// for exactly that gap. Everything else gets the floor, extended only if
    /// the slider asks for more than the floor already gives.
    public static func effectiveBudget(
        bindingName: String,
        userCap: TimeInterval,
        declaredTimeoutSeconds: TimeInterval? = nil,
        maximumDurationSeconds: TimeInterval? = nil
    ) -> TimeInterval {
        let base = declaredTimeoutSeconds
            ?? skillBudgets[bindingName]
            ?? max(clampedOrdinarySkillTimeout(userCap), ordinaryLandingFloor)
        return min(base, maximumDurationSeconds ?? base)
    }

    public func setOrdinarySkillTimeout(_ seconds: TimeInterval) {
        ordinarySkillTimeout.withLock { $0 = Self.clampedOrdinarySkillTimeout(seconds) }
    }

    /// Binding funnel and deadline — direct path and confirmed replay both enter here.
    func performExecute(
        binding: SkillBinding,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope] = [:],
        context: AbilityExecutionContext,
        maximumDurationSeconds: TimeInterval? = nil
    ) async -> SkillOutcome {
        let scale = budgetScale.withLock { $0 }
        let userCap = ordinarySkillTimeout.withLock { $0 }
        let unscaledBudget = Self.effectiveBudget(
            bindingName: binding.name,
            userCap: userCap,
            maximumDurationSeconds: maximumDurationSeconds)
        let budget = unscaledBudget * scale
        var boundedContext = context
        boundedContext.deadline = Date().addingTimeInterval(budget)
        // Hold the worker — `bounded` uses an unstructured `Task` that inherits neither cancel nor identity.
        let worker = Task {
            await Self.run(
                binding: binding,
                arguments: arguments,
                typedInputs: typedInputs,
                context: boundedContext)
        }
        // Stop-button handle — register before the wait, release after.
        let runIdentity = registerInFlight { worker.cancel() }
        defer { releaseInFlight(runIdentity) }
        let executeStart = DispatchTime.now()
        let outcome = await withTaskCancellationHandler {
            await bounded(budget) { await worker.value }
        } onCancel: {
            worker.cancel()
        }
        worker.cancel()
        let wasStopped = wasStopRequested(runIdentity)
        let executeMs = (DispatchTime.now().uptimeNanoseconds
            &- executeStart.uptimeNanoseconds) / 1_000_000
        let executeLine = "execute \(binding.name) — \(executeMs)ms"
            + (outcome == nil ? " (BUDGET EXPIRED at \(Int(unscaledBudget))s)" : "")
            + (wasStopped ? " (STOPPED)" : "")
        Self.timingLog.info("\(executeLine, privacy: .public)")
        // Stopped call says so, whatever the binding returned. Cancel is a request, not a guarantee.
        if wasStopped {
            return Self.hinted(
                SkillOutcome(
                    ok: false,
                    summary: "You stopped \(binding.name).",
                    status: .cancelled),
                binding)
        }
        guard let outcome else {
            // Honest timeout sentence, never silence — `BoundedWait`'s rule.
            return Self.hinted(
                SkillOutcome(
                    ok: false,
                    summary: "\(binding.name) didn't finish within \(Int(unscaledBudget)) seconds — whatever it drives may be busy or mid-sync. Ask me again in a moment."),
                binding)
        }
        return outcome
    }

    /// The binding itself, exactly as it ran before the deadline existed.
    static func run(
        binding: SkillBinding,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope],
        context: AbilityExecutionContext
    ) async -> SkillOutcome {
        // Stage Skills preempt the current stage holder first.
        if binding.stage {
            await StageArbiter.shared.preemptForNewClaim()
        }
        do {
            switch binding.backing {
            case .native(let implementation):
                return hinted(try await implementation(arguments, context), binding)
            case .typedNative(let implementation):
                let result = try await implementation(TypedSkillInvocation(
                    arguments: arguments,
                    inputs: typedInputs,
                    context: context))
                var outcome = result.outcome
                outcome.typedOutputs.merge(result.outputs) { _, typed in typed }
                return hinted(outcome, binding)
            }
        } catch {
            return hinted(
                SkillOutcome(
                    ok: false,
                    summary: "\(binding.name) failed: \(error.localizedDescription)"),
                binding)
        }
    }

    /// Append `spokenFailureHint` on every failure that does not already contain it.
    private static func hinted(_ outcome: SkillOutcome, _ binding: SkillBinding) -> SkillOutcome {
        guard !outcome.ok,
              let hint = binding.spokenFailureHint,
              !outcome.summary.contains(hint)
        else { return outcome }
        var spoken = outcome
        spoken.summary += " — \(hint)"
        return spoken
    }
}
