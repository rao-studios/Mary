// The brain's fire-and-forget seam for durable Ability execution memory.

import Foundation

public protocol ContextDepositing: Sendable {
    /// The caller captures subject and application before detaching the deposit.
    func depositSkillResult(
        reference: AbilitySkillReference,
        skillName: String,
        argumentsJSON: String,
        summary: String,
        userText: String,
        subject: DepositSubject,
        applicationID: String?,
        policy: ArchivePolicy,
        succeeded: Bool,
        /// `nil` is a machine-local adapter result with no portable package.
        /// A non-nil value is the package's frozen, already-resolved Totem
        /// plan and must be enforced by the depositor.
        projectionPlan: AbilityTotemProjectionPlan?
    ) async

    // APPLICATION-USE LEARNING IS NOT IN THIS CUT. A member here used to hand
    // the corpus one observation per successful capability use — which
    // application served which kind of work — and the corpus that learns from
    // those is deferred. It returns with the corpus, not before: a sink with
    // nothing reading it is a promise the code cannot keep.
}
