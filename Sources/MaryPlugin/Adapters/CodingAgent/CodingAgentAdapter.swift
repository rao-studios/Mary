//
//  CodingAgentAdapter.swift
//  MaryPlugin
//
//  DELEGATE A CODING TASK TO THE ON-DEVICE CODING ENGINE, at the live
//  project root. APPENDED, NOT CATALOGUED — a faculty, not an application's
//  property. The workdir is whoever's project is focused, never a named IDE.
//

import Foundation
import MaryFoundation

public struct CodingAgentAdapter: MaryAdapter {

    public let name = "coding-agent"
    public let summary = "Delegate multi-file coding work to a background on-device session at the live project root"

    public init() {}

    public var promptFragment: String? {
        """
        coding_agent: you pair-code on the project the user has open. \
        read_symbol/current_file to look. To CHANGE code call \
        delegate_coding with a clear, self-contained task — the file, \
        line, and symbol context attach automatically and the coding agent \
        edits the project on disk. New code is composition: describe what \
        to add. Changing code that already exists is a revision — \
        read_symbol it FIRST so the task names the real code; it lands on \
        that symbol, never at a cursor. Say the session number; \
        coding_status checks progress; build_check confirms. \
        coding_start begins a background session and returns a handle \
        like C1 — say it aloud as "session one". Sessions keep working \
        while you talk about other things; coding_send gives a finished \
        session follow-up instructions; coding_stop ends one. Delegate \
        multi-file coding work instead of typing edits yourself.
        """
    }

    public var skillBindings: [SkillBinding] {
        [delegateCoding, completeChange, codingStart, codingStatus, codingList,
         codingSend, codingStop]
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(
            _ name: String,
            capability: CapabilityID,
            inputTypes: [ValueTypeID] = []
        ) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID, operation: name,
                capabilities: [capability],
                inputTypes: inputTypes,
                outputTypes: ["coding.operation-result"],
                targetClasses: ["code-workspace"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Coding Agent",
            transport: .native,
            operations: [
                operation("delegate_coding", capability: "code.agent.delegate"),
                operation(
                    "complete_coding_change",
                    capability: "code.agent.complete",
                    inputTypes: ["coding.change-request"]),
                operation("coding_start", capability: "code.agent.start"),
                operation("coding_status", capability: "code.agent.status"),
                operation("coding_list", capability: "code.agent.list"),
                operation("coding_send", capability: "code.agent.send"),
                operation("coding_stop", capability: "code.agent.stop"),
            ],
            supportedValueTypes: ["coding.operation-result", "coding.change-request"],
            grantedPermissions: [.files])
    }

    private var delegateCoding: SkillBinding {
        SkillBinding(
            name: "delegate_coding",
            description: "Make a code change via a background coding-agent session — the current file, line, and symbol context attach automatically. Say the session number.",
            parameters: [
                .init(name: "task", type: "string",
                      description: "A clear, self-contained description of the change the user wants.",
                      required: true),
            ],
            access: .tweak,
            backing: .native { arguments, context in
                await spawn(arguments, context: context, delivery: .background)
            })
    }

    private var completeChange: SkillBinding {
        SkillBinding(
            name: "complete_coding_change",
            description: "Complete one project-scoped code change and return its settled result before verification continues.",
            parameters: [
                .init(name: "task", type: "string",
                      description: "A clear, self-contained description of the planned change.",
                      required: false),
                .init(name: "plan", type: "string",
                      description: "Workflow plan port; used when task is empty.",
                      required: false),
            ],
            access: .tweak,
            backing: .native { arguments, context in
                if (arguments["task"] ?? arguments["plan"] ?? arguments["request"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return await CodingAgentSessions.shared.latestSummary()
                }
                return await spawn(arguments, context: context, delivery: .awaited)
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
                await spawn(arguments, context: context, delivery: .background)
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

    private func spawn(
        _ arguments: [String: String],
        context: AbilityExecutionContext,
        delivery: CodingAgentDelivery
    ) async -> SkillOutcome {
        switch CodingAgentDelegation.target(arguments: arguments, context: context) {
        case .failure(let refusal):
            return SkillOutcome(ok: false, summary: refusal.spoken)
        case .success(let target):
            let style = CodingAgentDelegation.styleBlock(for: target.workdir)
            let brief = CodingAgentDelegation.delegationBrief(
                task: target.task,
                context: target.context,
                workdir: target.workdir,
                style: style)
            var outcome = await CodingAgentSessions.shared.start(
                task: target.task,
                workdir: target.workdir,
                brief: brief,
                delivery: delivery)
            if outcome.ok, target.usesRememberedRoot {
                outcome.summary += " In \(target.projectName) — the project you were last in."
            }
            return outcome
        }
    }
}
