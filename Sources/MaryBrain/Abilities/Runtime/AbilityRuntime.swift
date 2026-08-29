//
//  AbilityRuntime.swift
//  MaryBrain
//
//  The subshell's dispatcher: primitives (run_applescript, run_shell) +
//  every installed plugin's Skill bindings + the dynamic confirm/cancel built-ins.
//  Reads run seamlessly; writes — write bindings, mutating or suspect
//  AppleScript, non-allowlisted shell — are held as pending Skill invocations
//  until the user's spoken go-ahead. Tolerant by design: unknown Skills and drifted
//  argument names become spoken "that didn't work", never crashes.
//

import AppKit
import Foundation
import os

public final class AbilityRuntime: AbilityDispatching, @unchecked Sendable {

    public static let confirmSkillName = "confirm_pending_skill"
    public static let cancelSkillName = "cancel_pending_skill"
    /// The screen-look Skill — named here (the confirm/cancel names'
    /// precedent) so the routine settle policy and the pre-look arm identify
    /// it through a seam rather than a string scattered at call sites.
    public static let lookSkillName = "look_at_screen"

    private struct AttributedSkillBinding: Sendable {
        let owner: String   // plugin name; "" for standalone
        let binding: SkillBinding
    }

    private struct PluginRosterCache: Sendable {
        var revision: UUID?
        var bindings: [AttributedSkillBinding] = []
    }

    private let nativeAttributed: [AttributedSkillBinding]
    private let nativeProfiles: [ApplicationProfile]
    private let rosterCache = OSAllocatedUnfairLock<PluginRosterCache>(
        initialState: .init())
    /// THE TURN'S FROZEN PROVIDER CHOICES — computed at first use from the
    /// route's application signals, cleared in `beginTurn()` beside
    /// `resolutions`. Schema projection, chip emission, and dispatch all read
    /// this one memo, which is the doc's own requirement: a chip can never
    /// name Sketch while execution uses Keynote.
    private let providerSelection = OSAllocatedUnfairLock<ProviderTurnSelection?>(
        initialState: nil)

    /// WHAT Mary ACTUALLY OFFERED THIS TURN.
    ///
    /// Routing eligibility used to be re-run at dispatch, and the reason given
    /// was a real one: a stale or hallucinated invocation still reaches
    /// `dispatch`. But routing answers "is this Ability what the turn is
    /// about", which is not that question, and it answered it from a keyword
    /// classifier — so it refused far more correct calls than fabricated ones.
    ///
    /// This answers the actual question. Keyed by `AbilityRosterSkillKey`
    /// rather than by name so the provider-neutral invocation and the exact
    /// binding operation are one claim; both resolve to the same runtime Skill
    /// and therefore the same key.
    ///
    /// TWO GENERATIONS, NOT ONE, and this is load-bearing rather than tidy.
    /// `AbilityRuntime` is a single shared instance, and a detached routine can
    /// dispatch across a turn boundary — a new turn's `beginTurn()` landing
    /// between that routine's `schemas` read and its `dispatch` would otherwise
    /// refuse a perfectly legitimate call. `beginTurn()` demotes rather than
    /// drops.
    private struct TurnOfferLedger: Sendable {
        var projected = false
        var current: Set<AbilityRosterSkillKey> = []
        var previous: Set<AbilityRosterSkillKey> = []
    }
    private let offerLedger = OSAllocatedUnfairLock<TurnOfferLedger>(
        initialState: .init())

    /// THE CALL CURRENTLY BEING DISPATCHED, carried down to `performExecute`.
    ///
    /// A task local rather than four more parameters: `dispatch` →
    /// `dispatchCore` → `execute` → `performExecute` is a chain with a dozen
    /// call sites and several other entrances (the confirmation replay among
    /// them), and threading an identity through all of them to be read in one
    /// place is how the identity ends up missing from the entrance nobody
    /// updated. Unstructured tasks inherit task locals, which is exactly what
    /// `performExecute`'s held worker needs.
    enum RunContext {
        @TaskLocal static var runID: String?
    }

    private struct InFlightRun {
        /// TYPE-ERASED, because the two execution paths hold different tasks:
        /// a native binding's worker returns a `SkillOutcome` and a workflow's
        /// returns the state machine's result. A Stop must reach both — a
        /// registry that could only hold one of them would put a live button
        /// on half the running chips and a dead one on the rest.
        let cancel: @Sendable () -> Void
        /// Someone asked for this call to stop. Kept beside the canceller
        /// because cancelling a `Task` is a REQUEST — a binding sitting in a
        /// synchronous Accessibility round trip will not notice until it
        /// returns, and when it does the outcome must still read as stopped
        /// rather than as whatever the half-done work happened to produce.
        var stopRequested = false
    }

    /// EVERY CALL A PERSON COULD ASK TO STOP, keyed by the id its chip shows.
    ///
    /// Until now the only user-facing stop was saying "stop", which cancelled
    /// every detached routine at once — there was no handle on a single call
    /// at all, because the only cancellable `Task` in the execution path was a
    /// local inside `performExecute` that nothing outside could name.
    private let inFlightRuns = OSAllocatedUnfairLock<[String: InFlightRun]>(
        initialState: [:])

    /// Ask one running call to stop. Safe to call for an id that has already
    /// settled — a stop arriving a moment late is a race a person can lose
    /// honestly, not an error.
    public func cancelRun(id: String) {
        let cancel = inFlightRuns.withLock { runs -> (@Sendable () -> Void)? in
            guard var run = runs[id] else { return nil }
            run.stopRequested = true
            runs[id] = run
            return run.cancel
        }
        cancel?()
    }

    /// Which calls are still running — the ids a Stop control may offer.
    public var runningRunIDs: Set<String> {
        Set(inFlightRuns.withLock { $0.keys })
    }

    /// Register the current call's canceller, returning the id to release
    /// with. Nil when there is no run identity in scope (a nested workflow
    /// step, which is stopped by stopping its owner).
    private func registerInFlight(
        _ cancel: @escaping @Sendable () -> Void
    ) -> String? {
        guard let identity = RunContext.runID else { return nil }
        inFlightRuns.withLock { $0[identity] = InFlightRun(cancel: cancel) }
        return identity
    }

    private func releaseInFlight(_ identity: String?) {
        guard let identity else { return }
        inFlightRuns.withLock { $0[identity] = nil }
    }

    private func wasStopRequested(_ identity: String?) -> Bool {
        guard let identity else { return false }
        return inFlightRuns.withLock { $0[identity]?.stopRequested ?? false }
    }
    private var attributed: [AttributedSkillBinding] {
        let snapshot = abilitySnapshot
        let dynamic = rosterCache.withLock { cache -> [AttributedSkillBinding] in
            if cache.revision == snapshot.revision { return cache.bindings }
            let nativeNames = Set(nativeAttributed.map { $0.binding.name })
            var seen = nativeNames
            // Every imported operation enters Mary's one compiled, data-only
            // native interaction interpreter.
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
    private var skillBindings: [SkillBinding] { attributed.map(\.binding) }
    /// Plugin id → its targeted-read binding, so fetch-first can find the read
    /// belonging to the world that LEADS this turn without the brain (or this
    /// runtime) knowing any plugin's Skill names.
    private let targetedReads: [String: (binding: String, parameter: String)]
    /// Plugin id → its revision verb, and plugin id → its half of the passage
    /// contract. THE SAME SEAM `targetedReads` IS, for the same reason: the
    /// revision gates route by whichever world LEADS the turn, and neither the
    /// brain nor this runtime may learn a plugin's Skill names to do it.
    ///
    /// A plugin absent from `targetedEdits` can compose but not revise, and
    /// `locatePassage` leaves it entirely alone — see this file's
    /// `locatePassage` for what that buys.
    private let targetedEdits: [String: (binding: String, parameter: String)]
    private let passageBackings: [String: PassageBacking]

    /// WHICH WORLD EACH BINDING OWNER SERVES, when the owner's own id does not
    /// spell it. Empty for every plugin that IS its world; populated only by an
    /// observation adapter standing in for a world whose application identity
    /// now belongs to a Dynamic package (see `MaryAdapter.servedWorld`).
    private let servedWorlds: [String: AmbientWorld]
    private let contextProvider: @Sendable () -> AbilityExecutionContext
    /// Names a plugin whose Skill bindings lead the roster this round (Skill-order
    /// bias is real for small models) — the focus arbiter's lever. Nil keeps
    /// the natural order.
    private let focusProvider: (@Sendable () -> String?)?
    private let pendingStore: PendingSkillStore
    /// The session ledger every REAL execution reports to — recorded at the
    /// leaves only, so CONFIRM parking (nothing ran) never shows and a
    /// confirmed replay shows exactly once. Injectable for test isolation.
    private let executionLog: AbilityExecutionLog
    /// WHERE THE TURN'S ACTIONS GO. Optional because a runtime built for a
    /// test has no episode to file under, and appending to nothing is a
    /// better answer than a fake episode nobody sealed.
    private let behavior: BehavioralAssembler?
    /// THE AMBIENT CONTEXT STORE. The dispatcher is one of its four writers,
    /// and the most consequential: a READ RESULT REGISTERS A FACT here instead
    /// of vanishing when the turn ends.
    ///
    /// THE FAILURE THIS FIXES, in the user's own words: "I continued the
    /// conversation and mary has lost the context of the page and the
    /// paragraph it found earlier." Skill results structurally cannot reach the
    /// speaking lane's history (`spokenMessages()` drops `.skillResult` turns), and
    /// reads are deliberately never deposited to Totem (they would come back
    /// as self-referential RAG filler) — so a passage really did exist for
    /// exactly one prompt and then cease to exist. The store is the third
    /// place, and it is the right one: short-term, aged, superseded, bounded.
    private let ambient: AmbientContextStore
    /// THE HANDLE LEDGER. Injected rather than reached for, so a test can drive
    /// the whole locate path without minting `[S1]` into the process-wide
    /// ledger the next test then reads back.
    private let passages: PassageRegistry
    /// Conversation-level identity for addressable containers. A successful
    /// document-keyed read is evidence about exactly one container even when
    /// its result takes a non-speaking Skill lane.
    private let containers: ContainerRegistry
    /// WHICH APPLICATIONS EXIST, for the owners the world enum cannot name.
    ///
    /// HELD RATHER THAN READ OFF THE PROVIDER AT EACH USE, and the reason is
    /// the same one `AmbientIntentGate` takes its capability index as a
    /// parameter: the provider is process-wide mutable state, swift-testing
    /// runs suites in parallel, and a suite that installs a roster and clears
    /// it on the way out will clear it underneath another suite mid-turn. A
    /// dispatcher that resolved its owners differently depending on which
    /// unrelated test happened to be running is not a dispatcher anyone can
    /// reason about. Defaulted to the provider so production wiring is
    /// unchanged and only a test has to say so.
    /// TEST OVERRIDE ONLY. Production resolves through the provider on every
    /// read (see `applications`), because the roster changes when a package is
    /// imported or removed and this object outlives both: it is built once at
    /// configuration, while every other reader of the registry — the watcher,
    /// the passage enum, the pane — already sees a fresh import on the next
    /// turn. Freezing a copy here made `placeOfRead` the one blind reader, so
    /// a newly imported application's reads reached nobody until a Settings
    /// save — the calendar bug's shape, one layer out, again.
    private let applicationsOverride: (any AmbientApplicationIndex)?
    private var applications: any AmbientApplicationIndex {
        applicationsOverride ?? AmbientApplicationIndexProvider.current
    }
    /// THIS TURN'S RESOLUTIONS: the Skill name as the model spelled it → the
    /// index in `attributed` of the binding that answered to it, or nil where
    /// nothing did.
    ///
    /// TURN-SCOPED because what it caches is turn-scoped: `resolve` builds its
    /// fuzzy pool off `focusProvider`, the user moves between worlds, and a
    /// resolution held across that boundary would route this turn's fuzzy call
    /// into the last turn's document. Cleared in `beginTurn`, beside the
    /// pending Skill confirmation, for exactly that reason.
    ///
    /// It is also what makes `dispatch`, `isReadOnly` and `world(ofSkill:)`
    /// describe THE BINDING THAT ACTUALLY RAN rather than what a re-resolution
    /// would pick now. Those three used to carry three hand-copied
    /// exact-then-fuzzy pairs, each with a comment promising it mirrored the
    /// others — a promise no test could check and the roster could break by
    /// growing.
    private let resolutions = OSAllocatedUnfairLock<[String: Int?]>(initialState: [:])
    /// Cleared at every `beginTurn`. Package data and plan JSON cannot write
    /// this; only trusted Design referent resolution may arm it.
    private let surfaceReferent = OSAllocatedUnfairLock<AbilitySurfaceReferent>(
        initialState: .currentLiveSelection)

    /// `SemanticSkillRequestIndex.affinities(in:)` MEMOIZED FOR THE TURN, the
    /// same "compute once, freeze" shape `providerSelection` already uses.
    ///
    /// `abilityRoutingContext()` is rebuilt from scratch on every round of the
    /// local turn loop AND on every `dispatchCore` — up to ~20 times for one
    /// utterance — and until this cache existed every one of those rebuilds
    /// re-ran a full `NLEmbedding` sentence vectorization plus a dot-product
    /// scan over the whole Skill library, serialized behind
    /// `NLAmbientTextVectorizer`'s single process-wide lock. The rest of
    /// `abilityRoutingContext()` is deliberately NOT folded into this cache:
    /// `ambient.route()` reads a task-local `AmbientRouteTurnState` whose own
    /// doc comment ("every overlapping request gets its own route holder")
    /// makes clear it is a live, per-request read, not a value frozen at turn
    /// start — caching the whole context could serve a stale application,
    /// selection, or perception set to a later round. The utterance is
    /// different: `noteUtterance` is called exactly once per turn, before the
    /// round loop begins (`MaryBrain+TurnLoop.swift`), and never again until
    /// the next turn's `beginTurn()`. So only the utterance and the affinity
    /// map it produces are cached here — keyed on the utterance itself, not
    /// just "first call wins", so a mismatched read (a detached routine
    /// dispatching across a turn boundary, the same race `TurnOfferLedger`
    /// already guards against) recomputes instead of silently answering for
    /// the wrong words.
    private let semanticSkillAffinityCache = OSAllocatedUnfairLock<
        (utterance: String, affinities: [SkillID: Float])?
    >(initialState: nil)

    public init(
        plugins: [any MaryAdapter],
        standalone: [SkillBinding] = [],
        focusProvider: (@Sendable () -> String?)? = nil,
        executionLog: AbilityExecutionLog = .shared,
        behavior: BehavioralAssembler? = nil,
        ambient: AmbientContextStore = .shared,
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
        var worlds: [String: AmbientWorld] = [:]
        for plugin in plugins {
            // An observation adapter serving a world it is not named after is
            // registered under BOTH keys: its own, because that is the owner
            // stamped on its bindings, and the world's, because
            // `targetedReadInvocation(forWorld:)` asks by `world.pluginOwner`.
            if let served = plugin.servedWorld, served.pluginOwner != plugin.name {
                worlds[plugin.name] = served
            }
            if let targeted = plugin.targetedRead {
                reads[plugin.name] = targeted
                if let served = plugin.servedWorld, served.pluginOwner != plugin.name {
                    reads[served.pluginOwner] = targeted
                }
            }
            // BOTH HALVES OR NEITHER. A verb with no backing has nothing to
            // locate against, and a backing with no verb has nowhere to send
            // the result — either alone is a half-wired world, and the honest
            // reading of a half-wired world is that it cannot revise.
            // THE BACKING NO LONGER COMES FROM THE ADAPTER. A place is
            // editable because a REGISTRATION says where its prose lives, and
            // `PassageRecipes.installBackingResolver` asks the registry; an
            // adapter that answered for itself could only ever answer for the
            // applications somebody compiled it against.
            if let verb = plugin.targetedEdit {
                edits[plugin.name] = verb
            }
        }
        self.targetedReads = reads
        self.targetedEdits = edits
        self.passageBackings = backings
        self.servedWorlds = worlds
        self.contextProvider = contextProvider
        self.focusProvider = focusProvider
        self.executionLog = executionLog
        self.ambient = ambient
        self.passages = passages
        self.containers = containers
        self.applicationsOverride = applications
        self.pendingStore = PendingSkillStore()
    }

    // MARK: - AbilityDispatching

    /// THE COUNT WITHOUT THE CONSTRUCTION. Arithmetic over the same three
    /// terms `schemas` assembles — the two primitives, the attributedBindings roster,
    /// and the confirm/cancel pair that exists exactly while a question is
    /// open. Place scoping DOES resize the roster now, so this consults the
    /// same `placeScope()` judgement `schemas` applies — one `focusProvider`
    /// call; the expensive part this exists to avoid (~130 `ModelSkillSchema`
    /// constructions) is still avoided.
    ///
    /// It exists because the Routes pane asked for `schemas.count` and thereby
    /// bought a second whole focus resolution plus ~130 schema constructions
    /// on every turn — a debugger row is not allowed to cost that.
    public var schemaCount: Int {
        let snapshot = abilitySnapshot
        let routing = abilityRoutingContext()
        let roster = rosterArbitration(snapshot: snapshot, context: routing)
        recordProjectedRoster(roster)
        let scope = placeScope()
        let visible = attributed.reduce(into: 0) { count, item in
            guard admits(owner: item.owner, scope: scope) else { return }
            guard let skill = snapshot.skill(bindingOperation: item.binding.name) else {
                count += 1
                return
            }
            // Same one-projection-per-Skill rule `projectedSchema` applies.
            guard turnOperation(for: skill, snapshot: snapshot) == item.binding.name
            else { return }
            if roster.contains(skill) { count += 1 }
        }
        let schemaExecuted = snapshot.skills.filter {
            $0.skill.execution.kind != .binding
                && roster.contains($0)
        }.count
        return visible + schemaExecuted
            + (pendingStore.current() != nil ? 2 : 0)
    }

    public var applicationProfiles: [ApplicationProfile] {
        nativeProfiles + abilitySnapshot.plugins.applicationProfiles
    }
    public var focusedApplicationID: String? {
        // The injected focus resolver is the turn's already-arbitrated answer
        // (and the production composition root supplies it). Prefer that
        // answer when it names an installed application. Falling straight to
        // NSWorkspace here let an unrelated frontmost app contradict the
        // very lead used to scope this runtime's roster; tests could reproduce
        // it whenever another suite happened to foreground Chrome.
        if let resolvedOwner = focusProvider?(),
           let resolved = applicationProfiles.first(where: {
               $0.id.caseInsensitiveCompare(resolvedOwner) == .orderedSame
           }) {
            return resolved.id
        }
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier?.lowercased() else { return nil }
        return Self.applicationID(
            forBundleIdentifier: bundleIdentifier,
            profiles: applicationProfiles)
    }

    static func applicationID(
        forBundleIdentifier bundleIdentifier: String,
        profiles: [ApplicationProfile]
    ) -> String? {
        let bundleIdentifier = bundleIdentifier.lowercased()
        if let exact = profiles.first(where: { profile in
            profile.applicationIdentifiers.contains {
                $0.lowercased() == bundleIdentifier
            }
        }) {
            return exact.id
        }
        return profiles.first { profile in
            guard let prefix = profile.applicationBundlePrefix else {
                return false
            }
            return PluginApplicationSchema.bundleIdentifier(
                bundleIdentifier,
                isInFamily: prefix)
        }?.id
    }
    public var abilitySnapshot: AbilityRuntimeSnapshot {
        AbilityTurnContext.snapshot ?? AbilityLibrary.shared.snapshot()
    }
    public var abilityRosterTrace: AbilityRosterTrace {
        let snapshot = abilitySnapshot
        return rosterArbitration(
            snapshot: snapshot,
            context: abilityRoutingContext()).trace
    }

    public func skillReference(for invocationName: String) -> AbilitySkillReference {
        let snapshot = abilitySnapshot
        var reference = snapshot.reference(forInvocation: invocationName)
        // Chips print the TURN'S provider, not the static preference — the
        // memo guarantees this is the same choice dispatch executes.
        if let runtime = snapshot.skill(invocationName: invocationName),
           runtime.reference.invocationName == invocationName,
           let choice = turnProviderSelection(snapshot: snapshot)
               .choice(for: runtime.skill.id) {
            reference.adapterID = choice.binding.adapterID
            reference.bindingOperation = choice.binding.operation
            reference.provider = choice.provider
        }
        return reference
    }

    public var schemas: [ModelSkillSchema] {
        let snapshot = abilitySnapshot
        let routing = abilityRoutingContext()
        let roster = rosterArbitration(snapshot: snapshot, context: routing)
        recordProjectedRoster(roster)
        // Stable partition: the focused plugin's Skill bindings hoist to the
        // front; within-group order is preserved. Raw primitives are appended
        // only after the typed roster below.
        // Re-read every round, like the confirm/cancel exposure below.
        // PLACE SCOPING BEFORE THE HOIST. On a writing-led turn, rival
        // watched worlds' bindings leave the roster unless this turn's words
        // named them — see `placeScope()`. Nil scope (coding lead, nothing
        // open, plugin off) keeps today's roster byte for byte, and
        // `dispatch` itself never consults this: an exact name the model
        // insists on still runs, so capability is scoped in temptation only.
        let scope = placeScope()
        var ordered = attributed.filter { admits(owner: $0.owner, scope: scope) }
        if let hoisted = focusProvider?(),
           ordered.contains(where: { $0.owner == hoisted }) {
            ordered = ordered.filter { $0.owner == hoisted }
                + ordered.filter { $0.owner != hoisted }
        }
        // Preference is package data, applied as a stable tuning signal after
        // Mary has formed the safe/focused candidate roster. It can reorder
        // eligible Skills; it cannot manufacture an implementation or bypass
        // a local confirmation/stage constraint.
        ordered = ordered.enumerated().sorted { lhs, rhs in
            let left = snapshot.skill(bindingOperation: lhs.element.binding.name)?
                .skill.routing.preference ?? 0
            let right = snapshot.skill(bindingOperation: rhs.element.binding.name)?
                .skill.routing.preference ?? 0
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        var result: [ModelSkillSchema] = []
        let schemaExecuted = snapshot.skills
            .filter { $0.skill.execution.kind != .binding }
            .sorted {
                if $0.skill.routing.preference == $1.skill.routing.preference {
                    return $0.skill.id.rawValue < $1.skill.id.rawValue
                }
                return $0.skill.routing.preference > $1.skill.routing.preference
            }
        result.append(contentsOf: schemaExecuted.compactMap {
            projectedSchema(for: $0, roster: roster)
        })
        result.append(contentsOf: ordered.compactMap {
            projectedSchema(for: $0.binding, snapshot: snapshot, roster: roster)
        })
        // Raw machine primitives are escape hatches, so typed Ability Skills
        // lead the roster. On an application-control turn already covered by
        // a selected typed Skill, AppleScript and shell disappear entirely;
        // otherwise the model could bypass exact resolution (including by
        // shelling out to osascript) and manufacture a mutation confirmation
        // for an operation whose typed contract needs none.
        // The confirm/cancel Skills exist exactly while a question is open —
        // the brain re-reads schemas every round, so exposure is dynamic.
        if pendingStore.current() != nil {
            result.append(ModelSkillSchema(
                name: Self.confirmSkillName,
                description: "Execute the Skill invocation waiting for the user's confirmation. Call ONLY after the user has clearly agreed.",
                parameters: []
            ))
            result.append(ModelSkillSchema(
                name: Self.cancelSkillName,
                description: "Discard the Skill invocation waiting for confirmation. Call when the user declines or changes the subject.",
                parameters: []
            ))
        }
        return result
    }

    /// Project the portable Skill schema onto the provider-neutral callable
    /// contract. Adapter closures and trusted descriptions remain local;
    /// package data contributes only validated naming, typed parameter shape,
    /// bounded enum tokens, and model visibility.
    private func projectedSchema(
        for binding: SkillBinding,
        snapshot: AbilityRuntimeSnapshot,
        roster: AbilityRosterArbitration
    ) -> ModelSkillSchema? {
        guard let runtime = snapshot.skill(bindingOperation: binding.name) else {
            return binding.schema
        }
        // ONE PROJECTION PER SKILL. Every compatible candidate's operation
        // materializes now (rival applications included), and all of them
        // share the Skill's provider-neutral invocation name — only the
        // turn's chosen provider may project it, or the model would see
        // duplicate `create_design_shape` schemas.
        guard turnOperation(for: runtime, snapshot: snapshot) == binding.name else {
            return nil
        }
        guard roster.contains(runtime) else { return nil }
        let exposure = runtime.skill.modelExposure
        let parameters: [ModelSkillSchema.Parameter]
        if exposure.inheritsBindingContract && exposure.parameters.isEmpty {
            parameters = binding.parameters
        } else {
            parameters = exposure.parameters.map { projected in
                let adapterDescription = binding.parameters.first(where: {
                    $0.name == projected.name
                })?.description
                return ModelSkillSchema.Parameter(
                    name: projected.name,
                    type: projected.type,
                    description: adapterDescription ?? "Typed input \(projected.name).",
                    required: projected.required,
                    enumValues: projected.enumValues.isEmpty ? nil : projected.enumValues)
            }
        }
        return ModelSkillSchema(
            name: runtime.reference.invocationName,
            description: projectedBindingDescription(
                binding.description,
                for: runtime,
                bindingOperation: binding.name,
                snapshot: snapshot),
            parameters: parameters)
    }

    /// Dynamic operation semantics are a last-mile model-selection hint, not
    /// a routing input. Ordinary Ability, application, Skill, provider, and
    /// availability policy has already admitted exactly one binding before
    /// this seam runs. Resolve that binding back through its compiled
    /// realization and origin package so an alias can never leak between
    /// applications or similarly named operations. Free-form package prose
    /// is deliberately absent: only the closed role and validated machine
    /// tokens extend the Mary-owned adapter description.
    private func projectedBindingDescription(
        _ base: String,
        for runtime: AbilityRuntimeSkill,
        bindingOperation: String,
        snapshot: AbilityRuntimeSnapshot
    ) -> String {
        guard snapshot.validation.isValid else { return base }
        let providerSelection = turnProviderSelection(snapshot: snapshot)
        guard providerSelection.mismatch(for: runtime.skill.id) == nil else {
            return base
        }
        let selected = providerSelection.choice(for: runtime.skill.id)?.binding
            ?? runtime.availability.selectedBinding
        guard let selected,
              selected.operation == bindingOperation,
              let realization = snapshot.plugins.realization(
                  skillID: runtime.skill.id,
                  adapterID: selected.adapterID,
                  operation: selected.operation),
              let record = snapshot.package(id: realization.originPackageID),
              record.validation.isValid,
              let plugin = record.package.plugin,
              let operation = plugin.operations.first(where: {
                  $0.operation == selected.operation
                      && plugin.adapter(for: $0)?.id == selected.adapterID
              }),
              let semantics = operation.semantics
        else { return base }

        let role: String
        switch semantics.role {
        case .utility: role = "utility"
        case .observe: role = "observe"
        case .createArtifact: role = "create artifact"
        case .mutateArtifact: role = "mutate existing artifact"
        }
        var hint = "Semantic role: \(role). This hint distinguishes only among model tools already admitted by Ability, application, and Skill routing; it never grants application, target, or Skill authority."
        if semantics.role == .createArtifact, !semantics.aliases.isEmpty {
            hint += " Validated creation subjects: \(semantics.aliases.joined(separator: ", "))."
        }
        return "\(base) \(hint)"
    }

    /// Cognitive and workflow Skills have no direct Plugin binding, so they
    /// project through their executable machine contract rather than through
    /// package-authored prose. Cognitive schemas are completely Mary-owned;
    /// workflows expose only typed parameter shape plus a fixed description.
    private func projectedSchema(
        for runtime: AbilityRuntimeSkill,
        roster: AbilityRosterArbitration
    ) -> ModelSkillSchema? {
        guard roster.contains(runtime) else { return nil }
        switch runtime.skill.execution.kind {
        case .binding:
            return nil
        case .cognitive:
            return CognitivePrimitiveCatalog.modelSchema(for: runtime)
        case .stateMachine:
            let exposure = runtime.skill.modelExposure
            return ModelSkillSchema(
                name: runtime.reference.invocationName,
                description: "Run this validated Mary workflow. Every step is bounded and resolves to an installed Skill or a closed Mary cognitive primitive before execution begins.",
                parameters: exposure.parameters.map {
                    ModelSkillSchema.Parameter(
                        name: $0.name,
                        type: $0.type,
                        description: "Typed workflow input \($0.name).",
                        required: $0.required,
                        enumValues: $0.enumValues.isEmpty ? nil : $0.enumValues)
                })
        }
    }

    /// WHAT MAY EXECUTE — facts provable without consulting how the user
    /// phrased this turn.
    ///
    /// THE SPLIT THIS FILE NOW MAKES, and why. Everything below used to sit in
    /// one predicate shared by projection and dispatch, and two of its checks
    /// were routing eligibility: closed predicates over `.intent`,
    /// `.utteranceToken`, `.utterancePhrase` and minted `.targetClass` values,
    /// all produced by keyword classifiers. Enforcing those at dispatch meant a
    /// tool the model had already correctly chosen could be refused because a
    /// classifier under-produced a fact — and the tree carries the scars:
    /// `type_at_cursor` refused in a manuscript because the turn read `operate`
    /// rather than `compose`; `bring_window_forward` refused because the user
    /// said "pull it up" instead of "bring the window forward". Both were
    /// patched narrowly before, each time by widening a keyword list.
    ///
    /// `AmbientIntent`'s own header states the rule this restores: "Routing
    /// guides prompts and memory, NOT what applications or Abilities the user
    /// may reach." Routing now shapes what Mary OFFERS
    /// (`projectionEligibilityFailure`); this decides what may RUN. The
    /// concern that motivated the old re-check — a stale or hallucinated
    /// invocation reaching `dispatch` — is real, and is answered directly by
    /// `offerLedgerFailure`: was this in the roster we actually projected?
    /// That is a fact about the turn, not about its phrasing.
    private func dispatchEligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext,
        snapshot: AbilityRuntimeSnapshot
    ) -> String? {
        let policy = snapshot.executionPolicy(for: runtime.skill)
        if !runtime.skill.modelExposure.enabled {
            return "is not exposed for model invocation"
        }
        // Binding confirmations are resumable through `PendingSkillStore`.
        // State machines currently are not, so a top-level `.confirm`
        // workflow must never enter execution and run its first effect.
        if runtime.skill.execution.kind == .stateMachine,
           runtime.skill.access == .confirm {
            return "requires a resumable workflow confirmation boundary"
        }
        if policy.requiresStage && !runtime.skill.usesStage {
            return "does not declare the stage required by its Capability contract"
        }
        if policy.requiresUserConfirmation && runtime.skill.access != .confirm {
            return "does not declare the user confirmation required by its Capability contract"
        }
        if policy.allowedTargetClasses?.isEmpty == true {
            return "has conflicting Capability target-class allowlists"
        }
        if runtime.availability.readiness != .ready {
            return runtime.availability.reasons.first
                ?? "has no available adapter binding"
        }
        let requiredInteractions = Set(runtime.skill.requirements.interactions)
        let missingInteractions = requiredInteractions.subtracting(context.interactions)
        if let missing = missingInteractions.sorted(by: {
            $0.rawValue < $1.rawValue
        }).first {
            return "requires current Interaction \(missing.rawValue)"
        }
        let requiredPerceptions = Set(runtime.skill.requirements.perceptions)
        let missingPerceptions = requiredPerceptions.subtracting(context.perceptions)
        if let missing = missingPerceptions.sorted(by: {
            $0.rawValue < $1.rawValue
        }).first {
            return "requires current Perception \(missing.rawValue)"
        }
        let requiredCapabilities = Set(runtime.skill.requirements.capabilities)
        let executableCapabilities = context.capabilities.union(
            CognitivePrimitiveCatalog.internalCapabilities(for: runtime))
        let missingCapabilities = requiredCapabilities.subtracting(executableCapabilities)
        if let missing = missingCapabilities.sorted(by: {
            $0.rawValue < $1.rawValue
        }).first {
            return "requires available Capability \(missing.rawValue)"
        }
        let supportingAbilities = Set(
            runtime.skill.requirements.supportingAbilities
                + runtime.ability.operatingPolicy.defaultSupportingAbilities)
        if let missing = supportingAbilities
            .filter({ !snapshot.containsAbility($0) })
            .sorted(by: { $0.rawValue < $1.rawValue }).first {
            return "requires supporting Ability \(missing.rawValue)"
        }
        let effect = snapshot.effect(
            forInvocation: runtime.reference.invocationName)
        if let failure = routedSignalSnapshot()
            .mutationAuthorizationFailure(for: runtime.skill, effect: effect) {
            return failure
        }
        if runtime.skill.execution.kind == .stateMachine,
           let failure = workflowExecutionSafetyFailure(
               for: runtime,
               snapshot: snapshot) {
            return failure
        }
        return nil
    }

    /// ADVISORY. The closed routing predicates, read over a keyword
    /// classifier's reading of this turn.
    ///
    /// These decide what Mary OFFERS. They are a claim about relevance —
    /// which Ability this turn is probably about — and relevance is exactly
    /// the kind of judgement that should steer a model rather than overrule
    /// it. Kept separate so the distinction is visible at the call site: any
    /// future check added here is advisory by construction.
    private func routingEligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext
    ) -> String? {
        if !AbilityRoutingEvaluator.isEligible(runtime.ability.routing, in: context) {
            return "does not match its Ability-level routing policy"
        }
        if !AbilityRoutingEvaluator.isEligible(runtime.skill.routing, in: context) {
            return "does not match this turn's source and routing context"
        }
        return nil
    }

    /// WHAT MAY BE OFFERED — the executable set, narrowed by relevance.
    ///
    /// This is the arbitrator's complete pre-arbitration gate and its input
    /// diet is deliberately UNCHANGED by the projection/dispatch split.
    /// `AbilityRosterArbitrator` uses this to decide which Ability leads a
    /// turn; feeding it a set with routing removed would put Writing into the
    /// ability conflict group on coding turns and change what the model sees
    /// on every turn in the app. Keeping it identical is what bounds the split
    /// to dispatch.
    private func projectionEligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext,
        snapshot: AbilityRuntimeSnapshot
    ) -> String? {
        dispatchEligibilityFailure(for: runtime, in: context, snapshot: snapshot)
            ?? routingEligibilityFailure(for: runtime, in: context)
    }

    /// The closed arbitration stage starts from the projection gate's safe set
    /// and can only remove Skills.
    private func eligibilityFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext,
        snapshot: AbilityRuntimeSnapshot,
        roster: AbilityRosterArbitration? = nil
    ) -> String? {
        if let failure = projectionEligibilityFailure(
            for: runtime,
            in: context,
            snapshot: snapshot) {
            return failure
        }
        let roster = roster ?? rosterArbitration(snapshot: snapshot, context: context)
        return roster.failure(for: runtime)
    }

    /// Record the roster as PROJECTED, before place scoping and the
    /// one-projection-per-Skill filter narrow it further.
    ///
    /// Deliberately the pre-filter set. Recording what survived `placeScope()`
    /// and `admits(owner:scope:)` would quietly turn place scoping into a
    /// dispatch gate, contradicting the rule already written into `schemas`:
    /// "`dispatch` itself never consults this: an exact name the model insists
    /// on still runs."
    private func recordProjectedRoster(_ roster: AbilityRosterArbitration) {
        offerLedger.withLock {
            $0.projected = true
            $0.current.formUnion(roster.selectedKeys)
        }
    }

    /// THE ROSTER'S ONE AUTHORIZATION CLAIM: was this offered?
    ///
    /// A roster is advice. The ledger is the machine record of the advice
    /// actually given, and refusing a name Mary never offered is a fact
    /// about this turn's projection. Refusing one she DID offer, because the
    /// utterance no longer matches a keyword predicate, is not.
    private func offerLedgerFailure(
        for runtime: AbilityRuntimeSkill,
        roster: AbilityRosterArbitration
    ) -> String? {
        // Offerable right now: nothing to say.
        if roster.contains(runtime) { return nil }
        let ledger = offerLedger.withLock { $0 }
        // Nothing was ever projected against this runtime — the deterministic
        // decision path, a direct host call, a test driving dispatch alone.
        // There is no roster to have been offered from, so nothing to
        // contradict.
        guard ledger.projected else { return nil }
        let key = AbilityRosterSkillKey(runtime)
        if ledger.current.contains(key) || ledger.previous.contains(key) { return nil }
        // The arbitrator's own sentence when it has one — "had stronger typed
        // evidence in ability by …" tells the model which Skill to call
        // instead, which "was not offered" alone does not.
        guard let arbitration = roster.failure(for: runtime) else {
            return "was not offered in this turn's Skill roster"
        }
        return "was not offered in this turn's Skill roster — it \(arbitration)"
    }

    private func rosterArbitration(
        snapshot: AbilityRuntimeSnapshot,
        context: AbilityRoutingContext
    ) -> AbilityRosterArbitration {
        AbilityRosterArbitrator.arbitrate(
            skills: snapshot.skills,
            context: context) { [self] runtime in
                projectionEligibilityFailure(
                    for: runtime,
                    in: context,
                    snapshot: snapshot)
            }
    }

    /// Snapshot readiness proves schema-level resolution. This second check
    /// proves the live executable roster: workflow steps never use fuzzy name
    /// matching, never cross a hidden confirmation boundary, and never reach
    /// an arbitrary operation supplied only as package text.
    private func workflowExecutionSafetyFailure(
        for runtime: AbilityRuntimeSkill,
        snapshot: AbilityRuntimeSnapshot,
        visiting: Set<SkillID> = []
    ) -> String? {
        guard runtime.skill.execution.kind == .stateMachine else { return nil }
        guard !visiting.contains(runtime.skill.id) else {
            return "contains a recursive workflow cycle"
        }
        var nextVisiting = visiting
        nextVisiting.insert(runtime.skill.id)
        for step in runtime.skill.execution.steps {
            if let target = snapshot.skill(invocationName: step.operation) {
                if target.availability.readiness != .ready {
                    return "step \(step.id) targets an unavailable Skill"
                }
                if target.skill.access == .confirm {
                    return "step \(step.id) crosses an undeclared confirmation boundary"
                }
                switch target.skill.execution.kind {
                case .binding:
                    guard let operation = target.bindingOperation,
                          let local = attributed.first(where: {
                              $0.binding.name == operation
                          })?.binding
                    else {
                        return "step \(step.id) has no exact local implementation"
                    }
                    if local.access == .write {
                        return "step \(step.id) requires resumable user confirmation"
                    }
                case .cognitive:
                    guard CognitivePrimitiveCatalog.contract(for: target) != nil else {
                        return "step \(step.id) targets an unknown cognitive primitive"
                    }
                case .stateMachine:
                    if let failure = workflowExecutionSafetyFailure(
                        for: target,
                        snapshot: snapshot,
                        visiting: nextVisiting) {
                        return "step \(step.id) cannot run: \(failure)"
                    }
                }
            } else if CognitivePrimitiveCatalog.contract(
                workflowOperation: step.operation,
                abilityID: runtime.ability.id) == nil {
                return "step \(step.id) names unresolved operation \(step.operation)"
            }
        }
        return nil
    }

    private func blockedOutcome(
        runtime: AbilityRuntimeSkill,
        reason: String
    ) -> SkillOutcome {
        SkillOutcome(
            ok: false,
            summary: "\(runtime.reference.displayLabel) is unavailable: \(reason).",
            status: .blocked,
            archivePolicy: .none,
            skillReference: runtime.reference)
    }

    /// The immutable turn signal set after semantic route containment. A
    /// source-owned selection may remain on `AmbientRoute.attention` for
    /// diagnostics even when an explicitly named conflicting application
    /// means it is not this turn's referent. In that case its text/code
    /// Interaction cannot affect roster arbitration, payload delivery,
    /// mutation authorization, or workflow ports. Other Interaction and all
    /// Perception schemas remain untouched.
    private func routedSignalSnapshot() -> SchemaSignalTurnSnapshot {
        let snapshot = SchemaSignalTurnContext.snapshot ?? .empty
        let route = ambient.route()
        guard let rejectedAttention = route?.attention,
              rejectedAttention.tier == .selection,
              route?.selectionDefinesTurn != true
        else { return snapshot }
        let rejectedHandoffID = ambient.selectionHandoff(
            world: rejectedAttention.world)?.id
        // CODE OR PROSE, asked of the registration rather than of a name.
        // This read `== .xcode` when there was a compiled world to compare
        // against; the question it was really asking is which DISCIPLINE the
        // place registers for, and that is a thing a package declares.
        let rejectedSchema: InteractionID =
            rejectedAttention.place.focus == .coding
            ? .codeSelection
            : .textSelection
        return SchemaSignalTurnSnapshot(
            interactions: snapshot.interactions.filter {
                if let rejectedHandoffID {
                    return $0.id != rejectedHandoffID
                }
                // Identity is normally available through the turn-local
                // handoff. The schema fallback fails closed for legacy/manual
                // routes while preserving the other selection family.
                return $0.reference.schemaID != rejectedSchema
            },
            perceptions: snapshot.perceptions)
    }

    /// INTERNAL, not private: this is the turn's whole routing verdict, and
    /// the parity suite for a taught application has to be able to read it.
    /// The bug it exists to catch — a taught workspace producing none of these
    /// signals — is invisible from the outside until a Skill goes missing from
    /// the roster, which is three layers later and reads as a model failure.
    func abilityRoutingContext() -> AbilityRoutingContext {
        let route = ambient.route()
        let windowIntent = windowManagementTurnIntent(route: route)
        let diagnosticAttention = route?.attention
        // Keep the source packet on AmbientRoute for diagnostics and event
        // ordering, but do not let a selection the route explicitly rejected
        // as this turn's referent shape application, source, target, or roster
        // eligibility. Hover and other non-selection attention remain intact.
        let excludesDiagnosticSelection = diagnosticAttention?.tier == .selection
            && route?.selectionDefinesTurn != true
        let attention = excludesDiagnosticSelection ? nil : diagnosticAttention
        let facts = ambient.facts()
        let handoff = attention.flatMap {
            ambient.routedSelectionHandoff(world: $0.world)
        }
        var interactions: Set<InteractionID> = []
        let signalSnapshot = routedSignalSnapshot()
        let routingInteractions = signalSnapshot.interactions
        interactions.formUnion(routingInteractions.map { $0.reference.schemaID })
        var interactionEvidenceRanks: [InteractionID: Int] = [:]
        for interaction in routingInteractions {
            let id = interaction.reference.schemaID
            interactionEvidenceRanks[id] = max(
                interactionEvidenceRanks[id] ?? 0,
                interaction.evidenceRank)
        }
        // A selection only becomes a routable Interaction after the schema
        // bridge validates its typed payload, scope, and evidence. The raw
        // handoff remains conversational context when it cannot satisfy an
        // effectful Skill contract.
        // THE LEAD REALM, NOT THE LEAD WORLD. `route.lead` is an
        // `AmbientWorld?` and is nil on EVERY taught-application turn — the
        // arbiter forces it nil whenever a dynamic application leads — so a
        // manuscript application the user installed produced none of these
        // perceptions. `compose_draft`, `revise_selection`, `revert_last_edit`
        // and all five passage verbs require `workspace-focus`, which made
        // them ineligible on every single turn in that application while
        // `type_at_cursor` (which requires nothing) went on working. That is
        // the whole shape of "she can type but she can't write".
        //
        // `leadPlace` answers for both kinds and is already correct — see
        // `AmbientRoute.leadPlace(lead:leadApplicationID:)`.
        var perceptions = signalSnapshot.perceptionIDs
        if let lead = route?.leadPlace {
            // A NATIVE LEAD IS BYTE-IDENTICAL: it earns the focus perception
            // for leading at all, exactly as it did. A DYNAMIC one must earn
            // it from the class its package declared, so a taught data source
            // — a music player, a mail client — leading the turn does not
            // start claiming workspace focus. Strictly narrower than what a
            // compiled world gets, which is the safe direction to be wrong in.
            // A LEAD EARNS WORKSPACE FOCUS FROM ITS DECLARED CLASS, and only
            // from that. The version this replaces gave it away for free to
            // any compiled world and made a taught one prove it, which is a
            // rule about who wrote the integration rather than about what the
            // place is — so a music player taught to Mary was held to a
            // standard an editor compiled into her never met.
            if lead.worldClass == .workspace {
                perceptions.insert(.workspaceFocus)
                perceptions.insert(.projectFocus)
            }
            if lead.focus == .coding {
                perceptions.insert(.codeWorkspaceFocus)
            }
        }
        if attention?.applicationID != nil
            || route?.leadApplicationID != nil
            || !(route?.gate.applications.isEmpty ?? true) {
            perceptions.insert(.applicationFocus)
        }
        if handoff?.scope.windowID != nil { perceptions.insert(.windowFocus) }
        if attention?.tier == .hover { perceptions.insert(.hover) }
        if facts.contains(where: { $0.slot == .viewport }) {
            perceptions.insert(.viewport)
        }

        // Source resolution is the most specific fact this turn can prove,
        // not merely the presence of a highlighted range. A live Xcode file
        // or Pages/TextEdit document remains a document-scoped source when no
        // text is selected, which is the normal shape of build, read-symbol,
        // passage, and cursor-writing turns.
        func rank(_ value: SourceResolution) -> Int {
            switch value {
            case .unresolved: return 0
            case .device: return 1
            case .application: return 2
            case .window: return 3
            case .workspace: return 4
            case .document: return 5
            }
        }
        var sourceResolution = handoff?.scope.resolution
            ?? ((attention?.applicationID != nil || route?.leadApplicationID != nil)
                ? .application : .unresolved)
        func promote(_ candidate: SourceResolution) {
            if rank(candidate) > rank(sourceResolution) { sourceResolution = candidate }
        }
        for interaction in routingInteractions {
            promote(interaction.reference.scope.resolution)
        }
        for perception in signalSnapshot.perceptions {
            promote(perception.reference.scope.resolution)
        }
        if let lead = route?.leadPlace, lead.worldClass == .workspace {
            promote(.workspace)
            // `$0.place == lead`, NOT `$0.world == lead`. Every taught
            // application's facts ride the shared `.otherApps` host lane, so
            // matching on the world would let one application's open file
            // promote another's turn to `.document`.
            let leadFacts = facts.filter { $0.place == lead }
            if leadFacts.contains(where: {
                $0.slot == .file && $0.subject?.isEmpty == false
            }) {
                promote(.document)
            }
        } else if route?.leadApplicationID != nil
            || !(route?.gate.applications.isEmpty ?? true) {
            promote(.application)
        }
        // THE FAMILY IS THE LEAD PLACE'S ABILITY. This was an inline switch
        // producing an untyped string over exactly two values, and the values
        // it produced were `AbilityID` raw values by coincidence rather than
        // by construction. `AmbientPlace.ability` is now the one mapping, so
        // this cannot drift from the behavioural schema's Ability rung — and
        // `predicate(.workspaceFamily, "design")`, which design.mary has
        // always declared and which could never fire because nothing produced
        // "design", now resolves.
        //
        // ASKED OF THE REALM, and the correction matters: an earlier revision
        // of this comment recorded that no shipped package declares a
        // `workspaceFamily == "writing"` predicate. `writing.mary` does —
        // it is one of four `any(...)` arms by which the Writing ability is
        // admitted at all. Keyed on the WORLD, that arm was unreachable in
        // every taught application (`AmbientWorld.ability` answers only for
        // the compiled worlds), so the one road that does not depend on the
        // classifier reading a sentence correctly was open to Pages and shut
        // to a manuscript application the user installed.
        //
        // `.keynote` joined the writing family when its Plugin went Native:
        // the tracker already treats a deck session as `.writing(.keynote)`.
        // Pinned by `keynoteLeadWorkspaceFamilyGatesTheRoster` and, for the
        // taught side, by `TaughtApplicationParityTests`.
        let workspaceFamily: String? = route?.leadPlace?.ability?.rawValue
        let capabilities = Set(
            abilitySnapshot.bindings
                .filter { $0.adapter.isAvailable }
                .flatMap { $0.adapter.capabilities })
        let grantedPermissions = Set(
            abilitySnapshot.adapterManifests
                .filter(\.isAvailable)
                .flatMap(\.grantedPermissions))
        var targets = Set(route?.namedPlaces.map(\.token) ?? [])
        targets.formUnion(windowIntent.targetClasses)
        if let lead = route?.leadPlace {
            targets.insert(lead.token)
            targets.insert(lead.worldClass.rawValue)
            // A LEAD'S CLASSES COME FROM ITS PACKAGE, all of them.
            //
            // This used to be a switch over compiled worlds, with a
            // hand-written note explaining why one of them was deliberately
            // missing from the prose-surface arm — a policy about whether a
            // slide deck is editable prose, written into the reasoning core,
            // about an application. `targetClasses` is the field a package
            // declares for exactly this, and until now nothing read it: the
            // switch answered first for the five it knew and the declared
            // field only ever spoke for the rest.
            if let registration = AmbientApplicationIndexProvider.current
                .registration(place: lead) {
                targets.formUnion(registration.profile.targetClasses)
            }
        }
        if attention?.selectionEditability == .editable,
           attention?.place.focus != .coding {
            targets.insert("editable-prose-surface")
        }
        if let writingTarget = route?.writingTarget?.rawValue {
            targets.insert(writingTarget)
        }
        // A TAUGHT WORKSPACE'S CLASSES COME FROM ITS PACKAGE. The switch above
        // named `.scrivener` beside Pages and TextEdit, which is a compiled
        // answer to a question the package already answers:
        // `scrivener.mary` declares exactly `document-workspace` and
        // `editable-prose-surface` in its own `targetClasses`, and a second
        // manuscript application declares its own. Reading the roster is what
        // makes the passage verbs — which gate on precisely these two classes
        // — reachable for an application Mary was never compiled with.
        if let leadApplicationID = route?.leadApplicationID,
           let registration = AmbientApplicationIndexProvider.current
            .registration(id: leadApplicationID) {
            targets.formUnion(registration.profile.targetClasses)
        }
        // THE CLASS, from the lead PLACE. The block above stays keyed on
        // `route.lead` deliberately — `AmbientPlace.world` answers
        // `.otherApps` for a taught application, so `lead.rawValue` there
        // would start emitting "other_apps" and "perception_only" as target
        // classes on every taught turn. Only the CLASS generalises, and it is
        // the one a compiled workspace already contributes.
        if let leadPlace = route?.leadPlace {
            targets.insert(leadPlace.worldClass.rawValue)
        }
        var namedApplications = Set(route?.gate.applications ?? [])
        if let id = route?.leadPlace?.application { namedApplications.insert(id) }
        if let leadApplicationID = route?.leadApplicationID {
            namedApplications.insert(leadApplicationID)
        }
        if let applicationID = attention?.applicationID {
            namedApplications.insert(applicationID)
        }
        let normalizedApplicationIDs = Set(namedApplications.map { $0.lowercased() })
        for profile in applicationProfiles where
            normalizedApplicationIDs.contains(profile.id.lowercased())
                || !Set(profile.applicationIdentifiers.map { $0.lowercased() })
                    .isDisjoint(with: normalizedApplicationIDs) {
            targets.formUnion(profile.targetClasses)
        }
        // ONE VECTORIZATION FOR THE WHOLE TURN, computed here rather than per
        // Skill inside the scorer, which the arbitrator calls several times
        // for the same Skill across its passes.
        let utterance = ambient.utterance()
        return AbilityRoutingContext(
            utterance: utterance,
            intent: route?.intent.rawValue,
            namedApplications: namedApplications,
            targetClasses: targets,
            interactions: interactions,
            interactionEvidenceRanks: interactionEvidenceRanks,
            perceptions: perceptions,
            capabilities: capabilities,
            grantedPermissions: grantedPermissions,
            sourceResolution: sourceResolution,
            workspaceFamily: workspaceFamily,
            semanticSkillAffinity: semanticSkillAffinities(for: utterance))
    }

    /// See `semanticSkillAffinityCache`. One vectorization and one library
    /// scan per turn rather than one per `abilityRoutingContext()` call.
    private func semanticSkillAffinities(for utterance: String) -> [SkillID: Float] {
        if let cached = semanticSkillAffinityCache.withLock({ $0 }),
           cached.utterance == utterance {
            return cached.affinities
        }
        let computed = abilitySnapshot.semanticSkillIndex?
            .affinities(in: utterance) ?? [:]
        semanticSkillAffinityCache.withLock { $0 = (utterance, computed) }
        return computed
    }

    /// The window-classifier's view of the turn.
    ///
    /// THE DOCUMENT NOUN COMES FROM THE PACKAGE. This used to hand the
    /// classifier two booleans named after one application, which is how "the
    /// note" became a phrase compiled into Mary; a place that calls its
    /// documents chapters got the wrong word or none. The leading prose
    /// surface declares its own noun and the classifier is told it.
    private func windowManagementTurnIntent(
        route: AmbientRoute?
    ) -> WindowManagementTurnIntent {
        let referent = ambient.referent()
        let index = AmbientApplicationIndexProvider.current

        // WHICH DOCUMENT-HOLDING PLACE LEADS, by the same three rungs the rest
        // of routing uses: the referent points at one, the turn leads in one,
        // or the user named one.
        let candidates: [AmbientPlace] = [
            referent?.place, route?.leadPlace,
        ].compactMap { $0 } + Array(route?.namedPlaces ?? [])

        let place = candidates.first { candidate in
            index.registration(place: candidate)?.observesDocuments == true
        }
        let documentPlace = place.flatMap { candidate -> WindowManagementDocumentPlace? in
            guard let id = candidate.application else { return nil }
            return WindowManagementDocumentPlace(
                applicationID: id,
                documentNoun: index.registration(place: candidate)?
                    .documentNoun ?? "document",
                isReferent: referent?.place == candidate)
        }
        return WindowManagementTurnClassifier.classify(
            utterance: ambient.utterance(),
            documentPlace: documentPlace)
    }

    /// Whether this is an acting application turn covered by a typed operation
    /// or by that operation's frozen provider refusal. A mismatch is still a
    /// typed answer: reopening raw machine primitives there would let the model
    /// bypass the exact application/provider boundary that just abstained. The
    /// roster and provider resolver have already interpreted every package's
    /// predicates, signals, conflicts, and fallbacks; this boundary adds no
    /// second semantic classifier.
    private func selectedTypedAbilityCoversApplicationTurn(
        snapshot: AbilityRuntimeSnapshot,
        roster: AbilityRosterArbitration,
        routing: AbilityRoutingContext
    ) -> Bool {
        guard ["operate", "compose", "revise"].contains(routing.intent ?? "")
        else { return false }
        let hasApplicationContext = !routing.namedApplications.isEmpty
            || routing.perceptions.contains(.applicationFocus)
            || routing.sourceResolution == .application
            || routing.sourceResolution == .window
            || routing.sourceResolution == .workspace
            || routing.sourceResolution == .document
        guard hasApplicationContext else { return false }

        let providerSelection = turnProviderSelection(snapshot: snapshot)
        return snapshot.skills.contains { runtime in
            runtime.skill.modelExposure.enabled
                && runtime.skill.execution.kind != .cognitive
                && (roster.contains(runtime)
                    || providerSelection.mismatch(for: runtime.skill.id) != nil)
        }
    }

    public func beginTurn() {
        pendingStore.beginTurn()
        // The matcher memo is a claim about THIS turn's leading world; a new
        // turn may be led by another one. See `resolutions`.
        resolutions.withLock { $0.removeAll() }
        // Provider choices are a claim about this turn's signals — named,
        // interaction, focused — for exactly the same reason.
        providerSelection.withLock { $0 = nil }
        // The embedding memo is a claim about THIS turn's utterance; a new
        // turn notes a new one after this returns. See
        // `semanticSkillAffinityCache`.
        semanticSkillAffinityCache.withLock { $0 = nil }
        // WHICH BROWSER this turn means, for the same reason and with the
        // same lifetime. Held at the MaryAdapter contract root rather than
        // here because the bindings that read it are adapters, which this
        // library drives through the contract; the turn boundary is still
        // ours to declare.
        // The browser lane's per-turn pins used to be cleared here. That lane
        // is not in this cut; when it returns it clears itself from here.
        surfaceReferent.withLock { $0 = .currentLiveSelection }
        // DEMOTED, NOT DROPPED — see `TurnOfferLedger`. A detached routine
        // dispatches across this boundary, and clearing outright would refuse
        // its legitimate call as though it had been invented.
        offerLedger.withLock {
            $0.previous = $0.current
            $0.current = []
            $0.projected = !$0.previous.isEmpty
        }
    }


    private func executionContext() -> AbilityExecutionContext {
        var context = contextProvider()
        context.surfaceReferent = surfaceReferent.withLock { $0 }
        // PROVENANCE FOR THE ADAPTERS. Set here rather than in the injected
        // provider because the provider is built once at composition and the
        // utterance changes every turn.
        context.utterance = ambient.utterance()
        return context
    }

    // MARK: - Per-turn application-aware provider selection

    /// The turn's provider choices, resolved once from the route and frozen.
    /// A dispatch arriving outside any turn (no route noted yet) resolves
    /// with empty signals, which is static preference — today's behavior.
    private func turnProviderSelection(
        snapshot: AbilityRuntimeSnapshot
    ) -> ProviderTurnSelection {
        if let memo = providerSelection.withLock({ $0 }) { return memo }
        let route = ambient.route()
        // The words' own applications: the route gate plus the lead. The
        // lead conflates named and focus-inherited applications, and that is
        // fine — when it disagrees with the live focus it was named or
        // deliberately carried, which is exactly what outranks focus.
        var named = Set(route?.gate.applications ?? [])
        if let leadApplicationID = route?.leadApplicationID {
            named.insert(leadApplicationID)
        }
        let interaction = route?.selectionDefinesTurn == true
            ? route?.attention?.applicationID : nil
        let signals = ApplicationProviderSignals(
            namedApplicationIDs: named,
            interactionApplicationID: interaction,
            pinnedApplicationID: nil,
            focusedApplicationID: focusedApplicationID)
        let resolved = ApplicationProviderResolver.resolve(
            snapshot: snapshot, signals: signals,
            // The COMBINED list — native profiles included — so a spoken
            // native-app name still asserts to the mismatch ledger.
            profiles: applicationProfiles)
        // First writer wins; a racer that lost returns the stored choice so
        // every reader inside the turn sees one answer.
        providerSelection.withLock { memo in
            if memo == nil { memo = resolved }
        }
        return providerSelection.withLock { $0 } ?? resolved
    }

    /// The operation this turn executes for a Skill — the provider choice
    /// when one was made, else the statically selected binding.
    private func turnOperation(
        for runtime: AbilityRuntimeSkill,
        snapshot: AbilityRuntimeSnapshot
    ) -> String? {
        turnProviderSelection(snapshot: snapshot).operation(for: runtime.skill.id)
            ?? runtime.bindingOperation
    }

    /// `bindingOperation(forInvocation:)` with the turn's provider choice
    /// applied. Only the provider-neutral INVOCATION name is steered; an
    /// exact operation name stays exact — the model deliberately named a
    /// provider's own operation, and redirecting it would cross applications
    /// silently.
    private func turnBindingOperation(
        forInvocation name: String,
        snapshot: AbilityRuntimeSnapshot
    ) -> String {
        if let runtime = snapshot.skill(invocationName: name),
           runtime.reference.invocationName == name,
           let operation = turnProviderSelection(snapshot: snapshot)
               .operation(for: runtime.skill.id) {
            return operation
        }
        return snapshot.bindingOperation(forInvocation: name)
    }

    public var hasPendingSkillConfirmation: Bool {
        pendingStore.current() != nil
    }

    public var pendingSkillConfirmationID: UUID? {
        pendingStore.current()?.id
    }

    /// The stored preview, verbatim. `current()` already enforces the TTL and
    /// the turn window, so this can never hand back a stale question.
    public var pendingSkillConfirmationPreview: String? {
        pendingStore.current()?.preview
    }

    // MARK: - Matching a Skill invocation to a binding

    /// THE ONE MATCHER, and the one place the roster is searched. Exact against
    /// the WHOLE roster, then — only on a miss — fuzzy within the worlds this
    /// turn is allowed to reach.
    ///
    /// Resolution only identifies a local implementation. It grants no right
    /// to run: `dispatch` applies the frozen package Skill's availability and
    /// routing predicate after exact or fuzzy resolution and before preview or
    /// execution. This separation keeps adapter lookup reusable without
    /// allowing exact visibility to bypass Ability constraints.
    private func resolve(skillName: String) -> AttributedSkillBinding? {
        let query = turnBindingOperation(
            forInvocation: skillName, snapshot: abilitySnapshot).lowercased()
        if let memo = resolutions.withLock({ $0[query] }) {
            return memo.map { attributed[$0] }
        }
        let index = attributed.firstIndex { $0.binding.name == query }
            ?? fuzzyOrder().first { position in
                let name = attributed[position].binding.name
                // Bidirectional: models truncate ("time" → "speak_time") and
                // models pad ("read_documents" → "read_document").
                return name.contains(query) || query.contains(name)
            }
        // A MISS IS CACHED TOO, and the nesting is what says so: the outer
        // optional is "did this turn resolve `query` yet", the inner one is
        // "did anything answer to it". Storing a nil index rather than leaving
        // the key out is what stops a name no binding answers to from rebuilding
        // the pool on every one of the turn's three questions about it.
        resolutions.withLock { $0[query] = index }
        return index.map { attributed[$0] }
    }

    /// WHICH BINDINGS A FUZZY MATCH MAY REACH THIS TURN, and in what order —
    /// indices into `attributed`.
    ///
    /// THE FAILURE THIS FIXES, live: mid-Pages turn the model asked for a
    /// document read under a name nobody registered, and SCRIVENER's
    /// `read_document` answered it. The fallback matched the flat roster in
    /// REGISTRATION order (xcode, scrivener, typer, pages, …) with bidirectional
    /// containment, so `read_doc`, `document` and `read_documents` all reach
    /// `read_document` several positions before `pages_body` is even
    /// considered. Mary then reported on a manuscript the user was not
    /// looking at, in a turn whose every other part was about the Pages
    /// document in front of them. The focus hoist that would have prevented it
    /// existed already — in `schemas`, where it reorders the Skill projection list and
    /// writes to a local that dispatch never sees.
    ///
    /// So the pool drops the RIVAL WORKSPACE worlds and nothing else. The
    /// `hasEyes` three are the only worlds where "wrong world" means "wrong
    /// document"; everywhere else a mismatch costs a wasted call, not a wrong
    /// answer about the wrong text. EVERY EYELESS WORLD STAYS FUZZY-REACHABLE
    /// FROM EVERY TURN — calendar, reminders, mail, notes, music — which is
    /// `AmbientWorld`'s own doctrine ("eyes are an UPGRADE for workspace apps,
    /// never a precondition for acting") and must not regress here.
    ///
    /// NO LEAD, NO SCOPING, and the whole roster stands exactly as it does
    /// today. `focusProvider` answers nil for a CODING lead (`MaryRuntime`
    /// derives `leadOwner` only when the lead is writing) and nil when nothing
    /// is open — that gap is pre-existing and is not this method's to close;
    /// what matters is that the nil branch is today's behaviour byte for byte.
    /// The final guard mirrors `schemas`' hoist: a lead whose plugin is
    /// switched off owns no Skill bindings, so scoping to it would only take worlds
    /// away and give none back.
    /// WHICH PLACES THIS TURN'S ROSTER MAY SHOW — `fuzzyOrder`'s predicate,
    /// promoted to one shared judgement, and nil when no scoping applies (the
    /// nil branch is today's behaviour byte for byte).
    ///
    /// THE FAILURE THIS FIXES (live, in Pages): the hoist reorders and never
    /// removes, so on a Pages-led turn the model's schema list still carried
    /// `search_manuscript`, `textedit_text` and `textedit_windows` — four
    /// near-synonymous find-text-by-phrase verbs simultaneously in scope —
    /// and it reached for the rivals. Exposure is the temptation; this is
    /// where exposure obeys the same rule fuzzy resolution always has.
    ///
    /// `admitted` is what keeps capability total: the lead itself, every
    /// place the route classifier heard named (native worlds AND registered
    /// applications, via `namedPlaces`), the world of a referent the
    /// utterance resolved ("the sourdough note"), any watched world whose
    /// display name appears in the words, and Xcode whenever the words carry
    /// a coding cue — so "read my TextEdit note" from Pages re-admits
    /// TextEdit on exactly that turn. Eyeless places are never scoped, by
    /// `AmbientWorld`'s own doctrine. `route.candidateWorlds` is deliberately
    /// NOT consulted — its contract says it is never an execution allowlist.
    ///
    /// THE LEAD IS ONE VALUE NOW. A registered application like Sketch has
    /// no `AmbientWorld` case, but its being frontmost is exactly as strong
    /// a claim as a watched world's — its place is the lead, resolved
    /// through its registration. Before that arm existed it was the
    /// opposite: a nil world switched scoping OFF, every native workspace
    /// plugin stayed on the roster, and "move this image right" over a
    /// focused Sketch dispatched `keynote_slides` with Keynote not even
    /// running. The admissions ladder is identical either way.
    func placeScope() -> (lead: AmbientPlace, admitted: Set<AmbientPlace>)? {
        guard let owner = focusProvider?() else { return nil }
        // AN OWNER SCOPES ONLY WHEN THIS RUNTIME ACTUALLY KNOWS IT. An
        // unregistered owner proves nothing, and scoping on nothing would take
        // places away from the roster while giving none back.
        //
        // EITHER SOURCE OF KNOWING COUNTS. The ability snapshot proves a
        // package is admitted; the ambient ROSTER — built from that same
        // snapshot — proves the application exists and earned eyes, which is
        // strictly stronger. Requiring only the first denied scoping in any
        // process that had the roster and a leaner snapshot, which is every
        // process where the lead came from the focus tracker rather than from
        // a dispatch.
        let registration = applications.registration(id: owner)
        guard abilitySnapshot.plugins.applicationProfiles
            .contains(where: { $0.id == owner })
            || registration?.hasEyes == true
        else { return nil }
        let lead: AmbientPlace = registration?.place ?? .application(owner)
        var admitted: Set<AmbientPlace> = [lead]
        admitted.formUnion(admittedPlaceMentions())
        return (lead, admitted)
    }

    /// The places this turn's WORDS re-admit — `AmbientRanker`'s ONE
    /// mentions ladder, fed this dispatcher's own store. Shared by
    /// `placeScope()`, the native mismatch mirror in `dispatch`, AND the
    /// prompt's writing-fragment suppression (which used to hand-copy the
    /// rungs), so roster scoping, dispatch, and the fragments can never
    /// disagree about what the words re-admitted.
    func admittedPlaceMentions() -> Set<AmbientPlace> {
        AmbientRanker.admittedPlaceMentions(
            route: ambient.route(),
            referent: ambient.referent(),
            utterance: ambient.utterance())
    }

    /// True when this binding may appear on a turn scoped by `placeScope()`.
    /// Standalone bindings and eyeless places always pass — only a place
    /// with eyes is ever scoped OUT, because only there does "wrong place"
    /// mean "wrong document".
    private func admits(
        owner: String, scope: (lead: AmbientPlace, admitted: Set<AmbientPlace>)?
    ) -> Bool {
        guard let scope, let place = scopedPlace(owner: owner), place.hasEyes
        else { return true }
        return scope.admitted.contains(place)
    }

    /// An owner's place: native plugin owners through the enum bijection,
    /// registered applications through the roster. Nil for standalone
    /// bindings and owners nothing registered — which `admits` reads as
    /// "never scoped", today's behaviour for both.
    /// THE WORLD A BINDING OWNER SPEAKS FOR. Its own id, for every plugin that
    /// is a world; the world it declared, for an observation adapter serving
    /// one it is not named after. One reading, so a read's place, its Skill's
    /// world and its provider guard can never disagree about the same owner.
    /// The place a binding owner names.
    ///
    /// ONE LADDER: the roster, then the served map a package installed for
    /// itself. A compiled owner→world table used to answer first, which meant
    /// an owner the roster knew perfectly well got a compiled answer instead.
    private func place(ofOwner owner: String) -> AmbientPlace? {
        applications.registration(id: owner)?.place
            ?? servedWorlds[owner].map(AmbientPlace.lane)
    }

    private func scopedPlace(owner: String) -> AmbientPlace? {
        applications.registration(id: owner)?.place
    }

    private func fuzzyOrder() -> [Int] {
        let everything = Array(attributed.indices)
        guard let scope = placeScope() else { return everything }
        let eligible = everything.filter { index in
            // A standalone binding has no owner and no world; an eyeless place's
            // Skill bindings are reachable from everywhere, by doctrine.
            admits(owner: attributed[index].owner, scope: scope)
        }
        // The leading place first inside what remains — the same partition
        // `schemas` applies to the Skill list, for the same reason: what leads
        // the turn should be what a half-remembered name lands on. Hoisting
        // works uniformly on the lead place's owner: the native plugin owner,
        // or the dynamic application id.
        let owner = scope.lead.application ?? scope.lead.world.pluginOwner
        return eligible.filter { attributed[$0].owner == owner }
            + eligible.filter { attributed[$0].owner != owner }
    }

    public func isReadOnly(_ skillName: String) -> Bool {
        // Primitives can read OR mutate depending on their arguments — the name
        // alone can't tell, and their results (a calendar read, a git status)
        // are often worth recalling, so never suppress them. Only plugin `.read`
        // Skill bindings (read_lines, read_symbol, current_file, …) are pure queries.
        //
        // AND THAT LAST SENTENCE IS A CONTRACT, not a description — it was
        // false once and the cost was a loop. `search_web` was declared `.read`
        // while it activated a browser, navigated, and pressed a link, so the
        // continuation nudge (whose only question is this function) judged an
        // acting turn unfinished after the work had been done, and the model
        // re-ran the navigation. A binding that CHANGES anything is `.tweak`
        // or `.write`. If a skill needs to say "and the request is now
        // satisfied", that is `SkillOutcome.landed`, not this.
        let operation = abilitySnapshot.bindingOperation(forInvocation: skillName)
        switch operation {
        case Self.confirmSkillName, Self.cancelSkillName:
            return false
        default:
            return resolve(skillName: operation)?.binding.access == .read
        }
    }

    /// Whether one invocation is the screen look. The settle policy needs the
    /// distinction structurally: a look's summary IS the answer's content, so
    /// it must never settle silently the way a deposited machine receipt does.
    public func isLookSkill(_ skillName: String) -> Bool {
        abilitySnapshot.bindingOperation(forInvocation: skillName) == Self.lookSkillName
    }

    /// A COGNITIVE activation is instruction, not effect — it returns guidance
    /// for the model's next round and touches no application. The lane's
    /// continuation predicate needs this distinction: `compose_draft` ran,
    /// "something acted" read as true, and the turn terminated with the draft
    /// spoken into the void instead of typed into the named document.
    public func isNonEffectful(_ skillName: String) -> Bool {
        abilitySnapshot.skill(invocationName: skillName)?
            .skill.execution.kind == .cognitive
    }

    /// The binding's own `preparesSurface` declaration — a create/open/raise
    /// that staged a surface without delivering the asked-for work. See
    /// `SkillBinding.preparesSurface`.
    public func preparesSurface(_ skillName: String) -> Bool {
        let operation = abilitySnapshot.bindingOperation(forInvocation: skillName)
        return resolve(skillName: operation)?.binding.preparesSurface == true
    }

    /// WHICH WORLD a Skill the model called belongs to — the dispatcher is the
    /// only place that knows, and two callers need it for the same reason:
    ///
    /// - The ARCHIVE, so a `create_event` run while a Pages document happens
    ///   to lead is filed under Calendar rather than composed as "used on
    ///   <PagesDocument>" and dropped in the Pages group. The Skill's own world
    ///   is observed; the focused workspace is a coincidence of what the user
    ///   left open.
    /// - The SILENT-SETTLE gate, so "the pre-read already served this" is only
    ///   true when the lane's reads belong to the world the pre-read read.
    ///
    /// Nil for the primitives (`run_shell` / `run_applescript` drive whatever
    /// they address, which no static table can know) and for anything
    /// unmatched. Shares `resolve`'s memo with `dispatch` and `isReadOnly`, so
    /// all three answer about the binding that actually ran.
    /// The PLACE a Skill belongs to — `world(ofSkill:)`'s answer in the
    /// vocabulary that can also name a taught application, which has no
    /// `AmbientWorld` and would otherwise read as "belongs nowhere".
    public func place(ofSkill skillName: String) -> AmbientPlace? {
        let operation = abilitySnapshot.bindingOperation(forInvocation: skillName)
        switch operation {
        case Self.confirmSkillName, Self.cancelSkillName:
            return nil
        default:
            guard let owner = resolve(skillName: operation)?.owner, !owner.isEmpty
            else { return nil }
            return applications.registration(id: owner)?.place
        }
    }

    public func world(ofSkill skillName: String) -> AmbientWorld? {
        let operation = abilitySnapshot.bindingOperation(forInvocation: skillName)
        switch operation {
        case Self.confirmSkillName, Self.cancelSkillName:
            return nil
        default:
            guard let owner = resolve(skillName: operation)?.owner, !owner.isEmpty else { return nil }
            return place(ofOwner: owner)?.world
        }
    }

    /// The world's own declared targeted read — the call a `WorldVeto`
    /// redirect names. Same table fetch-first uses, so the redirect can never
    /// name a binding the world did not register.
    public func targetedReadInvocation(
        forWorld world: AmbientWorld
    ) -> (binding: String, parameter: String)? {
        targetedReads[world.pluginOwner]
    }

    /// FETCH-FIRST. Runs the leading world's targeted read for `phrase` and
    /// hands back the passage — bounds label and all, exactly as the model
    /// would have received it.
    ///
    /// Routed through `focusProvider` — the SAME single focus decision the
    /// prompt sections, the roster hoist and the deposit subject already come
    /// off — so the pre-read can never read a document the prompt isn't
    /// describing. A coding lead, or no lead at all, answers nil here, which
    /// is what makes a false-positive classification free.
    ///
    /// `ok: false` answers nil too: a failed read has nothing to say, and a
    /// script error dressed as a passage inside the authoritative live block
    /// would be worse than the silence it replaces.
    ///
    /// AND SO DOES A MISS. THE FAILURE THIS FIXES (confirmed against a live
    /// user session): a `find` miss is `ok: true` with a summary written for
    /// the MODEL — "…has no \"section 5\" in its body text… Read the whole
    /// document with pages_body and no target to check" — and this method's
    /// only gate was `ok`, so the miss was carried into the voice's live block
    /// under "I read this just now, for exactly what they asked about — it IS
    /// the authority for their question". The user heard Mary recite it:
    /// "I'm on it — let me pull up the full document to check for section 5."
    /// With `foundNothing` refused here, `readPassages` stays empty and the
    /// turn behaves exactly as it did before fetch-first existed: the
    /// window-framing rule makes her say the passage is outside what she can
    /// see and offer to look, which is the correct answer.
    public func readNamedPart(_ phrase: String) async -> String? {
        let wanted = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        // THE CONTAINER THE TURN NAMED FIRST, then the leading world.
        //
        // A COALESCE, NOT A REPLACEMENT — the whole safety argument. When the
        // referent is nil, which is every turn that names no container, this is
        // byte-for-byte the old expression including nil-for-a-coding-lead. Only
        // a turn that explicitly named a container in a non-leading world takes
        // the new branch, which is how "look at the sourdough note" gets a
        // fetch-first pre-read while coding without a coding turn gaining one.
        let owner = ambient.referent()?.place.memoryToken ?? focusProvider?()
        guard !wanted.isEmpty,
              let owner,
              let targeted = targetedReads[owner],
              skillBindings.contains(where: { $0.name == targeted.binding }),
              let arguments = try? JSONSerialization.data(
                withJSONObject: [targeted.parameter: wanted], options: [.sortedKeys]),
              let json = String(data: arguments, encoding: .utf8)
        else { return nil }
        let outcome = await dispatch(name: targeted.binding, argumentsJSON: json)
        guard outcome.ok, !outcome.foundNothing else { return nil }
        let summary = outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    /// THE PRE-LANE LOOK — `readNamedPart`'s sibling for sight. Runs the
    /// SAME `look_at_screen` binding the lane would (so the home: closure
    /// files the fact in the looked-at place, the glance stamps focus
    /// evidence, and the chips/log behave identically), and returns the
    /// summary VERBATIM — byte-identical to the filed fact, which is what
    /// lets `heldContext(suppressing:)` dedup it (one text, one claim).
    ///
    /// DECLINES when a world with its own eyes leads: exactly the workspace
    /// plugins declare `targetedRead`, and those worlds serve their own live
    /// sections — a Pages question is answered by the named-part read, not a
    /// screenshot. A browser playing a video, or no lead at all, falls
    /// through to the look. Nil on decline/refusal/miss — the turn proceeds
    /// lookless, exactly as before this existed.
    /// The decline predicate, separately callable: true when a pre-lane look
    /// WOULD run (no eyed world leads; the binding is installed). The turn
    /// loop asks this before promising a look, so `lookUnderway` can never
    /// claim a look that was declined.
    public func wouldServeLook() -> Bool {
        if let owner = focusProvider?(), targetedReads[owner] != nil { return false }
        return skillBindings.contains { $0.name == Self.lookSkillName }
    }

    public func lookAtScreen(_ query: String?) async -> String? {
        guard wouldServeLook() else { return nil }
        var arguments: [String: String] = [:]
        if let query, !query.isEmpty { arguments["query"] = query }
        guard let data = try? JSONSerialization.data(
                withJSONObject: arguments, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        let outcome = await dispatch(name: Self.lookSkillName, argumentsJSON: json)
        guard outcome.ok, !outcome.foundNothing else { return nil }
        let summary = outcome.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    // MARK: - Locating what a revision is about

    /// LOCATE, NOT READ. Resolve what the user called the part against whatever
    /// the LEADING world has open, mint a handle for it, and hand back the
    /// handle plus the verb that changes it.
    ///
    /// `readNamedPart`'s sibling in every structural respect — same
    /// `focusProvider` routing, same nil-on-nothing contract, same
    /// declared-by-the-plugin discipline — and its opposite in purpose. That
    /// one fetches TEXT TO SPEAK. This one produces A THING TO ACT ON, and it
    /// runs for the turns where speaking is not the answer:
    ///
    ///   "replace the Purpose section with the tighter version" → `type_at_cursor`,
    ///   the new prose at the caret, the Purpose section still standing. The
    ///   user: "intended for live writing behavior rather than revision
    ///   behavior."
    ///
    /// A paragraph of prompt telling her to prefer `replace_passage` is
    /// necessary and insufficient — this tree has replaced an ignored
    /// instruction with a mechanism three times now (`ActionClassifier`,
    /// `bareDecision`, `hasPendingSkillConfirmation`). The mechanism needs a fact, and the
    /// fact is a real handle in hand before the lane runs.
    ///
    /// NIL IS COMMON AND COSTS NOTHING: no lead, a world that composes but
    /// cannot revise, nothing open, nothing found. Every one of those returns
    /// nil, no gate fires, and the turn behaves exactly as it did before any of
    /// this existed. That is what makes a false-positive classification free.
    ///
    /// ONE LINE OF THIS FILE KNOWS `EditIntent`, deliberately: the intent's
    /// other fields (`shape`, `payload`, `anchor`, `destination`) describe the
    /// EDIT and belong to whatever performs it. Locating is a question about
    /// `target` alone.
    public func locatePassage(_ intent: EditIntent) async -> LocatedPassage? {
        await locatePassage(targets: intent.target, anaphoric: intent.isAnaphoric)
    }

    public func locatePassage(
        _ intent: EditIntent, worldHint: AmbientWorld?
    ) async -> LocatedPassage? {
        await locatePassage(
            targets: intent.target, anaphoric: intent.isAnaphoric,
            worldHint: worldHint)
    }

    /// THE LADDER, and it never stops to ask — "read wider, then decide alone"
    /// is the user's own fixed decision, so only the last rung gives up:
    ///
    ///   1. The first thing they called it, matched once and matched whole →
    ///      `widened: false`. Their words chose; we did not.
    ///   2. Several candidates → the one nearest where they are looking,
    ///      `widened: true`. That ranking is `PassageWidening`'s tie-break and
    ///      NOT a second one written here: rung ascending, overlap descending,
    ///      nearest the attention anchor, earliest, shortest — a total order,
    ///      adversarially verified, which is exactly why "which one did you
    ///      mean?" is unreachable.
    ///   3. A miss → the next phrase they might have meant, and the next. Each
    ///      is `widened: true`, because a second-choice phrase is our choice.
    ///   4. All of them miss → what they have SELECTED, or failing that the
    ///      block their attention is sitting in. Still a decision, still
    ///      widened, still reported.
    ///   5. Nothing at all → nil. No veto fires, she does what she would have
    ///      done, and the report says plainly she could not locate it.
    func locatePassage(
        targets: [String], anaphoric: Bool = false,
        worldHint: AmbientWorld? = nil, now: Date = Date()
    ) async -> LocatedPassage? {
        // THE SAME SINGLE FOCUS DECISION the prompt sections, the roster hoist,
        // the deposit subject and the pre-read all come off. A revision gate
        // aimed at a document the prompt is not describing would be worse than
        // no gate: it would redirect a caret write into a file the user is not
        // looking at.
        // A concrete current workspace still wins. When Mary itself has the
        // foreground, however, the focus arbiter may intentionally answer nil.
        // For an anaphoric revision only, the newest live passage Mary
        // minted is the missing source fact: it is exactly what “that” refers
        // to and already carries document identity, text and stable bounds.
        // This fallback is unavailable to named edits and expires with the
        // same bounded passage/read retention as the handle shown to the user.
        //
        // `worldHint` fills the same nil, one rung earlier: an accepted offer
        // carries the world the offered passage was discussed in, which is a
        // fact about the conversation rather than about any minted handle. It
        // never outranks a live focus — the single-decision doctrine stands.
        let recentAnaphoricPassage = anaphoric ? passages.live(at: now).first : nil
        let owner = focusProvider?() ?? worldHint?.pluginOwner
            ?? recentAnaphoricPassage?.place.memoryToken
        guard let owner,
              let verb = targetedEdits[owner],
              // Mirrors `readNamedPart`'s check that the declared binding is
              // really in the catalog — a world naming a verb nobody registered
              // would send the model to a Skill that answers "there is no
              // command called replace_passage".
              skillBindings.contains(where: { $0.name == verb.binding }),
              let backing = passageBackings[owner]
        else { return nil }

        // Everything above is a dictionary lookup, so a Scrivener turn — or any
        // of the fifteen worlds with no documents — costs nothing and reads no
        // body. THE BODY READ IS THE EXPENSIVE STEP (an osascript round trip on
        // every world that has one) and it happens once, here, shared by every
        // rung below.
        guard let snapshot = await backing.body() else { return nil }

        var wanted = targets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // RUNG 0a — WHAT THEY HAVE HIGHLIGHTED, ahead of the newest minted
        // handle. A live, route-admitted selection is what "it" means on THIS
        // turn; the paragraph handle a previous turn minted is what "it"
        // meant a turn ago. THE FAILURE THIS FIXES (live, in Pages): a
        // highlighted sentence, "what do you think of this part", then
        // "reword it and put it in" — the locate resolved the whole minted
        // paragraph and the model rewrote all of it; the highlight, exact
        // text in hand, never outranked the stale handle.
        //
        // `routedSelectionHandoff` on purpose: it reads through the turn's
        // task-local snapshot (the packet this turn claimed or re-admitted)
        // AND applies the route's own admission decision — the engine already
        // arbitrated whether this selection is the turn's referent, and this
        // rung reuses that decision rather than re-deriving it. `world:`
        // closes cross-world injection. The text joins as a TARGET, so the
        // rungs below re-find it verbatim in the current body and mint it as
        // a `.phrase` at exactly the highlight's bounds.
        if anaphoric,
           let handoff = ambient.routedSelectionHandoff(world: backing.place.world) {
            let selected = handoff.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty { wanted.append(selected) }
        }

        // RUNG 0 — "IT". An anaphoric revision ("reword it", "tighten that
        // paragraph") names nothing, so there is no phrase for the ladder to
        // match. What the user means is the passage Mary most recently
        // handed them, and the handle ledger already knows which one that is:
        // `live()` is sorted newest-minted first.
        //
        // It joins as a TARGET rather than short-circuiting the ladder, which
        // buys two things for free. The rungs below re-find that text in the
        // CURRENT body, so a passage that moved since it was minted is located
        // where it is now rather than where it was; and minting stays
        // idempotent by identity, so the handle the user was shown is the
        // handle the veto names.
        //
        // Scoped to the focused place: "it" cannot mean a paragraph in a
        // document nobody is looking at.
        if anaphoric,
           let recent = recentAnaphoricPassage ?? passages.live(at: now)
            .first(where: { $0.place == backing.place }) {
            wanted.append(recent.text)
        }

        // RUNGS 1–3. `PassageEditRunner.mint` is the ladder AND the minting the
        // five Skill bindings already use, so a passage located by the gate and one
        // located by `find_passage` are the same passage with the same handle —
        // minting is idempotent by identity, which is what lets the veto name a
        // handle the model can immediately spend.
        for (index, target) in wanted.enumerated() {
            guard case .found(let found) = await PassageEditRunner.mint(
                target: target, in: snapshot, backing: backing,
                registry: passages, ambient: ambient, now: now)
            else { continue }
            return LocatedPassage(
                passage: found.passage, label: found.label, verb: verb,
                widened: index > 0 || Self.chosenForThem(found))
        }

        // RUNG 4, then 5.
        return fallbackPassage(in: snapshot, backing: backing, verb: verb, now: now)
    }

    /// DID WE CHOOSE, OR DID THEIR OWN WORDS?
    ///
    /// False on exactly one shape: a single candidate, found by a rung that
    /// matched the target WHOLE. `PassageCandidate.overlap` is 1.0 on those
    /// three rungs by construction — verbatim, structural label, normalized —
    /// so "their words picked this" is arithmetic rather than a judgement call.
    ///
    /// Token overlap and widening both matched only PART of what they said, so
    /// both count as our decision however lonely the winner was. That matters
    /// downstream: `widened` is what earns the report its undo offer, and an
    /// unattended pick made from half a phrase is precisely the one a user
    /// needs offered back.
    static func chosenForThem(_ found: PassageEditRunner.Located) -> Bool {
        guard found.confidence == .exact, let rung = found.rung else { return true }
        switch rung {
        case .verbatim, .structural, .normalized: return false
        case .tokenOverlap, .widened:             return true
        }
    }

    /// RUNG 4 — nothing they named could be found, so fall back to where they
    /// ARE. Two sources and no third, in this order:
    ///
    ///   a. WHAT THEY HAVE SELECTED. A selection is an instruction: "replace
    ///      this" with a paragraph highlighted names that paragraph as surely
    ///      as saying its heading would.
    ///   b. THE BLOCK THEIR ATTENTION IS IN. `PassageAttention` locates it by
    ///      the WORDS of the ambient selection/viewport fact rather than by a
    ///      raw AX integer — an AX offset counts UTF-16 over a string that
    ///      includes headers and text boxes, `body text` offsets do neither,
    ///      and feeding one into the other resolved the viewport to the head of
    ///      the document on every tick (`ViewportProvenance.diverged`). Words
    ///      that are not in this body simply fail to locate, and rung 5 is the
    ///      honest consequence.
    ///
    /// Smallest enclosing BLOCK, never a phrase: widening exists so that a
    /// replacement begins where a paragraph begins.
    private func fallbackPassage(
        in snapshot: BodySnapshot,
        backing: PassageBacking,
        verb: (binding: String, parameter: String),
        now: Date
    ) -> LocatedPassage? {
        let units = backing.units(snapshot.text)

        // A current source-owned handoff keeps the full AX text. The ambient
        // fact is intentionally prompt-clipped, so it remains only a
        // compatibility fallback for older watcher selection writers.
        //
        // NOT `requiringWritingTarget: true`, which made this rung DEAD in
        // production: that flag demands `writingTarget == .selection`, while
        // this whole function runs only under `needsLocate`, which is
        // `writingTarget == .passage` — mutually exclusive by construction.
        // The route's admission (`admitsSelectionHandoff`) still applies.
        let selected = (ambient.routedSelectionHandoff(
            world: backing.place.world)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty,
           // FIRST occurrence, and that is not arbitrary: `PassageAttention`
           // locates its anchor with `range(of:)`, which is the same one. Two
           // spellings of "where the selection is" would be a coordinate
           // disagreement of exactly the kind this contract exists to end.
           let span = PassageWidening.occurrences(of: selected, in: snapshot.text).first {
            let unit = units.first { $0.range == span }
            return mintFallback(
                span: span, kind: unit?.kind ?? .window, label: unit?.label ?? "",
                note: "what you had selected",
                in: snapshot, backing: backing, verb: verb, now: now)
        }

        guard let anchor = PassageEditRunner
                .attention(for: backing.place, ambient: ambient)?
                .anchor(in: snapshot.text),
              let unit = units
                .filter(\.kind.isBlock)
                // An empty span at a unit's upper bound is OUTSIDE it —
                // `PassageUnit.contains`'s rule, and the reason a caret resting
                // at the end of a paragraph belongs to the seam rather than to
                // the paragraph it just left.
                .filter({ $0.contains(anchor..<anchor) })
                .min(by: { $0.length < $1.length })
        else { return nil }   // RUNG 5. Nothing to gate on; the turn is unchanged.

        return mintFallback(
            span: unit.range, kind: unit.kind, label: unit.label,
            note: "the part you're working in",
            in: snapshot, backing: backing, verb: verb, now: now)
    }

    /// `PassageRecipes.mintRead` — THE ONE PLACE A READ MINTS A HANDLE, reused
    /// rather than re-assembled here. Assembling a `PassageRegistry.mint` call
    /// locally is how a caller comes to hash the excerpt instead of the body,
    /// which produces a handle that resolves to the wrong prose rather than
    /// failing loudly.
    private func mintFallback(
        span: Range<Int>,
        kind: PassageUnitKind,
        label: String,
        note: String,
        in snapshot: BodySnapshot,
        backing: PassageBacking,
        verb: (binding: String, parameter: String),
        now: Date
    ) -> LocatedPassage? {
        guard let passage = PassageRecipes.mintRead(
            place: backing.place,
            documentKey: snapshot.documentKey,
            documentTitle: snapshot.documentTitle,
            body: snapshot.text,
            range: span,
            kind: kind,
            locatorNote: note,
            registry: passages,
            at: now)
        else { return nil }
        // ALWAYS WIDENED. We got here because nothing they said could be found,
        // so this is us choosing on their behalf by definition.
        return LocatedPassage(passage: passage, label: label, verb: verb, widened: true)
    }

    /// THE CHOKEPOINT. Every dispatch — the model's, a lane's deterministic
    /// press, a confirmation replay — passes through here, and exactly one
    /// `BehavioralActionRecord` is composed for each.
    ///
    /// A WRAPPER RATHER THAN A LINE INSIDE `dispatchCore`, because cognitive
    /// skills, blocked refusals and confirmation PARKS all return before
    /// `execute` is ever reached. Recording at the execution site would have
    /// caught only the acts that ran, and a dataset that omits every refusal
    /// teaches a model that its requests are always granted.
    ///
    /// THE REFERENCE PRECEDENCE IS THE POINT, and it is the defect this whole
    /// arrangement exists to kill:
    ///
    ///   1. `outcome.skillReference` — a confirmation replay carries the
    ///      reference FROZEN at park time, which is the binding the user
    ///      actually approved. Focus may have moved since; the roster would
    ///      now choose differently, and choosing differently is exactly what
    ///      must not happen to an act somebody already said yes to.
    ///   2. `skillReference(for:)` — the TURN-ACCURATE one, carrying this
    ///      turn's provider choice.
    ///
    /// What is never used is the static snapshot's reference. The ledger this
    /// replaces used it while the transcript chip used the turn-patched one,
    /// so the log and the chip printed different providers for the same act.
    /// There is one composition now, so there is one answer.
    /// WHERE A CALL'S TIME WENT — the gate chain against the work.
    ///
    /// Two lines per call, deliberately, because the interesting number is the
    /// difference. `dispatchCore` recomputes the ability snapshot, the routing
    /// context and the whole roster arbitration before any adapter is touched;
    /// `performExecute` is the adapter actually doing something. A call that
    /// spends most of its time in the first is a Mary problem, and one that
    /// spends it in the second is the target application being slow — and
    /// until now the two were one opaque duration.
    static let timingLog = Logger(subsystem: "nyc.rao.mary", category: "lanes")

    public func dispatch(
        name: String, argumentsJSON: String, runID: String? = nil
    ) async -> SkillOutcome {
        let startedAt = Date()
        let dispatchStart = DispatchTime.now()
        // READ BEFORE THE DISPATCH. `skillReference(for:)` consults the turn's
        // provider selection, and a dispatch can change it — reading after
        // would describe the act with the state it left behind.
        let turnReference = skillReference(for: name)
        let confirmationID = pendingStore.current()?.id

        // ONE IDENTITY FOR THE WHOLE ACT — the caller's wire id when it has
        // one, so the chip, the ledger row, the episode entry and the Stop
        // button are all talking about the same call.
        let identity = runID ?? UUID().uuidString
        let outcome = await RunContext.$runID.withValue(identity) {
            await dispatchCore(name: name, argumentsJSON: argumentsJSON)
        }

        let record = BehavioralActionRecord(
            outcome: outcome,
            intention: name,
            argumentsJSON: Self.canonicalArguments(argumentsJSON),
            reference: turnReference,
            runID: identity,
            // THE CONFIRMATION THREAD. A park and its later replay are two
            // episodes and one act; this is the string that joins them. Read
            // BEFORE for a park (the question is being asked now) and AFTER
            // for a replay (the pending store has just been emptied), which
            // is why both are consulted.
            confirmationID: confirmationID ?? pendingStore.current()?.id,
            startedAt: startedAt)
        executionLog.record(record)
        behavior?.append(record)
        let totalMs = (DispatchTime.now().uptimeNanoseconds
            &- dispatchStart.uptimeNanoseconds) / 1_000_000
        let line = "dispatch \(name) — total \(totalMs)ms,"
            + " status=\(record.disposition)"
        Self.timingLog.info("\(line, privacy: .public)")
        return outcome
    }

    private func dispatchCore(name: String, argumentsJSON: String) async -> SkillOutcome {
        let snapshot = abilitySnapshot
        let routing = abilityRoutingContext()
        let roster = rosterArbitration(snapshot: snapshot, context: routing)
        let operation = turnBindingOperation(forInvocation: name, snapshot: snapshot)
        let invokedRuntimeSkill = snapshot.skill(invocationName: name)
        // AN EXACT NAME MAY STAY EXACT WITHOUT CROSSING APPLICATIONS. Rival
        // provider operations are indexed to their owning neutral Skill so a
        // stale model call still receives routing and offer checks, but that
        // must not let the exact rival bypass the provider choice frozen from
        // this turn's named/interaction/focus signals. Never redirect it to
        // the selected operation: abstain before either provider executes.
        if operation != Self.confirmSkillName,
           operation != Self.cancelSkillName,
           let invokedRuntimeSkill,
           invokedRuntimeSkill.reference.invocationName != name,
           let exactBinding = snapshot.compatibleBindings(
               for: invokedRuntimeSkill.skill.id).first(where: {
                   $0.operation == name
               }),
           let exactApplicationID = snapshot.applicationID(
               of: invokedRuntimeSkill,
               binding: exactBinding)?.lowercased() {
            let providerSelection = turnProviderSelection(snapshot: snapshot)
            let frozenApplicationID = providerSelection.choice(
                for: invokedRuntimeSkill.skill.id)?
                .provider?.applicationID?.lowercased()
            // When one signal rung is ambiguous, a lower rung may freeze the
            // provider choice. An exact call may agree with that winner; it
            // may not select the other provider from the ambiguous rung.
            let admittedApplicationIDs: Set<String> = frozenApplicationID.map {
                [$0]
            } ?? providerSelection.decisiveApplicationIDs
            if !admittedApplicationIDs.isEmpty,
               !admittedApplicationIDs.contains(exactApplicationID) {
                let profiles = applicationProfiles
                let exactTitle = profiles.first {
                    $0.id.lowercased() == exactApplicationID
                }?.title ?? exactApplicationID
                let admittedTitles = admittedApplicationIDs.map { admitted in
                    profiles.first { $0.id.lowercased() == admitted }?.title
                        ?? admitted
                }.sorted()
                return blockedOutcome(
                    runtime: invokedRuntimeSkill,
                    reason: "the exact \(exactTitle) provider contradicts this turn's frozen application choice (\(admittedTitles.joined(separator: " or "))); use \(invokedRuntimeSkill.reference.invocationName) so the frozen provider can execute")
            }
        }
        // THE MISMATCH ABSTAIN. Only the provider-neutral invocation is
        // guarded, mirroring `turnBindingOperation`'s doctrine: an exact
        // operation name is the model deliberately naming a provider and
        // stays total. The blocked outcome is an escape hatch, not a
        // scolding — it names the app that can serve so the next call
        // lands. (The chip may still print the static provider for a
        // mismatched skill; this block corrects the record before anything
        // runs.)
        if operation != Self.confirmSkillName,
           operation != Self.cancelSkillName,
           let invokedRuntimeSkill,
           invokedRuntimeSkill.reference.invocationName == name,
           let mismatch = turnProviderSelection(snapshot: snapshot).mismatch(
               for: invokedRuntimeSkill.skill.id) {
            let escape: String
            if let available = mismatch.availableTitles.first {
                escape = "\(mismatch.availableTitles.joined(separator: " or ")) can — say 'in \(available)' or switch to it to make this change there"
            } else {
                escape = "no installed application currently can"
            }
            return blockedOutcome(
                runtime: invokedRuntimeSkill,
                reason: "\(mismatch.wantedTitle) can't do this yet; \(escape)")
        }
        // HARD FACTS FIRST, then the offer ledger. "Mary needs Accessibility
        // permission" is a more actionable sentence than "wasn't offered", and
        // when both are true the user should hear the one they can act on.
        if operation != Self.confirmSkillName,
           operation != Self.cancelSkillName,
           let invokedRuntimeSkill,
           let reason = dispatchEligibilityFailure(
               for: invokedRuntimeSkill,
               in: routing,
               snapshot: snapshot) {
            return blockedOutcome(runtime: invokedRuntimeSkill, reason: reason)
        }
        if operation != Self.confirmSkillName,
           operation != Self.cancelSkillName,
           let invokedRuntimeSkill,
           let reason = offerLedgerFailure(
               for: invokedRuntimeSkill,
               roster: roster) {
            return blockedOutcome(runtime: invokedRuntimeSkill, reason: reason)
        }
        // Built-ins match exactly, before anything else can eat them.
        switch operation {
        case Self.confirmSkillName:
            return await executePending()
        case Self.cancelSkillName:
            let reference = pendingStore.current()?.reference
                ?? snapshot.reference(forInvocation: Self.cancelSkillName)
            pendingStore.clear()
            // Nothing happened, so there is nothing to recall. Archiving it
            // minted a Totem document whose whole content was "nothing was
            // changed" — retrievable forever, useful never. `.none` is the
            // binding making that call itself, the way `deferred` already
            // does for acks.
            return SkillOutcome(
                ok: true, summary: "Okay, cancelled — nothing was changed.",
                status: .cancelled,
                archivePolicy: .none,
                skillReference: reference)
        default:
            break
        }

        // Schema-executed Skills have no direct Plugin binding. They are
        // dispatched only after the same eligibility check above and through
        // the frozen turn snapshot captured before the invocation arrived.
        if let invokedRuntimeSkill {
            let arguments = Self.stringArguments(fromJSON: argumentsJSON)
            let policy = snapshot.executionPolicy(for: invokedRuntimeSkill.skill)
            let signals = routedSignalSnapshot()
            if let failure = payloadFailure(
                runtime: invokedRuntimeSkill,
                arguments: arguments,
                typedInputs: [:],
                signals: signals,
                policy: policy) {
                return failure
            }
            switch invokedRuntimeSkill.skill.execution.kind {
            case .cognitive:
                let outcome = executeCognitive(
                    runtime: invokedRuntimeSkill,
                    arguments: arguments,
                    snapshot: snapshot,
                    signals: signals)
                return Self.applyingTotemArchivePolicy(
                    outcome,
                    reference: invokedRuntimeSkill.reference,
                    snapshot: snapshot)
            case .stateMachine:
                let outcome = await executeWorkflow(
                    runtime: invokedRuntimeSkill,
                    arguments: arguments,
                    snapshot: snapshot,
                    context: executionContext(),
                    signals: signals)
                return Self.applyingTotemArchivePolicy(
                    outcome,
                    reference: invokedRuntimeSkill.reference,
                    snapshot: snapshot)
            case .binding:
                break
            }
        }

        // Recipes: exact name, else fuzzy within the worlds this turn may
        // reach — one matcher, memoized for the turn. See `resolve`.
        guard var binding = resolve(skillName: operation)?.binding else {
            return SkillOutcome(ok: false, summary: "There is no command called \(name).")
        }
        let runtimeSkill = invokedRuntimeSkill
            ?? snapshot.skill(bindingOperation: binding.name)
        // The same two gates as above, for the Skill reached by exact binding
        // operation or by the fuzzy matcher rather than by invocation name.
        if let runtimeSkill,
           let reason = dispatchEligibilityFailure(
               for: runtimeSkill,
               in: routing,
               snapshot: snapshot)
               ?? offerLedgerFailure(for: runtimeSkill, roster: roster) {
            return blockedOutcome(runtime: runtimeSkill, reason: reason)
        }
        if let schemaSkill = runtimeSkill?.skill {
            // Portable policy may make a local operation stricter, never less
            // strict. The adapter's own declaration remains the hard floor.
            if schemaSkill.access == .confirm { binding.access = .write }
            binding.stage = binding.stage || schemaSkill.usesStage
        }
        let reference = runtimeSkill?.reference
            ?? snapshot.reference(forInvocation: binding.name)

        // THE MISMATCH LEDGER'S NATIVE MIRROR. Dynamic skills abstain when
        // every asserted application is one they cannot serve; native
        // bindings used to be exempt (they never enter `snapshot.skills`),
        // which is how `keynote_slides` ran a Sketch-led design turn with
        // Keynote not even open. The strongest signal rung governs, so an
        // unrelated focused app cannot rescue a binding after the person
        // named another destination; ambiguity within that rung remains
        // conservative. No signals at all is static behavior. Confined to
        // watched workspace worlds — calendar and every eyeless data source stay
        // reachable from anywhere, the eyes-are-an-upgrade doctrine intact.
        // This amends "capability is scoped in temptation only" for the
        // asserted-disjoint case: the blocked outcome names both sides and
        // the words to say, never silence.
        if runtimeSkill == nil,
           let owner = resolve(skillName: operation)?.owner,
           let ownerPlace = place(ofOwner: owner), ownerPlace.hasEyes {
            let asserted = turnProviderSelection(snapshot: snapshot)
                .decisiveApplicationIDs
            if !asserted.isEmpty, !asserted.contains(owner),
               !admittedPlaceMentions().contains(ownerPlace) {
                let profiles = nativeProfiles
                    + snapshot.plugins.applicationProfiles
                let wanted = profiles.first { asserted.contains($0.id) }?.title
                    ?? asserted.sorted()[0]
                return SkillOutcome(
                    ok: false,
                    summary: "\(ownerPlace.displayName) isn't the application this turn is about — \(wanted) is. Say 'in \(ownerPlace.displayName)' or switch to it to make this change there.",
                    status: .blocked,
                    archivePolicy: .none,
                    skillReference: reference)
            }
        }

        var arguments = Self.stringArguments(fromJSON: argumentsJSON)
        arguments = Self.reconcile(arguments, against: binding.parameters)
        // `type_at_cursor` serves both ordinary composition and exact
        // selection replacement, so its package requirement is necessarily
        // conditional. Enforce that machine branch here, at the last common
        // boundary before either adapter or confirmation can observe it. A
        // diagnostic/rejected handoff can never be re-read to authorize keys.
        if binding.name == "type_at_cursor",
           arguments["mode"] == "replace_selection",
           ambient.routedSelectionHandoff(
               requiringWritingTarget: true) == nil {
            return SkillOutcome(
                ok: false,
                summary: "That selection is not the routed writing target for this request, so I did not replace it.",
                status: .blocked,
                archivePolicy: .none,
                skillReference: reference)
        }
        let context = executionContext()
        let policy = runtimeSkill.map { snapshot.executionPolicy(for: $0.skill) }
            ?? .unconstrained
        let signals = routedSignalSnapshot()
        if let runtimeSkill,
           let failure = payloadFailure(
               runtime: runtimeSkill,
               arguments: arguments,
               typedInputs: [:],
               signals: signals,
               policy: policy) {
            return failure
        }

        if binding.access == .write {
            let preview = await previewQuestion(
                binding: binding, arguments: arguments, context: context)
            var deferredContext = context
            if deferredContext.surfaceReferent == .previouslyCreatedSurface {
                deferredContext.surfaceReferent =
                    .previouslyCreatedSurfaceUnavailable
            }
            pendingStore.set(
                skillName: binding.name,
                arguments: arguments,
                preview: preview,
                binding: binding,
                context: deferredContext,
                reference: reference,
                executionPolicy: policy,
                signalSnapshot: signals)
            return SkillOutcome(
                ok: true,
                // The question alone. The "nothing has happened yet" doctrine
                // is system-prompt guidance, and welding it into a tool result
                // put it on the data channel — where the relay spoke it.
                summary: "CONFIRM: \(preview)",
                status: .requested,
                archivePolicy: .none,
                skillReference: reference
            )
        }

        return await execute(
            binding: binding,
            arguments: arguments,
            context: context,
            reference: reference,
            runtime: runtimeSkill,
            policy: policy,
            signals: signals)
    }

    // MARK: - Cognitive and workflow execution

    /// Cognitive primitives and schema state machines intentionally keep
    /// their internal steps out of memory. Once the top-level Skill settles,
    /// however, a selected durable projection is its explicit authorization
    /// to archive. This turns Architect's capture workflow into a real
    /// idea-board write without teaching individual primitives about Totem.
    static func applyingTotemArchivePolicy(
        _ input: SkillOutcome,
        reference: AbilitySkillReference,
        snapshot: AbilityRuntimeSnapshot
    ) -> SkillOutcome {
        guard input.archivePolicy == .none,
              input.status == .succeeded || input.status == .failed,
              snapshot.totemProjectionPlan(for: reference)?.permitsDurableStorage == true
        else { return input }
        var output = input
        output.archivePolicy = .episodic
        return output
    }

    private func executeCognitive(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        snapshot: AbilityRuntimeSnapshot,
        typedInputs: [String: ValueEnvelope] = [:],
        signals: SchemaSignalTurnSnapshot
    ) -> SkillOutcome {
        let policy = snapshot.executionPolicy(for: runtime.skill)
        if let failure = payloadFailure(
            runtime: runtime,
            arguments: arguments,
            typedInputs: typedInputs,
            signals: signals,
            policy: policy) {
            return failure
        }
        guard let contract = CognitivePrimitiveCatalog.contract(for: runtime) else {
            return blockedOutcome(
                runtime: runtime,
                reason: "no closed Mary cognitive primitive is registered")
        }
        if let missing = CognitivePrimitiveCatalog.missingRequiredArgument(
            for: contract,
            arguments: arguments) {
            return SkillOutcome(
                ok: false,
                summary: "\(runtime.reference.displayLabel) needs \(missing).",
                status: .blocked,
                archivePolicy: .none,
                skillReference: runtime.reference)
        }
        var summary = CognitivePrimitiveCatalog.activate(
            contract,
            arguments: arguments)
        // compose_draft's delivery target, named concretely when the turn
        // knows one: a surface just staged for this work, else a writing
        // world the utterance named. One clause, one function — the focus
        // layer can re-source it without touching the activation text.
        if contract.primitive == .composeDraft {
            let staged = StagedWritingSurface.shared.fresh()
            // A NAMED PLACE THAT WRITES. The version this replaces filtered
            // the turn's named worlds against a compiled list of editors, so
            // naming any other application produced nothing at all.
            let namedWriting = ambient.route()?.namedPlaces
                .first(where: { $0.focus == .writing })
            if let clause = CognitivePrimitiveCatalog.composePlacementClause(
                stagedApplicationName: staged.map { $0.spokenName ?? $0.bundleID },
                namedWritingApplication: namedWriting?.displayName) {
                summary += clause
            }
        } else if contract.primitive == .reviseSelection {
            // revise_selection's mirror of the seam above: no surface to
            // name, only whether the turn's routed selection is still there
            // to write back into. Same predicate `type_at_cursor(mode:
            // "replace_selection")` itself checks at dispatch, so the clause
            // is never a promise dispatch would go on to refuse.
            if let clause = CognitivePrimitiveCatalog.revisionPlacementClause(
                hasRoutedSelection: ambient.routedSelectionHandoff(
                    requiringWritingTarget: true) != nil) {
                summary += clause
            }
        }
        var typedOutputs: [String: ValueEnvelope] = [:]
        for output in runtime.skill.outputs {
            guard let schema = snapshot.valueTypeSchema(id: output.valueType),
                  schema.shape == .string
            else { continue }
            typedOutputs[output.name] = ValueEnvelope(
                    typeID: output.valueType,
                    schemaVersion: schema.version,
                    value: .string(summary),
                    provenance: .init(operation: runtime.reference.invocationName),
                    privacy: .private)
        }
        let outcome = enforceOutputPayload(
            SkillOutcome(
            ok: true,
            summary: summary,
            archivePolicy: .none,
            skillReference: runtime.reference,
            typedOutputs: typedOutputs),
            runtime: runtime,
            policy: policy)
        recordSchemaExecution(
            runtime: runtime,
            arguments: arguments,
            outcome: outcome)
        return outcome
    }

    private func executeWorkflow(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        snapshot: AbilityRuntimeSnapshot,
        context: AbilityExecutionContext,
        signals: SchemaSignalTurnSnapshot,
        depth: Int = 0
    ) async -> SkillOutcome {
        guard depth < 8 else {
            return blockedOutcome(
                runtime: runtime,
                reason: "the nested workflow depth exceeded Mary's bound")
        }
        if let reason = workflowExecutionSafetyFailure(
            for: runtime,
            snapshot: snapshot) {
            return blockedOutcome(runtime: runtime, reason: reason)
        }
        let policy = snapshot.executionPolicy(for: runtime.skill)
        if let failure = payloadFailure(
            runtime: runtime,
            arguments: arguments,
            typedInputs: [:],
            signals: signals,
            policy: policy) {
            return failure
        }

        // Packages may ask for a shorter budget but may not enlarge Mary's
        // ten-minute ceiling. The default accommodates a real Xcode build;
        // every nested adapter retains its own tighter deadline as well.
        let budget = min(
            min(runtime.skill.timeoutSeconds ?? 600, 600),
            policy.maximumDurationSeconds ?? 600)
        let supplementalPorts = workflowSupplementalPorts(
            for: runtime,
            arguments: arguments,
            snapshot: snapshot)
        let worker = Task { [self] in
            await WorkflowStateMachine.run(
                skill: runtime.skill,
                arguments: arguments,
                supplementalPorts: supplementalPorts) { step, ports, originalArguments in
                    await self.executeWorkflowStep(
                        step,
                        owner: runtime,
                        ports: ports,
                        originalArguments: originalArguments,
                        snapshot: snapshot,
                        context: context,
                        signals: signals,
                        depth: depth)
                }
        }
        let runIdentity = registerInFlight { worker.cancel() }
        defer { releaseInFlight(runIdentity) }
        let result = await withTaskCancellationHandler {
            await bounded(budget) { await worker.value }
        } onCancel: {
            worker.cancel()
        }
        worker.cancel()
        // Same rule as `performExecute`: a stop the person asked for is what
        // the record says happened, whatever the machine got as far as.
        if wasStopRequested(runIdentity) {
            let stopped = SkillOutcome(
                ok: false,
                summary: "You stopped \(runtime.reference.invocationName).",
                status: .cancelled,
                archivePolicy: .none,
                skillReference: runtime.reference)
            recordSchemaExecution(
                runtime: runtime, arguments: arguments, outcome: stopped)
            return stopped
        }

        guard let machineResult = result else {
            let timedOut = SkillOutcome(
                ok: false,
                summary: "\(runtime.reference.displayLabel) did not finish within \(Int(budget)) seconds.",
                status: .failed,
                archivePolicy: .none,
                skillReference: runtime.reference)
            recordSchemaExecution(
                runtime: runtime,
                arguments: arguments,
                outcome: timedOut)
            return timedOut
        }
        var outcome = machineResult.outcome
        outcome.skillReference = runtime.reference
        for output in runtime.skill.outputs {
            if let envelope = machineResult.ports[output.name]?.envelope {
                outcome.typedOutputs[output.name] = envelope
            }
        }
        if outcome.status == .deferred || outcome.status == .requested {
            outcome.archivePolicy = .none
        }
        outcome = enforceOutputPayload(
            outcome,
            runtime: runtime,
            policy: policy)
        recordSchemaExecution(
            runtime: runtime,
            arguments: arguments,
            outcome: outcome)
        return outcome
    }

    private func executeWorkflowStep(
        _ step: WorkflowStepSchema,
        owner: AbilityRuntimeSkill,
        ports: [String: WorkflowPortValue],
        originalArguments: [String: String],
        snapshot: AbilityRuntimeSnapshot,
        context: AbilityExecutionContext,
        signals: SchemaSignalTurnSnapshot,
        depth: Int
    ) async -> WorkflowOperationResult {
        if let target = snapshot.skill(invocationName: step.operation) {
            // A validated workflow is already an exact machine route. Its
            // internal steps retain every base safety check, but do not re-run
            // top-level model-roster conflicts (which could hide two distinct
            // steps in the same group and make the workflow self-contradict).
            //
            // Nor do they re-run ROUTING: a workflow step was not chosen by
            // what the user said, so asking whether the utterance still matches
            // its Ability's routing policy is asking a question about a
            // decision nobody made this turn. The safety checks below are all
            // physical.
            if let reason = dispatchEligibilityFailure(
                for: target,
                in: abilityRoutingContext(),
                snapshot: snapshot) {
                return WorkflowOperationResult(outcome: blockedOutcome(
                    runtime: target,
                    reason: reason))
            }
            let arguments = workflowArguments(
                for: target,
                step: step,
                ports: ports,
                originalArguments: originalArguments)
            switch target.skill.execution.kind {
            case .cognitive:
                let outcome = executeCognitive(
                    runtime: target,
                    arguments: arguments,
                    snapshot: snapshot,
                    typedInputs: Dictionary(
                        uniqueKeysWithValues: step.consumes.compactMap { name in
                            ports[name]?.envelope.map { (name, $0) }
                        }),
                    signals: signals)
                return WorkflowOperationResult(
                    outcome: outcome,
                    outputTypes: target.skill.outputs.map(\.valueType),
                    outputEnvelopes: target.skill.outputs.map {
                        outcome.typedOutputs[$0.name]
                    })
            case .stateMachine:
                let outcome = await executeWorkflow(
                    runtime: target,
                    arguments: arguments,
                    snapshot: snapshot,
                    context: context,
                    signals: signals,
                    depth: depth + 1)
                return WorkflowOperationResult(
                    outcome: outcome,
                    outputTypes: target.skill.outputs.map(\.valueType),
                    outputEnvelopes: target.skill.outputs.map {
                        outcome.typedOutputs[$0.name]
                    })
            case .binding:
                guard let operation = target.bindingOperation,
                      var binding = attributed.first(where: {
                          $0.binding.name == operation
                      })?.binding
                else {
                    return WorkflowOperationResult(outcome: blockedOutcome(
                        runtime: target,
                        reason: "its exact adapter implementation disappeared"))
                }
                if target.skill.access == .confirm { binding.access = .write }
                binding.stage = binding.stage || target.skill.usesStage
                guard binding.access != .write else {
                    return WorkflowOperationResult(outcome: blockedOutcome(
                        runtime: target,
                        reason: "a workflow cannot cross a user-confirmation boundary without a declared continuation"))
                }
                let reconciled = Self.reconcile(
                    arguments,
                    against: binding.parameters)
                let typedInputs = Dictionary(
                    uniqueKeysWithValues: step.consumes.compactMap { name in
                        ports[name]?.envelope.map { (name, $0) }
                    })
                let outcome = await execute(
                    binding: binding,
                    arguments: reconciled,
                    typedInputs: typedInputs,
                    context: context,
                    reference: target.reference,
                    runtime: target,
                    policy: snapshot.executionPolicy(for: target.skill),
                    signals: signals)
                return WorkflowOperationResult(
                    outcome: outcome,
                    outputTypes: target.skill.outputs.map(\.valueType),
                    outputEnvelopes: target.skill.outputs.map {
                        outcome.typedOutputs[$0.name]
                    })
            }
        }

        guard let contract = CognitivePrimitiveCatalog.contract(
            workflowOperation: step.operation,
            abilityID: owner.ability.id)
        else {
            return WorkflowOperationResult(outcome: SkillOutcome(
                ok: false,
                summary: "Workflow step \(step.id) has no executable operation.",
                status: .blocked,
                archivePolicy: .none,
                skillReference: owner.reference))
        }
        let arguments = workflowArguments(
            for: nil,
            step: step,
            ports: ports,
            originalArguments: originalArguments)
        return WorkflowOperationResult(outcome: SkillOutcome(
            ok: true,
            summary: activateWorkflowPrimitive(
                contract,
                arguments: arguments),
            archivePolicy: .none,
            skillReference: owner.reference))
    }

    private func activateWorkflowPrimitive(
        _ contract: CognitivePrimitiveContract,
        arguments: [String: String]
    ) -> String {
        switch contract.primitive {
        case .retrieveProjectContext:
            return renderProjectFacts(
                arguments: arguments,
                retainedOnly: false)
        case .searchProjectKnowledge:
            return renderProjectFacts(
                arguments: arguments,
                retainedOnly: true)
        default:
            return CognitivePrimitiveCatalog.activate(
                contract,
                arguments: arguments)
        }
    }

    /// Concrete Architect retrieval over Mary's source-attributed ambient
    /// ledger. This is intentionally not described as Totem search: durable
    /// rationale reaches Totem through the receipt projection, while this
    /// primitive searches only facts the current Mary runtime actually
    /// holds and can attribute.
    private func renderProjectFacts(
        arguments: [String: String],
        retainedOnly: Bool
    ) -> String {
        let project = Self.projectName(in: arguments)?.lowercased()
        let requestTokens = Set(
            (arguments["request"] ?? arguments["question"] ?? "")
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count > 2 }
                .map(String.init))
        // Architect is an Ability execution path, so it must obey the same
        // immutable route as prompt assembly. In particular, a Pages
        // selection rejected because the user explicitly named Xcode cannot
        // re-enter through project-context retrieval a few milliseconds later.
        let routedFacts = ambient.route().map { route in
            ambient.facts().filter(route.admitsHeldFact)
        } ?? ambient.facts()
        let candidates = routedFacts.filter { fact in
            if retainedOnly && fact.registration != .askedFor
                && !fact.slot.isRead
                && fact.slot != .project
                && fact.slot != .git {
                return false
            }
            if let project {
                let identity = [fact.subject, fact.content]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")
                guard identity.contains(project) else { return false }
            }
            guard retainedOnly, !requestTokens.isEmpty else { return true }
            let searchable = "\(fact.subject ?? "") \(fact.content)".lowercased()
            let words = Set(searchable
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init))
            return !words.isDisjoint(with: requestTokens)
        }
        let selected = candidates
            .sorted { left, right in left.capturedAt > right.capturedAt }
            .prefix(8)
        guard !selected.isEmpty else {
            return retainedOnly
                ? "No matching source-attributed project knowledge is currently held."
                : "No source-attributed live context is currently held for that project."
        }
        return selected.map { fact in
            let subject = fact.subject.map { " · \($0)" } ?? ""
            let content = String(fact.content.prefix(700))
            return "\(fact.world.rawValue)/\(fact.slot.token)\(subject): \(content)"
        }.joined(separator: "\n")
    }

    private static func projectName(in arguments: [String: String]) -> String? {
        if let explicit = arguments["project"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        for key in ["scope", "interaction.project-reference", "request"] {
            guard let text = arguments[key],
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let project = object["project"] as? String,
                  !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return project
        }
        return nil
    }

    /// Adapts the typed workflow ledger onto today's string-dictionary Plugin
    /// seam. Exact names win; then matching Value types; finally positional
    /// mapping supplies the one-input legacy bindings. No port loses its type
    /// inside the machine even though the final adapter transport is a string.
    private func workflowArguments(
        for target: AbilityRuntimeSkill?,
        step: WorkflowStepSchema,
        ports: [String: WorkflowPortValue],
        originalArguments: [String: String]
    ) -> [String: String] {
        var result = originalArguments
        let consumed = step.consumes.compactMap { name in
            ports[name].map { (name, $0) }
        }
        for (name, port) in consumed { result[name] = port.value }
        guard let target else { return result }

        for (index, input) in target.skill.inputs.enumerated()
        where result[input.name] == nil {
            let typed = consumed.first { $0.1.valueType == input.valueType }
            let positional = index < consumed.count ? consumed[index] : nil
            if let source = typed ?? positional {
                result[input.name] = source.1.value
            }
        }

        for (index, parameter) in target.skill.modelExposure.parameters.enumerated()
        where result[parameter.name] == nil {
            if target.skill.inputs.count == 1,
               let input = target.skill.inputs.first,
               let value = result[input.name] {
                result[parameter.name] = value
            } else if index < consumed.count {
                result[parameter.name] = consumed[index].1.value
            }
        }
        return result
    }

    private func workflowSupplementalPorts(
        for runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        snapshot: AbilityRuntimeSnapshot
    ) -> [String: WorkflowPortValue] {
        var ports: [String: WorkflowPortValue] = [:]
        let signals = routedSignalSnapshot()
        for interaction in signals.interactions(declaredBy: runtime.skill) {
            ports[interaction.reference.schemaID.rawValue] = WorkflowPortValue(
                value: Self.legacyString(interaction.value.value),
                valueType: interaction.value.typeID,
                envelope: interaction.value,
                producerStepID: nil)
        }
        for interactionID in runtime.skill.requirements.optionalInteractions
        where ports[interactionID.rawValue] == nil {
            guard let interaction = snapshot.interactionSchema(id: interactionID),
                  let valueSchema = snapshot.valueTypeSchema(id: interaction.valueType),
                  let envelope = Self.structuredEnvelope(
                      arguments: arguments,
                      schema: valueSchema,
                      registry: snapshot.valueTypeSchemas,
                      operation: runtime.reference.invocationName,
                      interactionID: interactionID)
            else { continue }
            ports[interactionID.rawValue] = WorkflowPortValue(
                value: Self.legacyString(envelope.value),
                valueType: envelope.typeID,
                envelope: envelope,
                producerStepID: nil)
        }
        for perceptionID in runtime.skill.requirements.perceptions
            + runtime.skill.requirements.optionalPerceptions {
            guard let perception = signals.perceptions.first(where: {
                $0.reference.schemaID == perceptionID
            }) else { continue }
            ports[perceptionID.rawValue] = WorkflowPortValue(
                value: Self.legacyString(perception.value.value),
                valueType: perception.value.typeID,
                envelope: perception.value,
                producerStepID: nil)
        }

        for (index, input) in runtime.skill.inputs.enumerated() {
            let projectedName = index < runtime.skill.modelExposure.parameters.count
                ? runtime.skill.modelExposure.parameters[index].name : input.name
            guard let value = arguments[input.name] ?? arguments[projectedName],
                  let schema = snapshot.valueTypeSchema(id: input.valueType),
                  let envelope = Self.legacyEnvelope(
                      value,
                      schema: schema,
                      registry: snapshot.valueTypeSchemas,
                      operation: runtime.reference.invocationName)
                    ?? Self.structuredEnvelope(
                        arguments: arguments,
                        schema: schema,
                        registry: snapshot.valueTypeSchemas,
                        operation: runtime.reference.invocationName)
            else { continue }
            ports[input.name] = WorkflowPortValue(
                value: value,
                valueType: input.valueType,
                envelope: envelope,
                producerStepID: nil)
        }
        return ports
    }

    private static func legacyEnvelope(
        _ value: String,
        schema: ValueTypeSchema,
        registry: [ValueTypeSchema],
        operation: String
    ) -> ValueEnvelope? {
        let payload: MaryValue
        switch schema.shape {
        case .string, .enumeration:
            payload = .string(value)
        case .boolean:
            guard let parsed = Bool(value.lowercased()) else { return nil }
            payload = .boolean(parsed)
        case .integer:
            guard let parsed = Int64(value) else { return nil }
            payload = .integer(parsed)
        case .number:
            guard let parsed = Double(value), parsed.isFinite else { return nil }
            payload = .number(parsed)
        case .object, .array:
            guard let data = value.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(MaryValue.self, from: data)
            else { return nil }
            payload = parsed
        case .data:
            guard let data = Data(base64Encoded: value) else { return nil }
            payload = .data(data)
        }
        let envelope = ValueEnvelope(
            typeID: schema.id,
            schemaVersion: schema.version,
            value: payload,
            provenance: .init(operation: operation),
            privacy: .private)
        return ValueEnvelopeValidator.validate(
            envelope,
            schemas: registry).isValid ? envelope : nil
    }

    private static func structuredEnvelope(
        arguments: [String: String],
        schema: ValueTypeSchema,
        registry: [ValueTypeSchema],
        operation: String,
        interactionID: InteractionID? = nil
    ) -> ValueEnvelope? {
        let schemas = Dictionary(
            registry.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        guard let value = structuredValue(
            arguments: arguments,
            schema: schema,
            schemas: schemas)
        else { return nil }
        let project = arguments["project"]
        let envelope = ValueEnvelope(
            typeID: schema.id,
            schemaVersion: schema.version,
            value: value,
            scope: SourceScope(projectID: project),
            provenance: .init(
                operation: operation,
                interactionID: interactionID),
            privacy: .sensitive)
        return ValueEnvelopeValidator.validate(
            envelope,
            schemas: registry).isValid ? envelope : nil
    }

    private static func structuredValue(
        arguments: [String: String],
        schema: ValueTypeSchema,
        schemas: [ValueTypeID: ValueTypeSchema]
    ) -> MaryValue? {
        if schema.shape != .object {
            guard let text = arguments[schema.id.rawValue]
                ?? arguments[schema.id.rawValue.split(separator: ".").last.map(String.init) ?? ""]
            else { return nil }
            return primitiveValue(text, shape: schema.shape)
        }
        var fields: [String: MaryValue] = [:]
        for field in schema.fields {
            guard let fieldSchema = schemas[field.valueType] else { return nil }
            guard let text = arguments[field.name] else {
                if field.required { return nil }
                continue
            }
            guard let value = primitiveValue(text, shape: fieldSchema.shape) else {
                return nil
            }
            fields[field.name] = value
        }
        return .object(fields)
    }

    private static func primitiveValue(
        _ text: String,
        shape: ValueShape
    ) -> MaryValue? {
        switch shape {
        case .string, .enumeration: return .string(text)
        case .boolean: return Bool(text.lowercased()).map(MaryValue.boolean)
        case .integer: return Int64(text).map(MaryValue.integer)
        case .number:
            guard let value = Double(text), value.isFinite else { return nil }
            return .number(value)
        case .object, .array:
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(MaryValue.self, from: data)
        case .data:
            return Data(base64Encoded: text).map(MaryValue.data)
        }
    }

    private static func legacyString(_ value: MaryValue) -> String {
        switch value {
        case .string(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .null: return "null"
        case .object, .array, .data:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    private func recordSchemaExecution(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        outcome: SkillOutcome
    ) {
        // NOTHING IS RECORDED HERE ANY MORE. `dispatch` composes one record
        // for every act, refusals included; a second write from inside the
        // execution path would double every schema-executed row and describe
        // it with a reference this site cannot make turn-accurate.
        _ = arguments
        _ = outcome
    }

    /// THE SECOND UNBOUNDED AWAIT ON THIS PATH, and it is the one nobody looks
    /// at because nothing has run yet. A `confirmationPreview` is allowed to
    /// READ a store to describe its target — `update_reminder` and
    /// `delete_event` both resolve the handle to speak the thing's title — and
    /// every one of those reads was, until this round, a blocking EventKit
    /// round trip with no deadline in front of it. A hung preview does not
    /// merely delay an action: it holds the CONFIRM QUESTION ITSELF open, so
    /// the user is never even asked.
    ///
    /// 15 s is every store read deadline behind it (`CalendarStore.queryTimeout`,
    /// `RemindersStore.fetchTimeout`), so nothing legitimate reaches this
    /// number — and past it the generic question is a far better thing to ask
    /// than nothing at all. The preview is prose, so degrading it costs
    /// specificity and never correctness: the arguments the user is agreeing to
    /// are the ones already parked in `pendingStore`.
    static let previewBudget: TimeInterval = 15

    private func previewQuestion(
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

    /// The confirmed replay.
    ///
    /// THE FROZEN BINDING IS THE POINT. What runs is what was parked, with the
    /// arguments, the context and the reference it had at park time — never a
    /// re-resolution. The user approved one specific act; re-deciding which
    /// binding serves it, on a turn where focus has moved, would execute
    /// something they never saw.
    private func executePending() async -> SkillOutcome {
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

    // THE RAW MACHINE PRIMITIVES ARE NOT IN THIS CUT.
    //
    // `run_applescript` and `run_shell` used to live here as escape hatches:
    // whatever a package could not express, the model could reach by writing a
    // script. They are gone with the AppleScript lane, and their absence is a
    // design position rather than an omission — an escape hatch that can do
    // anything is a capability with no declared contract, no target
    // resolution, no confirmation policy, and no receipt worth the name. Every
    // act Mary performs now comes from something a package declared, which is
    // what makes a behavioral record a record of anything at all.

    // MARK: - Skill execution

    /// Recording wrapper: both the direct path and the confirmed replay
    /// funnel here, so every real binding run lands in the execution log once —
    /// and so an UNROUTED WRITE is bracketed exactly once, wherever it came
    /// from.
    private func execute(
        binding: SkillBinding,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope] = [:],
        context: AbilityExecutionContext,
        reference: AbilitySkillReference,
        runtime: AbilityRuntimeSkill? = nil,
        policy: CapabilityExecutionPolicy = .unconstrained,
        signals: SchemaSignalTurnSnapshot = .empty
    ) async -> SkillOutcome {
        if let runtime,
           let failure = payloadFailure(
               runtime: runtime,
               arguments: arguments,
               typedInputs: typedInputs,
               signals: signals,
               policy: policy) {
            return failure
        }
        // BEFORE the write, not after it. The refresh rests on the premise
        // that a caret write is ONE CONTIGUOUS INSERTION, and that premise only
        // holds across this single call — read the body a moment later and the
        // user has typed something themselves, at which point before/after
        // describes two edits and can be told apart from one by nothing.
        let bracket = await unroutedWriteBracket(binding)
        var outcome = await performExecute(
            binding: binding,
            arguments: arguments,
            typedInputs: typedInputs,
            context: context,
            maximumDurationSeconds: policy.maximumDurationSeconds)
        outcome = enforceOutputPayload(
            outcome,
            reference: reference,
            policy: policy)
        outcome.skillReference = outcome.skillReference ?? reference
        let owner = ownerID(bindingName: binding.name)
        // See `recordSchemaExecution`: the chokepoint owns the ledger.
        registerRead(binding: binding, owner: owner, arguments: arguments, outcome: outcome)
        if outcome.ok, let bracket {
            await refreshPassages(after: bracket)
        }
        return outcome
    }

    /// Canonical machine payload measured at the last boundary before an
    /// adapter or cognitive primitive can observe it. This includes provider
    /// arguments, typed workflow ports, and every Interaction/Perception the
    /// Skill declared it may consume; package payload limits therefore cannot
    /// be bypassed by moving bytes onto a different ingress channel.
    private struct MeasuredSkillInput: Encodable {
        var arguments: [String: String]
        var typedInputs: [String: ValueEnvelope]
        var interactions: [ValueEnvelope]
        var perceptions: [ValueEnvelope]
    }

    private struct MeasuredSkillOutput: Encodable {
        var summary: String
        var passageHandle: String?
        var typedOutputs: [String: ValueEnvelope]
    }

    private func payloadFailure(
        runtime: AbilityRuntimeSkill,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope],
        signals: SchemaSignalTurnSnapshot,
        policy: CapabilityExecutionPolicy
    ) -> SkillOutcome? {
        guard let maximum = policy.maximumPayloadBytes else { return nil }
        let payload = MeasuredSkillInput(
            arguments: arguments,
            typedInputs: typedInputs,
            interactions: signals.interactions(declaredBy: runtime.skill).map(\.value),
            perceptions: signals.perceptions(declaredBy: runtime.skill).map(\.value))
        guard let bytes = Self.canonicalByteCount(payload), bytes <= maximum else {
            return SkillOutcome(
                ok: false,
                summary: "\(runtime.reference.displayLabel) was blocked because its typed input exceeded the \(maximum)-byte Capability limit.",
                status: .blocked,
                archivePolicy: .none,
                skillReference: runtime.reference)
        }
        return nil
    }

    private func enforceOutputPayload(
        _ outcome: SkillOutcome,
        runtime: AbilityRuntimeSkill,
        policy: CapabilityExecutionPolicy
    ) -> SkillOutcome {
        enforceOutputPayload(
            outcome,
            reference: runtime.reference,
            policy: policy)
    }

    private func enforceOutputPayload(
        _ outcome: SkillOutcome,
        reference: AbilitySkillReference,
        policy: CapabilityExecutionPolicy
    ) -> SkillOutcome {
        guard let maximum = policy.maximumPayloadBytes else { return outcome }
        let payload = MeasuredSkillOutput(
            summary: outcome.summary,
            passageHandle: outcome.passageHandle,
            typedOutputs: outcome.typedOutputs)
        guard let bytes = Self.canonicalByteCount(payload), bytes <= maximum else {
            return SkillOutcome(
                ok: outcome.ok && Self.isMutation(policy.effect),
                summary: outcome.ok && Self.isMutation(policy.effect)
                    ? "\(reference.displayLabel) completed, but Mary omitted its oversized result at the \(maximum)-byte Capability boundary."
                    : "\(reference.displayLabel) returned more than its \(maximum)-byte Capability limit, so Mary discarded the result.",
                status: outcome.ok && Self.isMutation(policy.effect) ? .succeeded : .failed,
                archivePolicy: .none,
                foundNothing: false,
                passageHandle: nil,
                skillReference: reference,
                typedOutputs: [:])
        }
        return outcome
    }

    private static func canonicalByteCount<Value: Encodable>(_ value: Value) -> Int? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(value).count
    }

    private static func isMutation(_ effect: CapabilityEffect) -> Bool {
        switch effect {
        case .reversibleMutation, .mutation, .destructive, .externalCommunication:
            return true
        case .none, .read:
            return false
        }
    }

    /// A caret write in flight: which world it lands in, and the body one
    /// instant before it did.
    private struct UnroutedWriteBracket {
        let backing: PassageBacking
        let before: BodySnapshot
    }

    /// THE BEFORE-BODY for an unrouted write, or nil when there is nothing here
    /// worth protecting. Every gate is cheaper than the one after it, and
    /// NOTHING TALKS TO AN APPLICATION until the last:
    ///
    ///   1. `binding.unroutedWrite` — one declared Bool, false for every binding
    ///      but the two caret verbs, so a normal turn pays one branch.
    ///   2. A LEADING WORLD WITH A BACKING — two dictionary lookups, the same
    ///      `focusProvider` routing `locatePassage` and the pre-read use, so
    ///      the refresh can never re-aim handles at a document the prompt is
    ///      not describing. Nil for a coding lead and for every eyeless turn.
    ///   3. `backing.canWrite` — a nil check, and NOT a proxy for one. It is
    ///      the same evidence: Scrivener's body is read from `content.rtf`,
    ///      which TRAILS the live editor, so an after-read there returns the
    ///      pre-write text and the pair would "prove" that nothing moved.
    ///      Belt and braces today — this table admits only worlds that declared
    ///      an edit verb, and the derived declaration already requires
    ///      `canWrite` — but `targetedEdit` is overridable, and this is the
    ///      clause that says why a locate-only world may not be bracketed.
    ///   4. AT LEAST ONE LIVE HANDLE in that world — an in-memory sweep of the
    ///      registry. No handles means nothing can be orphaned, and the two
    ///      reads below would be spent shifting an empty set.
    ///   5. THE READ — one `backing.body()`, which in Pages is ONE osascript
    ///      spawn now that `documentScript` carries name, path and body in a
    ///      single event. So the whole seam is 1 spawn here + 1 in
    ///      `refreshPassages` = 2 on a protected caret write, and 0 on every
    ///      other turn in the tree.
    ///
    /// A FAILED before-read gives up rather than guessing: without the earlier
    /// string there is no delta, and a refresh computed from a body read AFTER
    /// the write would shift every handle by zero and call them all fresh.
    private func unroutedWriteBracket(_ binding: SkillBinding) async -> UnroutedWriteBracket? {
        guard binding.unroutedWrite,
              let owner = focusProvider?(),
              let backing = passageBackings[owner],
              backing.canWrite,
              passages.live().contains(where: { $0.place == backing.place }),
              let before = await backing.body()
        else { return nil }
        return UnroutedWriteBracket(backing: backing, before: before)
    }

    /// THE HANDLES, RE-AIMED — the answer to "it isn't in the document any
    /// more" said about a passage that was still there.
    ///
    /// The pair is what recovers it. A plain re-anchor cannot: she typed INSIDE
    /// the stored words, so the passage's text occurs zero times in the new
    /// body either way. `PassageRefresh.after` reads the two strings as one
    /// contiguous change and moves each live handle by it — before it, shifted;
    /// after it, untouched; INSIDE it, grown, so `[S1]` still names the same
    /// part of the document and now includes what was just typed into it.
    ///
    /// An unchanged body short-circuits: `resume_typing` with nothing left to
    /// type, or a write the app quietly refused, is not an edit, and the
    /// cheapest way to say so is that the two hashes agree.
    private func refreshPassages(after bracket: UnroutedWriteBracket) async {
        guard let after = await bracket.backing.body(),
              after.hash != bracket.before.hash else { return }
        // The count is the refresher's own reporting surface. Nothing here
        // speaks it and nothing logs it: the handles it moved ARE the product,
        // and a spoken "I re-anchored 2 passages" is exactly the machine talk
        // the passage contract exists to keep out of her mouth.
        //
        // THE INJECTED STORES, AND IT GREW THAT PARAMETER. `PassageRefresh`
        // landed with `registry`/`ambient` DEFAULTED to `.shared`, so this call
        // compiled unchanged and refreshed a different ledger than the one
        // `unroutedWriteBracket` swept two lines above. Measured, not reasoned
        // about: a caret write through a registry built with its own
        // `PassageRegistry` left the held handle reading the words the user had
        // just typed over, and every existing test passed — they count the
        // reads, and both reads happen either way. Defaults that agree in
        // production and disagree under injection are the shape that ships.
        _ = PassageRefresh.after(
            before: bracket.before, after: after, place: bracket.backing.place,
            registry: passages, ambient: ambient)
    }

    /// A READ RESULT BECOMES A FACT. Every gate here is a doctrine already in
    /// the tree, not a new rule:
    ///
    /// - `.read` only. A write's summary is a report of what happened, which is
    ///   the ACTION LOG's job and Totem's — never a description of the document
    ///   as it now stands.
    /// - `!outcome.foundNothing`. Slice 1's sentinel: a MISS is an answer, not
    ///   a passage, and the whole point of that flag is that a miss may never
    ///   be dressed as content. A miss that became a fact would be recited a
    ///   turn later with an age on it — the original bug, aged.
    /// - A KNOWN PLACE. `(world, application, slot)` is the key, and
    ///   `AmbientWorld` has one case per plugin owner, so calendar/mail/reminders
    ///   reads key exactly as document reads do.
    ///
    ///   THIS GUARD IS THE REGRESSION THIS SLICE REPAIRS, and the previous
    ///   comment here confessed it: "a calendar or mail read has no world to
    ///   key on and stays exactly as it is today". It did — reads are also
    ///   (correctly) not deposited to Totem, and the in-turn spoken pass was
    ///   removed, so an eyeless read reached NOBODY and was forgotten by the
    ///   next turn while a Pages read persisted. `ReadRoute.discarded` reported
    ///   it honestly and nothing acted on it. Widening the world vocabulary
    ///   flipped this line on with no change to the dispatcher: eyes are an
    ///   upgrade for workspace apps, never a precondition for remembering what
    ///   you read.
    ///
    ///   AND IT CAME BACK, for owners the vocabulary could not widen to cover.
    ///   A Dynamic `.mary` package's owner is a validated logical application
    ///   id — `"sketch"` — never a plugin owner, so `AmbientWorld.from` answered
    ///   nil and this guard dropped the read exactly as it dropped calendars:
    ///   a registered application's read ran, succeeded, and reached nobody.
    ///   The repair could not be another enum case, because there is no bound
    ///   on how many packages a user may import. `worldOfRead` now resolves a PLACE through
    ///   `AmbientApplicationIndexProvider`, so a registered application keys
    ///   under the generic perception world while keeping its own identity.
    ///
    /// Registering here rather than in the brain is deliberate: the dispatcher
    /// is the ONE place that knows which plugin owns a binding and which
    /// parameter carried the phrase, so fetch-first's pre-read and a read the
    /// model chose mid-turn become facts through the same line of code.
    private func registerRead(
        binding: SkillBinding, owner: String,
        arguments: [String: String], outcome: SkillOutcome
    ) {
        guard binding.access == .read, outcome.ok, !outcome.deferred, !outcome.foundNothing,
              // An adapter that filed its own richer fact (a named document,
              // an outline) already answered for this read; a second generic
              // fact would spend the lane's budget on a duplicate.
              !outcome.ambientDeposited,
              let place = placeOfRead(outcome: outcome, owner: owner),
              let fact = AmbientBridge.readFact(
                world: place.world,
                application: place.application,
                phrase: readPhrase(binding: binding, owner: owner, arguments: arguments),
                summary: outcome.summary,
                document: documentOfRead(outcome: outcome),
                passageHandle: outcome.passageHandle)
        else { return }
        ambient.register(fact)
        if case .namedRead(let document, _) = fact.slot,
           let document,
           !document.isEmpty {
            // BY REALM, not world: a registered application's read stamps
            // evidence under its own `other_apps:<id>` identity, so two
            // applications sharing the host lane cannot claim each other's
            // containers. Native facts key byte-identically to before.
            containers.noteEvidence(
                place: fact.place,
                key: document,
                .read,
                at: fact.capturedAt)
        }
    }

    /// WHICH DOCUMENT A READ'S FACT IS ABOUT — from the passage the read
    /// minted, and nil when it minted none.
    ///
    /// Read off the REGISTRY for `worldOfRead`'s exact reason: a handle this
    /// process did not mint resolves to `.unknown`, so a summary cannot spoof
    /// the discriminator any more than it can spoof the world. Nil is the
    /// answer for every eyeless world and for every read that names no
    /// passage, which restores today's key byte for byte.
    private func documentOfRead(outcome: SkillOutcome) -> String? {
        guard let handle = outcome.passageHandle,
              case .live(let passage) = passages.resolve(handle)
        else { return nil }
        return passage.documentKey
    }

    /// WHICH WORLD A READ'S FACT BELONGS TO — the passage's, when the read
    /// minted one, and otherwise the owning plugin's.
    ///
    /// THE CASE THIS EXISTS FOR: `find_passage` is owned by `typer`, because a
    /// revision is an act rather than a place and `typer` is the `.service`
    /// world that already owns the write verb. But the PASSAGE it hands back
    /// lives in Pages, or Xcode, or Scrivener. Filed under the owner it would
    /// become a `.typer` fact — a document quoted under a world that has no
    /// documents, invisible to every query that asks what Mary is holding
    /// about the file in front of the user, and rendered as "Typer · Essay".
    ///
    /// It reads the world off the REGISTRY rather than off the binding, so it
    /// cannot be spoofed by a summary: a handle that this process did not mint
    /// resolves to `.unknown` and the owner's world stands.
    /// WHERE A READ LANDS — an `AmbientPlace`: a built-in world's own place,
    /// or a registered application's host-lane place.
    ///
    /// Three rungs, and the order is the argument:
    ///
    ///   1. THE PASSAGE. A handle carries its own world; the passage knows
    ///      which document it was cut from, and that is structural knowledge.
    ///   2. THE PLUGIN OWNER. A compiled plugin's owner IS an `AmbientWorld`,
    ///      held so by the bijection `everyPluginOwnerIsAWorld` pins.
    ///   3. THE REGISTRY. Anything else is an application Mary was taught
    ///      rather than built with; its registration's `place` already spells
    ///      the rule this rung used to hand-roll — the `legacyWorld` when it
    ///      has a built-in counterpart, the `.otherApps` lane discriminated
    ///      by its logical id when it does not.
    ///
    /// Nil now means only "this owner is not registered at all", which is a
    /// process that has not been configured yet rather than a Dynamic package
    /// falling off the ambient layer.
    private func placeOfRead(
        outcome: SkillOutcome, owner: String
    ) -> AmbientPlace? {
        if let handle = outcome.passageHandle,
           case .live(let passage) = passages.resolve(handle) {
            return passage.place
        }
        return place(ofOwner: owner)
    }

    /// What the read was TARGETED at — the slot key, so re-reading the same
    /// phrase supersedes rather than accumulating. The plugin's own
    /// `targetedRead` parameter first (the phrase the user actually named),
    /// then the execution log's target heuristic, then the binding name: a read
    /// with no target is still one fact about one thing, keyed by the thing it
    /// reads (`current_file`, `code_changes`).
    private func readPhrase(
        binding: SkillBinding, owner: String, arguments: [String: String]
    ) -> String {
        if let parameter = targetedReads[owner]?.parameter,
           let value = arguments[parameter]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        // NO KEY SNIFFING. This used to guess the phrase from an argument
        // called "document", "file", "title" or one of ten others, which got
        // the wrong answer for any package using a different word. A binding
        // that wants its read named declares which parameter names it
        // (`targetedRead`, above); everything else is named after the binding,
        // which is at least true.
        return binding.name
    }

    private func ownerID(bindingName: String) -> String {
        let owner = attributed.first { $0.binding.name == bindingName }?.owner ?? ""
        return owner.isEmpty ? "mac" : owner
    }

    /// The turn's arguments, canonically ordered.
    ///
    /// RE-ENCODED, NOT PASSED THROUGH. A model emits keys in whatever order it
    /// pleases, and two calls that differ only in key order are the same call
    /// — a dataset that records them as different strings cannot deduplicate,
    /// diff, or compare a replay against the act it replays.
    static func canonicalArguments(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: canonical, encoding: .utf8)
        else { return argumentsJSON }
        return text
    }

    private static func encodeArguments(_ arguments: [String: String]) -> String? {
        guard !arguments.isEmpty,
              let data = try? JSONSerialization.data(
                withJSONObject: arguments, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    // MARK: - The dispatch budget

    /// HOW LONG ONE SKILL MAY RUN before the funnel stops waiting on it, for
    /// every binding that does not name its own number below.
    ///
    /// THE ARITHMETIC. The deepest chain an ordinary binding makes is TWO
    /// osascript round trips at osascript's own ceiling — the passage verbs
    /// read the live body and then write it back — plus the native budgets
    /// between them (`PagesPassageWriter.locateBudget` 8 s +
    /// `readBackBudget` 5 s ≈ 15 s):
    ///
    ///     2 × ScriptRunner.appleScriptTimeout (30) + 15 = 75
    ///
    /// It is also STRICTLY ABOVE `MaryBrain.routineProgressFirstMark` (45 s),
    /// and that ordering is deliberate: a binding that is merely slow is
    /// announced as "still working" thirty seconds before the dispatcher gives
    /// up on it, so the reassurance never arrives after the apology.
    ///
    /// A UNIVERSAL CAP MUST NOT KILL A REAL BUILD — the one thing a watchdog
    /// may never do, and the reason this is a per-binding budget with a default
    /// rather than one number for everything. `mdfind` at 20 s, `open -a` at
    /// 15 s, `git` at 30 s and every EventKit deadline at 15 s all fit under
    /// the default with room; the four that do not are named below with their
    /// own in-band ceiling.
    static let defaultSkillBudget: TimeInterval = 75

    /// The Skill bindings that legitimately outlive the default, each one being ITS
    /// OWN in-band `Subprocess.run` ceiling plus one `appleScriptTimeout` (30 s)
    /// of head-room for the spawn, the pipe drain and the summary built around
    /// it. Nothing here is taste: every number is read off the call it bounds.
    ///
    /// DECLARED HERE AND NOT ON `SkillBinding` ONLY BECAUSE OF WHERE THE FILE
    /// BOUNDARY FELL THIS ROUND — this is the same shape as `access`, `stage`
    /// and `unroutedWrite`, it belongs beside them, and `PluginCatalogTests`
    /// pins the set so a renamed binding cannot silently drop back to the
    /// default and start being killed mid-build.
    static let skillBudgets: [String: TimeInterval] = [
        "run_tests":    330,   // Subprocess.run(timeout: 300) — `swift test`
        "build_check":  330,   // BuildVerifier's `swift build`, the same 300
        "complete_coding_change": 280, // above Vibe's 240 s session cap
        "run_shortcut": 150,   // Subprocess.run(timeout: 120) — `shortcuts run`
        "zip_folder":   150,   // Subprocess.run(timeout: 120) — `ditto -c -k`
    ]

    static func budget(for binding: SkillBinding) -> TimeInterval {
        skillBudgets[binding.name] ?? defaultSkillBudget
    }

    /// THE BUDGET SCALE, and it exists for the reason `MaryBrain`'s watchdog
    /// scale does: a suite that had to sit through seventy-five real seconds to
    /// prove a deadline fires is a suite nobody runs, and an unrun pin is an
    /// absent one. INSTANCE-scoped rather than a global, so two tests scaling
    /// the number cannot collide — the same reason the routine watchdog's live
    /// value is an instance property beside a static default.
    private let budgetScale = OSAllocatedUnfairLock<Double>(initialState: 1)

    func setBudgetScaleForTesting(_ scale: Double) {
        budgetScale.withLock { $0 = scale }
    }

    /// THE ONE FUNNEL, AND NOW THE ONE DEADLINE. Both the direct path and the
    /// confirmed replay reach a binding through here and nowhere else, which is
    /// what lets a bound be universal — and universal is what it has to be:
    /// `.native` had NO bound of any kind, and four of the stores behind it
    /// (Contacts, Photos, Messages, Scrivener) still have none of their own.
    ///
    /// THE FAILURE THIS PREVENTS, in the user's own words: "For these type of
    /// actions where it is a list of information retrieval of another
    /// application it seems to be susceptible to getting locked."
    /// `list_reminders` spoke its acknowledgement, rendered its chip, and then
    /// produced nothing. Every other fix in this area is a bound on ONE known
    /// dependency; this is the bound on the ones nobody has found yet.
    private func performExecute(
        binding: SkillBinding,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope] = [:],
        context: AbilityExecutionContext,
        maximumDurationSeconds: TimeInterval? = nil
    ) async -> SkillOutcome {
        let scale = budgetScale.withLock { $0 }
        let declaredBudget = Self.budget(for: binding)
        let unscaledBudget = min(
            declaredBudget,
            maximumDurationSeconds ?? declaredBudget)
        let budget = unscaledBudget * scale
        var boundedContext = context
        boundedContext.deadline = Date().addingTimeInterval(budget)
        // THE WORKER IS HELD, not merely spawned. `bounded` runs its work in an
        // UNSTRUCTURED `Task`, which inherits neither cancellation nor the
        // caller's identity — so wrapping the call and walking away would have
        // quietly severed cancellation for every binding in the catalog. A
        // superseded or expired lane calls `routine.task.cancel()`, and
        // `RemindersStore.fetch`'s cancellation handler exists precisely so
        // "a cancelled read is a superseded turn walking away" stays true.
        // Cancelling from BOTH sides — the caller's, through the handler; the
        // deadline's, on the way out — keeps that contract intact underneath
        // the new bound.
        let worker = Task {
            await Self.run(
                binding: binding,
                arguments: arguments,
                typedInputs: typedInputs,
                context: boundedContext)
        }
        // THE HANDLE A STOP BUTTON REACHES. Registered before the wait and
        // removed after it, so `cancelRun` can only ever find a call that is
        // genuinely still running.
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
        // A STOPPED CALL SAYS SO, whatever the binding managed to return.
        //
        // Cancelling a Task is a request, not a guarantee: an Accessibility
        // round trip already in flight finishes regardless, and a binding that
        // ignores cancellation returns an ordinary success. Reporting that as
        // "completed" would tell the person their Stop did nothing when it may
        // well have stopped the rest of the sequence — and reporting it as a
        // failure would blame the application. `.cancelled` is the honest word
        // and the one the chip and the inspector already know.
        if wasStopped {
            return Self.hinted(
                SkillOutcome(
                    ok: false,
                    summary: "You stopped \(binding.name).",
                    status: .cancelled),
                binding)
        }
        guard let outcome else {
            // AN HONEST SENTENCE, NEVER SILENCE — `BoundedWait`'s whole rule.
            // It says what was waited on and how long, because "that didn't
            // work" about a binding that is still running somewhere is the
            // shape that sent the user to ask a second time.
            return Self.hinted(
                SkillOutcome(
                    ok: false,
                    summary: "\(binding.name) didn't finish within \(Int(unscaledBudget)) seconds — whatever it drives may be busy or mid-sync. Ask me again in a moment."),
                binding)
        }
        return outcome
    }

    /// The binding itself, exactly as it ran before the deadline existed.
    /// Static because nothing here needs the registry: extracting it is what
    /// lets the whole body — the stage preemption included — sit inside one
    /// cancellable task rather than half in and half out of the bound.
    private static func run(
        binding: SkillBinding,
        arguments: [String: String],
        typedInputs: [String: ValueEnvelope],
        context: AbilityExecutionContext
    ) async -> SkillOutcome {
        // Stage Skill bindings (activate an app, drive menus, type, move the caret)
        // preempt the current stage holder first — the newest request wins,
        // and the holder steps aside RESUMABLY (the typer saves its
        // remainder) instead of dying mid-word to a focus steal.
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

    /// THE DECLARED HINT, ON EVERY FAILURE — which is what `spokenFailureHint`
    /// has never once been.
    ///
    /// It used to be appended in a script-backing arm that nothing in the
    /// tree ever used — every binding that declared a hint drove its work from
    /// inside a compiled closure — so that branch was unreachable and the
    /// `catch` was the only path a hint ever reached the user through. Which
    /// meant a hint was spoken when a closure THREW and never when it returned
    /// `ok: false`, and `ok: false` is the shape a failure actually takes: a
    /// timeout said a bare "that failed" while the declaration's own
    /// "check the Automation permission" sat two lines above it, unread.
    ///
    /// IDEMPOTENT, because several Skill bindings already write their own guidance
    /// into the summary — `show_in_calendar_app` appends a bespoke sentence and
    /// declares `spokenFailureHint: nil` — and a binding that says the same
    /// thing twice is worse than one that says it once. It is also what makes
    /// the deadline sentence above safe to hint: the hint is about the app, and
    /// a deadline is exactly when the user needs to hear it.
    private static func hinted(_ outcome: SkillOutcome, _ binding: SkillBinding) -> SkillOutcome {
        guard !outcome.ok,
              let hint = binding.spokenFailureHint,
              !outcome.summary.contains(hint)
        else { return outcome }
        var spoken = outcome
        spoken.summary += " — \(hint)"
        return spoken
    }

    // MARK: - Argument tolerance (ported verbatim)

    /// Models drift on parameter names ("project_name" for "project"). If a
    /// declared parameter is missing but a provided key contains it (or vice
    /// versa), adopt that value under the declared name.
    static func reconcile(
        _ arguments: [String: String],
        against parameters: [ModelSkillSchema.Parameter]
    ) -> [String: String] {
        var result = arguments
        // A KEY THAT IS ITSELF A DECLARED PARAMETER IS NEVER A LOOSE SPELLING
        // OF ANOTHER ONE.
        //
        // THE FAILURE THIS FIXES (live): `restyle_design_layer` grew a
        // `fill_type` parameter beside its existing `fill`. The substring
        // test then read "fill_type".contains("fill") as a match, so a model
        // that correctly sent `fill: "blue"` had "blue" COPIED into
        // `fill_type` — and into `fill_stops` — where it failed token
        // validation. Every colour change died on a parameter the model never
        // sent. This heuristic exists to rescue a model that wrote
        // `filename` for `path`; it must never redistribute a value the model
        // placed exactly right.
        let declared = Set(parameters.map { $0.name.lowercased() })
        // A DECLARED ALIAS IS TRIED BEFORE THE HEURISTIC, and matched exactly.
        //
        // THE FAILURE THIS FIXES (live): the model raised a TextEdit window
        // with `{"app":"TextEdit","title":"Untitled 47"}`. The parameter is
        // spelled `window`; neither name contains the other, so the substring
        // test below could not bridge them, the binding read the miss as `""`,
        // and the user was told their window did not exist. `"Untitled 47"`
        // would have matched the resolver's exact-title rung on the first try.
        //
        // Exact rather than loose on purpose: containment is what let a
        // correctly-placed value be copied into a sibling parameter (see the
        // `fill` / `fill_type` note above), and an alias list is precisely the
        // case where we already know both spellings and need no guessing.
        // Declaration order decides which of two present aliases wins, so the
        // lookup is a plain exact-match table rather than an ordered scan.
        let byLowercasedKey = Dictionary(
            arguments.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first })
        for parameter in parameters where result[parameter.name] == nil {
            for alias in parameter.aliases {
                let candidate = alias.lowercased()
                // An alias that is ITSELF a declared parameter belongs to that
                // parameter, not to this one.
                guard !declared.contains(candidate) else { continue }
                if let value = byLowercasedKey[candidate] {
                    result[parameter.name] = value
                    break
                }
            }
        }
        for parameter in parameters where result[parameter.name] == nil {
            let want = parameter.name.lowercased()
            // Sorted: `Dictionary.first(where:)` has no defined order, so two
            // equally loose candidates used to resolve differently run to run.
            if let (_, value) = arguments.sorted(by: { $0.key < $1.key })
                .first(where: { key, _ in
                    let have = key.lowercased()
                    guard !declared.contains(have) else { return false }
                    return have.contains(want) || want.contains(have)
                }) {
                result[parameter.name] = value
            }
        }
        return result
    }

    /// Models emit JSON arguments; Skill bindings take strings. Numbers and bools
    /// are stringified so a schema-loose model never breaks dispatch.
    static func stringArguments(fromJSON json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let string as String: result[key] = string
            case let bool as Bool: result[key] = bool ? "true" : "false"
            case let number as NSNumber: result[key] = number.stringValue
            case let array as [Any]:
                if JSONSerialization.isValidJSONObject(array),
                   let data = try? JSONSerialization.data(
                       withJSONObject: array, options: [.sortedKeys]),
                   let encoded = String(data: data, encoding: .utf8) {
                    result[key] = encoded
                }
            case let dictionary as [String: Any]:
                if JSONSerialization.isValidJSONObject(dictionary),
                   let data = try? JSONSerialization.data(
                       withJSONObject: dictionary, options: [.sortedKeys]),
                   let encoded = String(data: data, encoding: .utf8) {
                    result[key] = encoded
                }
            default: break
            }
        }
        return result
    }
}
