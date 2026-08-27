import MaryFoundation
import Foundation
import os

/// Process-wide ingress for schema-typed environmental data. An installed
/// adapter must first advertise the schema ID in its manifest. Publishing then
/// validates the Value, provenance, scope, privacy, and evidence before the
/// instance is eligible for a turn.
public final class SchemaSignalRuntime: @unchecked Sendable {
    public static let shared = SchemaSignalRuntime()
    private static let ambientSelectionAdapterID = AdapterID("mary.ambient-selection")

    private struct State {
        var interactions: [UUID: RuntimeInteractionInstance] = [:]
        var perceptions: [String: RuntimePerceptionInstance] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    @discardableResult
    public func publishInteraction(
        schemaID: InteractionID,
        value incoming: ValueEnvelope,
        evidenceChannel: String,
        adapterID: AdapterID,
        registry: AbilityRuntimeSnapshot? = nil,
        now: Date = Date()
    ) throws -> RuntimeInteractionInstance {
        let registry = registry ?? AbilityLibrary.shared.snapshotEnsuringLoaded()
        guard let schema = registry.interactionSchema(id: schemaID) else {
            throw SchemaSignalRuntimeError.unknownInteraction(schemaID)
        }
        let manifest = try availableManifest(adapterID, in: registry)
        guard manifest.providesInteractions.contains(schemaID) else {
            throw SchemaSignalRuntimeError.undeclaredInteraction(adapterID, schemaID)
        }
        guard incoming.typeID == schema.valueType else {
            throw SchemaSignalRuntimeError.wrongValueType(
                expected: schema.valueType,
                actual: incoming.typeID)
        }
        guard schema.requiredScope.contains(incoming.scope.resolution) else {
            throw SchemaSignalRuntimeError.invalidScope(incoming.scope.resolution)
        }
        switch schema.ownership {
        case .sourceOwned where incoming.scope.applicationID == nil:
            throw SchemaSignalRuntimeError.ownershipMismatch(schema.ownership)
        case .deviceOwned where incoming.scope.deviceID == nil:
            throw SchemaSignalRuntimeError.ownershipMismatch(schema.ownership)
        default:
            break
        }
        guard Self.privacyRank(incoming.privacy) >= Self.privacyRank(schema.privacy) else {
            throw SchemaSignalRuntimeError.privacyMismatch(
                required: schema.privacy,
                actual: incoming.privacy)
        }
        guard let evidence = schema.evidence.first(where: { $0.channel == evidenceChannel }) else {
            throw SchemaSignalRuntimeError.invalidEvidence(evidenceChannel)
        }

        var value = incoming
        value.provenance.adapterID = adapterID
        value.provenance.interactionID = schemaID
        // Freshness belongs to the observation, not to the time it happened to
        // reach Mary. Delayed/replayed adapter packets cannot mint a new TTL.
        let schemaExpiry = incoming.createdAt.addingTimeInterval(schema.freshnessSeconds)
        value.expiresAt = min(value.expiresAt ?? schemaExpiry, schemaExpiry)
        let validation = ValueEnvelopeValidator.validate(
            value,
            schemas: registry.valueTypeSchemas,
            at: now)
        guard validation.isValid else {
            throw SchemaSignalRuntimeError.invalidValue(validation.issues)
        }

        let reference = InteractionInstanceReference(
            id: value.id,
            schemaID: schemaID,
            scope: value.scope,
            capturedAt: value.createdAt,
            expiresAt: value.expiresAt,
            completeness: .complete,
            valueDigest: value.payloadDigest)
        let instance = RuntimeInteractionInstance(
            reference: reference,
            value: value,
            adapterID: adapterID,
            evidenceChannel: evidenceChannel,
            evidenceRank: evidence.rank,
            canAuthorizeMutation: evidence.canAuthorizeMutation)
        let replacementScope = value.scope

        state.withLock { state in
            prune(&state, registry: registry, at: now)
            if schema.clearPolicies.contains(.replacement) {
                let identity = supersessionIdentity(
                    for: replacementScope,
                    keys: schema.supersessionKeys)
                state.interactions = state.interactions.filter { _, existing in
                    guard existing.reference.schemaID == schemaID,
                          let existingSchema = registry.interactionSchema(id: schemaID)
                    else { return true }
                    return supersessionIdentity(
                        for: existing.reference.scope,
                        keys: existingSchema.supersessionKeys) != identity
                }
            }
            state.interactions[instance.id] = instance
        }
        return instance
    }

    @discardableResult
    public func publishPerception(
        schemaID: PerceptionID,
        value incoming: ValueEnvelope,
        adapterID: AdapterID,
        registry: AbilityRuntimeSnapshot? = nil,
        now: Date = Date()
    ) throws -> RuntimePerceptionInstance {
        let registry = registry ?? AbilityLibrary.shared.snapshotEnsuringLoaded()
        guard let schema = registry.perceptionSchema(id: schemaID) else {
            throw SchemaSignalRuntimeError.unknownPerception(schemaID)
        }
        let manifest = try availableManifest(adapterID, in: registry)
        guard manifest.providesPerceptions.contains(schemaID) else {
            throw SchemaSignalRuntimeError.undeclaredPerception(adapterID, schemaID)
        }
        guard incoming.typeID == schema.valueType else {
            throw SchemaSignalRuntimeError.wrongValueType(
                expected: schema.valueType,
                actual: incoming.typeID)
        }
        guard Self.privacyRank(incoming.privacy) >= Self.privacyRank(schema.privacy) else {
            throw SchemaSignalRuntimeError.privacyMismatch(
                required: schema.privacy,
                actual: incoming.privacy)
        }
        var value = incoming
        value.provenance.adapterID = adapterID
        value.provenance.perceptionID = schemaID
        // Perceptions are observations too: ingress latency never extends
        // their schema-owned validity window.
        let expiry = incoming.createdAt.addingTimeInterval(schema.freshnessSeconds)
        value.expiresAt = min(value.expiresAt ?? expiry, expiry)
        let validation = ValueEnvelopeValidator.validate(
            value,
            schemas: registry.valueTypeSchemas,
            at: now)
        guard validation.isValid else {
            throw SchemaSignalRuntimeError.invalidValue(validation.issues)
        }
        let reference = PerceptionInstanceReference(
            id: value.id,
            schemaID: schemaID,
            scope: value.scope,
            capturedAt: value.createdAt,
            expiresAt: value.expiresAt ?? expiry,
            valueDigest: value.payloadDigest)
        let instance = RuntimePerceptionInstance(
            reference: reference,
            value: value,
            adapterID: adapterID)
        let perceptionScope = value.scope
        state.withLock { state in
            prune(&state, registry: registry, at: now)
            state.perceptions[perceptionIdentity(schemaID, perceptionScope)] = instance
        }
        return instance
    }

    /// Reserves every one-turn Interaction for exactly this turn and returns a
    /// frozen copy. Reusable signals remain live until expiry/replacement.
    public func snapshotForTurn(
        registry: AbilityRuntimeSnapshot? = nil,
        at now: Date = Date()
    ) -> SchemaSignalTurnSnapshot {
        snapshotForTurn(
            registry: registry,
            ambientSelection: nil,
            at: now)
    }

    /// Mary's ambient selection handoff is the only non-adapter bridge into
    /// a turn. Accepting the source packet here, rather than accepting caller-
    /// constructed RuntimeInteractionInstances, keeps evidence rank and
    /// mutation authority behind this file's schema validator.
    func snapshotForTurn(
        registry: AbilityRuntimeSnapshot? = nil,
        ambientSelection: AmbientSelectionHandoff?,
        at now: Date = Date()
    ) -> SchemaSignalTurnSnapshot {
        let registry = registry ?? AbilityLibrary.shared.snapshotEnsuringLoaded()
        let bridgedInteraction = ambientSelection.flatMap {
            bridgeSelection($0, registry: registry, at: now)
        }.flatMap { instance in
            isValidInteractionInstance(
                instance,
                registry: registry,
                at: now,
                allowsAmbientBridge: true) ? instance : nil
        }
        return state.withLock { state in
            prune(&state, registry: registry, at: now)
            var interactions = Array(state.interactions.values)
            if let bridgedInteraction {
                interactions.removeAll { $0.id == bridgedInteraction.id }
                interactions.append(bridgedInteraction)
            }
            let claimed = Set(interactions.compactMap { instance -> UUID? in
                registry.interactionSchema(id: instance.reference.schemaID)?.claimPolicy == .oneTurn
                    ? instance.id : nil
            })
            for id in claimed { state.interactions.removeValue(forKey: id) }
            return SchemaSignalTurnSnapshot(
                interactions: interactions,
                perceptions: Array(state.perceptions.values))
        }
    }

    /// Adapts the existing source-owned selection packet into the generic
    /// schema signal path. This is deliberately a validator/normalizer, not a
    /// second selection store: AmbientContextStore remains responsible for AX
    /// capture and the one-turn handoff owns the resulting instance.
    func bridgeSelection(
        _ handoff: AmbientSelectionHandoff,
        registry: AbilityRuntimeSnapshot,
        at now: Date = Date()
    ) -> RuntimeInteractionInstance? {
        // CODE OR PROSE, from the declared discipline. A selection in an IDE
        // is a code selection because the package said the place codes, not
        // because a compiled enum named that application.
        let schemaID = handoff.place.focus == .coding
            ? InteractionID.codeSelection : .textSelection
        guard let schema = registry.interactionSchema(id: schemaID),
              schema.requiredScope.contains(handoff.scope.resolution),
              Self.ownershipMatches(schema.ownership, scope: handoff.scope),
              handoff.isFresh(at: now)
        else { return nil }

        let channel: String
        switch (handoff.place.focus, handoff.sourceEvidence, handoff.payloadRecovery) {
        case (_, _, .applicationBodyRange):
            channel = "application-body-range-hydration"
        case (_, _, .applicationCopy):
            channel = "application-copy-probe"
        case (.coding, .documentAtomic, nil):
            channel = "code-buffer-selection"
        case (_, .discoveredDescendant, nil):
            channel = "workspace-descendant-discovery"
        default:
            channel = "focused-accessibility-selection"
        }
        guard let evidence = schema.evidence.first(where: { $0.channel == channel }),
              let valueTypeVersion = registry.valueTypeSchema(id: schema.valueType)?.version,
              let value = selectionValue(
                handoff,
                schema: schema,
                valueTypeVersion: valueTypeVersion),
              ValueEnvelopeValidator.validate(
                value,
                schemas: registry.valueTypeSchemas,
                at: now).isValid
        else { return nil }

        let reference = InteractionInstanceReference(
            id: handoff.id,
            schemaID: schemaID,
            scope: handoff.scope,
            capturedAt: handoff.capturedAt,
            expiresAt: value.expiresAt,
            completeness: handoff.completeness,
            valueDigest: value.payloadDigest)
        return RuntimeInteractionInstance(
            reference: reference,
            value: value,
            adapterID: Self.ambientSelectionAdapterID,
            evidenceChannel: channel,
            evidenceRank: evidence.rank,
            // A clipped payload is a referent, never mutation authority.
            canAuthorizeMutation: evidence.canAuthorizeMutation
                && handoff.completeness == .complete)
    }

    public func clearInteraction(
        schemaID: InteractionID,
        scope: SourceScope,
        policy: InteractionClearPolicy,
        registry: AbilityRuntimeSnapshot? = nil
    ) throws {
        let registry = registry ?? AbilityLibrary.shared.snapshotEnsuringLoaded()
        guard let schema = registry.interactionSchema(id: schemaID) else {
            throw SchemaSignalRuntimeError.unknownInteraction(schemaID)
        }
        guard schema.clearPolicies.contains(policy) else {
            throw SchemaSignalRuntimeError.unsupportedClearPolicy(policy)
        }
        state.withLock { state in
            state.interactions = state.interactions.filter { _, instance in
                instance.reference.schemaID != schemaID
                    || !Self.sameSource(instance.reference.scope, scope)
            }
        }
    }

    public func clearSourceTerminated(
        _ scope: SourceScope,
        registry: AbilityRuntimeSnapshot? = nil
    ) {
        let registry = registry ?? AbilityLibrary.shared.snapshotEnsuringLoaded()
        state.withLock { state in
            state.interactions = state.interactions.filter { _, instance in
                guard registry.interactionSchema(id: instance.reference.schemaID)?
                    .clearPolicies.contains(.sourceTermination) == true
                else { return true }
                return !Self.sameSource(instance.reference.scope, scope)
            }
            state.perceptions = state.perceptions.filter { _, instance in
                !Self.sameSource(instance.reference.scope, scope)
            }
        }
    }

    public func removeAll() {
        state.withLock {
            $0.interactions.removeAll()
            $0.perceptions.removeAll()
        }
    }

    private func availableManifest(
        _ adapterID: AdapterID,
        in registry: AbilityRuntimeSnapshot
    ) throws -> InstalledAdapterManifest {
        guard let manifest = registry.adapterManifest(id: adapterID), manifest.isAvailable else {
            throw SchemaSignalRuntimeError.unavailableAdapter(adapterID)
        }
        return manifest
    }

    private func selectionValue(
        _ handoff: AmbientSelectionHandoff,
        schema: InteractionSchema,
        valueTypeVersion: SemanticVersion
    ) -> ValueEnvelope? {
        let payload: MaryValue
        if handoff.place.focus == .coding {
            guard let document = handoff.scope.documentID else { return nil }
            let language: String
            switch URL(fileURLWithPath: document).pathExtension.lowercased() {
            case "swift": language = "swift"
            case "m", "h": language = "objective-c"
            case "mm": language = "objective-c++"
            case "c": language = "c"
            case "cc", "cpp", "cxx", "hpp": language = "c++"
            default: language = "source"
            }
            var context: [String: MaryValue] = [
                "file": .string(document),
                "language": .string(language),
            ]
            if let project = handoff.scope.projectID ?? handoff.scope.workspaceID {
                context["project"] = .string(project)
            }
            payload = .object([
                "context": .object(context),
                "source": .string(handoff.text),
            ])
        } else {
            var object: [String: MaryValue] = [
                "text": .string(handoff.text),
                "application": .string(handoff.applicationID),
            ]
            if let range = handoff.typedRange, range.isValid {
                object["range"] = .object([
                    "lowerBound": .integer(Int64(range.lowerBound)),
                    "upperBound": .integer(Int64(range.upperBound)),
                    "coordinateSpace": .string(range.coordinateSpace.rawValue),
                ])
            }
            if let document = handoff.scope.documentID {
                object["document"] = .string(document)
            }
            payload = .object(object)
        }

        return ValueEnvelope(
            id: handoff.id,
            typeID: schema.valueType,
            schemaVersion: valueTypeVersion,
            value: payload,
            scope: handoff.scope,
            provenance: .init(
                adapterID: Self.ambientSelectionAdapterID,
                interactionID: schema.id),
            privacy: schema.privacy,
            createdAt: handoff.capturedAt,
            expiresAt: min(
                handoff.capturedAt.addingTimeInterval(schema.freshnessSeconds),
                handoff.capturedAt.addingTimeInterval(AmbientSelectionHandoff.handoffFreshFor)))
    }

    private func prune(
        _ state: inout State,
        registry: AbilityRuntimeSnapshot,
        at now: Date
    ) {
        state.interactions = state.interactions.filter { _, instance in
            isValidInteractionInstance(
                instance,
                registry: registry,
                at: now,
                allowsAmbientBridge: false)
        }
        state.perceptions = state.perceptions.filter { _, instance in
            isValidPerceptionInstance(instance, registry: registry, at: now)
        }
    }

    /// Revalidates every machine-derived field, not only the Value payload.
    /// This matters after live package activation: a new schema may lower an
    /// evidence channel's authority, strengthen privacy, or shorten freshness.
    private func isValidInteractionInstance(
        _ instance: RuntimeInteractionInstance,
        registry: AbilityRuntimeSnapshot,
        at now: Date,
        allowsAmbientBridge: Bool
    ) -> Bool {
        guard let schema = registry.interactionSchema(id: instance.reference.schemaID),
              let evidence = schema.evidence.first(where: {
                  $0.channel == instance.evidenceChannel
              }),
              instance.reference.completeness != .unavailable,
              instance.reference.id == instance.value.id,
              instance.reference.scope == instance.value.scope,
              instance.reference.capturedAt == instance.value.createdAt,
              instance.reference.expiresAt == instance.value.expiresAt,
              instance.reference.valueDigest == instance.value.payloadDigest,
              instance.value.provenance.adapterID == instance.adapterID,
              instance.value.provenance.interactionID == schema.id,
              schema.valueType == instance.value.typeID,
              registry.valueTypeSchema(id: schema.valueType)?.version
                == instance.value.schemaVersion,
              schema.requiredScope.contains(instance.value.scope.resolution),
              Self.ownershipMatches(schema.ownership, scope: instance.value.scope),
              Self.privacyRank(instance.value.privacy) >= Self.privacyRank(schema.privacy),
              instance.evidenceRank == evidence.rank,
              instance.canAuthorizeMutation
                == (evidence.canAuthorizeMutation
                    && instance.reference.completeness == .complete),
              let expiry = instance.value.expiresAt,
              expiry <= instance.value.createdAt.addingTimeInterval(
                  schema.freshnessSeconds),
              ValueEnvelopeValidator.validate(
                  instance.value,
                  schemas: registry.valueTypeSchemas,
                  at: now).isValid
        else { return false }

        if instance.adapterID == Self.ambientSelectionAdapterID {
            return allowsAmbientBridge
        }
        guard let manifest = registry.adapterManifest(id: instance.adapterID) else {
            return false
        }
        return manifest.isAvailable
            && manifest.providesInteractions.contains(schema.id)
    }

    private func isValidPerceptionInstance(
        _ instance: RuntimePerceptionInstance,
        registry: AbilityRuntimeSnapshot,
        at now: Date
    ) -> Bool {
        guard let schema = registry.perceptionSchema(id: instance.reference.schemaID),
              instance.reference.id == instance.value.id,
              instance.reference.scope == instance.value.scope,
              instance.reference.capturedAt == instance.value.createdAt,
              instance.reference.expiresAt == instance.value.expiresAt,
              instance.reference.valueDigest == instance.value.payloadDigest,
              instance.value.provenance.adapterID == instance.adapterID,
              instance.value.provenance.perceptionID == schema.id,
              schema.valueType == instance.value.typeID,
              registry.valueTypeSchema(id: schema.valueType)?.version
                == instance.value.schemaVersion,
              Self.privacyRank(instance.value.privacy) >= Self.privacyRank(schema.privacy),
              let expiry = instance.value.expiresAt,
              expiry <= instance.value.createdAt.addingTimeInterval(
                  schema.freshnessSeconds),
              let manifest = registry.adapterManifest(id: instance.adapterID),
              manifest.isAvailable,
              manifest.providesPerceptions.contains(schema.id),
              ValueEnvelopeValidator.validate(
                  instance.value,
                  schemas: registry.valueTypeSchemas,
                  at: now).isValid
        else { return false }
        return true
    }

    private static func ownershipMatches(
        _ ownership: InteractionOwnership,
        scope: SourceScope
    ) -> Bool {
        switch ownership {
        case .sourceOwned: return scope.applicationID != nil
        case .deviceOwned: return scope.deviceID != nil
        case .systemOwned: return true
        }
    }

    private static func privacyRank(_ privacy: DataPrivacyClass) -> Int {
        switch privacy {
        case .publicDefinition: return 0
        case .private: return 1
        case .sensitive: return 2
        case .secret: return 3
        }
    }

    private func supersessionIdentity(
        for scope: SourceScope,
        keys: [String]
    ) -> String {
        keys.map { key in "\(key)=\(scope.value(forSupersessionKey: key) ?? "-")" }
            .joined(separator: "|")
    }

    private func perceptionIdentity(_ id: PerceptionID, _ scope: SourceScope) -> String {
        [
            id.rawValue,
            scope.deviceID ?? "-",
            scope.applicationID ?? "-",
            scope.processEpoch ?? "-",
            scope.windowID ?? "-",
            scope.workspaceID ?? "-",
            scope.projectID ?? "-",
            scope.documentID ?? "-",
            scope.surfaceID ?? "-",
        ].joined(separator: "|")
    }

    private static func sameSource(_ lhs: SourceScope, _ rhs: SourceScope) -> Bool {
        if let device = rhs.deviceID, lhs.deviceID != device { return false }
        if let application = rhs.applicationID, lhs.applicationID != application { return false }
        if let process = rhs.processID, lhs.processID != process { return false }
        if let epoch = rhs.processEpoch, lhs.processEpoch != epoch { return false }
        if let window = rhs.windowID, lhs.windowID != window { return false }
        if let workspace = rhs.workspaceID, lhs.workspaceID != workspace { return false }
        if let project = rhs.projectID, lhs.projectID != project { return false }
        if let document = rhs.documentID, lhs.documentID != document { return false }
        if let surface = rhs.surfaceID, lhs.surfaceID != surface { return false }
        return true
    }
}

private extension SourceScope {
    func value(forSupersessionKey key: String) -> String? {
        switch key {
        case "deviceID": return deviceID
        case "applicationID": return applicationID
        case "processID": return processID.map(String.init)
        case "processEpoch": return processEpoch
        case "activationSequence": return activationSequence.map(String.init)
        case "windowID": return windowID
        case "workspaceID": return workspaceID
        case "projectID": return projectID
        case "documentID": return documentID
        case "surfaceID": return surfaceID
        default: return nil
        }
    }
}

private extension DataPrivacyClass {
    var rank: Int {
        switch self {
        case .publicDefinition: return 0
        case .private: return 1
        case .sensitive: return 2
        case .secret: return 3
        }
    }
}

extension CapabilityEffect {
    var isMutation: Bool {
        switch self {
        case .none, .read: return false
        case .reversibleMutation, .mutation, .externalCommunication, .destructive: return true
        }
    }
}
