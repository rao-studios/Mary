//
//  MaryBrain+Configuration.swift
//  MaryBrain
//
//  The brain's wiring surface, moved out of MaryBrain.swift: every public
//  `set*` configuration method, `warmup`, `clearHistory`, `engineName`, and
//  `setHistoryLimit`. The designated `init` and the `*ForTesting` setters
//  stay in the core file with the stored properties they touch.
//
//  Moved verbatim; no behavior change. Depends on the internal-for-split
//  promotions of the stored properties these setters write (see the core
//  file); treat those as private.
//

import MaryVoice
import Foundation
import os

extension MaryBrain {

    public func setEngine(_ engine: any InferenceEngine) {
        self.engine = engine
    }

    public var engineName: String { engine.displayName }

    public func setDispatcher(_ dispatcher: (any AbilityDispatching)?) {
        self.dispatcher = dispatcher
    }

    /// The provider runs at the start of each turn, so prompts can carry the
    /// current date and time.
    /// Install the correction applier. See `referenceCorrector`.
    public func setReferenceCorrector(
        _ corrector: @escaping @Sendable (ResolvedReferent) -> ReferenceResolver.Rival?
    ) {
        referenceCorrector = corrector
    }

    /// Install the container resolver. See `referentResolver`.
    public func setReferentResolver(
        _ resolver: @escaping @Sendable (ReferenceAct) -> ReferenceDecision
    ) {
        referentResolver = resolver
    }

    public func setSystemPromptProvider(_ provider: @escaping @Sendable () -> String) {
        systemPromptProvider = provider
    }

    /// Runs a bounded, live-context refresh before each turn.
    public func setTurnContextPreparer(_ preparer: (@Sendable () async -> Void)?) {
        turnContextPreparer = preparer
    }

    /// Convenience for a fixed prompt.
    public func setSystemPrompt(_ prompt: String) {
        systemPromptProvider = { prompt }
    }

    /// Wire (or unwire) the Seer chat lane. Turns check readiness live, so a
    /// Seer that dies mid-session degrades to legacy turns automatically.
    public func setSeerChat(_ provider: (any SeerChatProviding)?) {
        seerChat = provider
    }

    /// Wire (or unwire) the realtime WebSocket route. When set and ready,
    /// Lane A rides it (interleaved text + server audio); the classic client
    /// stays wired underneath as the always-available fallback.
    public func setSeerRealtime(_ provider: (any SeerRealtimeProviding)?) {
        seerRealtime = provider
    }

    /// The provider runs on every spoken pass — turn AND follow-up — so the
    /// live focus, the capability line and the injected clock stay fresh for
    /// both. The grounded-results block is passed IN rather than concatenated
    /// on top of the provider's output: the two helper personas are mutually
    /// exclusive ("don't announce it's done" vs "report the outcome"), so
    /// they must be chosen, never stacked.
    public func setSeerInstructionsProvider(
        _ provider: @escaping @Sendable (SeerPass) -> String
    ) {
        seerInstructionsProvider = provider
    }

    public func setDepositor(_ depositor: (any ContextDepositing)?) {
        self.depositor = depositor
    }

    /// Install the focus-aware deposit subject. Same shape as the prompt
    /// providers on purpose: one synchronous read per turn off the app's
    /// single focus decision.
    public func setDepositSubjectProvider(_ provider: @escaping @Sendable () -> DepositSubject) {
        depositSubjectProvider = provider
    }

    public func warmup() async throws {
        try await engine.warmup()
    }

    /// Forget the conversation (Reset).
    public func clearHistory() {
        history = []
        recentApplicationReferent = nil
    }

    /// Settings: how many spoken messages the model keeps.
    public func setHistoryLimit(_ limit: Int) {
        historyMessageLimit = max(4, limit)
        trimHistory()
    }
}
