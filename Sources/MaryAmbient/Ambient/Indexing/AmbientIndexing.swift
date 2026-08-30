//
//  AmbientIndexing.swift
//  MaryAmbient
//
//  THE PROJECT LANE: one structural snapshot per project the user works in —
//  its name, the document in front of them, its section headings, how big it
//  is. Deliberately structural: headings and shape are project context, while
//  body text stays behind explicit reads.
//
//  WHAT THIS FILE NO LONGER CONTAINS, and why the absence is the design. The
//  source build put a second coordinator here that LEARNED an application's
//  schema by watching it — accumulating observations about which slots an
//  application tends to fill, with confidence rising and falling, until Mary
//  had a picture of what kind of thing it was. Mary does not need to guess:
//  an application arrives as a package that STATES what it is, what it can
//  be observed through, and what its documents are called. Keeping the
//  observer would have meant two sources of truth for one fact, with the
//  learned one free to drift away from the declared one and no rule for
//  which wins.
//
//  Its mechanics were good and are not lost — support counts, decay,
//  counter-evidence, a format version from the first commit. `StyleTenet` and
//  `StyleEvidence` are that design generalized, applied to the one thing Mary
//  genuinely cannot be told and has to observe: how a person works.
//

import Foundation

/// A durable-project indexing candidate. The snapshot is intentionally
/// structural: its section names and location are project context, while body
/// text remains available only through explicit reads and the normal action
/// archive.
public struct AmbientProjectSnapshot: Sendable, Equatable {
    public var subject: DepositSubject
    public var projectName: String
    public var focusedDocument: String?
    public var sections: [String]
    public var documentCount: Int
    public var wordCount: Int
    public var capturedAt: Date

    public init(
        subject: DepositSubject,
        projectName: String,
        focusedDocument: String? = nil,
        sections: [String] = [],
        documentCount: Int = 0,
        wordCount: Int = 0,
        capturedAt: Date = Date()
    ) {
        self.subject = subject
        self.projectName = projectName
        self.focusedDocument = focusedDocument
        self.sections = Array(Set(sections)).sorted()
        self.documentCount = documentCount
        self.wordCount = wordCount
        self.capturedAt = capturedAt
    }

    public var projectID: String? { subject.projectIdentity ?? subject.documentIdentity }

    public var fingerprint: String {
        [
            projectName,
            focusedDocument ?? "",
            sections.joined(separator: "|"),
            String(documentCount),
            String(wordCount),
        ].joined(separator: "\u{1F}")
    }
}

public protocol AmbientProjectIndexSink: Sendable {
    func ingest(_ snapshot: AmbientProjectSnapshot) async
    func reset() async
}

/// Delays structural project indexing until a user has stopped moving through
/// the workspace. A changed binder or document is indexed once; hover,
/// selection, and text entry continually reset the idle clock instead.
public actor AmbientProjectIndexingCoordinator: AmbientProjectIndexSink {
    public typealias IndexSink = @Sendable (AmbientProjectSnapshot) async -> Void

    private let idleNanoseconds: UInt64
    private let indexSink: IndexSink
    private var pending: [String: AmbientProjectSnapshot] = [:]
    private var indexedFingerprints: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(idleFor: TimeInterval = 12, indexSink: @escaping IndexSink) {
        idleNanoseconds = UInt64(max(0.1, idleFor) * 1_000_000_000)
        self.indexSink = indexSink
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    public func ingest(_ snapshot: AmbientProjectSnapshot) {
        guard let projectID = snapshot.projectID, !projectID.isEmpty else { return }
        guard indexedFingerprints[projectID] != snapshot.fingerprint else { return }
        pending[projectID] = snapshot
        tasks[projectID]?.cancel()
        let wait = idleNanoseconds
        tasks[projectID] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: wait) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.flush(projectID: projectID)
        }
    }

    public func reset() {
        for task in tasks.values { task.cancel() }
        pending = [:]
        indexedFingerprints = [:]
        tasks = [:]
    }

    /// Test and shutdown seam: publish the latest stable candidate without
    /// waiting for the idle timer.
    public func flush() async {
        for projectID in Array(pending.keys).sorted() {
            await flush(projectID: projectID)
        }
    }

    private func flush(projectID: String) async {
        tasks[projectID] = nil
        guard let snapshot = pending.removeValue(forKey: projectID),
              indexedFingerprints[projectID] != snapshot.fingerprint else { return }
        indexedFingerprints[projectID] = snapshot.fingerprint
        await indexSink(snapshot)
    }
}
