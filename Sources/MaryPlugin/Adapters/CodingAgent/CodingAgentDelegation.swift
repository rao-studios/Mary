//
//  CodingAgentDelegation.swift
//  MaryPlugin
//
//  Bonnie's coding-delegate brief, rebuilt from the live code surface and
//  project root. Never names a product — the editor's displayName and the
//  focused file arrive from the package registration.
//

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation

enum CodingAgentDelegation {

    struct LiveContext: Sendable {
        var filePath: String
        var editorName: String
        var selectedSymbolName: String?
        var selectedLine: Int?
        var windowText: String
        var selectedRange: Range<Int>?
    }

    struct Target: Sendable {
        var task: String
        var workdir: String
        var projectName: String
        var context: LiveContext?
        var usesRememberedRoot: Bool
    }

    static func delegationBrief(
        task: String,
        context: LiveContext?,
        workdir: String? = nil,
        style: String? = nil
    ) -> String {
        var brief = "Task from a live voice pair-coding conversation: \(task)"
        if let context {
            var location = "\n\nThe user is in \(context.editorName) editing \(context.filePath)"
            if let symbol = context.selectedSymbolName {
                location += ", in \(symbol)"
            }
            if let line = context.selectedLine {
                location += " around line \(line)"
            }
            brief += location + "."
            if let range = context.selectedRange, !range.isEmpty, !context.windowText.isEmpty {
                brief += " Their current selection is within:\n```\n\(context.windowText)\n```"
            }
        }
        if let workdir {
            brief += "\n\nThe authorized project root is \(workdir). Keep every file operation inside it."
        }
        if let style, !style.isEmpty {
            brief += "\n\n\(style)"
        }
        brief += "\n\nKeep the change minimal and compilable, and write it the way they write. If a new file must be added to a project target, update the project file too."
        return brief
    }

    static func styleBlock(for projectRoot: String?) -> String {
        guard let producer = StyleProducerRegistry.shared.producer(for: .coding) else {
            return ""
        }
        let tenets = StyleEvidenceStore.shared.renderable(
            forAbility: producer.ability,
            applications: producer.applications,
            languages: producer.languages,
            projectRoot: projectRoot)
        return StyleRendering.block(
            for: tenets, heading: producer.heading) ?? ""
    }

    static func target(
        arguments: [String: String],
        context: AbilityExecutionContext
    ) -> Result<Target, ProjectRootResolver.Refusal> {
        let task = arguments["task"] ?? arguments["plan"] ?? arguments["request"] ?? ""
        guard !task.isEmpty else {
            return .failure(ProjectRootResolver.Refusal(
                spoken: "What should the coding agent do?"))
        }
        switch ProjectRootResolver.live(named: arguments["project"], context: context) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let focus):
            if let dirty = dirtyBufferRefusal(workdir: focus.root) {
                return .failure(ProjectRootResolver.Refusal(spoken: dirty))
            }
            let live = liveContext(workdir: focus.root)
            let remembered = context.codingProjectRoot == focus.root
                && (arguments["project"] ?? "").isEmpty
                && ProjectCorpusSupport.resolve(nil).isFailure
            return .success(Target(
                task: task,
                workdir: focus.root,
                projectName: focus.name,
                context: live,
                usesRememberedRoot: remembered))
        }
    }

    static func dirtyBufferRefusal(workdir: String) -> String? {
        for registration in CodeSurfaceSupport.shared.all() {
            guard let pid = CodeSurfaceSupport.pid(of: registration),
                  let surface = CodeSurfaceEditorCache.frontSurface(
                    pid: pid, registration: registration),
                  let diskURL = CodeSurfaceWriter.fileURL(fromDocumentKey: surface.documentKey)
            else { continue }
            let diskPath = diskURL.standardizedFileURL.path
            let root = URL(fileURLWithPath: workdir).standardizedFileURL.path
            guard diskPath == root || diskPath.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            else { continue }
            let live = CodeSurfaceAX.fullString(of: surface.editor)
            let disk = try? String(contentsOf: diskURL, encoding: .utf8)
            if let disk, let refusal = CodeSurfaceWriter.cleanBufferRefusal(
                live: live, disk: disk, documentTitle: surface.title)
            {
                return refusal.errorDescription
                    ?? "Save the file first — there are unsaved changes."
            }
        }
        return nil
    }

    static func liveContext(workdir: String) -> LiveContext? {
        for registration in CodeSurfaceSupport.shared.all() {
            guard let pid = CodeSurfaceSupport.pid(of: registration),
                  let surface = CodeSurfaceEditorCache.frontSurface(
                    pid: pid, registration: registration)
            else { continue }
            let diskURL = CodeSurfaceWriter.fileURL(fromDocumentKey: surface.documentKey)
            let absolute = diskURL?.standardizedFileURL.path
            var filePath = surface.title
            if let corpus = CorpusSupport.shared.registration(
                applicationID: registration.applicationID),
               let focus = CorpusObserver.focus(pid: pid, registration: corpus)
            {
                filePath = focus.relativePath
            } else if let absolute {
                let root = URL(fileURLWithPath: workdir).standardizedFileURL.path
                if absolute.hasPrefix(root) {
                    filePath = String(absolute.dropFirst(root.count).drop(while: { $0 == "/" }))
                }
            }
            let text = CodeSurfaceAX.fullString(of: surface.editor) ?? ""
            let range = CodeSurfaceAX.selectedRange(of: surface.editor)
            let line: Int?
            if let range {
                let prefix = text.prefix(range.lowerBound)
                line = prefix.split(separator: "\n", omittingEmptySubsequences: false).count
            } else {
                line = nil
            }
            var symbol: String?
            if let range, !text.isEmpty {
                symbol = enclosingSymbol(in: text, at: range.lowerBound)
            }
            var windowText = text
            if let range, !range.isEmpty, range.upperBound <= text.utf16.count {
                let start = text.index(text.startIndex, offsetBy: range.lowerBound,
                                       limitedBy: text.endIndex) ?? text.startIndex
                let end = text.index(text.startIndex, offsetBy: range.upperBound,
                                     limitedBy: text.endIndex) ?? text.endIndex
                windowText = String(text[start..<end])
            } else if text.count > 4_000 {
                windowText = String(text.prefix(4_000))
            }
            return LiveContext(
                filePath: filePath,
                editorName: registration.displayName,
                selectedSymbolName: symbol,
                selectedLine: line,
                windowText: windowText,
                selectedRange: range)
        }
        return nil
    }

    static func enclosingSymbol(in text: String, at offset: Int) -> String? {
        let idx = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex)
            ?? text.endIndex
        let pattern = try? NSRegularExpression(
            pattern: #"^\s*(?:(?:public|private|internal|fileprivate|open|static|class|mutating|override|nonisolated)\s+)*(?:func|struct|class|enum|actor|protocol|extension)\s+(\w+)"#,
            options: [.anchorsMatchLines])
        guard let pattern else { return nil }
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var last: String?
        for match in matches {
            if match.range.location > offset { break }
            if match.numberOfRanges > 1 {
                last = ns.substring(with: match.range(at: 1))
            }
        }
        _ = idx
        return last
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
