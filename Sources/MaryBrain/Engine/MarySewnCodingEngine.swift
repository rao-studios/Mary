//
//  MarySewnCodingEngine.swift
//  MaryBrain
//
//  WHAT: Hosted pair-coding synthesis through `/v1/code/complete`.
//  IN:   CodingAgentTurnLoop
//  OUT:  one bounded round; dispatch stays in CodingAgentWorkspace
//  PIN:  Sewn picks the model; Mary never sends one.
//
import Foundation
import MaryPlugin

public actor MarySewnCodingEngine: CodingAgentBackend {

    private let client: any SewnSkillProviding
    private let stackEnabled: @Sendable () -> Bool
    private var histories: [String: [(role: String, text: String)]] = [:]
    private var cancelled: Set<String> = []

    public init(
        client: any SewnSkillProviding,
        stackEnabled: @escaping @Sendable () -> Bool
    ) {
        self.client = client
        self.stackEnabled = stackEnabled
    }

    public func isPrepared() async -> Bool {
        guard stackEnabled() else { return false }
        return await client.isReady()
    }

    public func unpreparedSummary() async -> String {
        "The coding agent is not ready. Choose Hosted under Coding Agent in Settings, sign in to Sewn, and keep Chat through Sewn on."
    }

    public func downloadProgress() async -> Double { 1.0 }

    public func prepare(modelID: String) async throws {}

    public func cancel(sessionID: String) async {
        cancelled.insert(sessionID)
    }

    public func run(
        brief: String,
        workdir: String,
        delivery: CodingAgentDelivery
    ) async throws -> CodingAgentRun {
        let sessionID = UUID().uuidString
        histories[sessionID] = [("user", brief)]
        return try await loop(sessionID: sessionID, workdir: workdir)
    }

    public func resume(
        sessionID: String,
        message: String,
        workdir: String
    ) async throws -> CodingAgentRun {
        var history = histories[sessionID] ?? []
        history.append(("user", message))
        histories[sessionID] = history
        cancelled.remove(sessionID)
        return try await loop(sessionID: sessionID, workdir: workdir)
    }

    private func loop(sessionID: String, workdir: String) async throws -> CodingAgentRun {
        guard await isPrepared() else { throw CodingAgentBackendError.notPrepared }
        var history = histories[sessionID] ?? []
        let run = try await CodingAgentTurnLoop.run(
            sessionID: sessionID,
            workdir: workdir,
            history: &history,
            isCancelled: { await self.cancelled.contains(sessionID) },
            generate: { hist in
                try await self.generateRound(history: hist)
            })
        histories[sessionID] = history
        return run
    }

    private func generateRound(
        history: [(role: String, text: String)]
    ) async throws -> (String, [ModelSkillInvocation]) {
        let skills = CodingAgentWorkspace.toolSchemas
        let round = try await client.complete(
            instructions: CodingAgentTurnLoop.instructions(skills: skills),
            messages: CodingAgentTurnLoop.messages(from: history),
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
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), invocations)
    }
}
