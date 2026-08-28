//
//  DocumentCorpusSupport.swift
//  MaryPlugin
//
//  WHICH PROJECT IS OPEN, AND WHO HAS IT.
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

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation
import os

public struct DocumentCorpusRegistration: Sendable, Equatable {
    public let applicationID: String
    public let bundleIdentifiers: [String]
    public let displayName: String
    public let structure: PluginCorpusStructureSchema

    public init(
        applicationID: String,
        bundleIdentifiers: [String],
        displayName: String,
        structure: PluginCorpusStructureSchema
    ) {
        self.applicationID = applicationID
        self.bundleIdentifiers = bundleIdentifiers
        self.displayName = displayName
        self.structure = structure
    }

    /// PREFIX-MATCHED, and this is the case the rule exists for. Scrivener's
    /// bundle id carries its major version — `…scrivener3` today,
    /// `…scrivener4` next year — and the Setapp build adds its own suffix. A
    /// package naming the family should not stop working at the next
    /// release, so membership is a prefix test even though nothing here
    /// launches anything by exact id.
    public func owns(bundleID: String) -> Bool {
        bundleIdentifiers.contains { bundleID.lowercased().hasPrefix($0.lowercased()) }
    }
}

/// One project, open in one process.
public struct OpenCorpus: Sendable, Equatable {
    public let registration: DocumentCorpusRegistration
    public let projectRoot: URL
    public let processIdentifier: pid_t

    /// The project's own name, as a person would say it.
    public var name: String { projectRoot.deletingPathExtension().lastPathComponent }
}

public final class DocumentCorpusSupport: @unchecked Sendable {

    public static let shared = DocumentCorpusSupport()

    private let box = OSAllocatedUnfairLock<[String: DocumentCorpusRegistration]>(
        initialState: [:])

    public init() {}

    public func reconcile(_ registrations: [DocumentCorpusRegistration]) {
        let map = Dictionary(
            registrations.map { ($0.applicationID, $0) },
            uniquingKeysWith: { first, _ in first })
        box.withLock { $0 = map }
    }

    public func all() -> [DocumentCorpusRegistration] {
        box.withLock { Array($0.values) }.sorted { $0.applicationID < $1.applicationID }
    }

    // MARK: - What is open

    /// Every project currently open in a declared application.
    ///
    /// EVERY WINDOW, not just the front one: a writer with two manuscripts
    /// open has two, and naming one of them should reach it without first
    /// bringing it forward.
    public func openCorpora() -> [OpenCorpus] {
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
                guard let root = Self.projectRoot(
                    ofWindow: window, structure: registration.structure) else { continue }
                guard !found.contains(where: { $0.projectRoot == root }) else { continue }
                found.append(OpenCorpus(
                    registration: registration,
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
    public func resolve(_ named: String?) -> Result<OpenCorpus, Refusal> {
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
        let states = corpus.registration.structure.openState
        if states.contains(.alwaysOpen) { return true }
        var satisfied = true
        if states.contains(.runningApplication) {
            satisfied = satisfied
                && NSRunningApplication(processIdentifier: corpus.processIdentifier)?
                    .isTerminated == false
        }
        if states.contains(.lockFile), let path = corpus.registration.structure.lockFilePath {
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
