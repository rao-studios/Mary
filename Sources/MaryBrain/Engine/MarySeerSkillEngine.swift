//
//  MarySeerSkillEngine.swift
//  MaryBrain
//
//  WHAT: Lane B — one POST to `/v1/skills/complete` per acting round.
//  IN:   orchestrator lane
//  OUT:  invocation synthesis; dispatch stays on this Mac
//  PIN:  There is no local fallback any more: on-device generation lives in
//        Seer, so an unready server is an error, not a quieter engine. The
//        `choice` is stored because it is WHICH BACKEND Seer will use, and the
//        behavioral record and the Life gate both read it.
//
import Foundation

public actor MarySeerSkillEngine: InferenceEngine {

    public nonisolated let choice: LLMEngineChoice
    public nonisolated var requiresExclusiveGeneration: Bool { false }
    public nonisolated let displayName: String

    private let client: any SeerSkillProviding

    public init(client: any SeerSkillProviding, choice: LLMEngineChoice = .mistral) {
        self.client = client
        self.choice = choice
        self.displayName = "Skills via Seer — \(choice.displayName)"
    }

    /// Nothing to warm here: the model, if there is one, lives in Seer and is
    /// warmed through `/v1/providers/local/warm`.
    public func warmup() async throws {}

    public nonisolated func stream(
        system: String,
        history: [BrainTurn],
        skills: [ModelSkillSchema]
    ) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamRound(
                        system: system, history: history, skills: skills,
                        continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamRound(
        system: String,
        history: [BrainTurn],
        skills: [ModelSkillSchema],
        continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation
    ) async throws {
        if await client.isReady() {
            let round = try await client.complete(
                instructions: system,
                messages: Self.messages(from: history),
                skills: skills)
            var invocations = round.invocations
            var text = round.text
            if invocations.isEmpty, !text.isEmpty {
                var interceptor = SkillCallTextInterceptor(
                    knownSkillNames: Set(skills.map(\.name)))
                _ = interceptor.ingest(text)
                switch interceptor.finish() {
                case .skillInvocations(let recovered):
                    invocations = recovered
                    text = ""
                case .speech(let spoken):
                    text = spoken
                case .dropped, .nothing:
                    break
                }
            }
            if !text.isEmpty {
                continuation.yield(.text(text))
            }
            for invocation in invocations {
                continuation.yield(.skillInvocation(invocation))
            }
            continuation.yield(.done)
            return
        }
        // NO SILENT SECOND ENGINE. On-device now means Seer's backend, so an
        // unreachable or signed-out server is reported rather than papered over.
        throw SeerSkillError.notAuthenticated
    }

    /// Mistral-family templates reject a bare tool role, so skill results
    /// ride as labeled user text — the same mapping Seer applies on-device.
    static func messages(from history: [BrainTurn]) -> [SeerChatMessage] {
        var mapped: [(role: String, text: String)] = []
        for turn in history {
            let entry: (String, String)
            switch turn.role {
            case .user:
                entry = ("user", turn.text)
            case .assistant:
                guard !turn.text.isEmpty else { continue }
                entry = ("assistant", turn.text)
            case .skillResult:
                entry = (
                    "user",
                    "[skill result — \(turn.skillName ?? "skill")]: \(turn.text)")
            }
            if let last = mapped.last, last.role == entry.0 {
                mapped[mapped.count - 1].text += "\n\n" + entry.1
            } else {
                mapped.append((entry.0, entry.1))
            }
        }
        return mapped.map { SeerChatMessage(role: $0.role, content: $0.text) }
    }
}
