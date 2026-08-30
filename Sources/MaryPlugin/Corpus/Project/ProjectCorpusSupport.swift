//
//  ProjectCorpusSupport.swift
//  MaryPlugin
//
//  WHICH PROJECT IS OPEN, AND WHO HAS IT.
//
//  "PROJECT" IS THE PRECISE WORD, and the alternatives are both taken. This
//  lane serves only corpora that declare a `structure` — a notation-only
//  corpus, a body of source files learned from by style, is EXPLICITLY
//  EXCLUDED and a test asserts it — so "document corpus" would name the
//  opposite of what it filters for. And across the ambient layer "document"
//  already means the thing open in an editor right now (`documentNoun`,
//  `documentKey`, `holdsWholeDocument`), so a second meaning here would make
//  one word mean "a file on disk somewhere in a project" three modules away.
//
//  What distinguishes this lane is that its corpus has an OUTLINE: a manifest
//  naming items, their nesting, and where each one's text lives. That is a
//  project, and the vocabulary throughout — `projectRoot`, `noSuchProject` —
//  agrees.
//
//  THE PROJECT COMES FROM THE APPLICATION, NOT FROM A SEARCH — measured
//  2026-08-28, and it collapses most of what this file was going to be. The
//  predecessor discovered projects with Spotlight over a declared extension
//  plus a list of "activity paths", which is a guess refined by heuristics: it
//  can find projects nobody has open, miss one saved somewhere unusual, and
//  has to rank what it finds. Scrivener's own window publishes `AXDocument` as
//  the project root's file URL, exactly as Xcode publishes its workspace root.
//
//  So: ask the running application what it has open. The answer is exact,
//  costs one attribute read, needs no index, and is never stale — and when no
//  application has anything open, the honest answer is that there is no
//  project rather than a list of ones on disk somewhere.
//
//  THE DECLARED EXTENSION IS A CHECK, NOT A SEARCH. A package says a project
//  is a `.scriv`, and a window claiming to hold something else is not the
//  corpus this registration describes — which matters because an application
//  can have several kinds of window open.
//
//  OPEN-STATE IS NOT THE SAME QUESTION. `lockFile` and `runningApplication`
//  answer "is it safe to expect the application to act on this", which the
//  ceremonies need; `AXDocument` answers "what is it showing", which the reads
//  need. A crash leaves a lock file behind, which is why the two are paired
//  rather than either being trusted alone.
//
//  NO ROSTER OF ITS OWN. Which applications have a corpus is one fact from one
//  declaration block, and it lives in `CorpusSupport` — see that file's header
//  for the two consumers and why they share it. What is here is the part that
//  is genuinely about PROJECTS: finding the one an application has open, and
//  deciding whether it can be acted on.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

/// One project, open in one process.
///
/// IT CARRIES ITS STRUCTURE rather than reaching back through the
/// registration for it. A corpus reaches this type only by having one — the
/// roster is filtered on exactly that — so an `OpenCorpus` with no structure
/// is a state that cannot occur, and holding it as an optional would make
/// every reader unwrap something that is never nil and invent a sentence for
/// a case that never happens.
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

    /// Every project currently open in a declared application.
    ///
    /// EVERY WINDOW, not just the front one: a writer with two manuscripts
    /// open has two, and naming one of them should reach it without first
    /// bringing it forward.
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
                // ONE PROJECT, ONE ENTRY. An application shows the same
                // project in several windows — an editor and an outliner — and
                // each would otherwise arrive as a rival for the same name.
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

    /// The project one window is showing, if it is one this registration
    /// describes.
    ///
    /// `.fileSystemTree` TAKES A DIFFERENT ROAD, and the reason is the same
    /// one `CorpusObserver`'s own header records: `AXDocument` on a workspace
    /// editor is the ACTIVE FILE, not the project — measured live against
    /// Xcode with a source file open, where no window attribute carries the
    /// workspace at all. A bundle-style project (`.scriv`) never has this
    /// problem because its window's `AXDocument` names the bundle itself; a
    /// directory-of-source project does, because there is no bundle boundary
    /// for the window to report. So this climbs to the nearest ancestor
    /// holding a declared marker — the identical algorithm the passive style
    /// crawl already uses, so the two lanes can never disagree about which
    /// folder is "the project" for the same window.
    static func projectRoot(
        ofWindow window: AXUIElement, structure: PluginCorpusStructureSchema,
        projectMarkers: [String] = []
    ) -> URL? {
        guard let raw = AX.string(window, kAXDocumentAttribute), !raw.isEmpty,
              let url = URL(string: raw), url.isFileURL
        else { return nil }
        // A trailing slash on a directory URL leaves `pathExtension` empty,
        // so the comparison is made on the standardized path.
        let standardized = URL(fileURLWithPath: url.path).standardizedFileURL

        if structure.manifest.kind == .fileSystemTree {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: standardized.path, isDirectory: &isDirectory)
            else { return nil }
            // A window already showing a folder (no file open) is itself the
            // answer — exactly `CorpusObserver.documentRoot`'s own rule.
            if isDirectory.boolValue { return standardized }
            // NOT FOUND IS NOTHING TO CRAWL, not a guess. A loose file this
            // corpus's markers cannot place belongs to no project, and
            // guessing its containing folder is how a read learns from work
            // that is not the user's.
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

    /// The project a request addresses.
    ///
    /// A NAME IS AUTHORITY AND NEVER FALLS THROUGH. "Read the outline of
    /// gitas-ballad" while another manuscript is in front means that one, and
    /// a name that matches nothing must refuse rather than silently answering
    /// about a different book. Otherwise: the only one open, and a refusal
    /// naming both when two are and nothing said which.
    public static func resolve(_ named: String?) -> Result<OpenCorpus, Refusal> {
        let open = openCorpora()
        guard !open.isEmpty else {
            return .failure(all().isEmpty ? .noneDeclared : .noneOpen(all().map(\.displayName)))
        }
        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            // EXACT BEFORE CONTAINED, so a project whose name is a prefix of
            // another's is still reachable by saying it exactly — "ballad"
            // and "ballad-notes" open together must not make "ballad"
            // ambiguous.
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

    /// Whether the owning application is in a state where a ceremony can act.
    ///
    /// SEPARATE FROM `resolve`, because a read does not need it. A project can
    /// be read off disk while its application is busy; only a menu-driven
    /// change needs the application present and attending.
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
            // A CRASH LEAVES A LOCK BEHIND, which is exactly why this is
            // paired with the process check rather than trusted alone — a
            // stale lock would otherwise say "open" about a project nothing
            // has had open for a week.
            let lock = corpus.projectRoot.appendingPathComponent(path)
            satisfied = satisfied && FileManager.default.fileExists(atPath: lock.path)
        }
        return satisfied
    }
}
