//
//  ProjectGitAdapter.swift
//  MaryPlugin
//
//  WHAT: Git at the live project root.
//  IN:   ProjectRootResolver
//  OUT:  status / diff / log / stash-undo / commit / push
//  PIN:  No application name; no unbound run_shell.
//

import Foundation
import MaryComputerUse
import MaryFoundation

public struct ProjectGitAdapter: MaryAdapter {

    public let name = "project-git"
    public let summary = "Inspect and act on git at the live project root"

    public init() {}

    public var skillBindings: [SkillBinding] {
        [codeChanges, showDiff, recentCommits, undoFileChanges, restoreUndone,
         commitChanges, pushChanges]
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(_ name: String, capability: CapabilityID) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID, operation: name,
                capabilities: [capability],
                outputTypes: ["coding.operation-result"],
                targetClasses: ["code-workspace", "writing-project"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Project Git",
            transport: .native,
            operations: [
                operation("code_changes", capability: "code.git.status"),
                operation("show_diff", capability: "code.git.diff"),
                operation("recent_commits", capability: "code.git.log"),
                operation("undo_file_changes", capability: "code.git.undo"),
                operation("restore_undone", capability: "code.git.restore"),
                operation("commit_changes", capability: "code.git.commit"),
                operation("push_changes", capability: "code.git.push"),
            ],
            supportedValueTypes: ["coding.operation-result"],
            grantedPermissions: [.files])
    }

    private var codeChanges: SkillBinding {
        SkillBinding(
            name: "code_changes",
            description: "What has changed in the live project — files modified, lines added and removed.",
            access: .read,
            backing: .native { _, context in
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    let status = await git(focus.root, ["status", "--porcelain"])
                    guard status.ok else { return status }
                    if status.summary.isEmpty || status.summary == "Done — no output." {
                        return SkillOutcome(ok: true, summary: "The working tree is clean — nothing has changed.")
                    }
                    let stat = await git(focus.root, ["diff", "--stat", "HEAD"])
                    return SkillOutcome(
                        ok: true,
                        summary: TextBudget.truncate(
                            "Changed files:\n\(status.summary)\n\(stat.summary)", limit: 1500))
                }
            })
    }

    private var showDiff: SkillBinding {
        SkillBinding(
            name: "show_diff",
            description: "The diff of what changed — a named file, or the whole tree.",
            parameters: [
                .init(name: "file", type: "string",
                      description: "File name, or 'all'; omit for the whole tree.",
                      required: false),
            ],
            access: .read,
            backing: .native { arguments, context in
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    var args = ["diff", "HEAD"]
                    if let file = arguments["file"], !file.isEmpty, file.lowercased() != "all" {
                        args += ["--", file]
                    }
                    let diff = await git(focus.root, args)
                    guard diff.ok else { return diff }
                    if diff.summary.isEmpty || diff.summary == "Done — no output." {
                        return SkillOutcome(ok: true, summary: "No changes there.")
                    }
                    return SkillOutcome(
                        ok: true, summary: TextBudget.truncate(diff.summary, limit: 1800))
                }
            })
    }

    private var recentCommits: SkillBinding {
        SkillBinding(
            name: "recent_commits",
            description: "The latest commits on this project.",
            parameters: [
                .init(name: "count", type: "string",
                      description: "How many; default eight.", required: false),
            ],
            access: .read,
            backing: .native { arguments, context in
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    let count = arguments["count"].flatMap { Int($0.filter(\.isNumber)) } ?? 8
                    let log = await git(
                        focus.root, ["log", "--oneline", "-n", "\(max(1, min(count, 30)))"])
                    guard log.ok else { return log }
                    return SkillOutcome(
                        ok: true, summary: TextBudget.truncate(log.summary, limit: 1200))
                }
            })
    }

    private var undoFileChanges: SkillBinding {
        SkillBinding(
            name: "undo_file_changes",
            description: "Stash the uncommitted changes so they can be restored. The current file, a named file, or all.",
            parameters: [
                .init(name: "file", type: "string",
                      description: "File name, or 'all'.", required: false),
            ],
            access: .write,
            backing: .native { arguments, context in
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    let target = arguments["file"] ?? "all"
                    if target.lowercased() == "all" {
                        return await git(focus.root, ["stash", "push", "-u", "-m", "mary-undo"])
                    }
                    return await git(
                        focus.root, ["stash", "push", "-u", "-m", "mary-undo", "--", target])
                }
            })
    }

    private var restoreUndone: SkillBinding {
        SkillBinding(
            name: "restore_undone",
            description: "Pop the last mary-undo stash back into the working tree.",
            access: .write,
            backing: .native { _, context in
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    return await git(focus.root, ["stash", "pop"])
                }
            })
    }

    private var commitChanges: SkillBinding {
        SkillBinding(
            name: "commit_changes",
            description: "Commit the current changes with a message the user supplied.",
            parameters: [
                .init(name: "message", type: "string",
                      description: "The commit message.", required: true),
            ],
            access: .write,
            backing: .native { arguments, context in
                guard let message = arguments["message"], !message.isEmpty else {
                    return SkillOutcome(ok: false, summary: "What should the commit say?")
                }
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    let add = await git(focus.root, ["add", "-A"])
                    guard add.ok else { return add }
                    return await git(focus.root, ["commit", "-m", message])
                }
            })
    }

    private var pushChanges: SkillBinding {
        SkillBinding(
            name: "push_changes",
            description: "Push the current branch to its remote.",
            access: .write,
            backing: .native { _, context in
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    return await git(focus.root, ["push"])
                }
            })
    }

    private func git(_ root: String, _ arguments: [String]) async -> SkillOutcome {
        do {
            let result = try await Subprocess.run(
                "/usr/bin/git", arguments, timeout: 30, currentDirectory: root)
            if result.exitCode == 0 {
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return SkillOutcome(
                    ok: true,
                    summary: output.isEmpty ? "Done — no output." : output)
            }
            let err = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return SkillOutcome(
                ok: false,
                summary: err.isEmpty ? "git failed." : err)
        } catch {
            return SkillOutcome(ok: false, summary: error.localizedDescription)
        }
    }
}
