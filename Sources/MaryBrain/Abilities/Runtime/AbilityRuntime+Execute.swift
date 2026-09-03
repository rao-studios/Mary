//
//  AbilityRuntime+Execute.swift
//  MaryBrain
//
//  WHAT: Running one binding, and the payload bounds around it.
//  IN:   a resolved SkillBinding + its execution context
//  OUT:  SkillOutcome; a successful read becomes an ambient fact
//  PIN:  Direct path and confirmed replay funnel here — one log row per real
//        binding run. A caret write is bracketed so live handles re-aim.
//
import Foundation

extension AbilityRuntime {

    // MARK: - Skill execution

    /// Direct path and confirmed replay funnel here — one log row per real binding run.
    func execute(
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
        // Bracket before the write — refresh assumes one contiguous caret insertion.
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

    /// Canonical machine payload measured at the last boundary before an adapter or cognitive primitive can observe it.
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

    func payloadFailure(
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

    func enforceOutputPayload(
        _ outcome: SkillOutcome,
        runtime: AbilityRuntimeSkill,
        policy: CapabilityExecutionPolicy
    ) -> SkillOutcome {
        enforceOutputPayload(
            outcome,
            reference: runtime.reference,
            policy: policy)
    }

    func enforceOutputPayload(
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

    /// Caret write in flight: world it lands in, and the body one instant before.
    private struct UnroutedWriteBracket {
        let backing: PassageBacking
        let before: BodySnapshot
    }

    /// Before-body for an unrouted write, or nil when nothing here is worth protecting.
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

    /// Re-aim handles after an unrouted write shifted the body under them.
    private func refreshPassages(after bracket: UnroutedWriteBracket) async {
        guard let after = await bracket.backing.body(),
              after.hash != bracket.before.hash else { return }
        // Injected stores — `PassageRefresh.after` reports the count.
        _ = PassageRefresh.after(
            before: bracket.before, after: after, place: bracket.backing.place,
            registry: passages, ambient: world.store)
    }

    /// A successful read becomes an ambient fact. Gates here are existing doctrine.
    private func registerRead(
        binding: SkillBinding, owner: String,
        arguments: [String: String], outcome: SkillOutcome
    ) {
        guard binding.access == .read, outcome.ok, !outcome.deferred, !outcome.foundNothing,
              // Adapter already filed a richer fact — skip a duplicate generic one.
              !outcome.ambientDeposited,
              let place = placeOfRead(outcome: outcome, owner: owner),
              let fact = AmbientBridge.readFact(
                attention: place.attention,
                application: place.application,
                phrase: readPhrase(binding: binding, owner: owner, arguments: arguments),
                summary: outcome.summary,
                document: documentOfRead(outcome: outcome),
                passageHandle: outcome.passageHandle)
        else { return }
        world.store.register(fact)
        if case .namedRead(let document, _) = fact.slot,
           let document,
           !document.isEmpty {
            // By place, not world — registered-app reads stamp `other_apps:<id>`.
            containers.noteEvidence(
                place: fact.place,
                key: document,
                .read,
                at: fact.capturedAt)
        }
    }

    /// Document a read's fact is about — from the minted passage, else nil.
    private func documentOfRead(outcome: SkillOutcome) -> String? {
        guard let handle = outcome.passageHandle,
              case .live(let passage) = passages.resolve(handle)
        else { return nil }
        return passage.documentKey
    }

    /// Place a read's fact belongs to — minted passage, else the owning plugin.
    /// PIN: Reads place off the registry, not the binding.
    private func placeOfRead(
        outcome: SkillOutcome, owner: String
    ) -> AmbientPlace? {
        if let handle = outcome.passageHandle,
           case .live(let passage) = passages.resolve(handle) {
            return passage.place
        }
        return place(ofOwner: owner)
    }

    /// Phrase the read targeted — slot key so a re-read supersedes.
    private func readPhrase(
        binding: SkillBinding, owner: String, arguments: [String: String]
    ) -> String {
        if let parameter = targetedReads[owner]?.parameter,
           let value = arguments[parameter]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        // No key sniffing — used to guess the phrase from document/file/title args.
        return binding.name
    }

    private func ownerID(bindingName: String) -> String {
        let owner = attributed.first { $0.binding.name == bindingName }?.owner ?? ""
        return owner.isEmpty ? "mac" : owner
    }
}
