//
//  ProseSurfaceAdapter.swift
//  MaryPlugin
//
//  WHAT: Skills a declared prose surface answers (list, read, create).
//  PIN:  No app named. create_document is here because a recipe cannot return identity.

import AppKit
import Foundation
import MaryAmbient
import MaryComputerUse
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

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(
            _ name: String, capability: CapabilityID
        ) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID, operation: name,
                capabilities: [capability],
                outputTypes: ["writing.text"],
                targetClasses: ["editable-prose-surface", "document-workspace"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Prose Surface",
            transport: .accessibility,
            operations: [
                operation("list_documents", capability: "prose.list-documents"),
                operation("read_document", capability: "prose.read-document"),
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "create_document",
                    capabilities: ["prose.create-document"],
                    outputTypes: ["writing.text"],
                    targetClasses: ["editable-prose-surface", "document-workspace"]),
            ],
            supportedValueTypes: ["writing.text"],
            grantedPermissions: [.accessibility])
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
                    // WHAT WAS READ, as a record. A read acts on nothing, so this is not an
                    // acted element.
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
                let before = ProseSurfaceAX.surfaces(
                    pid: pid, registration: registration).count

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

                // WAIT FOR THE DOCUMENT TO EXIST, rather than assuming the keystroke
                // worked.
                var appeared: ProseSurfaceAX.Surface?
                let deadline = Date().addingTimeInterval(2.0)
                while Date() < deadline, appeared == nil {
                    let now = ProseSurfaceAX.surfaces(pid: pid, registration: registration)
                    if now.count > before { appeared = now.first }
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
    private func resolve(_ requested: String?) -> (ProseSurfaceRegistration, pid_t)? {
        support.resolve(requested)
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
