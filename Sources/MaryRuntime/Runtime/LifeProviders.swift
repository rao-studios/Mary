//
//  LifeProviders.swift
//  MaryRuntime
//
//  WHAT: The three seams MaryLifeEngine is built on, filled in with Mary's
//        real world: Fleet's adapters, the machine's quiet, the lead place.
//  IN:   FleetDirectClient / brain / AmbientContextStore
//  OUT:  MaryLifeEngine
//  PIN:  The engine never dials Fleet or reads AppKit. These do.
//
import AppKit
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryThread
import os

/// Ready adapters, dialed from Fleet and cached so a monitor can read them
/// without a round trip.
package actor LifeSlotProvider: LifeSlotProviding {

    private var cached: [AbilityID: LifeLoRASlot] = [:]
    private var reachable = true
    private let log = Logger(subsystem: "nyc.rao.mary", category: "life")

    package init() {}

    package func adapters() async -> (slots: [AbilityID: LifeLoRASlot], reachable: Bool) {
        await refresh()
        return (cached, reachable)
    }

    /// Last known, without dialing. The Life sheet polls this.
    package func lastKnown() -> (slots: [AbilityID: LifeLoRASlot], reachable: Bool) {
        (cached, reachable)
    }

    @discardableResult
    package func refresh() async -> Bool {
        let threadID = MaryRuntime.threadNodeIDBox.withLock { $0 }
        guard !threadID.isEmpty else { return reachable }
        do {
            let slots = try await MaryRuntime.makeFleetClient().listAdapters(threadID: threadID)
            // uniquingKeysWith, NOT uniqueKeysWithValues: two rows for one
            // ability is a Fleet-side bug, and trapping the whole app over it
            // is the wrong way to report it.
            cached = Dictionary(
                slots.map { slot -> (AbilityID, LifeLoRASlot) in
                    let id = AbilityID(slot.abilityID)
                    return (id, LifeLoRASlot(
                        abilityID: id,
                        generation: slot.generation,
                        pairCount: slot.pairCount,
                        artifactPath: slot.artifactPath,
                        schemaJSON: slot.schemaJSON,
                        ready: slot.ready,
                        trainedAt: slot.trainedAt,
                        training: slot.training,
                        modelID: slot.modelID,
                        cid: slot.cid))
                },
                uniquingKeysWith: { _, newer in newer })
            reachable = true
        } catch {
            reachable = false
            log.debug("listAdapters: \(error.localizedDescription, privacy: .public)")
        }
        return reachable
    }
}

/// Everything the gates ask about the world that the engine cannot see.
package struct LifeConditionsProvider: LifeConditionsProviding {

    package init() {}

    package func conditions() async -> LifeConditions {
        LifeConditions(
            isTurnInFlight: await MaryRuntime.brain.hasOpenTurn,
            isSkillRunning: await MaryRuntime.brain.isBusy,
            isWorkspaceIndexing: await MaryRuntime.unitIndexer.hasPendingIdle,
            lastUserEpisodeAt: MaryRuntime.lastUserEpisodeAtBox.withLock { $0 },
            secondsSinceUserInput: Self.secondsSinceUserInput(),
            now: Date())
    }

    /// Seconds since the last keyboard or mouse event anywhere in the session.
    /// A CONVERSATION PAUSE IS NOT AN IDLE MACHINE: without this, "quiet"
    /// means only that Mary was not spoken to, and the idle engine acts into
    /// a window someone is typing in. Nil when the source is unavailable —
    /// the gate then reports what it knows rather than inventing quiet.
    package static func secondsSinceUserInput() -> TimeInterval? {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel,
        ]
        return types
            .map {
                CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState, eventType: $0)
            }
            .min()
    }
}

/// The quiet world as a training-shaped input, plus what the lead place can do.
///
/// PIN: The input is built through `MaryRuntime.behavioralCapture` — the same
/// function that stages a real turn's capture — and then projected with the
/// same `BehavioralTrainingInput(input:)` the training pair uses. That is the
/// whole point of this type: the adapter must see, at rest, the shape of
/// input it was taught on.
package struct LifeWorldProvider: LifeWorldProviding {

    /// What an idle pulse asks. A CONSTANT, not a sentence about the lead:
    /// the place is already carried by `ambient_lead`, and a query that
    /// changes with the app name is a second, noisier encoding of it.
    package static let idleQuery = "idle"

    package init() {}

    package func pulseWorld() async -> LifeWorld? {
        guard let build = MaryRuntime.lifeWorldBox.withLock({ $0 }) else { return nil }
        return build(Date())
    }

    /// Disciplines the lead application declares, sorted for a stable choice.
    package static func disciplines(
        lead: AmbientPlace,
        profiles: [ApplicationProfile],
        abilities: any AbilityCapabilityIndex = AmbientCapabilityIndexProvider.current
    ) -> [AbilityID] {
        guard let leadID = lead.application,
              let profile = profiles.first(where: { $0.id == leadID })
        else { return [] }
        return profile.abilities
            .filter { (abilities.paradigm(of: $0) ?? .discipline) == .discipline }
            .sorted { $0.rawValue < $1.rawValue }
    }
}
