//
//  AbilityRuntime+Dispatch.swift
//  MaryBrain
//
//  WHAT: THE CHOKEPOINT. Model call, deterministic lane press and
//        confirmation replay all enter here.
//  IN:   invocation name + JSON arguments
//  OUT:  SkillOutcome, one ledger row, and what the turn learned
//  PIN:  One identity for the whole act — chip, ledger, episode and Stop
//        share it. Only a vouched, succeeded dispatch teaches a habit.
//
import Foundation
import MaryComputerUse
import os

extension AbilityRuntime {

    /// Call identity for the in-flight dispatch, carried to `performExecute`.
    /// PIN: Task-local rather than four extra parameters down the chain.
    enum RunContext {
        @TaskLocal static var runID: String?
    }

    /// Lane timing log — every dispatch (model, deterministic press, confirm replay).
    static let timingLog = Logger(subsystem: "nyc.rao.mary", category: "lanes")

    /// Dispatch chokepoint — model, lane press, and confirmation replay all enter here.
    /// The parts of one dispatch, for the timing line — the budget wrapper
    /// writes `executeMs`, the worker writes `preemptMs`, `dispatch` reads both.
    /// Task-local, so the worker's own Task inherits it.
    final class DispatchTiming: @unchecked Sendable {
        private let lock = NSLock()
        private var preempt: UInt64 = 0
        private var execute: UInt64 = 0
        var preemptMs: UInt64 {
            get { lock.withLock { preempt } }
            set { lock.withLock { preempt = newValue } }
        }
        var executeMs: UInt64 {
            get { lock.withLock { execute } }
            set { lock.withLock { execute = newValue } }
        }
    }
    @TaskLocal static var timing: DispatchTiming?

    public func dispatch(
        name: String, argumentsJSON: String, runID: String? = nil
    ) async -> SkillOutcome {
        let startedAt = Date()
        let dispatchStart = DispatchTime.now()
        // Read reference before dispatch — a dispatch can change provider selection.
        let turnReference = skillReference(for: name)
        let confirmationID = pendingStore.current()?.id

        // One identity for the whole act — chip, ledger, episode, and Stop share it.
        let identity = runID ?? UUID().uuidString
        let timing = DispatchTiming()
        let outcome = await Self.$timing.withValue(timing) {
            await RunContext.$runID.withValue(identity) {
                await dispatchCore(name: name, argumentsJSON: argumentsJSON)
            }
        }

        let record = BehavioralActionRecord(
            outcome: outcome,
            intention: name,
            argumentsJSON: Self.canonicalArguments(argumentsJSON),
            reference: turnReference,
            runID: identity,
            // Confirmation thread — park and replay are two episodes, one act.
            confirmationID: confirmationID ?? pendingStore.current()?.id,
            startedAt: startedAt)
        executionLog.record(record)
        behavior?.append(record)
        // Mary's own act, not the model's — the "looked first" capsule's raw
        // material. Nil outside a bound turn (see `OwnActCollector.current`'s
        // own doc), so this is a no-op for the Life pulse.
        if record.initiator != .model {
            OwnActCollector.current?.append(record)
        }
        let totalMs = (DispatchTime.now().uptimeNanoseconds
            &- dispatchStart.uptimeNanoseconds) / 1_000_000
        // WHERE THE TIME WENT: the gates before the binding, the stage preempt,
        // and the binding itself — one line, so a slow dispatch says which.
        let gatesMs = totalMs > timing.executeMs ? totalMs - timing.executeMs : 0
        let line = "dispatch \(name) — total \(totalMs)ms"
            + " · gates \(gatesMs)ms · preempt \(timing.preemptMs)ms · run \(timing.executeMs)ms,"
            + " status=\(record.disposition)"
        Self.timingLog.info("\(line, privacy: .public)")
        TurnCircuitLog.dispatch(
            name: name,
            ok: outcome.ok,
            foundNothing: outcome.foundNothing,
            disposition: record.disposition.rawValue)
        // Only a SUCCEEDED dispatch feeds the habit store. `outcome.ok`
        // conflates "was this the right Skill" with "did it execute" — an AX
        // timeout, an unrelated adapter bug, or a since-fixed defect all read
        // as `ok: false` / `foundNothing: true` with zero bearing on whether
        // routing here was correct. Recording that as a negative permanently
        // suppresses this phrasing's affinity for the Skill (see
        // `SemanticSkillRequestIndex`'s negative-margin gate) even after the
        // real defect is fixed — the exact "a bad night pins a centroid"
        // outcome `RoutingHabitStore`'s own PIN says must not happen.
        //
        // AND ONLY A DISPATCH A LANE VOUCHED FOR. Recording used to happen for
        // every caller of this chokepoint — the accepted-prose path storing
        // "yes please" as the way to ask for `type_at_cursor`, the runtime's
        // own pre-reads storing the user's sentence against a Skill they never
        // asked for. `RoutingHabitRecordingContext.grant` is how a lane says "these
        // words caused this act"; without one, nothing is learned.
        if let grant = RoutingHabitRecordingContext.grant,
           name != Self.confirmSkillName, name != Self.cancelSkillName,
           outcome.ok, !outcome.foundNothing,
           let skillID = abilitySnapshot.skill(invocationName: name)?.skill.id,
           // A MODEL LANE MAY NOT TEACH A READ. "Fix the bug in main.swift"
           // reads the buffer before it edits; learned, that phrasing could
           // later win `read_buffer` uniquely and the shortcut would read the
           // file and CLOSE the turn without doing the work. The confidence
           // lane is exempt: there the embedding already picked this Skill
           // from this query, so the row only reinforces its own win.
           grant.lane == .confidence || !isReadOnly(name),
           grant.budget.consume() {
            EmbeddingRouting.recordRoutingHabits(
                query: grant.query,
                intent: grant.intent,
                outcomes: [(skillID.rawValue, true)],
                store: routingHabitStore.withLock { $0 })
        }
        // WHICH PLAYER, alongside which Skill. Same success gate as the
        // habit above — a vouched dispatch that actually landed — but no
        // budget: the budget exists so one turn teaches one PHRASING, whereas
        // every act in a player is a vote about where this person works.
        if RoutingHabitRecordingContext.grant != nil,
           name != Self.confirmSkillName, name != Self.cancelSkillName,
           outcome.ok, !outcome.foundNothing,
           let runtime = abilitySnapshot.skill(invocationName: name),
           let habit = ExpertiseResolution.habit(
               proving: runtime,
               outcome: outcome,
               providerApplicationID: turnProviderSelection(
                   snapshot: abilitySnapshot)
                   .choice(for: runtime.skill.id)?.provider?.applicationID,
               snapshot: abilitySnapshot) {
            applicationHabitLedger.withLock { $0 }.record(habit)
        }
        return outcome
    }

    private func dispatchCore(name: String, argumentsJSON: String) async -> SkillOutcome {
        // THE TURN'S INPUTS, ONCE, AT THE TOP. Every gate and every executor
        // below reads these bindings; none of them goes back to the world.
        let snapshot = abilitySnapshot
        let signals = routedSignalSnapshot()
        let routing = abilityRoutingContext(snapshot: snapshot, signals: signals)
        let roster = rosterArbitration(
            snapshot: snapshot, context: routing, signals: signals)
        let operation = turnBindingOperation(forInvocation: name, snapshot: snapshot)
        let invokedRuntimeSkill = snapshot.skill(invocationName: name)
        // Exact name may stay exact without crossing applications.
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
            // Frozen provider from a lower rung wins; an exact call may not pick the rival.
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
        // Mismatch abstain — only the provider-neutral invocation is guarded.
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
        // Hard facts first, then the offer ledger — permission miss outranks "wasn't offered".
        if operation != Self.confirmSkillName,
           operation != Self.cancelSkillName,
           let invokedRuntimeSkill,
           let reason = dispatchEligibilityFailure(
               for: invokedRuntimeSkill,
               in: routing,
               snapshot: snapshot,
               signals: signals) {
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
            // Nothing happened, so there is nothing to recall.
            return SkillOutcome(
                ok: true, summary: "Okay, cancelled — nothing was changed.",
                status: .cancelled,
                archivePolicy: .none,
                skillReference: reference)
        default:
            break
        }

        // Schema-executed Skills have no Plugin binding — same eligibility, frozen snapshot.
        if let invokedRuntimeSkill {
            let arguments = Self.stringArguments(fromJSON: argumentsJSON)
            let policy = snapshot.executionPolicy(for: invokedRuntimeSkill.skill)
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
                return Self.applyingThreadArchivePolicy(
                    outcome,
                    reference: invokedRuntimeSkill.reference,
                    snapshot: snapshot)
            case .stateMachine:
                let outcome = await executeWorkflow(
                    runtime: invokedRuntimeSkill,
                    arguments: arguments,
                    snapshot: snapshot,
                    context: executionContext(),
                    routing: routing,
                    signals: signals)
                return Self.applyingThreadArchivePolicy(
                    outcome,
                    reference: invokedRuntimeSkill.reference,
                    snapshot: snapshot)
            case .binding:
                break
            }
        }

        // Exact name, else fuzzy within this turn's worlds. See `resolve`.
        guard var binding = resolve(skillName: operation)?.binding else {
            return SkillOutcome(ok: false, summary: "There is no command called \(name).")
        }
        let runtimeSkill = invokedRuntimeSkill
            ?? snapshot.skill(bindingOperation: binding.name)
        // Same two gates for a Skill reached by binding name or fuzzy match.
        if let runtimeSkill,
           let reason = dispatchEligibilityFailure(
               for: runtimeSkill,
               in: routing,
               snapshot: snapshot,
               signals: signals)
               ?? offerLedgerFailure(for: runtimeSkill, roster: roster) {
            return blockedOutcome(runtime: runtimeSkill, reason: reason)
        }
        if let schemaSkill = runtimeSkill?.skill {
            // Portable policy may tighten a local operation, never loosen it.
            if schemaSkill.access == .confirm { binding.access = .write }
            binding.stage = binding.stage || schemaSkill.usesStage
        }
        let reference = runtimeSkill?.reference
            ?? snapshot.reference(forInvocation: binding.name)

        // Native mismatch mirror — abstain when every asserted app is one they cannot serve.
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
        // A STRUCTURED VALUE THE PERSON SAID, WHEN THE CALLER SENT NONE.
        //
        // PIN: THE REPAIR BONNIE HAD PER-ADAPTER, GENERALISED ONCE. Its music
        // plugin resolved a missing or garbled `action` out of the raw utterance
        // through a hand-written synonym table, which meant every OTHER platform's
        // enum had no such rescue — Mary's `control_playback` inherited the enum
        // and not the repair, so a small model omitting `action` failed the turn
        // outright ("I don't know how to do that to the music"). Here the words
        // come from the package's own `spokenValues`, so every enum in every
        // world gets the same treatment and no Swift file learns a verb.
        // REPAIR, NEVER OVERRIDE: a value already in the enum is left alone.
        arguments = SpokenEnumExtractor.repaired(
            arguments,
            parameters: Self.enumParameters(
                binding: binding, declared: runtimeSkill),
            utterance: world.store.utterance())
        // A SKILL IS NEVER POINTED AT ITS OWN HOST. `window-management` answers
        // to "window" as an application alias, so "bring a TextEdit window
        // forward" named window-management itself as the app, and the adapter
        // went looking for a process by that name. Dropped here, for both
        // lanes, so the resolution below gets its turn.
        if let runtimeSkill,
           let receiver = ApplicationParameterNames.receiver(
               in: binding.parameters.map(\.name)),
           let named = arguments[receiver],
           Self.namesOwnHost(named, ability: runtimeSkill.ability.id) {
            arguments[receiver] = nil
            Self.timingLog.info(
                "own host — dropped \(named, privacy: .public) from \(receiver, privacy: .public)")
        }
        // THE SILENCE THIS FILLS: "pause the music" names no player, and a
        // discipline's Skill has no application of its own. When something
        // inherits that discipline, the person's own habit says which one they
        // mean — so they never have to say "in Apple Music" again, and when
        // they move to another player the ranking follows them.
        //
        // ONLY THE SILENCE. A named app arrives via the provider ladder's
        // decisive rung and wins there; a model that filled the parameter
        // itself is left alone.
        //
        // WHICHEVER PARAMETER TAKES ONE, NOT ALWAYS `app`. This seam is the
        // FOURTH place that had to agree on that list, and it was the one still
        // hardcoding a single spelling — so a Skill saying `app_name` had the
        // whole resolution computed and dropped. `ApplicationParameterNames`
        // exists precisely so the four cannot drift again.
        if let runtimeSkill,
           let receiver = ApplicationParameterNames.receiver(
               in: binding.parameters.map(\.name)),
           (arguments[receiver] ?? "").isEmpty {
            let asserted = turnProviderSelection(snapshot: snapshot)
                .decisiveApplicationIDs
            let utterance = world.store.utterance()
            // A PROVEN STAGING IS AN ASSERTION, and it outranks a habit for the
            // same reason words do: it is a fact about THIS turn, not a tally
            // over past ones.
            //
            // MEASURED, and it is why the staging existed and did nothing.
            // `type_at_cursor` documents "omit `app` to type into the
            // just-opened document" — but a discipline's Skill with an empty
            // `app` reaches `ExpertiseResolution`, which is non-nil whenever
            // the discipline has ANY dependent, so an omitted `app` came back
            // filled with `pages` at standing `staticPreference`: a cold-start
            // default, never a decision. The typer resolves a NAMED application
            // before it ever looks at the stage, so the window Mary had just
            // opened and staged lost to a package's declared preference, and
            // the documented contract could not once be honoured.
            //
            // An id outside this discipline's own candidates is ignored by the
            // resolver, so a staged editor cannot speak for a music turn.
            //
            // IT REACHES THE HABIT TIER ONLY, and that boundary is the point.
            // `ApplicationReferenceResolution`'s first tier means one thing —
            // THE WORDS NAMED EXACTLY ONE — and a staged surface is not words.
            // Injecting it there would turn a sentence that plainly names
            // Safari into two "named" candidates, collapsing a certain answer
            // into a distance judgement. `ExpertiseResolution`'s asserted tier
            // means "the turn established this", which a proven staging is.
            var assertedWithStaging = asserted
            if let staged = StagedWritingSurface.shared.fresh(),
               let stagedApplicationID = snapshot.applicationID(
                   forBundleIdentifier: staged.bundleID) {
                assertedWithStaging.insert(stagedApplicationID)
            }
            // WORDS FIRST, HABIT SECOND — and until now the words never got a
            // turn here at all.
            //
            // `ApplicationReferenceResolution` ranks the applications a Skill
            // declared it can be POINTED AT, by what this sentence actually
            // says. Its only caller was the confidence lane, which requires a
            // dispatchable `confidenceShape` — and that is nil for any Skill
            // whose one required string `requiresComposition`. So the reverse
            // lookup could never run for `type_at_cursor`, whose text only a
            // model round can produce and whose application is exactly the
            // thing that model should not have to guess. The resolver ran only
            // where the model was absent, and was missing wherever it was not.
            //
            // Habit is the fallback and not the lead, which is what both
            // resolvers' own PINs already claim: naming an application is an
            // instruction, distance answers when nothing was named, and a
            // habit only fills a silence neither of them broke.
            let byWords = runtimeSkill.skill.requirements.resolvesApplication
                ? ApplicationReferenceResolution.resolve(
                    for: runtimeSkill,
                    snapshot: snapshot,
                    utterance: utterance,
                    assertedApplicationIDs: asserted)
                : nil
            if let chosen = byWords?.chosen {
                arguments[receiver] = chosen.applicationID
                Self.timingLog.info(
                    "reference — host=\(runtimeSkill.ability.id.rawValue, privacy: .public) chose=\(chosen.applicationID, privacy: .public) standing=\(chosen.standing.rawValue, privacy: .public) into=\(receiver, privacy: .public)")
            } else if let verdict = ExpertiseResolution.resolve(
                for: runtimeSkill,
                snapshot: snapshot,
                assertedApplicationIDs: assertedWithStaging,
                // So a shared word like "music" cannot count as naming a
                // player — see `assertionIsOnlyDisciplineVocabulary`.
                utterance: utterance,
                ledger: applicationHabitLedger.withLock { $0 }),
                let chosen = verdict.chosen {
                arguments[receiver] = chosen.applicationID
                Self.timingLog.info(
                    "expertise — discipline=\(verdict.disciplineID.rawValue, privacy: .public) chose=\(chosen.applicationID, privacy: .public) standing=\(chosen.standing.rawValue, privacy: .public) into=\(receiver, privacy: .public)")
            }
        }
        // A PROCESS IS NAMED BY ITS BUNDLE, NOT BY ITS PACKAGE.
        //
        // Both lanes hand a system-control Skill the LOGICAL id the roster
        // knows an application by (`chrome`, `apple-music`), or the model's own
        // spelling of it ("Apple Music"). The window manager acts on a macOS
        // process, and its cold-launch path is `open -a <name>`, which finds
        // `Music.app` from neither — so "open Apple Music" with the player
        // closed resolved perfectly and launched nothing. The package already
        // carries the join, and this is the one seam both lanes pass through.
        //
        // SYSTEM CONTROL ONLY. A discipline's receiver (`type_at_cursor`'s
        // `app`) is read against the roster by logical id. A name no installed
        // expertise claims ("Calculator") passes through untouched, and the
        // adapter resolves it by name exactly as it always did.
        if let runtimeSkill,
           runtimeSkill.skill.requirements.resolvesApplication,
           snapshot.paradigm(of: runtimeSkill.ability.id) == .systemControl,
           let receiver = ApplicationParameterNames.receiver(
               in: binding.parameters.map(\.name)),
           let named = arguments[receiver], !named.isEmpty,
           let bundleID = snapshot.bundleIdentifier(ofApplication: named) {
            arguments[receiver] = bundleID
            Self.timingLog.info(
                "launch identity — \(named, privacy: .public) -> \(bundleID, privacy: .public) into=\(receiver, privacy: .public)")
        }
        // `type_at_cursor` covers compose and replace-selection — requirement is conditional.
        if binding.name == "type_at_cursor",
           arguments["mode"] == "replace_selection",
           world.store.routedSelectionHandoff(
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
                // Question alone — "nothing has happened yet" is prompt guidance, not tool text.
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
}
