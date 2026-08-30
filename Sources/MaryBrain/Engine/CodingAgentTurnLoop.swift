//
//  CodingAgentTurnLoop.swift
//  MaryBrain
//
//  WHAT: Shared jailed pair-coding loop.
//  IN:   MaryCodingEngine / MarySeerCodingEngine
//  OUT:  CodingAgentWorkspace dispatch
//  PIN:  Engines only swap synthesis; dispatch stays on device.
//
import Foundation
import MaryPlugin

enum CodingAgentTurnLoop {

    static let maxTurns = 40

    static let systemPrompt = """
    You are Mary's coding agent. You edit files on disk inside the \
    authorized project root from a live voice pair-coding conversation. \
    Stay inside that root. Prefer the smallest compilable change. Match the \
    surrounding style. After edits, summarize what changed in one short clause.
    """

    static func instructions(skills: [ModelSkillSchema]) -> String {
        let roster = skills.map { "\($0.name) — \($0.description)" }.joined(separator: "\n")
        return systemPrompt + """


        Tools, by exact name:
        \(roster)

        To use a tool, respond with ONLY this format:
        <tool_call>{"name": "tool_name", "arguments": {"param": "value"}}</tool_call>
        You may also emit a *** Begin Patch / *** End Patch block for apply_patch.
        When the change is done, reply with a short summary and no tool call.
        """
    }

    static func run(
        sessionID: String,
        workdir: String,
        history: inout [(role: String, text: String)],
        isCancelled: () async -> Bool,
        generate: ([(role: String, text: String)]) async throws -> (String, [ModelSkillInvocation])
    ) async throws -> CodingAgentRun {
        var lastSpeech = ""
        var turns = 0

        while turns < maxTurns {
            if await isCancelled() { throw CodingAgentBackendError.cancelled }
            turns += 1
            let (speech, invocations) = try await generate(history)
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
                return CodingAgentRun(
                    sessionID: sessionID,
                    summary: lastSpeech.isEmpty ? "done" : lastSpeech,
                    ok: true)
            }
            var results: [String] = []
            for call in calls {
                if await isCancelled() { throw CodingAgentBackendError.cancelled }
                let args = stringArgs(call.argumentsJSON)
                do {
                    let result = try CodingAgentWorkspace.perform(
                        name: call.name, arguments: args, workdir: workdir)
                    results.append("\(call.name): \(result)")
                } catch {
                    results.append("\(call.name) failed: \(error.localizedDescription)")
                }
            }
            if !speech.isEmpty { history.append(("assistant", speech)) }
            history.append(("user", "Tool results:\n" + results.joined(separator: "\n")))
        }
        return CodingAgentRun(
            sessionID: sessionID,
            summary: lastSpeech.isEmpty
                ? "Stopped after \(maxTurns) tool rounds." : lastSpeech,
            ok: false)
    }

    static func stringArgs(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            result[key] = "\(value)"
        }
        return result
    }

    static func messages(from history: [(role: String, text: String)]) -> [SeerChatMessage] {
        history.map { SeerChatMessage(role: $0.role, content: $0.text) }
    }
}
