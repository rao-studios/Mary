//
//  CodeSurfaceAdapter.swift
//  MaryPlugin
//
//  THE SKILLS A DECLARED CODE SURFACE CAN ANSWER — read the live buffer, read
//  the live selection.
//
//  WHY THESE ARE HERE AND NOT IN A PACKAGE. A managed-UI recipe presses keys
//  and reports whether the press landed; it has no channel for handing a
//  value back (`PluginSchema`'s header, consequence 1). So a Skill that must
//  give the model a VALUE — the buffer's text, the selection's text — has to
//  bind to a compiled provider, and this is that provider for the code
//  family. `ProseSurfaceAdapter`'s sibling, minus its whole write half: Mary
//  has no code-writing lane, so there is no `create_document` here and
//  neither Skill below ever presses a key.
//
//  NO APPLICATION IS NAMED. Each Skill takes an optional `app`; the
//  registration behind it decides everything else.
//
//  THIS IS MARY'S CLOSEST ANALOGUE TO BONNIE'S OLD `read_selection` /
//  cursor-scope tool — the piece "read my repo" (the project-corpus lane)
//  could never cover, because a corpus read comes from disk and an unsaved
//  edit is not on disk yet. `read_buffer` and `read_selection` read the live
//  in-memory buffer instead, verified by the spike this file's sibling
//  (`CodeSurfaceAX`) replaces: an unsaved edit shows up on the very next
//  read, while the file's own mtime never moves.
//

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation

public struct CodeSurfaceAdapter: MaryAdapter {

    public let name = "code-surface"
    public let summary =
        "reads a code editor's live buffer and current selection through Accessibility"

    private let support: CodeSurfaceSupport

    public init(support: CodeSurfaceSupport = .shared) {
        self.support = support
    }

    public var skillBindings: [SkillBinding] {
        [readBuffer, readSelection]
    }

    /// A FULLY DECLARED MANIFEST, ON `ProjectCorpusAdapter`'s PATTERN rather
    /// than the protocol's minimal default. The default reports `.native`
    /// transport with bare operation names and nothing else, which is
    /// honest but leaves `targetClasses` empty — and an empty `targetClasses`
    /// on the OPERATION is exactly the shape of the routing carve-out this
    /// branch has found twice already (a whole skill family structurally
    /// valid and unreachable through real dispatch because nothing produced
    /// its target classes). Declaring it here, matching what `xcode.mary`'s
    /// own `application.targetClasses` and this adapter's Skill bindings both
    /// name, keeps that gap from opening a third time.
    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(
            _ name: String, capability: CapabilityID
        ) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID, operation: name,
                capabilities: [capability],
                outputTypes: ["coding.code-text"],
                targetClasses: ["code-workspace"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            // THE TITLE IS SPOKEN — see `ProjectCorpusAdapter`'s own note.
            title: "Code Surface",
            transport: .accessibility,
            operations: [
                operation("read_buffer", capability: "code.read-buffer"),
                operation("read_selection", capability: "code.read-selection"),
            ],
            supportedValueTypes: ["coding.code-text"],
            grantedPermissions: [.accessibility])
    }

    // MARK: - Reading the buffer

    private var readBuffer: SkillBinding {
        SkillBinding(
            name: "read_buffer",
            description: """
            Read the live source code in the front editor's buffer, including \
            unsaved edits not yet on disk. Call this before describing, \
            explaining, or answering any question about code that's open \
            right now — "what does this do", "what does this function do", \
            "what am I looking at" — rather than guessing at code you have \
            not actually read this turn.
            """,
            parameters: [
                .init(
                    name: "app", type: "string",
                    description: "Which editor. Omit for the one in front.",
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
                guard let surface = CodeSurfaceAX.frontSurface(pid: pid, registration: registration)
                else {
                    return SkillOutcome(
                        ok: true,
                        summary: "\(registration.displayName) has no source file open.",
                        foundNothing: true)
                }
                guard let text = CodeSurfaceAX.fullString(of: surface.editor) else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't read \"\(surface.title)\" just now.")
                }
                let body = Self.excerpt(text, around: arguments["find"], budgets: registration.budgets)
                return SkillOutcome(
                    ok: true,
                    summary: body.isEmpty
                        ? "\"\(surface.title)\" is empty."
                        : "\(surface.title):\n\(body)",
                    archivePolicy: .stateSnapshot,
                    foundNothing: body.isEmpty,
                    // WHAT WAS READ, as a record — a read acts on nothing, so
                    // this is not an acted element, it is the element the
                    // answer came out of. `ProseSurfaceAdapter.readDocument`'s
                    // same move.
                    target: ActedElementReader.record(of: surface.editor, pid: pid),
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - Reading the selection

    private var readSelection: SkillBinding {
        SkillBinding(
            name: "read_selection",
            description: """
            Read the text currently highlighted/selected in the editor, with \
            a little surrounding context. Call this whenever the user says \
            "this", "this code", "the selected code", or asks you to read or \
            explain what's selected — never assume or guess what's selected.
            """,
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
                guard let surface = CodeSurfaceAX.frontSurface(pid: pid, registration: registration)
                else {
                    return SkillOutcome(
                        ok: true,
                        summary: "\(registration.displayName) has no source file open.",
                        foundNothing: true)
                }
                guard let selection = CodeSurfaceAX.selectedRange(of: surface.editor),
                      !selection.isEmpty
                else {
                    return SkillOutcome(
                        ok: true,
                        summary: "Nothing is selected in \"\(surface.title)\".",
                        foundNothing: true)
                }
                guard let selected = CodeSurfaceAX.substring(of: surface.editor, range: selection)
                else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't read the selection in \"\(surface.title)\" just now.")
                }

                // A WINDOW EITHER SIDE, IN THE ELEMENT'S OWN COORDINATES —
                // never by locating `selected` inside a materialized whole
                // buffer, which would need to reconcile AX's character
                // coordinates against `String.Index` for no reason: the same
                // parameterized read that gave us the selection gives us its
                // neighbourhood directly.
                let half = max(registration.budgets.regionCharacters / 2, 0)
                let total = CodeSurfaceAX.characterCount(of: surface.editor) ?? selection.upperBound
                let contextStart = max(0, selection.lowerBound - half)
                let contextEnd = min(total, selection.upperBound + half)
                let before = contextStart < selection.lowerBound
                    ? (CodeSurfaceAX.substring(
                        of: surface.editor, range: contextStart..<selection.lowerBound) ?? "")
                    : ""
                let after = selection.upperBound < contextEnd
                    ? (CodeSurfaceAX.substring(
                        of: surface.editor, range: selection.upperBound..<contextEnd) ?? "")
                    : ""

                return SkillOutcome(
                    ok: true,
                    summary: "\(surface.title):\n\(before)[[\(selected)]]\(after)",
                    archivePolicy: .stateSnapshot,
                    target: ActedElementReader.record(of: surface.editor, pid: pid),
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - Internals

    /// Which editor this call is about, and whether it is running. Named
    /// explicitly, else the frontmost declared surface — `ProseSurfaceAdapter
    /// .resolve`'s same rule, and the same reason: with several editors
    /// installed, "read my buffer" with nothing in front is a question, not a
    /// guess to answer from whichever package happens to be alone.
    private func resolve(_ requested: String?) -> (CodeSurfaceRegistration, pid_t)? {
        if let requested, !requested.isEmpty {
            let wanted = requested.lowercased()
            if let match = support.all().first(where: {
                $0.applicationID.lowercased() == wanted
                    || $0.displayName.lowercased() == wanted
                    || $0.owns(bundleID: requested)
            }), let pid = CodeSurfaceSupport.pid(of: match) {
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
                summary: "There's no code editor in front of me right now.",
                foundNothing: true)
        }
        return ClosedWorld.read(app: requested)
    }

    /// The whole buffer, or the part around a phrase — `ProseSurfaceAdapter
    /// .excerpt`'s same shape, reused rather than duplicated in spirit
    /// because the underlying question is identical: how much text to hand
    /// back, bounded by the same kind of declared budget.
    ///
    /// `static` and not `private`, on `ProjectCorpusAdapter.locate`'s
    /// precedent: it is pure text logic with no Accessibility dependency, so
    /// a unit test can pin its windowing directly rather than only through a
    /// live probe.
    static func excerpt(
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
