//
//  ProseSurfaceAdapter.swift
//  MaryAdapters
//
//  THE SKILLS A DECLARED PROSE SURFACE CAN ANSWER — list the documents, read
//  one, make a new one.
//
//  WHY THESE ARE HERE AND NOT IN A PACKAGE. A managed-UI recipe presses keys
//  and reports whether the press landed; it has no channel for handing a value
//  back. So every Skill that must give the model a VALUE — the roster, the
//  text of a document — has to bind to a compiled provider, and this is that
//  provider for the prose family. `create_document` could almost be a recipe
//  (it is a chord), and is here anyway: it must return the identity of the
//  document it just made, and a recipe cannot say what it created.
//
//  NO APPLICATION IS NAMED. Each Skill takes an optional `app`; the
//  registration behind it decides everything else. Which windows exist, what
//  a document is called, which chord makes a new one — all declared.
//

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation

public struct ProseSurfaceAdapter: MaryAdapter {

    public let name = "prose-surface"
    public let summary =
        "reads and creates documents in text editors that declare where their prose lives"

    private let support: ProseSurfaceSupport

    public init(support: ProseSurfaceSupport = .shared) {
        self.support = support
    }

    public var skillBindings: [SkillBinding] {
        [listDocuments, readDocument, createDocument]
    }

    // MARK: - Reads

    private var listDocuments: SkillBinding {
        SkillBinding(
            name: "list_documents",
            description: "List the open documents in a text editor, with a handle for each.",
            parameters: [
                .init(
                    name: "app", type: "string",
                    description: "Which editor. Omit for the one in front.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let (registration, pid) = resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                let surfaces = ProseSurfaceAX.surfaces(pid: pid, registration: registration)
                guard !surfaces.isEmpty else {
                    return SkillOutcome(
                        ok: true,
                        summary: "\(registration.displayName) has no \(registration.noun.plural) open.",
                        foundNothing: true)
                }
                let rows = surfaces.map { surface -> String in
                    let handle = ContainerRegistry.shared.handle(
                        place: .application(registration.applicationID),
                        prefix: registration.handlePrefix,
                        key: surface.documentKey)
                    return "[\(handle)] \(surface.title)"
                }
                return SkillOutcome(
                    ok: true,
                    summary: rows.joined(separator: "\n"),
                    archivePolicy: .stateSnapshot)
            })
    }

    private var readDocument: SkillBinding {
        SkillBinding(
            name: "read_document",
            description: "Read the text of an open document.",
            parameters: [
                .init(
                    name: "app", type: "string",
                    description: "Which editor. Omit for the one in front.",
                    required: false),
                .init(
                    name: "document", type: "string",
                    description: "A handle like W2, or the document's title. Omit for the front one.",
                    required: false),
                .init(
                    name: "find", type: "string",
                    description: "Return only the part around this phrase.",
                    required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let (registration, pid) = resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                let surfaces = ProseSurfaceAX.surfaces(pid: pid, registration: registration)
                guard let surface = pick(arguments["document"], among: surfaces, registration) else {
                    return SkillOutcome(
                        ok: true,
                        summary: arguments["document"].map {
                            "I couldn't find a \(registration.noun.singular) called \"\($0)\"."
                        } ?? "\(registration.displayName) has no \(registration.noun.plural) open.",
                        foundNothing: true)
                }
                guard let text = ProseSurfaceAX.fullString(of: surface.editor) else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't read \"\(surface.title)\" just now.")
                }
                let body = excerpt(
                    text, around: arguments["find"], budgets: registration.budgets)
                return SkillOutcome(
                    ok: true,
                    summary: body.isEmpty
                        ? "\"\(surface.title)\" is empty."
                        : body,
                    archivePolicy: .stateSnapshot,
                    foundNothing: body.isEmpty,
                    // WHAT WAS READ, as a record. A read acts on nothing, so
                    // this is not an acted element — it is the element the
                    // answer came out of, which is what lets a later edit be
                    // matched to the read that motivated it.
                    target: ActedElementReader.record(of: surface.editor, pid: pid),
                    adapterTrail: ["prose-surface"])
            })
    }

    // MARK: - Creating

    private var createDocument: SkillBinding {
        SkillBinding(
            name: "create_document",
            description: "Make a new empty document in a text editor.",
            parameters: [
                .init(
                    name: "app", type: "string",
                    description: "Which editor. Omit for the one in front.",
                    required: false),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let (registration, pid) = resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                guard let chord = registration.newDocumentChord else {
                    return SkillOutcome(
                        ok: false,
                        summary: "\(registration.displayName) hasn't told me how to make a new \(registration.noun.singular).")
                }
                let before = Set(
                    ProseSurfaceAX.surfaces(pid: pid, registration: registration)
                        .map(\.documentKey))

                let activation = await VerifiedActivation.bringForward(pid: pid)
                guard activation.succeeded else {
                    return SkillOutcome(
                        ok: false,
                        summary: activation.reason(app: registration.displayName)
                            ?? "\(registration.displayName) didn't come forward.")
                }
                guard KeyChordPress.press(key: chord.key, modifiers: chord.modifiers) else {
                    return SkillOutcome(
                        ok: false, summary: "The new-\(registration.noun.singular) shortcut didn't go through.")
                }

                // WAIT FOR THE DOCUMENT TO EXIST, rather than assuming the
                // keystroke worked. A window takes a moment to appear, and a
                // create that reported success before its document existed
                // would send the very next typing Skill into the old one.
                var appeared: ProseSurfaceAX.Surface?
                let deadline = Date().addingTimeInterval(2.0)
                while Date() < deadline, appeared == nil {
                    appeared = ProseSurfaceAX.surfaces(pid: pid, registration: registration)
                        .first { !before.contains($0.documentKey) }
                    if appeared == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                guard let made = appeared else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I pressed the shortcut but no new \(registration.noun.singular) appeared.")
                }

                // The typer's handshake: the next write goes HERE, not to
                // whatever the turn's attention pointed at before this ran.
                StagedWritingSurface.shared.record(
                    bundleID: registration.bundleIdentifiers.first ?? "",
                    spokenName: registration.displayName)

                return SkillOutcome(
                    ok: true,
                    summary: "New \(registration.noun.singular) in \(registration.displayName).",
                    target: ActedElementReader.record(of: made.editor, pid: pid),
                    adapterTrail: ["prose-surface"])
            })
    }

    // MARK: - Internals

    /// Which editor this call is about, and whether it is running.
    ///
    /// Named explicitly, else the frontmost declared surface. NEVER the sole
    /// registered one: with several editors installed, "read my note" with
    /// nothing in front is a question, and answering it from whichever
    /// package happens to be alone is a guess wearing a fact's clothes.
    private func resolve(_ requested: String?) -> (ProseSurfaceRegistration, pid_t)? {
        if let requested, !requested.isEmpty {
            let wanted = requested.lowercased()
            if let match = support.all().first(where: {
                $0.applicationID.lowercased() == wanted
                    || $0.displayName.lowercased() == wanted
                    || $0.owns(bundleID: requested)
            }), let pid = ProseSurfaceSupport.pid(of: match) {
                return (match, pid)
            }
            return nil
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              let registration = support.registration(bundleID: bundleID)
        else { return nil }
        return (registration, front.processIdentifier)
    }

    private func notRunning(_ requested: String?) -> SkillOutcome {
        guard let requested, !requested.isEmpty else {
            return SkillOutcome(
                ok: true,
                summary: "There's no text editor in front of me right now.",
                foundNothing: true)
        }
        return ClosedWorld.read(app: requested)
    }

    /// The document a phrase names — a handle first, then an exact title,
    /// then a unique partial. Ambiguity refuses rather than picking.
    private func pick(
        _ phrase: String?,
        among surfaces: [ProseSurfaceAX.Surface],
        _ registration: ProseSurfaceRegistration
    ) -> ProseSurfaceAX.Surface? {
        guard let phrase, !phrase.isEmpty else { return surfaces.first }
        let place = AmbientPlace.application(registration.applicationID)
        if let resolved = ContainerRegistry.shared.resolvePlace(phrase),
           resolved.place == place,
           let match = surfaces.first(where: { $0.documentKey == resolved.key }) {
            return match
        }
        let wanted = phrase.lowercased()
        if let exact = surfaces.first(where: { $0.title.lowercased() == wanted }) {
            return exact
        }
        let partial = surfaces.filter { $0.title.lowercased().contains(wanted) }
        return partial.count == 1 ? partial.first : nil
    }

    /// The whole document, or the part around a phrase.
    private func excerpt(
        _ text: String, around find: String?, budgets: PluginProseBudgetSchema
    ) -> String {
        guard let find, !find.isEmpty,
              let range = text.range(of: find, options: .caseInsensitive)
        else { return String(text.prefix(budgets.wholeDocumentCharacters)) }

        let window = budgets.regionCharacters / 2
        let start = text.index(
            range.lowerBound, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(
            range.upperBound, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
}
