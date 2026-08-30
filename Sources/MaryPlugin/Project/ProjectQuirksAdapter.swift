//
//  ProjectQuirksAdapter.swift
//  MaryPlugin
//
//  WHAT: On-the-job notes for the live project.
//  IN:   ProjectRootResolver
//  OUT:  {root}/.mary/quirks.md
//  PIN:  Language-generic seed; a second IDE on the same checkout shares it.
//

import Foundation
import MaryFoundation

public struct ProjectQuirksAdapter: MaryAdapter {

    public let name = "project-quirks"
    public let summary = "Record and list on-the-job notes for the live project"

    public init() {}

    public var skillBindings: [SkillBinding] {
        [listQuirks, recordQuirk]
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Project Quirks",
            transport: .native,
            operations: [
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "list_quirks",
                    capabilities: ["code.quirks.list"],
                    outputTypes: ["coding.operation-result"],
                    targetClasses: ["code-workspace"]),
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "record_quirk",
                    capabilities: ["code.quirks.record"],
                    outputTypes: ["coding.operation-result"],
                    targetClasses: ["code-workspace"]),
            ],
            supportedValueTypes: ["coding.operation-result"],
            grantedPermissions: [.files])
    }

    private var listQuirks: SkillBinding {
        SkillBinding(
            name: "list_quirks",
            description: "Read the on-the-job notes for the live project.",
            access: .read,
            backing: .native { _, context in
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    let text = Self.load(root: focus.root)
                    return SkillOutcome(
                        ok: true,
                        summary: TextBudget.truncate(text, limit: 2000),
                        archivePolicy: .stateSnapshot)
                }
            })
    }

    private var recordQuirk: SkillBinding {
        SkillBinding(
            name: "record_quirk",
            description: "Append an on-the-job note to the live project's quirks file.",
            parameters: [
                .init(name: "note", type: "string",
                      description: "What to remember.", required: true),
            ],
            access: .write,
            backing: .native { arguments, context in
                guard let note = arguments["note"], !note.isEmpty else {
                    return SkillOutcome(ok: false, summary: "What should I remember?")
                }
                switch ProjectRootResolver.live(named: nil, context: context) {
                case .failure(let refusal): return SkillOutcome(ok: false, summary: refusal.spoken)
                case .success(let focus):
                    do {
                        try Self.append(note, root: focus.root)
                    } catch {
                        return SkillOutcome(
                            ok: false,
                            summary: "I couldn't save that note: \(error.localizedDescription)")
                    }
                    return SkillOutcome(ok: true, summary: "Noted for \(focus.name).")
                }
            })
    }

    static let seed = """
    # Project quirks

    On-the-job knowledge for this project. Mary reads this before editing and
    appends what she learns.

    ## Notes
    """

    static func file(root: String) -> URL {
        URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".mary", isDirectory: true)
            .appendingPathComponent("quirks.md")
    }

    static func load(root: String) -> String {
        let url = file(root: root)
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        return seed
    }

    static func append(_ note: String, root: String) throws {
        let url = file(root: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = load(root: root)
        if body == seed {
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        let line = "\n- \(note.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) { try handle.write(contentsOf: data) }
        } else {
            try (body + line).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
