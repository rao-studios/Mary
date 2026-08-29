//
//  CodingAgentAdapter.swift
//  MaryPlugin
//
//  DELEGATE A CODING TASK TO A BACKGROUND CLI, at the live project root.
//  APPENDED, NOT CATALOGUED — this is a faculty, not an application's
//  property. The workdir is whoever's project is focused, never a named IDE.
//

import Foundation
import MaryFoundation
import os

public struct CodingAgentAdapter: MaryAdapter {

    public let name = "coding-agent"
    public let summary = "Delegate multi-file coding work to a background session at the live project root"

    public init() {}

    public var skillBindings: [SkillBinding] {
        [delegateCoding, completeChange, codingStart, codingStatus, codingList,
         codingSend, codingStop]
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(_ name: String, capability: CapabilityID) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID, operation: name,
                capabilities: [capability],
                outputTypes: ["coding.operation-result"],
                targetClasses: ["code-workspace"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Coding Agent",
            transport: .native,
            operations: [
                operation("delegate_coding", capability: "code.agent.delegate"),
                operation("complete_coding_change", capability: "code.agent.complete"),
                operation("coding_start", capability: "code.agent.start"),
                operation("coding_status", capability: "code.agent.status"),
                operation("coding_list", capability: "code.agent.list"),
                operation("coding_send", capability: "code.agent.send"),
                operation("coding_stop", capability: "code.agent.stop"),
            ],
            supportedValueTypes: ["coding.operation-result"],
            grantedPermissions: [.files])
    }

    private var delegateCoding: SkillBinding {
        SkillBinding(
            name: "delegate_coding",
            description: "Hand a coding task to a background agent working in the live project. Ask first.",
            parameters: [
                .init(name: "task", type: "string",
                      description: "What the agent should do.", required: true),
            ],
            access: .write,
            backing: .native { arguments, context in
                await start(arguments, context: context)
            })
    }

    private var completeChange: SkillBinding {
        SkillBinding(
            name: "complete_coding_change",
            description: "Wait for the latest coding-agent session to finish and report what it did.",
            access: .read,
            backing: .native { _, _ in
                await CodingAgentSessions.shared.latestSummary()
            })
    }

    private var codingStart: SkillBinding {
        SkillBinding(
            name: "coding_start",
            description: "Start a background coding-agent session. Returns a handle like C1.",
            parameters: [
                .init(name: "task", type: "string", description: "What the agent should do.", required: true),
                .init(name: "project", type: "string", description: "Configured project name; omit for the live root.", required: false),
            ],
            access: .write,
            backing: .native { arguments, context in
                await start(arguments, context: context)
            })
    }

    private var codingStatus: SkillBinding {
        SkillBinding(
            name: "coding_status",
            description: "How a coding-agent session is doing. Pass the handle, or omit for the latest.",
            parameters: [
                .init(name: "session", type: "string", description: "Session handle like C1; omit for the latest.", required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                await CodingAgentSessions.shared.status(handle: arguments["session"])
            })
    }

    private var codingList: SkillBinding {
        SkillBinding(
            name: "coding_list",
            description: "List coding-agent sessions still in memory.",
            access: .read,
            backing: .native { _, _ in
                await CodingAgentSessions.shared.list()
            })
    }

    private var codingSend: SkillBinding {
        SkillBinding(
            name: "coding_send",
            description: "Give a finished session follow-up instructions.",
            parameters: [
                .init(name: "session", type: "string", description: "Session handle like C1.", required: true),
                .init(name: "message", type: "string", description: "Follow-up instructions.", required: true),
            ],
            access: .write,
            backing: .native { arguments, _ in
                guard let handle = arguments["session"], let message = arguments["message"]
                else {
                    return SkillOutcome(ok: false, summary: "Which session, and what should I tell it?")
                }
                return await CodingAgentSessions.shared.send(handle: handle, message: message)
            })
    }

    private var codingStop: SkillBinding {
        SkillBinding(
            name: "coding_stop",
            description: "Stop a coding-agent session.",
            parameters: [
                .init(name: "session", type: "string", description: "Session handle like C1; omit for the latest.", required: false),
            ],
            access: .write,
            backing: .native { arguments, _ in
                await CodingAgentSessions.shared.stop(handle: arguments["session"])
            })
    }

    private func start(
        _ arguments: [String: String], context: AbilityExecutionContext
    ) async -> SkillOutcome {
        guard let task = arguments["task"], !task.isEmpty else {
            return SkillOutcome(ok: false, summary: "What should the coding agent do?")
        }
        switch ProjectRootResolver.live(named: arguments["project"], context: context) {
        case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
        case .success(let focus):
            return await CodingAgentSessions.shared.start(task: task, workdir: focus.root)
        }
    }
}

actor CodingAgentSessions {
    static let shared = CodingAgentSessions()

    struct Session: Sendable {
        var handle: String
        var task: String
        var workdir: String
        var output: String
        var running: Bool
        var processIdentifier: pid_t?
    }

    private var sessions: [Session] = []
    private var next = 1

    func start(task: String, workdir: String) async -> SkillOutcome {
        let handle = "C\(next)"
        next += 1
        var session = Session(
            handle: handle, task: task, workdir: workdir,
            output: "", running: true, processIdentifier: nil)
        sessions.append(session)

        let binary = ProcessInfo.processInfo.environment["MARY_CODING_AGENT"]
            ?? which("claude")
            ?? which("vibe")
        guard let binary else {
            session.running = false
            session.output = "No coding-agent CLI is installed."
            replace(session)
            return SkillOutcome(
                ok: false,
                summary: "I don't have a coding agent CLI on this Mac. Set MARY_CODING_AGENT to the binary.")
        }
        let capturedTask = task
        let capturedDir = workdir
        let capturedBinary = binary
        let capturedHandle = handle
        Task {
            await self.run(
                handle: capturedHandle, binary: capturedBinary,
                task: capturedTask, workdir: capturedDir)
        }
        return SkillOutcome(
            ok: true,
            summary: "Started session \(handle) on \(task).")
    }

    private func run(handle: String, binary: String, task: String, workdir: String) async {
        guard var session = find(handle) else { return }
        do {
            let result = try await Subprocess.run(
                binary, ["-p", task], timeout: 600, currentDirectory: workdir)
            session.running = false
            session.output = result.output
            replace(session)
        } catch {
            session.running = false
            session.output = error.localizedDescription
            replace(session)
        }
    }

    func status(handle: String?) -> SkillOutcome {
        guard let session = find(handle) else {
            return SkillOutcome(ok: true, summary: "No coding-agent sessions.", foundNothing: true)
        }
        let state = session.running ? "still working" : "finished"
        return SkillOutcome(
            ok: true,
            summary: "Session \(session.handle) is \(state) on \(session.task).\n"
                + TextBudget.truncate(session.output, limit: 800))
    }

    func list() -> SkillOutcome {
        guard !sessions.isEmpty else {
            return SkillOutcome(ok: true, summary: "No coding-agent sessions.", foundNothing: true)
        }
        let lines = sessions.map {
            "\($0.handle): \($0.running ? "running" : "done") — \($0.task)"
        }
        return SkillOutcome(ok: true, summary: lines.joined(separator: "\n"))
    }

    func send(handle: String, message: String) async -> SkillOutcome {
        await start(task: message, workdir: find(handle)?.workdir ?? NSHomeDirectory())
    }

    func stop(handle: String?) -> SkillOutcome {
        guard var session = find(handle) else {
            return SkillOutcome(ok: true, summary: "No session to stop.", foundNothing: true)
        }
        if let pid = session.processIdentifier { kill(pid, SIGTERM) }
        session.running = false
        replace(session)
        return SkillOutcome(ok: true, summary: "Stopped \(session.handle).")
    }

    func latestSummary() -> SkillOutcome {
        status(handle: sessions.last?.handle)
    }

    private func find(_ handle: String?) -> Session? {
        if let handle, !handle.isEmpty {
            return sessions.first { $0.handle.lowercased() == handle.lowercased() }
        }
        return sessions.last
    }

    private func replace(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.handle == session.handle }) {
            sessions[index] = session
        }
    }

    private func which(_ name: String) -> String? {
        let paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
