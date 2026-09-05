//
//  AbilityRuntime.swift
//  MaryBrain
//
//  WHAT: Subshell dispatcher — primitives, plugin bindings, confirm/cancel.
//  IN:   AbilityDispatching (brain) + frozen snapshot
//  OUT:  SkillOutcome; writes held until spoken go-ahead
//  PIN:  Unknown Skills become spoken "that didn't work", never crashes.
//        STATE LIVES HERE. Swift forbids stored properties in an extension,
//        so every `let`/`var` with storage stays in this file; the concerns
//        that read them are AbilityRuntime+*.swift siblings.
//
import Foundation
import os

public final class AbilityRuntime: AbilityDispatching, @unchecked Sendable {

    public static let confirmSkillName = "confirm_pending_skill"
    public static let cancelSkillName = "cancel_pending_skill"
    /// Screen-look Skill name — settle policy and pre-look arm share this seam.
    public static let lookSkillName = "look_at_screen"

    struct AttributedSkillBinding: Sendable {
        let owner: String   // plugin name; "" for standalone
        let binding: SkillBinding
    }

    private struct PluginRosterCache: Sendable {
        var revision: UUID?
        var bindings: [AttributedSkillBinding] = []
    }

    private let nativeAttributed: [AttributedSkillBinding]
    let nativeProfiles: [ApplicationProfile]
    private let rosterCache = OSAllocatedUnfairLock<PluginRosterCache>(
        initialState: .init())
    /// Frozen provider choices for this turn. Cleared in `beginTurn()` beside `resolutions`.
    let providerSelection = OSAllocatedUnfairLock<ProviderTurnSelection?>(
        initialState: nil)

    /// Skills offered this turn.
    /// PIN: Two generations — detached routines dispatch across `beginTurn`.
    struct TurnOfferLedger: Sendable {
        var projected = false
        var current: Set<AbilityRosterSkillKey> = []
        var previous: Set<AbilityRosterSkillKey> = []
    }
    let offerLedger = OSAllocatedUnfairLock<TurnOfferLedger>(
        initialState: .init())
    /// turnLog roster line once per beginTurn — schemas is read every round.
    let codingRosterLogged = OSAllocatedUnfairLock<Bool>(initialState: false)

    struct InFlightRun {
        /// Canceller for the in-flight worker (native or workflow — types differ).
        let cancel: @Sendable () -> Void
        /// Stop asked for this call. Cancelling a `Task` is a request, not a guarantee.
        var stopRequested = false
    }

    /// In-flight calls keyed by the id the Stop chip shows.
    let inFlightRuns = OSAllocatedUnfairLock<[String: InFlightRun]>(
        initialState: [:])

    var attributed: [AttributedSkillBinding] {
        let snapshot = abilitySnapshot
        let dynamic = rosterCache.withLock { cache -> [AttributedSkillBinding] in
            if cache.revision == snapshot.revision { return cache.bindings }
            let nativeNames = Set(nativeAttributed.map { $0.binding.name })
            var seen = nativeNames
            // Every imported operation enters Mary's compiled native-interaction interpreter.
            let managedUI = PluginManagedUIExecutor.shared.runtimeBindings(in: snapshot)
                .map { (owner: $0.owner, binding: $0.binding) }
            cache.bindings = managedUI
                .compactMap { item in
                    guard seen.insert(item.binding.name).inserted else { return nil }
                    return AttributedSkillBinding(
                        owner: item.owner,
                        binding: item.binding)
                }
            cache.revision = snapshot.revision
            return cache.bindings
        }
        return nativeAttributed + dynamic
    }
    var skillBindings: [SkillBinding] { attributed.map(\.binding) }
    /// Plugin id → targeted-read binding. Fetch-first uses this; runtime never names plugin Skills.
    let targetedReads: [String: (binding: String, parameter: String)]
    /// Awareness bindings, learned from whichever adapters declare them.
    /// PIN: the brain asks for "awareness"; only this table knows the names.
    let awarenessReads: [AwarenessRead]
    /// The same reads, by the owner whose world they describe.
    let awarenessReadsByOwner: [String: AwarenessRead]
    /// Plugin id → its revision verb, and plugin id → its half of the passage contract.
    let targetedEdits: [String: (binding: String, parameter: String)]
    let passageBackings: [String: PassageBacking]

    /// World each binding owner serves when the owner's id does not spell it.
    let servedAttentions: [String: AmbientAttention]
    let contextProvider: @Sendable () -> AbilityExecutionContext
    /// Plugin whose Skills hoist to the front of the roster. Nil keeps natural order.
    let focusProvider: (@Sendable () -> String?)?
    /// THE PLACE THE PERSON PLANTED A FLAG IN, when they planted one.
    ///
    /// PIN: INJECTED LIKE `focusProvider`, AND FOR ITS REASON. The provider
    /// ladder has always spelled `named > interaction > pinned > focused >
    /// habit`, and the pinned rung was hard-wired nil with a comment saying "no
    /// pinning surface exists yet" — while `WorkspaceFocusTracker.pin` had been
    /// the debugger's focus-correction control the whole time. A rung the spec
    /// declares and nothing fills is a ladder with a hole in it.
    let pinnedProvider: (@Sendable () -> String?)?
    let pendingStore: PendingSkillStore
    /// Session ledger for real executions — leaves only, so parked confirms stay off it.
    let executionLog: AbilityExecutionLog
    /// Episode sink for this turn's actions. Nil in tests (no fake episode).
    let behavior: BehavioralAssembler?
    /// Ambient world — this dispatcher is one of its store's four writers.
    let world: AmbientWorld
    /// Handle ledger. Injected so tests locate without minting into the process-wide store.
    let passages: PassageRegistry
    /// Addressable-container identity. A document-keyed read is evidence for one container.
    let containers: ContainerRegistry
    /// Applications this runtime knows, for owners the world enum cannot name.
    private let applicationsOverride: (any AmbientApplicationIndex)?
    var applications: any AmbientApplicationIndex {
        applicationsOverride ?? AmbientApplicationIndexProvider.current
    }
    /// This turn's Skill-name → attributed-index map (nil = miss). Cleared in `beginTurn`.
    let resolutions = OSAllocatedUnfairLock<[String: Int?]>(initialState: [:])
    /// Surface referent for this turn. Only trusted Design resolution may arm it.
    let surfaceReferent = OSAllocatedUnfairLock<AbilitySurfaceReferent>(
        initialState: .currentLiveSelection)

    /// `SemanticSkillRequestIndex.affinities(in:)` memoized for the turn (same freeze as `providerSelection`).
    let semanticSkillAffinityCache = OSAllocatedUnfairLock<
        (utterance: String, affinities: [SkillID: Float])?
    >(initialState: nil)
    /// Where settled outcomes are recorded. `.shared` (persist: true) in
    /// production; a unit test that dispatches must not write to
    /// `~/Library/Application Support/Mary/routing-habits.json`.
    let routingHabitStore = OSAllocatedUnfairLock<RoutingHabitStore>(
        initialState: .shared)

    func setRoutingHabitStoreForTesting(_ store: RoutingHabitStore) {
        routingHabitStore.withLock { $0 = store }
    }

    /// Where "which app you reach for" is tallied. `.shared` in production; a
    /// unit test that dispatches must not teach the real personal ledger.
    let applicationHabitLedger = OSAllocatedUnfairLock<ApplicationHabitLedger>(
        initialState: .shared)

    func setApplicationHabitLedgerForTesting(_ ledger: ApplicationHabitLedger) {
        applicationHabitLedger.withLock { $0 = ledger }
    }

    public init(
        plugins: [any MaryAdapter],
        standalone: [SkillBinding] = [],
        focusProvider: (@Sendable () -> String?)? = nil,
        pinnedProvider: (@Sendable () -> String?)? = nil,
        executionLog: AbilityExecutionLog = .shared,
        behavior: BehavioralAssembler? = nil,
        world: AmbientWorld = .shared,
        passages: PassageRegistry = .shared,
        containers: ContainerRegistry = .shared,
        applications: (any AmbientApplicationIndex)? = nil,
        contextProvider: @escaping @Sendable () -> AbilityExecutionContext
    ) {
        var seen = Set<String>()
        var attributedBindings: [AttributedSkillBinding] = []
        let all = plugins.flatMap { plugin in plugin.skillBindings.map { (plugin.name, $0) } }
            + standalone.map { ("", $0) }
        for (owner, binding) in all {
            guard seen.insert(binding.name).inserted else {
                assertionFailure("Duplicate binding name: \(binding.name)")
                continue
            }
            attributedBindings.append(AttributedSkillBinding(owner: owner, binding: binding))
        }
        self.behavior = behavior
        self.nativeAttributed = attributedBindings
        self.nativeProfiles = plugins.map(\.applicationProfile)
        var reads: [String: (binding: String, parameter: String)] = [:]
        var edits: [String: (binding: String, parameter: String)] = [:]
        var backings: [String: PassageBacking] = [:]
        var attentions: [String: AmbientAttention] = [:]
        for plugin in plugins {
            // Observation adapter serving a differently-named world: register under both keys.
            if let served = plugin.servedAttention, served.pluginOwner != plugin.name {
                attentions[plugin.name] = served
            }
            if let targeted = plugin.targetedRead {
                for key in Self.readOwnerKeys(for: plugin) { reads[key] = targeted }
            }
            // Both halves or neither: verb without backing cannot locate; backing without verb cannot send.
            if let verb = plugin.targetedEdit {
                edits[plugin.name] = verb
            }
        }
        self.awarenessReads = plugins.compactMap(\.awarenessRead)
        // WHICH FACULTY SERVES WHICH WORLD. Two adapters declare an awareness
        // read — the code/prose one and the browsing one — and `fetchAwareness`
        // took whichever came first in the catalog, which is an ordering
        // accident rather than an answer about the work in front of someone.
        //
        // PIN: THE SAME KEYS THE TARGETED TABLE USES, and that is the whole
        // repair. This was keyed by the plugin's NAME ALONE while `targetedReads`
        // was keyed by name, served attention and declared aliases — so the
        // lookup, which asks with a PLACE token, could never hit for an adapter
        // whose place is spelled differently from its name. Measured: a browser
        // leads as `"browser"`, the browsing adapter is called `"web-surface"`,
        // the dictionary missed every time, and "what is this page about?" fell
        // through to catalog order and pre-read the CODE buffer — which answers
        // nothing about a page, so the turn spoke with nothing in hand.
        var awarenessByOwner: [String: AwarenessRead] = [:]
        for plugin in plugins {
            guard let read = plugin.awarenessRead else { continue }
            for key in Self.readOwnerKeys(for: plugin) where awarenessByOwner[key] == nil {
                awarenessByOwner[key] = read
            }
        }
        self.awarenessReadsByOwner = awarenessByOwner
        self.targetedReads = reads
        self.targetedEdits = edits
        self.passageBackings = backings
        self.servedAttentions = attentions
        self.contextProvider = contextProvider
        self.focusProvider = focusProvider
        self.pinnedProvider = pinnedProvider
        self.executionLog = executionLog
        self.world = world
        self.passages = passages
        self.containers = containers
        self.applicationsOverride = applications
        self.pendingStore = PendingSkillStore()
    }

    /// EVERY NAME AN ADAPTER ANSWERS TO, as a fetch-first owner key.
    ///
    /// PIN: ONE LIST, BOTH TABLES, BECAUSE THEY ARE ASKED THE SAME QUESTION.
    /// `readNamedPart` and `fetchAwareness` both look up the LEAD PLACE'S token
    /// — `world.store.referent()?.place.memoryToken ?? focusProvider()` — so the
    /// key is a place's spelling, not an adapter's. An adapter whose place is
    /// named differently from itself must be registered under both, or it is
    /// unreachable through whichever table forgot. Kept as one function so the
    /// two can never disagree again.
    static func readOwnerKeys(for plugin: any MaryAdapter) -> [String] {
        var keys = [plugin.name]
        if let served = plugin.servedAttention, served.pluginOwner != plugin.name {
            keys.append(served.pluginOwner)
        }
        keys.append(contentsOf: plugin.readOwnerAliases.filter { $0 != plugin.name })
        return keys
    }

    /// The user-facing ceiling for one ordinary dispatch. See
    /// `AbilityRuntime+Budget.swift` for how it is clamped and applied.
    let ordinarySkillTimeout = OSAllocatedUnfairLock<TimeInterval>(
        initialState: ordinarySkillTimeoutDefault)

    /// Test-only budget scale — same reason as `MaryBrain`'s watchdog scale.
    let budgetScale = OSAllocatedUnfairLock<Double>(initialState: 1)

    func setBudgetScaleForTesting(_ scale: Double) {
        budgetScale.withLock { $0 = scale }
    }

    // MARK: - AbilityDispatching

    public var abilitySnapshot: AbilityRuntime.Snapshot {
        AbilityTurnContext.snapshot ?? AbilityLibrary.shared.snapshot()
    }
}
