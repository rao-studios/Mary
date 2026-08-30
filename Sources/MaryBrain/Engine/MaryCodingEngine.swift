//
//  MaryCodingEngine.swift
//  MaryBrain
//
//  On-device coding delegate. Hub-downloads the selected MLX id (default:
//  the Gemma 4 12B coder 4-bit snapshot) and runs a workdir-jailed tool
//  loop. Frigate only supplies the architecture; Mary Settings owns download.
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
        let skills = CodingAgentWorkspace.toolSchemas
        let known = Set(skills.map(\.name))
        var lastSpeech = ""
        var turns = 0
        let maxTurns = 40

        while turns < maxTurns {
            if cancelled.contains(sessionID) {
                throw CodingAgentBackendError.cancelled
            }
            turns += 1
            let (speech, invocations) = try await generateRound(
                sessionID: sessionID, skills: skills, known: known)
            if !speech.isEmpty { lastSpeech = speech }

            var calls = invocations
            if calls.isEmpty, let fence = CodingAgentWorkspace.extractPatchFence(from: speech) {
                let json = (try? JSONSerialization.data(
                    withJSONObject: ["path": fence.path, "patch": fence.patch]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                calls = [ModelSkillInvocation(
                    id: "patch-\(turns)", name: "apply_patch", argumentsJSON: json)]
            }
            if calls.isEmpty {
                let run = CodingAgentRun(
                    sessionID: sessionID, summary: lastSpeech.isEmpty ? "done" : lastSpeech,
                    ok: true)
                return run
            }
            var results: [String] = []
            for call in calls {
                if cancelled.contains(sessionID) {
                    throw CodingAgentBackendError.cancelled
                }
                let args = Self.stringArgs(call.argumentsJSON)
                do {
                    let result = try CodingAgentWorkspace.perform(
                        name: call.name, arguments: args, workdir: workdir)
                    results.append("\(call.name): \(result)")
                } catch {
                    results.append("\(call.name) failed: \(error.localizedDescription)")
                }
            }
            var history = histories[sessionID] ?? []
            if !speech.isEmpty { history.append(("assistant", speech)) }
            history.append(("user", "Tool results:\n" + results.joined(separator: "\n")))
            histories[sessionID] = history
        }
        return CodingAgentRun(
            sessionID: sessionID,
            summary: lastSpeech.isEmpty
                ? "Stopped after \(maxTurns) tool rounds." : lastSpeech,
            ok: false)
    }

    private func generateRound(
        sessionID: String,
        skills: [ModelSkillSchema],
        known: Set<String>
    ) async throws -> (String, [ModelSkillInvocation]) {
        let ctx = try await loadedContext()
        let history = histories[sessionID] ?? []
        var system = Self.systemPrompt
        let roster = skills.map { "\($0.name) — \($0.description)" }.joined(separator: "\n")
        system += """


        Tools, by exact name:
        \(roster)

        To use a tool, respond with ONLY this format:
        <tool_call>{"name": "tool_name", "arguments": {"param": "value"}}</tool_call>
        You may also emit a *** Begin Patch / *** End Patch block for apply_patch.
        When the change is done, reply with a short summary and no tool call.
        """

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

    private static func stringArgs(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            result[key] = "\(value)"
        }
        return result
    }

    private static let systemPrompt = """
    You are Mary's on-device coding agent. You edit files on disk inside the \
    authorized project root from a live voice pair-coding conversation. \
    Stay inside that root. Prefer the smallest compilable change. Match the \
    surrounding style. After edits, summarize what changed in one short clause.
    """
}
