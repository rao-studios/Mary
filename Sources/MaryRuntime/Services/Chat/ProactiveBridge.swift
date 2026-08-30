//
//  ProactiveBridge.swift
//  MaryRuntime
//
//  WHAT: Proactive channel's app-side consumer — id-anchored Kinds into MirrorVoice.
//  IN:   HomeSessionView boot (loop lives for the app)
//  OUT:  ChatService.mirrorVoice; FollowUpSpeech when no voice session
//  PIN:  Voice playback stays the pipeline's job (single-driver).
//

import MaryBrain
import MaryVoice
import Foundation

/// Per-origin follow-up narration. Sequential routines stack with "\n\n"
/// — same join as mergeFollowUpIntoHistory.
package struct FollowUpComposer {
    /// Per-origin finalized narration — earlier routines' paragraphs.
    private var committed: [UUID: String] = [:]
    /// Per-origin in-flight accumulation.
    private var open: [UUID: String] = [:]
    /// The standalone notice's accumulation (no origin — each notice is its
    /// own bubble, so nothing stacks).
    private var openNotice = ""

    package init() {}

    package mutating func token(_ token: String, origin: UUID?) -> String {
        guard let origin else {
            openNotice += token
            return openNotice
        }
        let accumulated = (open[origin] ?? "") + token
        open[origin] = accumulated
        return joined(committed[origin], accumulated)
    }

    package mutating func completed(_ fullText: String, origin: UUID?) -> String {
        guard let origin else {
            let text = fullText.isEmpty ? openNotice : fullText
            openNotice = ""
            return text
        }
        let streamed = open.removeValue(forKey: origin) ?? ""
        let final = fullText.isEmpty ? streamed : fullText
        // Identical paragraphs under one origin stack as one.
        if let existing = committed[origin],
           existing.components(separatedBy: "\n\n").contains(final) {
            return existing
        }
        let result = joined(committed[origin], final)
        if !result.isEmpty { committed[origin] = result }
        return result
    }

    /// Cancelled routine: clear `open` only. `committed` keeps finished paragraphs.
    package mutating func cancelled(origin: UUID) {
        open[origin] = nil
    }

    private func joined(_ committed: String?, _ tail: String) -> String {
        guard let committed, !committed.isEmpty else { return tail }
        guard !tail.isEmpty else { return committed }
        return committed + "\n\n" + tail
    }
}

package enum ProactiveBridge {
    /// One subscription. SwiftUI re-runs .task on window reappearance — do not double.
    @MainActor private static var live: Task<Void, Never>?

    /// Subscribe to the brain's proactive channel and forward every event to
    /// the single writer as an id-anchored Kind. Idempotent — a repeat call
    /// returns the existing loop.
    @discardableResult
    @MainActor
    package static func start(
        mirror: @escaping @Sendable (ChatService.MirrorVoice.Meta.Kind) -> Void
    ) -> Task<Void, Never> {
        if let live { return live }
        let task = Task {
            var composer = FollowUpComposer()
            for await event in MaryRuntime.brain.proactiveEvents() {
                switch event {
                case .routineStarted(let routineID, let label, let origin):
                    mirror(.routineStarted(
                        routineID: routineID, label: label, originTurnID: origin))

                case .skillInvocation(let reference, let argumentsJSON, let runID, let origin):
                    // Progress chip onto the routine's ORIGINATING bubble.
                    mirror(.proactiveAbilityBadge(reference: reference, turnID: origin))
                    mirror(.abilityRunStarted(
                        .requested(
                            id: runID,
                            action: BehavioralAction(
                                intention: reference.invocationName,
                                argumentsJSON: argumentsJSON,
                                skill: reference)),
                        turnID: origin))

                case .skillResult(let record, let origin):
                    // The raw machine summary lives on the run row (the chip
                    // modal) — settled routines no longer narrate it.
                    mirror(.abilityRunResult(record: record, turnID: origin))

                case .followUpToken(let token, let origin):
                    mirror(.followUpChanged(
                        turnID: origin,
                        text: composer.token(token, origin: origin),
                        isFinal: false))

                case .followUpCompleted(let fullText, let origin):
                    mirror(.followUpChanged(
                        turnID: origin,
                        text: composer.completed(fullText, origin: origin),
                        isFinal: true))
                    // Text mode speaks through FollowUpSpeech. Await enqueue (not spawn).
                    if !fullText.isEmpty {
                        await FollowUpSpeech.shared.enqueue(fullText, origin: origin)
                    }

                case .routineProgress(let line, let origin):
                    // Progress notice: set followUpText (not append), uncommitted — result overwrites it.
                    mirror(.followUpChanged(turnID: origin, text: line, isFinal: false))
                    // Text mode: FollowUpSpeech.Delivery.progress. Voice session: pipeline plays it.
                    await FollowUpSpeech.shared.enqueue(line, origin: origin, as: .progress)

                case .routineCancelled(let routineID, _, let origin):
                    // The stop turn already spoke and mirrored its ack —
                    // this is chip + origin bookkeeping only. The partial
                    // narration dies with the routine (see `cancelled`).
                    composer.cancelled(origin: origin)
                    mirror(.routineEnded(routineID: routineID, originTurnID: origin))

                case .routineSettled(let routineID, let origin):
                    // One routine fully done (speech included — settle fires
                    // after the serialized follow-up).
                    mirror(.routineEnded(routineID: routineID, originTurnID: origin))

                case .ambientUtterance(let line, let candidateID):
                    // Standalone trailing bubble (by id). Not through composer — nil-origin shares one accumulator.
                    mirror(.followUpChanged(turnID: nil, text: line, isFinal: true))
                    await FollowUpSpeech.shared.enqueue(
                        line, origin: nil, as: .ambient(candidateID))

                case .autoMemoryTriggered:
                    // Collapse through the same Kind as the turn-side path.
                    mirror(.autoMemoryTriggered)
                }
            }
        }
        live = task
        return task
    }
}
