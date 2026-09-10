//
//  MaryBrain+Lanes.swift
//  MaryBrain
//
//  WHAT: Three lane runners — classic Sewn, realtime Sewn, silent orchestrator.
//  IN:   sewnTurn / localTurn
//  OUT:  LaneOutcome + OrchestratorLaneResult
//
import MaryVoice
import Foundation
import os

extension MaryBrain {

    // internal for file split — treat as private
    func runSewnLane(
        sewnChat: any SewnChatProviding,
        messages: [SewnChatMessage],
        instructions: String,
        /// Stage-0 observation only (precedent: `runOrchestratorLane`'s
        /// `traceID`): which `RetrievalTraceLedger` row this lane's scope and
        /// contribution belong to. Nil books nothing.
        exchangeID: UUID? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation
    ) async -> SewnLaneResult {
        var result = SewnLaneResult()
        do {
            let events = sewnChat.stream(messages: messages, instructions: instructions)
            for try await event in events {
                if Task.isCancelled { break }
                switch event {
                case .token(let token):
                    result.text += token
                    continuation.yield(.token(token))
                case .scoped(let request):
                    if let exchangeID {
                        wiring.retrieval.noteSewnRequest(
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

    /// Lane A over the realtime WebSocket route: tokens become transcript events, PCM chunks feed the speaker directly
    /// Fallback rules (pinned by DualLaneTests): 1.
    // internal for file split — treat as private
    func runRealtimeSewnLane(
        realtime: any SewnRealtimeProviding,
        messages: [SewnChatMessage],
        instructions: String,
        /// Stage-0 observation only (precedent: `runOrchestratorLane`'s
        /// `traceID`): which `RetrievalTraceLedger` row this lane's scope and
        /// contribution belong to. Nil books nothing.
        exchangeID: UUID? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation
    ) async -> (result: SewnLaneResult, serverVoiced: Bool, fellBackPreStream: Bool) {
        var result = SewnLaneResult()
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
                // Content-vs-bookkeeping is classified ON THE EVENT (`SewnChatEvent.forwardsContent`), never per arm here: `forwardedAny` is rule 2's discriminator
                if event.forwardsContent { markForwarding() }
                switch event {
                case .token(let token):
                    result.text += token
                    continuation.yield(.token(token))
                case .audio(let pcm, let sampleRate):
                    continuation.yield(.audioChunk(pcm: pcm, sampleRate: sampleRate))
                case .scoped(let request):
                    // MUST NOT count as forwarded content — the client yields `.scoped` before it even connects, so counting it would make every pre-stream failure look mid-turn.
                    if let exchangeID {
                        wiring.retrieval.noteSewnRequest(
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
