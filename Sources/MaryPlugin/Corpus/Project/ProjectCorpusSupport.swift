//
//  ProjectCorpusSupport.swift
//  MaryPlugin
//
//  WHICH PROJECT IS OPEN, AND WHO HAS IT.
//
//  ⚠️ "PROJECT", NOT "DOCUMENT", AND THE NAME WAS WRONG BOTH WAYS. This lane
//  shipped as `DocumentCorpus*`, which reads as "the corpus lane for things
//  that are documents" — implying it serves any corpus of files, source
//  included. It does the opposite: `all()` filters to corpora that declare a
//  `structure`, so a notation-only corpus (a body of source files, learned
//  from by style) is EXPLICITLY EXCLUDED, and a test asserts it.
//
//  The word was also already taken. Across the ambient layer "document"
//  means the thing open in an editor right now — `documentNoun`,
//  `documentKey`, `holdsWholeDocument` — so a second meaning here made the
//  same word mean "a file on disk somewhere in a project" three modules
//  away.
//
//  What actually distinguishes this lane is that its corpus has an OUTLINE:
//  a manifest naming items, their nesting, and where each one's text lives.
//  That is a project. The vocabulary in these files had already settled
//  there on its own — `projectRoot`, "which project", `noSuchProject` — and
//  the type now agrees with it.
//
//  THE PROJECT COMES FROM THE APPLICATION, NOT FROM A SEARCH — measured
//  2026-08-28, and it collapses most of what this file was going to be. The
//  predecessor discovered projects with Spotlight over a declared extension
//  plus a list of "activity paths", which is a guess refined by heuristics:
//  it can find projects nobody has open, miss one saved somewhere unusual,
//  and has to rank what it finds. Scrivener's own window publishes
//  `AXDocument` as the project root's file URL, exactly as Xcode publishes
//  its workspace root.
//
//  So: ask the running application what it has open. The answer is exact,
//  costs one attribute read, needs no index, and is never stale — and when
//  no application has anything open, the honest answer is that there is no
//  project rather than a list of ones on disk somewhere.
//
//  THE DECLARED EXTENSION IS A CHECK, NOT A SEARCH. A package says a project
//  is a `.scriv`, and a window claiming to hold something else is not the
//  corpus this registration describes — which matters because an application
//  can have several kinds of window open.
//
//  OPEN-STATE IS NOT THE SAME QUESTION. `lockFile` and `runningApplication`
//  answer "is it safe to expect the application to act on this", which the
//  ceremonies need; `AXDocument` answers "what is it showing", which the
//  reads need. A crash leaves a lock file behind, which is why the two are
//  paired rather than either being trusted alone.
//
//  ⚠️ NO ROSTER OF ITS OWN, and it briefly had one. This file first shipped
//  with a `ProjectCorpusRegistration` and a registry beside it — the same
//  four fields, the same frozen swap, fed by a reconciler that differed from
//  the existing one by a single guard. Two answers to "which applications
//  have a corpus", from one declaration, kept in step by hand.
//
//  There IS a real difference between the two consumers, and it is not the
//  roster: `CorpusObserver` watches a corpus passively for style, this lane
//  answers the model and drives menus. Different protocols, different
//  questions, one fact about which applications are involved. So the roster
//  is `CorpusSupport`'s, and what remains here is the part that is genuinely
//  about PROJECTS: finding the one an application has open, and deciding
//  whether it can be acted on.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation
import os

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
        CorpusSupport.shared.withStructure.sorted { $0.applicationID < $1.applicationID }
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

            let pid = application.processIdentifier
            let element = AXUIElementCreateApplication(pid)
            for window in AX.children(element, kAXWindowsAttribute) {
                guard let structure = registration.structure,
                      let root = projectRoot(ofWindow: window, structure: structure)
                else { continue }
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
    static func projectRoot(
        ofWindow window: AXUIElement, structure: PluginCorpusStructureSchema
    ) -> URL? {
        guard let raw = AX.string(window, kAXDocumentAttribute), !raw.isEmpty,
              let url = URL(string: raw), url.isFileURL
        else { return nil }
        // A trailing slash on a directory URL leaves `pathExtension` empty,
        // so the comparison is made on the standardized path.
        let standardized = URL(fileURLWithPath: url.path).standardizedFileURL
        if let wanted = structure.projectExtension, !wanted.isEmpty {
            guard standardized.pathExtension.caseInsensitiveCompare(wanted) == .orderedSame
            else { return nil }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardized.path, isDirectory: &isDirectory) else { return nil }
        return standardized
    }

    /// The project a request addresses.
    ///
    /// A NAME IS AUTHORITY AND NEVER FALLS THROUGH. "Read the outline of
    /// gitas-ballad" while another manuscript is in front means that one, and
    /// a name that matches nothing must refuse rather than silently answering
    /// about a different book. Otherwise: the only one open, and nil when two
    /// are and nothing said which.
    public static func resolve(_ named: String?) -> Result<OpenCorpus, Refusal> {
        let open = openCorpora()
        guard !open.isEmpty else {
            return .failure(all().isEmpty ? .noneDeclared : .noneOpen(all().map(\.displayName)))
        }
        if let named, !named.isEmpty {
            let wanted = named.lowercased()
            let matches = open.filter {
                $0.name.lowercased() == wanted || $0.name.lowercased().contains(wanted)
            }
            if matches.count == 1 { return .success(matches[0]) }
            if matches.count > 1 {
                return .failure(.ambiguous(matches.map(\.name)))
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
                return "I don't have a writing project set up to read."
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
