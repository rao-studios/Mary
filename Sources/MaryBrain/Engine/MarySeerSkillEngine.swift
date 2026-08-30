//
//  MarySeerSkillEngine.swift
//  MaryBrain
//
//  WHAT: Lane B hosted — one POST to `/v1/skills/complete` per acting round.
//  IN:   orchestrator lane
//  OUT:  invocation synthesis; dispatch on-device
//  PIN:  If Seer is unready, optional local MLX carries the round.
//
import Foundation

public actor MarySeerSkillEngine: InferenceEngine {

    public nonisolated var choice: LLMEngineChoice { .hosted }
    public nonisolated var requiresExclusiveGeneration: Bool { false }
    public nonisolated let displayName = "Hosted skills (via Seer)"

    private let client: any SeerSkillProviding
    private let fallback: MaryLocalEngine?

    public init(client: any SeerSkillProviding, fallback: MaryLocalEngine? = nil) {
        self.client = client
        self.fallback = fallback
    }

    public func warmup() async throws {
        if let fallback {
            try await fallback.warmup()
        }
    }

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
        guard let fallback else {
            throw SeerSkillError.notAuthenticated
        }
        for try await event in fallback.stream(
            system: system, history: history, skills: skills)
        {
            continuation.yield(event)
        }
    }

    /// Mistral-family templates reject a bare tool role, so skill results
    /// ride as labeled user text — the same mapping as MaryLocalEngine.
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
