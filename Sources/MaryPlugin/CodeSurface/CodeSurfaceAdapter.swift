//
//  CodeSurfaceAdapter.swift
//  MaryPlugin
//
//  WHAT: Skills a declared code surface answers (buffer, selection, replace).
//  IN:   CodeSurfaceEditorCache  OUT: CodeSurfaceWriter / PassageEditRunner
//  PIN:  No app named. replace_selection is disk write, not AX set.

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation
import os

public struct CodeSurfaceAdapter: MaryAdapter {

    public let name = "code-surface"
    public let summary =
        "reads a code editor's live buffer and current selection through Accessibility"

    let support: CodeSurfaceSupport

    public init(support: CodeSurfaceSupport = .shared) {
        self.support = support
    }

    public var skillBindings: [SkillBinding] {
        [readBuffer, readSelection, listDeclarations, replaceSelection]
            + familyReadBindings + familyEditBindings
    }

    /// A FULLY DECLARED MANIFEST, ON `ProjectCorpusAdapter`'s PATTERN rather than the
    /// protocol's minimal default.
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
                operation("list_declarations", capability: "code.list-declarations"),
                operation("current_file", capability: "code.workspace.inspect"),
                operation("read_symbol", capability: "code.buffer.read-symbol"),
                operation("read_lines", capability: "code.buffer.read-lines"),
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "replace_selection",
                    capabilities: ["code.replace-selection"],
                    inputTypes: ["coding.code-text"],
                    targetClasses: ["code-workspace"]),
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "replace_symbol",
                    capabilities: ["code.replace-symbol"],
                    inputTypes: ["coding.code-text"],
                    targetClasses: ["code-workspace"]),
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "insert_code",
                    capabilities: ["code.insert-code"],
                    inputTypes: ["coding.code-text"],
                    targetClasses: ["code-workspace"]),
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "apply_edit",
                    capabilities: ["code.apply-edit"],
                    inputTypes: ["coding.code-text"],
                    targetClasses: ["code-workspace"]),
                InstalledAdapterBinding(
                    adapterID: adapterID, operation: "create_file",
                    capabilities: ["code.create-file"],
                    inputTypes: ["coding.code-text"],
                    targetClasses: ["code-workspace"]),
            ],
            supportedValueTypes: ["coding.code-text"],
            grantedPermissions: [.accessibility, .files])
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
                guard let surface = CodeSurfaceEditorCache.frontSurface(
                    pid: pid, registration: registration)
                else {
                    let line = "read_buffer — \(registration.displayName) has no source file open"
                    TurnLog.logger.info("\(line, privacy: .public)")
                    return SkillOutcome(
                        ok: true,
                        summary: "\(registration.displayName) has no source file open.",
                        foundNothing: true)
                }
                guard let text = CodeSurfaceAX.fullString(of: surface.editor) else {
                    let line = "read_buffer — could not read \"\(surface.title)\""
                    TurnLog.logger.info("\(line, privacy: .public)")
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't read \"\(surface.title)\" just now.")
                }
                // No `find`: "what does this do" means the part they're
                // looking at, not the file's first N characters — window on
                // the caret. Falls back to the old file-start excerpt when
                // the caret can't be read (e.g. no selection info).
                let find = arguments["find"]
                var body: String
                var headerSuffix = ""
                if let windowed = (find?.isEmpty ?? true)
                    ? Self.caretWindow(editor: surface.editor, budgets: registration.budgets)
                    : nil {
                    body = windowed.body
                    headerSuffix = windowed.headerSuffix
                } else {
                    body = Self.excerpt(text, around: find, budgets: registration.budgets)
                }
                let line = "read_buffer — \(surface.title) chars=\(body.count) empty=\(body.isEmpty)"
                TurnLog.logger.info("\(line, privacy: .public)")
                return SkillOutcome(
                    ok: true,
                    summary: body.isEmpty
                        ? "\"\(surface.title)\" is empty."
                        : "\(surface.title)\(headerSuffix):\n\(body)",
                    archivePolicy: .stateSnapshot,
                    foundNothing: body.isEmpty,
                    // WHAT WAS READ, as a record — a read acts on nothing, so this is not
                    // an acted element, it is the element the answer came out of.
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
                guard let surface = CodeSurfaceEditorCache.frontSurface(
                    pid: pid, registration: registration)
                else {
                    let line = "read_selection — \(registration.displayName) has no source file open"
                    TurnLog.logger.info("\(line, privacy: .public)")
                    return SkillOutcome(
                        ok: true,
                        summary: "\(registration.displayName) has no source file open.",
                        foundNothing: true)
                }
                guard let selection = CodeSurfaceAX.selectedRange(of: surface.editor),
                      !selection.isEmpty
                else {
                    let line = "read_selection — nothing selected in \"\(surface.title)\""
                    TurnLog.logger.info("\(line, privacy: .public)")
                    return SkillOutcome(
                        ok: true,
                        summary: "Nothing is selected in \"\(surface.title)\".",
                        foundNothing: true)
                }
                guard let selected = CodeSurfaceAX.substring(of: surface.editor, range: selection)
                else {
                    let line = "read_selection — could not read selection in \"\(surface.title)\""
                    TurnLog.logger.info("\(line, privacy: .public)")
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't read the selection in \"\(surface.title)\" just now.")
                }

                // A WINDOW EITHER SIDE, IN THE ELEMENT'S OWN COORDINATES — never by
                // locating `selected` inside a materialized whole buffer, which would.
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

                let line = "read_selection — \(surface.title) chars=\(selected.count)"
                TurnLog.logger.info("\(line, privacy: .public)")
                return SkillOutcome(
                    ok: true,
                    summary: "\(surface.title):\n\(before)[[\(selected)]]\(after)",
                    archivePolicy: .stateSnapshot,
                    target: ActedElementReader.record(of: surface.editor, pid: pid),
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - Listing declarations

    /// A LIGHTWEIGHT OUTLINE OVER THE SAME BUFFER `read_buffer` ALREADY FETCHES — no new AX
    /// surface, no jump-bar reading.
    private var listDeclarations: SkillBinding {
        SkillBinding(
            name: "list_declarations",
            description: """
            List the declarations — structs, classes, enums, actors, \
            protocols, typealiases and functions — found in the front \
            editor's buffer, including unsaved edits, with their \
            approximate line numbers. Call this for a quick outline of what \
            a file contains — "what's in this file", "what functions does \
            this have", "give me an outline" — before reading the whole \
            buffer with read_buffer.
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
                guard let surface = CodeSurfaceEditorCache.frontSurface(
                    pid: pid, registration: registration)
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
                guard let corpus = CorpusSupport.shared
                    .registration(applicationID: registration.applicationID)?.schema,
                    !corpus.relations.declarations.isEmpty
                else {
                    return SkillOutcome(
                        ok: true,
                        summary: "\(registration.displayName) has no declared outline patterns.",
                        foundNothing: true)
                }
                let bounded = String(text.prefix(registration.budgets.wholeDocumentCharacters))
                let found = Self.declarations(in: bounded, patterns: corpus.relations.declarations)
                let body = found.isEmpty
                    ? nil
                    : found.map { "\($0.name) — line \($0.line)" }.joined(separator: "\n")
                var outcome = SkillOutcome(
                    ok: true,
                    summary: body.map { "\(surface.title):\n\($0)" }
                        ?? "\"\(surface.title)\" has no recognizable declarations.",
                    archivePolicy: .stateSnapshot,
                    foundNothing: body == nil,
                    target: ActedElementReader.record(of: surface.editor, pid: pid),
                    adapterTrail: [AdapterID.normalized(name)])
                if let body {
                    outcome.typedOutputs["declarations"] = ValueEnvelope(
                        typeID: "coding.code-text",
                        value: .string(body),
                        provenance: .init(
                            adapterID: AdapterID.normalized(name), operation: name),
                        privacy: .private)
                }
                return outcome
            })
    }

    /// Every declaration `patterns` finds in `text`, ordered by line —
    /// `CorpusPatterns.capturesWithLines` run once per declared pattern and merged.
    static func declarations(
        in text: String, patterns: [String]
    ) -> [CorpusPatterns.PositionedCapture] {
        patterns
            .flatMap { CorpusPatterns.capturesWithLines($0, in: text) }
            .sorted { $0.line < $1.line }
    }

    // MARK: - Replacing the selection

    /// Narrower than the five shared passage verbs on purpose — see this file's header — it
    /// needs no `passage`/`target` argument because the.
    private var replaceSelection: SkillBinding {
        SkillBinding(
            name: "replace_selection",
            description: """
            Replace the code currently selected in the editor with code YOU \
            write, straight to the file on disk — the editor reloads it \
            automatically within a second or two. This is how you carry out \
            "reword this comment", "make this more concise", "tidy this up", \
            "simplify this function": write the revised version yourself and \
            pass it as `text`. Refuses if the file has unsaved changes; save \
            first (Cmd-S), then ask again. Call read_selection first if \
            you're not certain what's selected.
            """,
            parameters: [
                .init(
                    name: "text", type: "string",
                    description: "The replacement code, exactly as it should "
                        + "read — including any revision you were asked to make.",
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
                guard let surface = CodeSurfaceEditorCache.frontSurface(
                    pid: pid, registration: registration)
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

                // A FILE THAT HAS NEVER BEEN SAVED HAS NO DISK LOCATION TO WRITE TO —
                // refused here, in its own clear words, rather than reaching the writer
                // only to fail on the same fact.
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

                // THE BACKING — built for this one call, not installed globally: this is a
                // `.native`-bound Skill on `coding.mary`, not one of the five shared
                // passage verbs, so it never touches `PassageRecipes`' process-wide
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

                // TARGET, NOT HANDLE — the location is the live selection's own exact
                // words, searched for verbatim (`PassageWidening`'s rung 0) rather than
                // named by heading or phrase, which is what makes this narrower and safer
                return await PassageEditRunner.edit(
                    .replace, handle: nil, target: selected, text: replacement, backing: backing)
            })
    }

    // MARK: - Internals

    /// Which editor this call is about, and whether it is running.
    func resolve(_ requested: String?) -> (CodeSurfaceRegistration, pid_t)? {
        support.resolve(requested)
    }

    func notRunning(_ requested: String?) -> SkillOutcome {
        let asked = requested?.isEmpty == false ? requested! : "front"
        TurnLog.logger.info("code-surface — not running requested=\(asked, privacy: .public)")
        guard let requested, !requested.isEmpty else {
            return SkillOutcome(
                ok: true,
                summary: "There's no code editor in front of me right now.",
                foundNothing: true)
        }
        return ClosedWorld.read(app: requested)
    }

    /// The whole buffer, or the part around a phrase — `ProseSurfaceAdapter .excerpt`'s
    /// same shape, reused rather than duplicated in.
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

    /// The buffer windowed on the caret — `CodeCursorScope`'s own AX-range
    /// math (the same one `CodeSurfaceObserver` uses for the ambient live-work
    /// fact), reused here rather than a second file-start excerpt. Nil when
    /// the caret can't be read; the caller falls back to `excerpt`.
    static func caretWindow(
        editor: AXUIElement, budgets: PluginProseBudgetSchema
    ) -> (body: String, headerSuffix: String)? {
        guard let selection = CodeSurfaceAX.selectedRange(of: editor),
              let total = CodeSurfaceAX.characterCount(of: editor), total > 0
        else { return nil }
        let caret = max(0, min(selection.lowerBound, total))
        let bounds = CodeCursorScope.window(
            around: caret, total: total, budget: budgets.wholeDocumentCharacters)
        guard !bounds.isEmpty,
              let raw = CodeSurfaceAX.substring(of: editor, range: bounds)
        else { return nil }
        let body = CodeCursorScope.snapped(
            raw, cutAtStart: bounds.lowerBound > 0, cutAtEnd: bounds.upperBound < total)
        guard bounds.count < total else { return (body, "") }
        let suffix = " — around the cursor (characters \(bounds.lowerBound)–\(bounds.upperBound) of \(total))"
        return (body, suffix)
    }
}
