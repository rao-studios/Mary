//
//  ProjectCorpusSupport.swift
//  MaryPlugin
//
//  WHAT: Which project is open, and who has it.
//  IN:   CorpusSupport / AXDocument / lockFile
//  OUT:  ProjectCorpusAdapter / ProjectRootResolver
//  PIN:  Ask the running app. Extension is a check, not a search.
//        lockFile + process = ceremonies; AXDocument = reads.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

/// One project, open in one process. Carries `structure` — never optional.
public struct OpenCorpus: Sendable, Equatable {
    public let registration: CorpusRegistration
    public let structure: PluginCorpusStructureSchema
    public let projectRoot: URL
    public let processIdentifier: pid_t

    /// The project's own name, as a person would say it.
    public var name: String { projectRoot.deletingPathExtension().lastPathComponent }
}

public enum ProjectCorpusSupport {

    /// The declared corpora that are PROJECTS. Read from the one roster, not
    /// kept in a second one — see the header.
    public static func all() -> [CorpusRegistration] {
        CorpusSupport.shared.all
            .filter { $0.structure != nil || !$0.schema.include.isEmpty }
            .sorted { $0.applicationID < $1.applicationID }
    }

    /// A notation-only corpus still has a file-tree outline so coding and
    /// writing share one reader. Ceremonies still require a declared
    /// `structure` — menus belong to manuscript packages.
    static func projectStructure(for registration: CorpusRegistration) -> PluginCorpusStructureSchema {
        registration.structure ?? PluginCorpusStructureSchema(
            discovery: .manifestPresence,
            openState: [.runningApplication],
            manifest: .init(kind: .fileSystemTree))
    }

    // MARK: - What is open

    /// Every project open in a declared application — every window, not just front.
    public static func openCorpora() -> [OpenCorpus] {
        let declared = all()
        guard !declared.isEmpty else { return [] }

        var found: [OpenCorpus] = []
        for application in NSWorkspace.shared.runningApplications {
            guard application.activationPolicy == .regular,
                  let bundleID = application.bundleIdentifier,
                  let registration = declared.first(where: { $0.owns(bundleID: bundleID) })
            else { continue }
            let structure = projectStructure(for: registration)

            let pid = application.processIdentifier
            let element = AXUIElementCreateApplication(pid)
            for window in AX.children(element, kAXWindowsAttribute) {
                guard let root = projectRoot(
                    ofWindow: window, structure: structure,
                    projectMarkers: registration.schema.projectMarkers)
                else { continue }
                // One project, one entry — several windows would otherwise rival the same name.
                guard !found.contains(where: { $0.projectRoot == root }) else { continue }
                found.append(OpenCorpus(
                    registration: registration,
                    structure: structure,
                    projectRoot: root,
                    processIdentifier: pid))
            }
        }
        return found
    }

    /// Project this window is showing, if this registration describes it.
    /// PIN: `.fileSystemTree` climbs markers (`CorpusObserver.projectRoot`);
    /// `AXDocument` is the active file, not the workspace.
    static func projectRoot(
        ofWindow window: AXUIElement, structure: PluginCorpusStructureSchema,
        projectMarkers: [String] = []
    ) -> URL? {
        guard let raw = AX.string(window, kAXDocumentAttribute), !raw.isEmpty,
              let url = URL(string: raw), url.isFileURL
        else { return nil }
        // Trailing slash leaves pathExtension empty — compare standardized paths.
        let standardized = URL(fileURLWithPath: url.path).standardizedFileURL

        if structure.manifest.kind == .fileSystemTree {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: standardized.path, isDirectory: &isDirectory)
            else { return nil }
            // Window showing a folder is itself the root — same as CorpusObserver.documentRoot.
            if isDirectory.boolValue { return standardized }
            // Unplaceable file: nothing to crawl, not a guess at the folder.
            guard !projectMarkers.isEmpty,
                  let rootPath = CorpusObserver.projectRoot(
                    containing: standardized.deletingLastPathComponent().path,
                    markers: projectMarkers)
            else { return nil }
            return URL(fileURLWithPath: rootPath, isDirectory: true)
        }

        if let wanted = structure.projectExtension, !wanted.isEmpty {
            guard standardized.pathExtension.caseInsensitiveCompare(wanted) == .orderedSame
            else { return nil }
        }
        guard FileManager.default.fileExists(atPath: standardized.path) else { return nil }
        return standardized
    }

    /// Project a request addresses. Named project wins; no silent fallback.
    /// One open → that one. Two unnamed → refuse naming both.
    public static func resolve(_ named: String?) -> Result<OpenCorpus, Refusal> {
        let open = openCorpora()
        guard !open.isEmpty else {
            return .failure(all().isEmpty ? .noneDeclared : .noneOpen(all().map(\.displayName)))
        }
        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            // Exact before contained — a prefix name stays reachable by saying it exactly.
            let exact = open.filter { $0.name.lowercased() == wanted }
            if exact.count == 1 { return .success(exact[0]) }
            if exact.count > 1 { return .failure(.ambiguous(exact.map(\.name))) }
            let contained = open.filter { $0.name.lowercased().contains(wanted) }
            if contained.count == 1 { return .success(contained[0]) }
            if contained.count > 1 {
                return .failure(.ambiguous(contained.map(\.name)))
            }
            return .failure(.noSuchProject(named, open: open.map(\.name)))
        }
        if open.count == 1 { return .success(open[0]) }
        return .failure(.ambiguous(open.map(\.name)))
    }

    public enum Refusal: Error, Equatable, Sendable {
        case noneDeclared
        case noneOpen([String])
        case noSuchProject(String, open: [String])
        case ambiguous([String])

        public var spoken: String {
            switch self {
            case .noneDeclared:
                return "I don't have a project set up to read."
            case .noneOpen(let applications):
                return "Nothing is open in \(applications.joined(separator: " or ")) just now."
            case .noSuchProject(let named, let open):
                return open.isEmpty
                    ? "I don't see a project called \(named)."
                    : "I don't see \(named) open. Open right now: "
                        + open.joined(separator: ", ") + "."
            case .ambiguous(let names):
                return "\(names.joined(separator: " and ")) are both open — which one?"
            }
        }
    }

    // MARK: - Is the application ready to be driven

    /// Whether a ceremony can act. Separate from `resolve` — reads do not need it.
    public static func isOpenForEditing(_ corpus: OpenCorpus) -> Bool {
        let structure = corpus.structure
        let states = structure.openState
        if states.contains(.alwaysOpen) { return true }
        var satisfied = true
        if states.contains(.runningApplication) {
            satisfied = satisfied
                && NSRunningApplication(processIdentifier: corpus.processIdentifier)?
                    .isTerminated == false
        }
        if states.contains(.lockFile), let path = structure.lockFilePath {
            // Crash leaves a lock; pair with the process check, never trust alone.
            let lock = corpus.projectRoot.appendingPathComponent(path)
            satisfied = satisfied && FileManager.default.fileExists(atPath: lock.path)
        }
        return satisfied
    }
}
