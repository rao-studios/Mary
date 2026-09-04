//
//  SandBenchEngine.swift
//  Sand
//
//  WHAT: The model seat, with a person in it.
//  IN:   MaryBrain's generation round — system prompt, history, offered skills
//  OUT:  one skill invocation or one line of prose, chosen by hand
//  PIN:  THIS ENGINE DECIDES NOTHING ABOUT THE ROSTER. By the time `stream` is
//        called, the turn has already published the utterance, warmed its
//        vector, triaged it, resolved a route, projected a roster and armed the
//        offer ledger. The `skills` argument IS the turn's answer to "what may
//        be called" — this file forwards it untouched, because the moment it
//        filtered or reordered anything the bench would stop being evidence
//        about Mary and start being evidence about itself.
//        ONE ROUND AT A TIME. The brain runs rounds in a loop; a second round
//        arriving while one is parked answers the first with `.abandon` rather
//        than leaving a continuation to leak.
//
import Foundation
import MaryBrain
import MaryPlugin

/// One generation round, handed to the UI.
struct SandModelRound: Identifiable, Sendable {
    let id = UUID()
    let index: Int
    let system: String
    let history: [BrainTurn]
    /// Exactly the roster the model would see, in the order it would see it.
    let skills: [ModelSkillSchema]
}

/// What the person answers with.
enum SandModelAnswer: Sendable {
    case invoke(name: String, argumentsJSON: String)
    case say(String)
    /// The round is over without an answer — cancelled, superseded, or the
    /// window went away.
    case abandon
}

final class SandBenchEngine: InferenceEngine, @unchecked Sendable {

    let displayName = "Sand bench — you are the model"
    var choice: LLMEngineChoice { .local }

    /// Called on the main actor when the brain asks for a round.
    private let present: @MainActor @Sendable (SandModelRound) -> Void
    /// Called on the main actor when a round ends, so the pane can clear.
    private let dismiss: @MainActor @Sendable (UUID) -> Void

    private let lock = NSLock()
    private var parked: (id: UUID, continuation: CheckedContinuation<SandModelAnswer, Never>)?
    private var roundCount = 0

    init(
        present: @escaping @MainActor @Sendable (SandModelRound) -> Void,
        dismiss: @escaping @MainActor @Sendable (UUID) -> Void
    ) {
        self.present = present
        self.dismiss = dismiss
    }

    func warmup() async throws {}

    // MARK: - Answering from the UI

    /// Resume the parked round. Ignored when the id is stale — a click that
    /// arrives after the turn was cancelled must not answer the next round.
    func answer(_ answer: SandModelAnswer, for id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<SandModelAnswer, Never>? in
            guard let parked, parked.id == id else { return nil }
            let held = parked.continuation
            self.parked = nil
            return held
        }
        continuation?.resume(returning: answer)
    }

    /// Abandon whatever is parked. Called when the turn is cancelled.
    func abandonParkedRound() {
        let continuation = lock.withLock { () -> CheckedContinuation<SandModelAnswer, Never>? in
            let held = parked?.continuation
            parked = nil
            return held
        }
        continuation?.resume(returning: .abandon)
    }

    // MARK: - The round

    func stream(
        system: String, history: [BrainTurn], skills: [ModelSkillSchema]
    ) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let round = self.makeRound(system: system, history: history, skills: skills)
                await MainActor.run { self.present(round) }
                let answer = await self.park(round.id)
                await MainActor.run { self.dismiss(round.id) }
                switch answer {
                case .invoke(let name, let argumentsJSON):
                    continuation.yield(.skillInvocation(ModelSkillInvocation(
                        id: UUID().uuidString, name: name, argumentsJSON: argumentsJSON)))
                    continuation.yield(.done)
                    continuation.finish()
                case .say(let text):
                    if !text.isEmpty { continuation.yield(.text(text)) }
                    continuation.yield(.done)
                    continuation.finish()
                case .abandon:
                    continuation.finish(throwing: CancellationError())
                }
            }
            // A cancelled turn tears the stream down; release the waiter with it.
            continuation.onTermination = { [weak self] _ in
                work.cancel()
                self?.abandonParkedRound()
            }
        }
    }

    private func makeRound(
        system: String, history: [BrainTurn], skills: [ModelSkillSchema]
    ) -> SandModelRound {
        lock.withLock {
            roundCount += 1
            return SandModelRound(
                index: roundCount, system: system, history: history, skills: skills)
        }
    }

    private func park(_ id: UUID) async -> SandModelAnswer {
        await withCheckedContinuation { continuation in
            let stale = lock.withLock { () -> CheckedContinuation<SandModelAnswer, Never>? in
                let previous = parked?.continuation
                parked = (id, continuation)
                return previous
            }
            // Never two waiters: the older round is over by definition.
            stale?.resume(returning: .abandon)
        }
    }
}
