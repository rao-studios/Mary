//
//  DocumentCorpusAdapter+Ceremonies.swift
//  MaryPlugin
//
//  CHANGING A PROJECT'S SHAPE THROUGH THE APPLICATION'S OWN COMMANDS.
//
//  ⚠️ WHY NOT JUST EDIT THE FILES. Because the application has the project
//  open and autosaves on its own schedule: a write from outside races that
//  save and LOSES, silently, with no failing call anywhere. The user finds a
//  chapter gone an hour later and nothing says why. A menu command is slower,
//  needs the application in front, and cannot lose work — so every change
//  goes that way and the reads stay on disk where they are safe.
//
//  THE ACTS ARE A CLOSED SET AND THE PATHS ARE DATA. A package says where
//  this application keeps its "move" command; it cannot name a fifth act or
//  word a refusal. That boundary is what keeps a declaration from becoming a
//  script — and it is why `setVocabularyValue` is absent rather than
//  declared: Scrivener 3 has no Status or Label menu at all (measured), so
//  the honest response is to offer no act for it rather than one that fails.
//
//  VERIFIED ON DISK, ALWAYS, and the delays are Mary's rather than the
//  package's. The application writes its manifest on its own timetable, so a
//  read taken immediately after a menu press sees the project as it was. Two
//  waits: the first commonly races a slow save, and a second look is cheap. A
//  package that could shorten these could make every ceremony report a
//  success it never confirmed.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

extension DocumentCorpusAdapter {

    /// MARY'S, NOT THE PACKAGE'S. Measured shape rather than a guess at
    /// timing: the first wait covers the ordinary autosave, the second covers
    /// a slow one, and a ceremony that cannot see its change after both
    /// reports that it could not — never that it worked.
    static let verifyDelays: [Duration] = [.milliseconds(3500), .milliseconds(2500)]

    var ceremonyBindings: [SkillBinding] {
        [addItem, addContainer, moveItem, trashItem]
    }

    // MARK: - The shared choreography

    /// Bring the application forward, press a declared path, and prove the
    /// outline changed.
    ///
    /// `expectation` receives the outline BEFORE and AFTER and says whether
    /// what was asked for happened — a count, a name, a parent. It is the
    /// only evidence a ceremony has, because a menu press reports nothing.
    func perform(
        act: PluginCorpusCeremony.Act,
        named project: String?,
        extraPath: [String] = [],
        summarize: @escaping ([DocumentCorpusReader.Item], [DocumentCorpusReader.Item]) -> String?
    ) async -> SkillOutcome {
        let corpus: OpenCorpus
        switch self.project(project) {
        case .corpus(let found): corpus = found
        case .refused(let outcome): return outcome
        }
        let structure = corpus.structure

        guard let ceremony = structure.ceremonies.first(where: { $0.act == act }) else {
            // A package that declared no path for this act has said it cannot
            // do it here, which is a different thing from failing.
            return SkillOutcome(
                ok: false,
                summary: "\(corpus.registration.displayName) doesn't offer that from a menu.")
        }
        guard DocumentCorpusSupport.isOpenForEditing(corpus) else {
            return SkillOutcome(
                ok: false,
                summary: "\(corpus.name) isn't open in "
                    + "\(corpus.registration.displayName) just now.")
        }

        let before: [DocumentCorpusReader.Item]
        switch outline(corpus) {
        case .items(let items): before = items
        case .refused(let outcome): return outcome
        }

        // THE APPLICATION MUST OWN THE SCREEN. A menu bar belongs to the
        // frontmost application, so a press aimed at a background one reaches
        // whatever is actually in front — and presses something there.
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

        // VERIFY ON DISK, TWICE.
        for delay in Self.verifyDelays {
            try? await Task.sleep(for: delay)
            guard case .success(let after) = DocumentCorpusReader.outline(
                projectRoot: corpus.projectRoot, structure: structure) else { continue }
            if let summary = summarize(before, after) {
                return SkillOutcome(
                    ok: true, summary: summary,
                    adapterTrail: [AdapterID.normalized(name)])
            }
        }
        // DELIVERED AND UNCONFIRMED IS NOT SUCCESS. The command was chosen and
        // the project does not show it; saying so is the only honest report,
        // and it is genuinely different from the command having failed.
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
                    // THE NEWEST ITEM BY DIFFERENCE OF IDS, never by position
                    // — a new document renumbers its neighbours, so an
                    // ordinal names a different item after the change than
                    // before it.
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

                // THE LAST LEVEL IS THE USER'S OWN FOLDER, which no package
                // can enumerate — it is read off the live menu here. That is
                // what `completedByContainer` declares, and it is why menu
                // driving exists at all: no chord can name a folder made this
                // morning.
                return await perform(
                    act: .moveToContainer, named: arguments["project"],
                    extraPath: [destination]
                ) { before, after in
                    // A MOVE CHANGES NO COUNT, so the evidence is the item's
                    // PARENT. Find a document whose ancestry differs.
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
            // A TWEAK RATHER THAN A WRITE, and the reason is what the act
            // actually does: the project's trash is a folder, the document is
            // still there, and the application's own undo puts it back. It
            // would be a write if it deleted anything.
            access: .tweak,
            backing: .native { arguments, _ in
                await perform(act: .trash, named: arguments["project"]) { before, after in
                    // THE OUTLINE EXCLUDES THE TRASH, so a trashed document
                    // simply leaves it — which makes the count the evidence,
                    // and makes it read the same way for a document trashed
                    // from anywhere in the binder.
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
    static func parents(of items: [DocumentCorpusReader.Item]) -> [String: String] {
        var map: [String: String] = [:]
        func walk(_ item: DocumentCorpusReader.Item) {
            for child in item.children {
                map[child.id] = item.title
                walk(child)
            }
        }
        for item in items { walk(item) }
        return map
    }
}
