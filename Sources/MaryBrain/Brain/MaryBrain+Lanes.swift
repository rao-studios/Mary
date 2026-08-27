//
//  MaryBrain+Lanes.swift
//  MaryBrain
//
//  The three lane runners, moved out of MaryBrain.swift: `runSeerLane`
//  (classic Lane A), `runRealtimeSeerLane` (WebSocket Lane A), and
//  `runOrchestratorLane` (Lane B, the silent Skill loop), plus
//  `selectionInvocation`.
//
//  Moved verbatim; no behavior change. Depends on the internal-for-split
//  promotions of the core file's stored lane state (engineGate, engine,
//  dispatcher, maxSkillRounds…); treat all of them as private.
//

import MaryVoice
import Foundation
import os

extension MaryBrain {

    // internal for file split — treat as private
    func runSeerLane(
        seerChat: any SeerChatProviding,
        messages: [SeerChatMessage],
        instructions: String,
        /// Stage-0 observation only (precedent: `runOrchestratorLane`'s
        /// `traceID`): which `RetrievalTraceLedger` row this lane's scope and
        /// contribution belong to. Nil books nothing.
        exchangeID: UUID? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation
    ) async -> SeerLaneResult {
        var result = SeerLaneResult()
        do {
            let events = seerChat.stream(messages: messages, instructions: instructions)
            for try await event in events {
                if Task.isCancelled { break }
                switch event {
                case .token(let token):
                    result.text += token
                    continuation.yield(.token(token))
                case .scoped(let request):
                    if let exchangeID {
                        wiring.retrieval.noteSeerRequest(
                            request, forExchange: exchangeID)
                    }
                case .contribution(let contribution):
                    if result.contribution == nil { result.contribution = contribution }
                    // The ledger pairs it with the row's last-booked request
                    // itself — the rule lives beside the row, not in a
                    // hand-carried lane local.
                    if let exchangeID {
                        wiring.retrieval.noteContribution(
                            .init(contribution),
                            forExchange: exchangeID)
                    }
                case .autoMemory(let flag):
                    result.autoMemory = result.autoMemory || flag
                case .phase, .audio, .ttsFailed:
                    break   // realtime-route events; the classic client never emits them
                }
            }
        } catch {
            result.failed = true
        }
        return result
    }

    /// Lane A over the realtime WebSocket route: tokens become transcript
    /// events, PCM chunks feed the speaker directly, and `.speechSource`
    /// markers steer who voices what.
    ///
    /// Fallback rules (pinned by DualLaneTests):
    /// 1. Not ready → caller never invokes this lane.
    /// 2. Failure BEFORE any forwarded event → `fellBackPreStream` and the
    ///    caller reruns the classic lane, indistinguishably.
    /// 3. Failure mid-turn → `.speechSource(.local)` is emitted, received
    ///    text is kept, and the lane reports `failed` so the standard
    ///    dropped-connection notice speaks locally.
    /// 4. After a server-voiced lane, the caller emits `.speechSource(.local)`
    ///    before any post-lane deterministic prose (CONFIRM, fallbacks).
    // internal for file split — treat as private
    func runRealtimeSeerLane(
        realtime: any SeerRealtimeProviding,
        messages: [SeerChatMessage],
        instructions: String,
        /// Stage-0 observation only (precedent: `runOrchestratorLane`'s
        /// `traceID`): which `RetrievalTraceLedger` row this lane's scope and
        /// contribution belong to. Nil books nothing.
        exchangeID: UUID? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation
    ) async -> (result: SeerLaneResult, serverVoiced: Bool, fellBackPreStream: Bool) {
        var result = SeerLaneResult()
        var forwardedAny = false
        var serverVoiced = false

        func markForwarding() {
            guard !forwardedAny else { return }
            forwardedAny = true
            serverVoiced = true
            continuation.yield(.speechSource(.server))
        }

        do {
            let events = realtime.streamTurn(messages: messages, instructions: instructions)
            for try await event in events {
                if Task.isCancelled { break }
                // Content-vs-bookkeeping is classified ON THE EVENT
                // (`SeerChatEvent.forwardsContent`), never per arm here:
                // `forwardedAny` is rule 2's discriminator, and one future
                // case left unclassified would silently disable the
                // invisible classic rerun.
                if event.forwardsContent { markForwarding() }
                switch event {
                case .token(let token):
                    result.text += token
                    continuation.yield(.token(token))
                case .audio(let pcm, let sampleRate):
                    continuation.yield(.audioChunk(pcm: pcm, sampleRate: sampleRate))
                case .scoped(let request):
                    // MUST NOT count as forwarded content — the client yields
                    // `.scoped` before it even connects, so counting it would
                    // make every pre-stream failure look mid-turn. Enforced
                    // by `SeerChatEvent.forwardsContent`, beside the cases.
                    if let exchangeID {
                        wiring.retrieval.noteSeerRequest(
                            request, forExchange: exchangeID)
                    }
                case .phase:
                    break
                case .ttsFailed:
                    // Server audio stopped; hand the rest to the local voice.
                    if serverVoiced {
                        serverVoiced = false
                        continuation.yield(.speechSource(.local))
                    }
                case .contribution(let contribution):
                    if result.contribution == nil { result.contribution = contribution }
                    // The ledger pairs it with the row's last-booked request
                    // itself — see `noteContribution`.
                    if let exchangeID {
                        wiring.retrieval.noteContribution(
                            .init(contribution),
                            forExchange: exchangeID)
                    }
                case .autoMemory(let flag):
                    result.autoMemory = result.autoMemory || flag
                }
            }
        } catch {
            guard forwardedAny else {
                return (result, false, true)
            }
            if serverVoiced {
                serverVoiced = false
                continuation.yield(.speechSource(.local))
            }
            result.failed = true
        }
        return (result, serverVoiced, false)
    }

}
