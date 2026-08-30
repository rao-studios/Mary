//
//  CodingAgentSessions.swift
//  MaryPlugin
//
//  Session handles C1, C2, … plus background vs awaited delivery. The
//  backend is injected by Runtime; without a prepared model every skill
//  refuses toward Settings.
//

import Foundation
import os

public actor CodingAgentSessions {
    public static let shared = CodingAgentSessions()

    public struct Session: Sendable {
        public var handle: String
        public var task: String
        public var workdir: String
        public var output: String
        public var running: Bool
        public var backendSessionID: String?
        public var delivery: CodingAgentDelivery
    }

    private var sessions: [Session] = []
    private var next = 1
    private var backend: CodingAgentBackend?
    private var completionHandlers: [@Sendable (CodingAgentCompletion) -> Void] = []

    public func install(backend: CodingAgentBackend?) {
        self.backend = backend
    }

    public func isPrepared() async -> Bool {
        await backend?.isPrepared() ?? false
    }

    public func prepare(modelID: String) async throws {
        guard let backend else {
            throw CodingAgentBackendError.notPrepared
        }
        try await backend.prepare(modelID: modelID)
    }

    public func downloadProgress() async -> Double {
        await backend?.downloadProgress() ?? 1.0
    }

    public func onCompletion(_ handler: @escaping @Sendable (CodingAgentCompletion) -> Void) {
        completionHandlers.append(handler)
    }

    public func start(
        task: String,
        workdir: String,
        brief: String,
        delivery: CodingAgentDelivery
    ) async -> SkillOutcome {
        guard let backend else {
            return SkillOutcome(
                ok: false,
                summary: "The coding agent is off. Switch it on in Settings, under Coding Agent.")
        }
        guard await backend.isPrepared() else {
            return SkillOutcome(
                ok: false,
                summary: await backend.unpreparedSummary())
        }
        let handle = "C\(next)"
        next += 1
        let session = Session(
            handle: handle, task: task, workdir: workdir,
            output: "", running: true, backendSessionID: nil,
            delivery: delivery)
        sessions.append(session)

        switch delivery {
        case .background:
            let capturedHandle = handle
            let capturedBrief = brief
            let capturedWorkdir = workdir
            let capturedTask = task
            Task { [weak self] in
                guard let self else { return }
                await self.execute(
                    handle: capturedHandle, brief: capturedBrief,
                    workdir: capturedWorkdir, task: capturedTask,
                    delivery: .background, resumeID: nil, message: nil)
            }
            return SkillOutcome(
                ok: true,
                summary: "Started session \(spokenNumber(handle)) on \(task). The editor will pick the changes up as they land.",
                deferred: true)
        case .awaited:
            return await execute(
                handle: handle, brief: brief, workdir: workdir, task: task,
                delivery: .awaited, resumeID: nil, message: nil)
        }
    }

    public func send(handle: String, message: String) async -> SkillOutcome {
        guard var session = find(handle) else {
            return SkillOutcome(ok: false, summary: "I don't have a session \(handle).")
        }
        guard !session.running else {
            return SkillOutcome(
                ok: false,
                summary: "Session \(spokenNumber(session.handle)) is still working — wait for it to finish, or stop it first.")
        }
        session.running = true
        session.task = message
        replace(session)
        let capturedHandle = session.handle
        let capturedWorkdir = session.workdir
        let resumeID = session.backendSessionID
        Task { [weak self] in
            guard let self else { return }
            await self.execute(
                handle: capturedHandle, brief: message,
                workdir: capturedWorkdir, task: message,
                delivery: .background, resumeID: resumeID, message: message)
        }
        return SkillOutcome(
            ok: true,
            summary: "Told session \(spokenNumber(capturedHandle)): \(message)",
            deferred: true)
    }

    public func status(handle: String?) -> SkillOutcome {
        guard let session = find(handle) else {
            return SkillOutcome(ok: true, summary: "No coding-agent sessions.", foundNothing: true)
        }
        let state = session.running ? "still working" : "finished"
        return SkillOutcome(
            ok: true,
            summary: "Session \(spokenNumber(session.handle)) is \(state) on \(session.task).\n"
                + TextBudget.truncate(session.output, limit: 800))
    }

    public func list() -> SkillOutcome {
        guard !sessions.isEmpty else {
            return SkillOutcome(ok: true, summary: "No coding-agent sessions.", foundNothing: true)
        }
        let lines = sessions.map {
            "\(spokenNumber($0.handle)): \($0.running ? "running" : "done") — \($0.task)"
        }
        return SkillOutcome(ok: true, summary: lines.joined(separator: "\n"))
    }

    public func stop(handle: String?) async -> SkillOutcome {
        guard var session = find(handle) else {
            return SkillOutcome(ok: true, summary: "No session to stop.", foundNothing: true)
        }
        if let backendID = session.backendSessionID {
            await backend?.cancel(sessionID: backendID)
        }
        session.running = false
        session.output = session.output.isEmpty ? "Stopped." : session.output
        replace(session)
        return SkillOutcome(ok: true, summary: "Stopped session \(spokenNumber(session.handle)).")
    }

    public func latestSummary() -> SkillOutcome {
        status(handle: sessions.last?.handle)
    }

    @discardableResult
    private func execute(
        handle: String,
        brief: String,
        workdir: String,
        task: String,
        delivery: CodingAgentDelivery,
        resumeID: String?,
        message: String?
    ) async -> SkillOutcome {
        guard let backend else {
            return SkillOutcome(ok: false, summary: "The coding agent is off.")
        }
        do {
            let run: CodingAgentRun
            if let resumeID, let message {
                run = try await backend.resume(
                    sessionID: resumeID, message: message, workdir: workdir)
            } else {
                run = try await backend.run(
                    brief: brief, workdir: workdir, delivery: delivery)
            }
            if var session = find(handle) {
                session.running = false
                session.output = run.summary
                session.backendSessionID = run.sessionID
                replace(session)
            }
            let completion = CodingAgentCompletion(
                handle: handle, delivery: delivery, ok: run.ok,
                summary: run.summary, task: task, workdir: workdir)
            publish(completion)
            let number = spokenNumber(handle)
            if run.ok {
                return SkillOutcome(
                    ok: true,
                    summary: delivery == .awaited
                        ? "Session \(number) completed the code change: \(run.summary)"
                        : "Session \(number) finished.")
            }
            return SkillOutcome(
                ok: false,
                summary: "Session \(number) failed: \(run.summary)")
        } catch is CancellationError {
            if var session = find(handle) {
                session.running = false
                session.output = "Stopped."
                replace(session)
            }
            return SkillOutcome(
                ok: false,
                summary: "Session \(spokenNumber(handle)) stopped.",
                status: .cancelled)
        } catch {
            if var session = find(handle) {
                session.running = false
                session.output = error.localizedDescription
                replace(session)
            }
            let completion = CodingAgentCompletion(
                handle: handle, delivery: delivery, ok: false,
                summary: error.localizedDescription, task: task, workdir: workdir)
            publish(completion)
            return SkillOutcome(
                ok: false,
                summary: "Session \(spokenNumber(handle)) failed: \(error.localizedDescription)")
        }
    }

    private func publish(_ completion: CodingAgentCompletion) {
        for handler in completionHandlers {
            handler(completion)
        }
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

    public static func spokenNumber(_ handle: String) -> String {
        let digits = handle.drop(while: { !$0.isNumber })
        guard let n = Int(digits) else { return handle }
        return "\(n)"
    }

    private func spokenNumber(_ handle: String) -> String {
        Self.spokenNumber(handle)
    }
}
