//
//  UnitIndexLedger.swift
//  MaryAmbient
//
//  THE MIRROR, BECAUSE THE PIPELINE IS WRITE-ONLY BY CONSTRUCTION.
//
//  An `IndexedUnit` is destroyed the moment it reaches the sink. The
//  coordinator keeps a manifest row of three fields. And Totem cannot give the
//  rest back: `documents(ids:)` returns id, name, owner, group, createdAt,
//  texts and media type — so tags, metadata, entities and relationships are
//  all write-only, and a partition hit carries no timestamp at all. Nothing
//  downstream can be asked "what did you ingest, and when, and why".
//
//  So this holds the answer locally. It is the same conclusion `AmbientTraceLog`
//  reached for routes, and this file is shaped after it deliberately —
//  including the LATE-ATTACH mutators, for the same stated reason: the facts
//  are known at different times. A crawl produces a unit; the annotation
//  outcome arrives seconds later at the end of a serialized chain; the deposit
//  result later still. Recording the row only at the end would mean a unit
//  that was skipped, refused, or failed to deposit left no trace — and those
//  are exactly the ones worth seeing.
//
//  Two shapes in one place, because they answer two different questions:
//    · `units` — what is CURRENTLY known about each indexed file, keyed and
//      replaced in place. This is the browsable inventory.
//    · `operations` — what HAPPENED, newest first, bounded. This is the
//      history, and a skipped-by-hash row is as informative as an indexed one.
//

import Foundation

/// What became of a unit's annotation. Three of these were previously
/// indistinguishable: the manifest row is written BEFORE annotating and labels
/// are backfilled only when non-empty, so "not yet", "no annotator installed"
/// and "the annotator refused" all looked like an empty label list.
public enum UnitAnnotationOutcome: String, Sendable, Equatable, Codable {
    /// Queued behind the annotation chain, or annotating right now.
    case pending
    /// A précis and labels came back.
    case ran
    /// No annotator installed — indexing is on, annotation is not.
    case noAnnotator
    /// The engine requires exclusive generation, so annotating would have
    /// queued behind the turn path. Declined on purpose; the card still
    /// carries its structure.
    case refusedExclusiveEngine
    /// An annotator was installed and returned nothing usable.
    case failed
    /// Labels are pinned by hand, so the model's were discarded for this unit.
    case pinned
    /// An outcome this build does not know, met while reading a manifest a
    /// NEWER build wrote.
    case unknown

    /// UNKNOWN VALUES DECAY, THEY NEVER THROW — the rule `StyleDimension`'s
    /// header states and `docs/TOTEM-MERGE.md` paid for: `Access` was a plain
    /// Codable string enum, a rollback binary met a value it did not know,
    /// `restore()` threw, and the throw re-seeded the registry empty and
    /// orphan-swept documents.
    ///
    /// This enum sits inside a PERSISTED `UnitIndexManifest.Entry` and had
    /// exactly that shape. The manifest's format version was masking it —
    /// refusing the whole file kept an unknown value from ever being decoded —
    /// but a version gate is a blunt instrument for one unrecognised row, and
    /// with one format there is nothing left to bump. Decaying costs one row's
    /// annotation state; throwing costs the project's whole index.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = UnitAnnotationOutcome(rawValue: raw) ?? .unknown
    }

    public var isSettled: Bool { self != .pending }
}

public enum UnitDepositOutcome: String, Sendable, Equatable, Codable {
    case pending
    case deposited
    case failed
    /// Deposited once and then removed by hand.
    case forgotten
    /// An outcome this build does not know — same decay rule as its sibling.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = UnitDepositOutcome(rawValue: raw) ?? .unknown
    }
}

/// What the ledger knows about one indexed file, right now.
public struct UnitIndexRecord: Sendable, Equatable, Identifiable {
    public var unitKey: String
    public var projectID: String
    public var projectName: String
    /// Which application indexed this — the plugin owner, e.g. `"xcode"`.
    /// Carried because a project alone does not say which craft was practised
    /// in it, and the moment a second producer exists that stops being merely
    /// unstated and becomes ambiguous.
    public var applicationID: String
    public var relativePath: String
    public var contentHash: String
    public var declaredTypes: [String]
    public var neighbours: [String]
    public var relations: [UnitRelation]
    public var apiHeaders: [String]
    public var doc: String?
    public var precis: String?
    public var labels: [String]
    public var pinnedLabels: [String]?
    public var annotation: UnitAnnotationOutcome
    public var deposit: UnitDepositOutcome
    public var indexedAt: Date
    /// The exact document id this unit occupies in Totem, so the pane can
    /// remove or probe it without re-deriving the address.
    public var documentID: String?

    public var id: String { unitKey }

    public var isPinned: Bool { !(pinnedLabels ?? []).isEmpty }

    public init(
        unitKey: String,
        projectID: String,
        projectName: String,
        applicationID: String = "",
        relativePath: String,
        contentHash: String,
        declaredTypes: [String] = [],
        neighbours: [String] = [],
        relations: [UnitRelation] = [],
        apiHeaders: [String] = [],
        doc: String? = nil,
        precis: String? = nil,
        labels: [String] = [],
        pinnedLabels: [String]? = nil,
        annotation: UnitAnnotationOutcome = .pending,
        deposit: UnitDepositOutcome = .pending,
        indexedAt: Date = Date(),
        documentID: String? = nil
    ) {
        self.unitKey = unitKey
        self.projectID = projectID
        self.projectName = projectName
        self.applicationID = applicationID
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.declaredTypes = declaredTypes
        self.neighbours = neighbours
        self.relations = relations
        self.apiHeaders = apiHeaders
        self.doc = doc
        self.precis = precis
        self.labels = labels
        self.pinnedLabels = pinnedLabels
        self.annotation = annotation
        self.deposit = deposit
        self.indexedAt = indexedAt
        self.documentID = documentID
    }

    public init(unit: IndexedUnit, documentID: String? = nil) {
        self.init(
            unitKey: unit.unitKey,
            projectID: unit.projectID ?? "",
            projectName: unit.projectName,
            applicationID: unit.subject.app ?? "",
            relativePath: unit.relativePath,
            contentHash: unit.contentHash,
            declaredTypes: unit.declaredTypes,
            neighbours: unit.neighbours,
            relations: unit.relations,
            apiHeaders: unit.apiHeaders,
            doc: unit.doc,
            precis: unit.annotation?.precis,
            labels: unit.annotation?.labels ?? [],
            annotation: unit.annotation == nil ? .pending : .ran,
            indexedAt: unit.capturedAt,
            documentID: documentID)
    }
}

/// One thing that happened. A skipped row is as informative as an indexed one,
/// which is why skipping is recorded rather than being silent.
public struct UnitIndexOperation: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case crawled
        case indexed
        case skippedUnchanged
        case annotated
        case deposited
        case invalidated
        case forgotten
        case labelsPinned
        /// Evidence decayed past the floor and was let go.
        case evicted
        case failed
    }

    public let id: UUID
    public var kind: Kind
    public var projectName: String
    public var subject: String
    public var detail: String?
    public var at: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        projectName: String,
        subject: String,
        detail: String? = nil,
        at: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.projectName = projectName
        self.subject = subject
        self.detail = detail
        self.at = at
    }
}

/// Process-wide, lock-boxed, and read by a 1 Hz poll — the house pattern for
/// anything an inspector pane shows.
public final class UnitIndexLedger: @unchecked Sendable {

    public static let shared = UnitIndexLedger()

    /// Units are bounded too. A very large project could otherwise pin one
    /// record per file for the life of the process; the oldest-indexed rows
    /// are the ones you are least likely to be looking at.
    public static let unitCapacity = 500
    public static let operationCapacity = 200

    private let lock = NSLock()
    private var units: [String: UnitIndexRecord] = [:]
    private var operations: [UnitIndexOperation] = []
    private let unitCapacity: Int
    private let operationCapacity: Int

    public init(
        unitCapacity: Int = UnitIndexLedger.unitCapacity,
        operationCapacity: Int = UnitIndexLedger.operationCapacity
    ) {
        self.unitCapacity = max(1, unitCapacity)
        self.operationCapacity = max(1, operationCapacity)
    }

    // MARK: - Reads

    /// Newest-indexed first.
    public func allUnits() -> [UnitIndexRecord] {
        lock.lock()
        defer { lock.unlock() }
        return units.values.sorted {
            $0.indexedAt == $1.indexedAt
                ? $0.relativePath < $1.relativePath
                : $0.indexedAt > $1.indexedAt
        }
    }

    public func units(inProject projectID: String) -> [UnitIndexRecord] {
        allUnits().filter { $0.projectID == projectID }
    }

    public func unit(_ unitKey: String) -> UnitIndexRecord? {
        lock.lock()
        defer { lock.unlock() }
        return units[unitKey]
    }

    /// Every project the ledger has seen a unit for, with its display name.
    /// The coordinator cannot answer this — its manifest map is private and
    /// keyed only by id — and the runtime's configured-roots box holds what
    /// was configured rather than what was actually indexed.
    public func projects() -> [(id: String, name: String, unitCount: Int)] {
        let all = allUnits()
        var seen: [String: (name: String, count: Int)] = [:]
        for unit in all where !unit.projectID.isEmpty {
            let existing = seen[unit.projectID]
            seen[unit.projectID] = (unit.projectName, (existing?.count ?? 0) + 1)
        }
        return seen
            .map { (id: $0.key, name: $0.value.name, unitCount: $0.value.count) }
            .sorted { $0.name < $1.name }
    }

    public func recentOperations() -> [UnitIndexOperation] {
        lock.lock()
        defer { lock.unlock() }
        return operations
    }

    // MARK: - Writes

    public func note(_ operation: UnitIndexOperation) {
        lock.lock()
        defer { lock.unlock() }
        operations.insert(operation, at: 0)
        if operations.count > operationCapacity {
            operations.removeLast(operations.count - operationCapacity)
        }
    }

    /// Record a unit at index time, before annotation has run. The row exists
    /// from this moment so a unit that never finishes still leaves a trace.
    public func noteIndexed(_ unit: IndexedUnit, documentID: String? = nil) {
        let record = UnitIndexRecord(unit: unit, documentID: documentID)
        lock.lock()
        units[record.unitKey] = record
        prune()
        lock.unlock()
        note(.init(
            kind: .indexed,
            projectName: unit.projectName,
            subject: unit.relativePath,
            detail: "\(unit.neighbours.count) neighbours",
            at: unit.capturedAt))
    }

    public func noteSkipped(
        projectName: String, relativePath: String, at now: Date = Date()
    ) {
        note(.init(
            kind: .skippedUnchanged,
            projectName: projectName,
            subject: relativePath,
            detail: "unchanged since last index",
            at: now))
    }

    /// LATE ATTACH. The annotation outcome is known at the far end of a
    /// serialized chain, seconds after the row was written.
    public func noteAnnotation(
        _ outcome: UnitAnnotationOutcome,
        precis: String? = nil,
        labels: [String] = [],
        forUnit unitKey: String,
        at now: Date = Date()
    ) {
        var subject = ""
        var project = ""
        lock.lock()
        if var record = units[unitKey] {
            record.annotation = outcome
            if let precis { record.precis = precis }
            if !labels.isEmpty { record.labels = labels }
            units[unitKey] = record
            subject = record.relativePath
            project = record.projectName
        }
        lock.unlock()
        guard !subject.isEmpty else { return }
        note(.init(
            kind: .annotated,
            projectName: project,
            subject: subject,
            detail: outcome.rawValue,
            at: now))
    }

    public func noteDeposit(
        _ outcome: UnitDepositOutcome,
        documentID: String? = nil,
        forUnit unitKey: String,
        at now: Date = Date()
    ) {
        var subject = ""
        var project = ""
        lock.lock()
        if var record = units[unitKey] {
            record.deposit = outcome
            if let documentID { record.documentID = documentID }
            units[unitKey] = record
            subject = record.relativePath
            project = record.projectName
        }
        lock.unlock()
        guard !subject.isEmpty else { return }
        note(.init(
            kind: outcome == .failed ? .failed : .deposited,
            projectName: project,
            subject: subject,
            detail: outcome.rawValue,
            at: now))
    }

    public func notePinnedLabels(
        _ labels: [String], forUnit unitKey: String, at now: Date = Date()
    ) {
        var subject = ""
        var project = ""
        lock.lock()
        if var record = units[unitKey] {
            record.pinnedLabels = labels.isEmpty ? nil : labels
            if !labels.isEmpty {
                record.labels = labels
                record.annotation = .pinned
            }
            units[unitKey] = record
            subject = record.relativePath
            project = record.projectName
        }
        lock.unlock()
        guard !subject.isEmpty else { return }
        note(.init(
            kind: .labelsPinned,
            projectName: project,
            subject: subject,
            detail: labels.isEmpty ? "unpinned" : labels.joined(separator: ", "),
            at: now))
    }

    public func noteForgotten(unitKey: String, at now: Date = Date()) {
        var subject = ""
        var project = ""
        lock.lock()
        if let record = units.removeValue(forKey: unitKey) {
            subject = record.relativePath
            project = record.projectName
        }
        lock.unlock()
        guard !subject.isEmpty else { return }
        note(.init(kind: .forgotten, projectName: project, subject: subject, at: now))
    }

    public func noteInvalidated(
        projectName: String, subject: String, at now: Date = Date()
    ) {
        note(.init(
            kind: .invalidated,
            projectName: projectName,
            subject: subject,
            detail: "will re-index on next visit",
            at: now))
    }



    public func noteEviction(subject: String, at date: Date = Date()) {
        note(.init(
            kind: .evicted,
            projectName: "",
            subject: subject,
            detail: "no longer reinforced",
            at: date))
    }

    public func noteCrawl(
        projectName: String, focusedPath: String, unitCount: Int, at now: Date = Date()
    ) {
        note(.init(
            kind: .crawled,
            projectName: projectName,
            subject: (focusedPath as NSString).lastPathComponent,
            detail: "\(unitCount) files",
            at: now))
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        units = [:]
        operations = []
    }

    /// Caller holds the lock.
    private func prune() {
        guard units.count > unitCapacity else { return }
        let ordered = units.values.sorted { $0.indexedAt < $1.indexedAt }
        for record in ordered.prefix(units.count - unitCapacity) {
            units[record.unitKey] = nil
        }
    }
}
