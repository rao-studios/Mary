//
//  CodeSurfaceAdapter+Family.swift
//  MaryPlugin
//
//  THE REST OF THE CODE-SURFACE FAMILY — current file, symbol, lines, and
//  the disk writes Bonnie's native editor plugin already had. Nothing here
//  names an application. `read_symbol` uses `SwiftSymbolLocator` when the
//  live project's corpus notation is `swift`; otherwise it searches the
//  package's declared `declarations` patterns.
//

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation

extension CodeSurfaceAdapter {

    var familyReadBindings: [SkillBinding] {
        [currentFile, readSymbol, readLines]
    }

    var familyEditBindings: [SkillBinding] {
        [replaceSymbol, insertCode, applyEdit, createFile]
    }

    public var targetedRead: (binding: String, parameter: String)? {
        ("read_symbol", "symbol")
    }

    /// Each package that declares a `codeSurface` is a place whose lead owner
    /// is the application id (`"xcode"`), not `"code-surface"`. Fetch-first
    /// and `wouldServeLook` look the targeted-read table up by that owner.
    public var targetedReadAliases: [String] {
        support.all().map(\.applicationID)
    }

    // MARK: - Writes onto disk

    func writeLiveFile(
        _ newText: String,
        surface: CodeSurfaceAX.Surface,
        registration: CodeSurfaceRegistration,
        summary: String
    ) -> SkillOutcome {
        guard let diskURL = CodeSurfaceWriter.fileURL(fromDocumentKey: surface.documentKey)
        else {
            return SkillOutcome(
                ok: false,
                summary: PassageWriteError.noDiskLocation(document: surface.title)
                    .errorDescription ?? "That file has never been saved.")
        }
        guard let diskText = try? String(contentsOf: diskURL, encoding: .utf8) else {
            return SkillOutcome(ok: false, summary: "I couldn't read \"\(surface.title)\" from disk just now.")
        }
        guard let liveText = CodeSurfaceAX.fullString(of: surface.editor) else {
            return SkillOutcome(ok: false, summary: "I couldn't read \"\(surface.title)\" just now.")
        }
        if let refusal = CodeSurfaceWriter.cleanBufferRefusal(
            live: liveText, disk: diskText, documentTitle: surface.title) {
            return SkillOutcome(ok: false, summary: refusal.errorDescription ?? "")
        }
        do {
            try CodeSurfaceWriter.atomicWrite(newText, to: diskURL)
        } catch {
            return SkillOutcome(
                ok: false,
                summary: "I couldn't write \"\(surface.title)\": \(error.localizedDescription)")
        }
        return SkillOutcome(
            ok: true,
            summary: "\(summary) in \(surface.title).",
            adapterTrail: [AdapterID.normalized(name)])
    }

    // MARK: - Reads

    private var currentFile: SkillBinding {
        SkillBinding(
            name: "current_file",
            description: "What file the user is looking at in the front code editor right now.",
            parameters: [
                .init(name: "app", type: "string",
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
                var brief = "Looking at \(surface.title) in \(registration.displayName)."
                if let corpus = CorpusSupport.shared.registration(
                    applicationID: registration.applicationID),
                   let focus = CorpusObserver.focus(pid: pid, registration: corpus) {
                    brief = "Looking at \(focus.relativePath) in \(focus.projectName)."
                }
                return SkillOutcome(
                    ok: true, summary: brief, archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    private var readSymbol: SkillBinding {
        SkillBinding(
            name: "read_symbol",
            description: "Read a function or type by name from the file open in the front editor.",
            parameters: [
                .init(name: "symbol", type: "string",
                      description: "The name to read.", required: true),
                .init(name: "app", type: "string",
                      description: "Which editor. Omit for the one in front.",
                      required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let wanted = arguments["symbol"], !wanted.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Which symbol?")
                }
                guard let (registration, pid) = resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                guard let surface = CodeSurfaceEditorCache.frontSurface(
                    pid: pid, registration: registration),
                      let text = CodeSurfaceAX.fullString(of: surface.editor)
                else {
                    return SkillOutcome(
                        ok: true,
                        summary: "\(registration.displayName) has no source file open.",
                        foundNothing: true)
                }
                let notation = CorpusSupport.shared.registration(
                    applicationID: registration.applicationID)?.schema.notation
                if notation == "swift" || notation == nil {
                    switch SwiftSymbolLocator.locate(symbol: wanted, in: text) {
                    case .found(let span):
                        let body = String(text[span.declStart..<span.fullEnd])
                        return SkillOutcome(
                            ok: true,
                            summary: "\(span.display):\n"
                                + TextBudget.truncate(body, limit: 2000),
                            archivePolicy: .stateSnapshot,
                            adapterTrail: [AdapterID.normalized(name)])
                    case .ambiguous(let spans):
                        return SkillOutcome(
                            ok: true,
                            summary: "There are \(spans.count) things called \(wanted) in this file.",
                            foundNothing: true)
                    case .notFound:
                        break
                    }
                }
                return SkillOutcome(
                    ok: true, summary: "I don't see \(wanted) in this file.",
                    foundNothing: true)
            })
    }

    private var readLines: SkillBinding {
        SkillBinding(
            name: "read_lines",
            description: "Read a line range from the file open in the front editor.",
            parameters: [
                .init(name: "start", type: "string",
                      description: "First line number.", required: true),
                .init(name: "end", type: "string",
                      description: "Last line number; omit for a window around start.",
                      required: false),
                .init(name: "app", type: "string",
                      description: "Which editor. Omit for the one in front.",
                      required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let startText = arguments["start"],
                      let start = Int(startText.filter(\.isNumber)), start >= 1
                else {
                    return SkillOutcome(ok: false, summary: "Which line number?")
                }
                let end = arguments["end"].flatMap { Int($0.filter(\.isNumber)) }
                guard let (registration, pid) = resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                guard let surface = CodeSurfaceEditorCache.frontSurface(
                    pid: pid, registration: registration),
                      let text = CodeSurfaceAX.fullString(of: surface.editor)
                else {
                    return SkillOutcome(
                        ok: true,
                        summary: "\(registration.displayName) has no source file open.",
                        foundNothing: true)
                }
                let lines = text.components(separatedBy: "\n")
                guard start <= lines.count else {
                    return SkillOutcome(
                        ok: true, summary: "The file doesn't reach line \(start).",
                        foundNothing: true)
                }
                let last = min(end ?? (start + 24), lines.count)
                let slice = lines[(start - 1)..<last].joined(separator: "\n")
                return SkillOutcome(
                    ok: true,
                    summary: "\(surface.title) \(start)–\(last):\n"
                        + TextBudget.truncate(slice, limit: 1800),
                    archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - Edits

    private var replaceSymbol: SkillBinding {
        SkillBinding(
            name: "replace_symbol",
            description: "Replace a whole function or type in the open file with new source, written to disk.",
            parameters: [
                .init(name: "symbol", type: "string",
                      description: "The function or type name to replace.", required: true),
                .init(name: "new_source", type: "string",
                      description: "The complete new declaration.", required: true),
                .init(name: "app", type: "string", description: "Which editor. Omit for the one in front.", required: false),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                await editLive(arguments) { text, args in
                    try CodeSurfaceEdit.replaceSymbol(
                        args["symbol"] ?? "", with: args["new_source"] ?? "", in: text)
                }
            })
    }

    private var insertCode: SkillBinding {
        SkillBinding(
            name: "insert_code",
            description: "Add a complete new function or block to the open file — after a named symbol, or at the end.",
            parameters: [
                .init(name: "source", type: "string",
                      description: "The complete code to add.", required: true),
                .init(name: "after_symbol", type: "string",
                      description: "Insert after this symbol; omit for end of file.",
                      required: false),
                .init(name: "app", type: "string", description: "Which editor. Omit for the one in front.", required: false),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                await editLive(arguments) { text, args in
                    try CodeSurfaceEdit.insertCode(
                        args["source"] ?? "", afterSymbol: args["after_symbol"], in: text)
                }
            })
    }

    private var applyEdit: SkillBinding {
        SkillBinding(
            name: "apply_edit",
            description: "Find one exact snippet in the open file and replace it. Refuses if the snippet appears zero or many times.",
            parameters: [
                .init(name: "find", type: "string",
                      description: "The exact text to find (must be unique).", required: true),
                .init(name: "replace", type: "string",
                      description: "The replacement text.", required: true),
                .init(name: "app", type: "string", description: "Which editor. Omit for the one in front.", required: false),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                await editLive(arguments) { text, args in
                    try CodeSurfaceEdit.applyEdit(
                        find: args["find"] ?? "", replace: args["replace"] ?? "", in: text)
                }
            })
    }

    private var createFile: SkillBinding {
        SkillBinding(
            name: "create_file",
            description: "Create a new source file in the live project. Destination is under the project root the corpus resolved.",
            parameters: [
                .init(name: "path", type: "string",
                      description: "File name or project-relative path.", required: true),
                .init(name: "contents", type: "string",
                      description: "The file's contents.", required: true),
                .init(name: "app", type: "string", description: "Which editor. Omit for the one in front.", required: false),
            ],
            access: .write,
            backing: .native { arguments, _ in
                guard let relative = arguments["path"], !relative.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Where should the file go?")
                }
                guard let contents = arguments["contents"] else {
                    return SkillOutcome(ok: false, summary: "What should be in it?")
                }
                guard let (registration, pid) = resolve(arguments["app"]) else {
                    return notRunning(arguments["app"])
                }
                guard let corpus = CorpusSupport.shared.registration(
                    applicationID: registration.applicationID),
                      let focus = CorpusObserver.focus(pid: pid, registration: corpus)
                else {
                    return SkillOutcome(
                        ok: false,
                        summary: "I don't know which project you're in — open a file first.")
                }
                let root = URL(fileURLWithPath: focus.root, isDirectory: true)
                let dest = root.appendingPathComponent(relative).standardizedFileURL
                guard dest.path.hasPrefix(root.standardizedFileURL.path) else {
                    return SkillOutcome(ok: false, summary: "That path would leave the project.")
                }
                if FileManager.default.fileExists(atPath: dest.path) {
                    return SkillOutcome(ok: false, summary: "\(dest.lastPathComponent) already exists.")
                }
                do {
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try CodeSurfaceWriter.atomicWrite(contents, to: dest)
                } catch {
                    return SkillOutcome(
                        ok: false,
                        summary: "I couldn't create that file: \(error.localizedDescription)")
                }
                return SkillOutcome(
                    ok: true,
                    summary: "Created \(relative) in \(focus.projectName).",
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    private func editLive(
        _ arguments: [String: String],
        transform: (String, [String: String]) throws -> CodeSurfaceEditResult
    ) async -> SkillOutcome {
        guard let (registration, pid) = resolve(arguments["app"]) else {
            return notRunning(arguments["app"])
        }
        guard let surface = CodeSurfaceEditorCache.frontSurface(
            pid: pid, registration: registration),
              let text = CodeSurfaceAX.fullString(of: surface.editor)
        else {
            return SkillOutcome(
                ok: true,
                summary: "\(registration.displayName) has no source file open.",
                foundNothing: true)
        }
        do {
            let result = try transform(text, arguments)
            return writeLiveFile(
                result.newText, surface: surface, registration: registration,
                summary: result.summary)
        } catch {
            return SkillOutcome(
                ok: false,
                summary: error.localizedDescription)
        }
    }
}
