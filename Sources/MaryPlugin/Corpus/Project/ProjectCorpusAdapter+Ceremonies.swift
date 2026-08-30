//
//  ProjectCorpusAdapter+Ceremonies.swift
//  MaryPlugin
//
//  WHAT: Change a project's shape through the application's own commands.
//  IN:   ProjectCorpusAdapter.swift (sibling split)
//  OUT:  ApplicationMenuDriver / ProjectCorpusReader (verify on disk)
//  PIN:  Never write project files — autosave would clobber. Closed act set;
//        paths are data. Verify on disk after Mary's delays, not the package's.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

extension ProjectCorpusAdapter {

    /// Mary's delays, not the package's. Two waits; unseen change is failure.
    static let verifyDelays: [Duration] = [.milliseconds(3500), .milliseconds(2500)]

    var ceremonyBindings: [SkillBinding] {
        [addItem, addContainer, moveItem, trashItem]
    }

    // MARK: - The shared choreography

    /// Bring the app forward, press a declared path, prove the outline changed.
    /// `summarize` is the only evidence — a menu press reports nothing.
    func perform(
        act: PluginCorpusCeremony.Act,
        named project: String?,
        extraPath: [String] = [],
        summarize: @escaping ([ProjectCorpusReader.Item], [ProjectCorpusReader.Item]) -> String?
    ) async -> SkillOutcome {
        let corpus: OpenCorpus
        switch self.project(project) {
        case .corpus(let found): corpus = found
        case .refused(let outcome): return outcome
        }
        let structure = corpus.structure

        guard let ceremony = structure.ceremonies.first(where: { $0.act == act }) else {
            // No declared path for this act is not a failed press.
            return SkillOutcome(
                ok: false,
                summary: "\(corpus.registration.displayName) doesn't offer that from a menu.")
        }
        guard ProjectCorpusSupport.isOpenForEditing(corpus) else {
            return SkillOutcome(
                ok: false,
                summary: "\(corpus.name) isn't open in "
                    + "\(corpus.registration.displayName) just now.")
        }

        let before: [ProjectCorpusReader.Item]
        switch outline(corpus) {
        case .items(let items): before = items
        case .refused(let outcome): return outcome
        }

        // Menu bar belongs to the frontmost app — activate first.
        let activation = await VerifiedActivation.bringForward(
            pid: corpus.processIdentifier, requireVisibleWindow: true)
        guard activation.succeeded else {
            return SkillOutcome(
                ok: false,
                summary: activation.reason(app: corpus.registration.displayName)
                    ?? "I couldn't bring \(corpus.registration.displayName) forward.")
        }

        let path = ceremony.menuPath + extraPath
        if case .failure(let failure) = await ApplicationMenuDriver.choose(
            path: path, pid: corpus.processIdentifier) {
            return SkillOutcome(
                ok: false,
                summary: failure.spoken(app: corpus.registration.displayName))
        }

        // Verify on disk, twice.
        for delay in Self.verifyDelays {
            try? await Task.sleep(for: delay)
            guard case .success(let after) = ProjectCorpusReader.outline(
                projectRoot: corpus.projectRoot, structure: structure) else { continue }
            if let summary = summarize(before, after) {
                return SkillOutcome(
                    ok: true, summary: summary,
                    adapterTrail: [AdapterID.normalized(name)])
            }
        }
        // Chosen but unseen is not success.
        return SkillOutcome(
            ok: false,
            summary: """
            I chose \(path.joined(separator: " → ")) in \
            \(corpus.registration.displayName), but \(corpus.name) doesn't show the change.
            """)
    }

    // MARK: - The acts

    private var addItem: SkillBinding {
        SkillBinding(
            name: "add_corpus_item",
            description: "Add a new document to a writing project, through its own New command.",
            parameters: [Self.projectParameter],
            access: .tweak,
            backing: .native { arguments, _ in
                await perform(act: .addItem, named: arguments["project"]) { before, after in
                    let grew = after.flatMap(\.flattened).count
                        - before.flatMap(\.flattened).count
                    guard grew > 0 else { return nil }
                    // Newest item by id difference, never position — a new document renumbers neighbours.
                    let existing = Set(before.flatMap(\.flattened).map(\.id))
                    let added = after.flatMap(\.flattened).first { !existing.contains($0.id) }
                    return added.map {
                        "Added \($0.title.isEmpty ? "a new document" : "\"\($0.title)\"")."
                    } ?? "Added a new document."
                }
            })
    }

    private var addContainer: SkillBinding {
        SkillBinding(
            name: "add_corpus_container",
            description: "Add a new folder to a writing project, through its own New command.",
            parameters: [Self.projectParameter],
            access: .tweak,
            backing: .native { arguments, _ in
                await perform(act: .addContainer, named: arguments["project"]) { before, after in
                    let existing = Set(before.flatMap(\.flattened).map(\.id))
                    guard let added = after.flatMap(\.flattened)
                        .first(where: { !existing.contains($0.id) }) else { return nil }
                    return "Added \(added.title.isEmpty ? "a new folder" : "\"\(added.title)\"")."
                }
            })
    }

    private var moveItem: SkillBinding {
        SkillBinding(
            name: "move_corpus_item",
            description: """
            Move the document the writer is on into another folder, through \
            the project's own Move command.
            """,
            parameters: [
                .init(
                    name: "destination", type: "string",
                    description: "The folder to move it into, as the outline names it.",
                    required: true),
                Self.projectParameter,
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let destination = arguments["destination"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !destination.isEmpty
                else { return SkillOutcome(ok: false, summary: "Move it into which folder?") }

                // Last menu level is the user's folder (`completedByContainer`).
                // No package can enumerate it; no chord can name it.
                return await perform(
                    act: .moveToContainer, named: arguments["project"],
                    extraPath: [destination]
                ) { before, after in
                    // A move changes no count — evidence is the item's parent.
                    let beforeParents = Self.parents(of: before)
                    let afterParents = Self.parents(of: after)
                    let moved = afterParents.first { id, parent in
                        beforeParents[id] != nil && beforeParents[id] != parent
                    }
                    guard let moved else { return nil }
                    let title = after.flatMap(\.flattened)
                        .first { $0.id == moved.key }?.title ?? "it"
                    return "Moved \"\(title)\" into \(moved.value)."
                }
            })
    }

    private var trashItem: SkillBinding {
        SkillBinding(
            name: "trash_corpus_item",
            description: """
            Move the document the writer is on to the project's trash, through \
            its own command. Nothing is deleted; the trash keeps it.
            """,
            parameters: [Self.projectParameter],
            // Tweak, not write: trash is a folder; undo puts it back.
            access: .tweak,
            backing: .native { arguments, _ in
                await perform(act: .trash, named: arguments["project"]) { before, after in
                    // Outline excludes trash, so a trashed document leaves it.
                    let gone = Set(before.flatMap(\.flattened).map(\.id))
                        .subtracting(after.flatMap(\.flattened).map(\.id))
                    guard let id = gone.first else { return nil }
                    let title = before.flatMap(\.flattened)
                        .first { $0.id == id }?.title ?? "it"
                    return "Moved \"\(title)\" to the trash. It's still there if you want it back."
                }
            })
    }

    /// Every item's parent title, keyed by id — the shape a move changes.
    static func parents(of items: [ProjectCorpusReader.Item]) -> [String: String] {
        var map: [String: String] = [:]
        func walk(_ item: ProjectCorpusReader.Item) {
            for child in item.children {
                map[child.id] = item.title
                walk(child)
            }
        }
        for item in items { walk(item) }
        return map
    }
}
