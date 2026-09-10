//
//  MaryBrain+Configuration.swift
//  MaryBrain
//
//  WHAT: Public `set*` wiring, warmup, clearHistory, engineName, setHistoryLimit.
//  IN:   MaryBrain.swift stored properties
//  OUT:  runtime / tests
//  PIN:  init and *ForTesting stay in the core file.
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

    /// The installed dispatcher, so the Life engine can be handed the same
    /// one rather than building a second authorization path.
    public func currentDispatcher() -> (any AbilityDispatching)? { dispatcher }

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

    /// Watch the roster this turn projected, at the moment it projected it.
    ///
    /// PIN: THE ONLY HONEST WAY TO SEE IT FROM OUTSIDE. `AbilityRuntime
    /// .abilityRosterTrace` re-arbitrates on demand and is documented as diagnostics —
    /// read after a turn, from another task, it answers with neither the turn's frozen
    /// signals nor its task-locals, so a bench showed a roster the turn never used
    /// (measured on a confidence-lane dispatch, which returns before the second
    /// projection runs). This fires INSIDE the turn, with what the turn actually held.
    /// A CLOSURE, NOT A `BrainEvent`. `BrainEvent` is declared in MaryVoice, which
    /// depends on MaryFoundation alone; `AbilityRosterTrace` is MaryAmbient's. An enum
    /// case would either invert that layering or smuggle the trace through as JSON.
    public func setRosterProjectionObserver(
        _ observer: (@Sendable (AbilityRosterTrace) -> Void)?
    ) {
        rosterProjectionObserver = observer
    }

    /// Convenience for a fixed prompt.
    public func setSystemPrompt(_ prompt: String) {
        systemPromptProvider = { prompt }
    }

    /// Wire (or unwire) the Sewn chat lane. Turns check readiness live, so a
    /// Sewn that dies mid-session degrades to legacy turns automatically.
    public func setSewnChat(_ provider: (any SewnChatProviding)?) {
        sewnChat = provider
    }

    /// Wire (or unwire) the realtime WebSocket route. When set and ready,
    /// Lane A rides it (interleaved text + server audio); the classic client
    /// stays wired underneath as the always-available fallback.
    public func setSewnRealtime(_ provider: (any SewnRealtimeProviding)?) {
        sewnRealtime = provider
    }

    /// The provider runs on every spoken pass — turn AND follow-up — so the live focus, the capability line and the injected clock stay fresh for both.
    public func setSewnInstructionsProvider(
        _ provider: @escaping @Sendable (SewnPass) -> String
    ) {
        sewnInstructionsProvider = provider
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

    public func setLifeEngine(_ engine: MaryLifeEngine?) {
        lifeEngine = engine
    }

    /// The idle engine, for the surfaces that monitor it.
    public var life: MaryLifeEngine? { lifeEngine }

    public func setOrdinarySkillTimeout(_ seconds: TimeInterval) {
        dispatcher?.setOrdinarySkillTimeout(seconds)
    }

    public var hasOpenTurn: Bool { openExchange != nil }

    public var isBusy: Bool {
        openExchange != nil
            || wiring.behavior.openEpisodeID != nil
            || !activeRoutines.isEmpty
            || !(dispatcher?.runningRunIDs.isEmpty ?? true)
    }
}
