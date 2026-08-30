//
//  MaryCodingEngine.swift
//  MaryBrain
//
//  On-device coding delegate. Hub-downloads the selected MLX id (default:
//  the Gemma 4 12B coder 4-bit snapshot) and synthesizes rounds for the
//  shared jailed loop. Frigate only supplies the architecture.
//

import Foundation
import MLXLLM
import MLXLMCommon
import MaryPlugin

public actor MaryCodingEngine: CodingAgentBackend {

    public static let defaultModelID =
        "mlx-community/gemma-4-12b-coder-fable5-composer2.5-4bit"

    public static let shared = MaryCodingEngine()

    private var modelID: String = MaryCodingEngine.defaultModelID
    private var context: ModelContext?
    private(set) var downloadProgress: Double = 1.0
    private var histories: [String: [(role: String, text: String)]] = [:]
    private var cancelled: Set<String> = []

    public func isPrepared() async -> Bool {
        context != nil
    }

    public func unpreparedSummary() async -> String {
        "The coding agent has no model yet. Open Settings, download the coding model, and select it."
    }

    public func downloadProgress() async -> Double {
        downloadProgress
    }

    public func prepare(modelID: String) async throws {
        if context != nil, self.modelID == modelID { return }
        self.modelID = modelID
        context = nil
        downloadProgress = 0
        let ctx = try await MLXLMCommon.loadModel(
            configuration: ModelConfiguration(
                id: modelID,
                extraEOSTokens: ["<end_of_turn>"],
                toolCallFormat: .gemma),
            progressHandler: { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { await self?.setDownloadProgress(fraction) }
            }
        )
        downloadProgress = 1.0
        context = ctx
    }

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
        guard context != nil else { throw CodingAgentBackendError.notPrepared }
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
        let ctx = try await loadedContext()
        let skills = CodingAgentWorkspace.toolSchemas
        let known = Set(skills.map(\.name))
        let system = CodingAgentTurnLoop.instructions(skills: skills)

        var messages: [Chat.Message] = [.system(system)]
        for entry in history {
            messages.append(entry.role == "user" ? .user(entry.text) : .assistant(entry.text))
        }

        await MLXGPUGate.shared.acquire()
        let speech: String
        let invocations: [ModelSkillInvocation]
        do {
            let input = try await ctx.processor.prepare(
                input: UserInput(
                    chat: messages,
                    tools: skills.map(MaryLocalEngine.toolSpec(from:))
                )
            )
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 2048),
                context: ctx
            )
            var interceptor = SkillCallTextInterceptor(knownSkillNames: known)
            var collected: [ModelSkillInvocation] = []
            var spoken = ""
            for await item in stream {
                if Task.isCancelled { break }
                switch item {
                case .chunk(let text):
                    let speakable = interceptor.ingest(text)
                    if !speakable.isEmpty { spoken += speakable }
                case .toolCall(let call):
                    let argumentsJSON: String
                    if let data = try? JSONSerialization.data(
                        withJSONObject: call.function.arguments.mapValues { $0.anyValue }),
                       let json = String(data: data, encoding: .utf8)
                    {
                        argumentsJSON = json
                    } else {
                        argumentsJSON = "{}"
                    }
                    collected.append(ModelSkillInvocation(
                        id: "code-\(UUID().uuidString.prefix(8))",
                        name: call.function.name,
                        argumentsJSON: argumentsJSON))
                case .info:
                    break
                }
            }
            switch interceptor.finish() {
            case .speech(let text):
                spoken += text
            case .skillInvocations(let extra):
                collected.append(contentsOf: extra)
            case .dropped, .nothing:
                break
            }
            speech = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            invocations = collected
            await MLXGPUGate.shared.release()
        } catch {
            await MLXGPUGate.shared.release()
            throw error
        }
        return (speech, invocations)
    }

    private func loadedContext() async throws -> ModelContext {
        if let context { return context }
        try await prepare(modelID: modelID)
        guard let context else { throw CodingAgentBackendError.notPrepared }
        return context
    }

    private func setDownloadProgress(_ value: Double) {
        downloadProgress = value
    }
}
