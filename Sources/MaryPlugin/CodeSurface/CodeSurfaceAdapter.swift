//
//  CodeSurfaceAdapter.swift
//  MaryPlugin
//
//  THE SKILLS A DECLARED CODE SURFACE CAN ANSWER — read the live buffer, read
//  the live selection, replace the live selection.
//
//  WHY THESE ARE HERE AND NOT IN A PACKAGE. A managed-UI recipe presses keys
//  and reports whether the press landed; it has no channel for handing a
//  value back (`PluginSchema`'s header, consequence 1), and — confirmed
//  against `PluginRecipeStepKind` — no disk-write primitive either. So a
//  Skill that must give the model a VALUE, or must write a byte Mary did not
//  type, has to bind to a compiled provider, and this is that provider for
//  the code family. `ProseSurfaceAdapter`'s sibling, still without
//  `create_document` (a new source file is `coding.mary`'s own ceremony, not
//  this adapter's), and none of the Skills below ever presses a key or
//  drives Accessibility's text setter — the buffer stays Xcode's own to
//  type into; `replace_selection` changes the file on disk instead.
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
//  `replace_selection` IS THE ONE WRITE, and it is not a third read. Mary
//  now HAS a code-writing lane — `CodeSurfaceWriter`'s atomic disk write,
//  Bonnie's own proven chain for the one application that never let a
//  keystroke land in it — and this is its narrowest useful shape: replace
//  exactly what `read_selection` already reports as selected, nothing
//  broader. It pairs the live selection's own range (an exact, already-
//  disambiguated location) with `PassageEditRunner`'s full nine-step guard
//  chain — locate, snapshot, identity, compute, re-check, apply, verify,
//  undo-record, re-mint — reused rather than re-implemented, exactly as that
//  file's own header asks of a new `PassageWriter` conformer. The clean-
//  buffer gate below is this operation's OWN addition to that chain: it is
//  checked here, up front, so a dirty buffer is refused in its own clear
//  words rather than surfacing as a confusing "I couldn't find that
//  passage" once the stale disk snapshot no longer contains the live
//  selection's exact text — and `CodeSurfaceWriter` checks it again,
//  immediately before writing, against the race that Steps 1 through 6 open
//  by taking hundreds of milliseconds while the user keeps typing.
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
        [readBuffer, readSelection, replaceSelection]
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
                // NO `outputTypes` — an edit reports what happened, it does
                // not hand back a value the way the two reads above do, the
                // same shape `coding.mary`'s own build/run/test/save
                // capabilities already declare.
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "replace_selection",
                    capabilities: ["code.replace-selection"],
                    inputTypes: ["coding.code-text"],
                    targetClasses: ["code-workspace"]),
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

    // MARK: - Replacing the selection

    /// THE ONE WRITE. Narrower than the five shared passage verbs on
    /// purpose — see this file's header — it needs no `passage`/`target`
    /// argument because the location is never in question: it is exactly
    /// what `read_selection` already reports, read fresh here rather than
    /// trusted from an earlier turn.
    private var replaceSelection: SkillBinding {
        SkillBinding(
            name: "replace_selection",
            description: """
            Replace the code currently selected in the editor with new code, \
            written straight to the file on disk — the editor reloads it \
            automatically within a second or two. Refuses if the file has \
            unsaved changes; save first (Cmd-S), then ask again. Call \
            read_selection first if you're not certain what's selected.
            """,
            parameters: [
                .init(
                    name: "text", type: "string",
                    description: "The replacement code, exactly as it should read.",
                    required: true),
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
                guard let replacement = arguments["text"], !replacement.isEmpty else {
                    return SkillOutcome(ok: false, summary: "There's no replacement text to write.")
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
                        summary: "Nothing is selected in \"\(surface.title)\", so there's "
                            + "nothing to replace.",
                        foundNothing: true)
                }
                guard let selected = CodeSurfaceAX.substring(of: surface.editor, range: selection)
                else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't read the selection in \"\(surface.title)\" just now.")
                }

                // A FILE THAT HAS NEVER BEEN SAVED HAS NO DISK LOCATION TO
                // WRITE TO — refused here, in its own clear words, rather
                // than reaching the writer only to fail on the same fact.
                // `documentKey` is Xcode's own `AXDocument` string, measured
                // live to be a `file://` URL rather than a bare path — see
                // `CodeSurfaceWriter.fileURL`, the one place both this
                // up-front check and the writer's own read resolve it.
                guard let diskURL = CodeSurfaceWriter.fileURL(fromDocumentKey: surface.documentKey)
                else {
                    return SkillOutcome(
                        ok: false,
                        summary: PassageWriteError.noDiskLocation(document: surface.title)
                            .errorDescription ?? "")
                }

                // THE CLEAN-BUFFER GATE, UP FRONT — see this file's header
                // and `CodeSurfaceWriter`'s own. Checked again, redundantly,
                // inside the writer immediately before it writes.
                guard let diskText = try? String(contentsOf: diskURL, encoding: .utf8) else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't read \"\(surface.title)\" from disk just now.")
                }
                guard let liveText = CodeSurfaceAX.fullString(of: surface.editor) else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't read \"\(surface.title)\" just now.")
                }
                if let refusal = CodeSurfaceWriter.cleanBufferRefusal(
                    live: liveText, disk: diskText, documentTitle: surface.title) {
                    return SkillOutcome(ok: false, summary: refusal.errorDescription ?? "")
                }

                // THE BACKING — built for this one call, not installed
                // globally: this is a `.native`-bound Skill on `coding.mary`,
                // not one of the five shared passage verbs, so it never
                // touches `PassageRecipes`' process-wide resolver. Its
                // `body()` re-reads disk fresh every time it is asked, which
                // is what gives `PassageEditRunner`'s own step 6 re-check a
                // real, current answer rather than the snapshot above.
                let documentKey = surface.documentKey
                let documentTitle = surface.title
                let backing = PassageBacking(
                    place: .application(registration.applicationID),
                    units: { text in ProseStructure.units(in: text, rules: .lines) },
                    body: {
                        guard let text = try? String(contentsOf: diskURL, encoding: .utf8)
                        else { return nil }
                        return BodySnapshot(
                            text: text, documentKey: documentKey, documentTitle: documentTitle)
                    },
                    writer: CodeSurfaceWriter(registration: registration))

                // TARGET, NOT HANDLE — the location is the live selection's
                // own exact words, searched for verbatim
                // (`PassageWidening`'s rung 0) rather than named by heading
                // or phrase, which is what makes this narrower and safer
                // than the general-purpose `replace_passage`.
                return await PassageEditRunner.edit(
                    .replace, handle: nil, target: selected, text: replacement, backing: backing)
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
