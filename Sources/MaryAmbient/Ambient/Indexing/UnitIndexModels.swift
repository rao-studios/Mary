//
//  UnitIndexModels.swift
//  MaryAmbient
//
//  The model, protocol, and hashing types AmbientUnitIndexingCoordinator
//  reads and writes. Split out of UnitIndex.swift (docs/DECOMPOSITION.md
//  Wave 2) — pure relocation, no declaration changed.
//

import CryptoKit
import Foundation
import MaryFoundation


/// One edge between two named things in a unit's neighbourhood.
///
/// The predicate vocabulary is closed on purpose. These strings reach Totem as
/// graph relationships and become the retrieval surface, so a producer that
/// invented its own spelling would create a second, silently unjoinable half
/// of the same graph.
public enum UnitRelationPredicate: String, Sendable, Equatable, Codable, CaseIterable {
    /// A file declares a type.
    case declares
    /// A type names another in its inheritance clause. The edge the crawl
    /// follows past its first hop.
    case inheritsFrom = "inherits from"
    /// A type holds another as stored state.
    case holds
    /// A unit sits inside a project.
    case partOf = "part of"
    /// A project practices a discipline — the join that lets skill-time
    /// retrieval find other work in the same craft without merging repos.
    case practices
    /// A unit expresses a concept — the label edge that lets a code
    /// neighbourhood be reachable from an unrelated domain.
    case expresses
}

public struct UnitRelation: Sendable, Equatable, Codable {
    public var subject: String
    public var predicate: UnitRelationPredicate
    public var object: String

    public init(subject: String, predicate: UnitRelationPredicate, object: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

/// What a model added to a unit: one sentence of what it is for, and the
/// concept labels that make it reachable from another domain.
///
/// Both are OWNER-OBSERVED — written from this user's own code, on this
/// machine. They may reach a local prompt. They are never exported as
/// instruction; on the portable side they are inspector metadata, which is
/// what keeps an imported profile from becoming prompt authority.
public struct UnitAnnotation: Sendable, Equatable, Codable {
    public var precis: String
    public var labels: [String]

    public init(precis: String, labels: [String]) {
        self.precis = precis
        // Sorted and deduplicated so the same annotation encodes identically
        // twice — a digest over an unordered array is not reproducible.
        self.labels = Array(Set(labels.filter { !$0.isEmpty })).sorted()
    }

    public var isEmpty: Bool { precis.isEmpty && labels.isEmpty }
}

/// Everything an annotator is allowed to see. Deliberately the projected unit
/// rather than the file: an annotator never receives a function body, because
/// nothing upstream of it ever holds one.
public struct UnitAnnotationRequest: Sendable, Equatable {
    public var projectName: String
    public var relativePath: String
    public var declaredTypes: [String]
    public var relations: [UnitRelation]
    public var apiHeaders: [String]
    public var doc: String?

    public init(
        projectName: String,
        relativePath: String,
        declaredTypes: [String],
        relations: [UnitRelation],
        apiHeaders: [String],
        doc: String?
    ) {
        self.projectName = projectName
        self.relativePath = relativePath
        self.declaredTypes = declaredTypes
        self.relations = relations
        self.apiHeaders = apiHeaders
        self.doc = doc
    }
}

public enum UnitAnnotationAttempt: Sendable, Equatable {
    case annotated(UnitAnnotation)
    case seerUnavailable
    case empty
    case unparsable
    /// The round failed before a body arrived. The associated reason is what
    /// the Corpus card should name instead of "returned nothing".
    case failed(String?)
}

/// The seam to whatever can write a précis. Declared here because this package
/// may name only `MaryFoundation` — the implementation lives above, over an
/// inference engine, and is installed by the composition root.
public protocol UnitAnnotating: Sendable {
    /// Nil when annotation is unavailable. A nil is not a failure: the unit
    /// still deposits with its structure and headers, and says so honestly
    /// rather than being dropped.
    func annotate(_ request: UnitAnnotationRequest) async -> UnitAnnotation?

    /// Distinguishes why `annotate` returned nil, so the Corpus card can name
    /// "not signed in" separately from "the model answered in prose".
    func annotationAttempt(
        _ request: UnitAnnotationRequest
    ) async -> UnitAnnotationAttempt

    var refusesToAnnotate: Bool { get }
}

public extension UnitAnnotating {
    var refusesToAnnotate: Bool { false }

    func annotationAttempt(
        _ request: UnitAnnotationRequest
    ) async -> UnitAnnotationAttempt {
        if let annotation = await annotate(request), !annotation.isEmpty {
            return .annotated(annotation)
        }
        return .failed(nil)
    }
}

/// One indexed file and its neighbourhood.
public struct IndexedUnit: Sendable, Equatable {
    public var subject: DepositSubject
    public var projectName: String
    /// Project-relative. This is the unit's identity within its project and is
    /// deliberately not absolute — an absolute path is machine-local, and the
    /// addressing scheme has to survive being carried somewhere else.
    public var relativePath: String
    public var contentHash: String
    public var declaredTypes: [String]
    public var relations: [UnitRelation]
    public var apiHeaders: [String]
    /// Project-relative paths of the files this one reaches.
    public var neighbours: [String]
    public var doc: String?
    public var annotation: UnitAnnotation?
    public var capturedAt: Date
    /// The craft this unit's project practices, when the place can name one.
    /// Nil rather than invented: a unit with no discipline is not filed as
    /// coding.
    public var discipline: AbilityID?

    public init(
        subject: DepositSubject,
        projectName: String,
        relativePath: String,
        contentHash: String,
        declaredTypes: [String] = [],
        relations: [UnitRelation] = [],
        apiHeaders: [String] = [],
        neighbours: [String] = [],
        doc: String? = nil,
        annotation: UnitAnnotation? = nil,
        capturedAt: Date = Date(),
        discipline: AbilityID? = nil
    ) {
        self.subject = subject
        self.projectName = projectName
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.declaredTypes = declaredTypes
        self.relations = relations
        self.apiHeaders = apiHeaders
        self.neighbours = neighbours
        self.doc = doc
        self.annotation = annotation
        self.capturedAt = capturedAt
        self.discipline = discipline
    }

    public var projectID: String? {
        subject.projectIdentity ?? subject.documentIdentity
    }

    /// The unit's owner-free logical key. Placement adds the owner; identity
    /// does not carry it, which is what lets the same unit be addressed under
    /// a different owner without changing what it is.
    public var unitKey: String {
        UnitIndexHashing.canonical("\(projectName)|\(relativePath)")
    }

    /// SHA-256 prefix of a file's contents — the gate on re-indexing.
    public static func hash(_ contents: String) -> String {
        let digest = SHA256.hash(data: Data(contents.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// The compact per-project catalogue that survives a relaunch, so a new
/// process resumes instead of re-indexing everything it already knows.
/// Modelled on the application-schema manifest, with the one thing that file
/// lacks: a version.
public struct UnitIndexManifest: Sendable, Equatable, Codable {

    /// CARRIED FROM DAY ONE, DELIBERATELY. The observation manifest this
    /// descends from had no version and a loader that swallowed decode
    /// failures — so adding one later would not have been an error, it would
    /// have been silent total amnesia. Any
    /// future field lands beside a version that can refuse rather than forget.
    ///
    /// ONE FORMAT. This briefly counted to 2 while fields were being added
    /// during development; nothing has shipped, and a manifest is re-derivable
    /// by re-crawling, so there is no older shape worth understanding.
    public static let currentFormatVersion = 1

    public struct Entry: Sendable, Equatable, Codable {
        public var contentHash: String
        public var labels: [String]
        public var indexedAt: Date
        /// Labels corrected by hand. When present they REPLACE whatever the
        /// annotator proposes, for this unit, from now on — a correction you
        /// have to make twice is not a correction. The précis still refreshes,
        /// so the card does not freeze.
        public var pinnedLabels: [String]?
        /// Why this unit's labels look the way they do. Previously
        /// unrecoverable: the row is written BEFORE annotating and labels are
        /// backfilled only when non-empty, so "not yet", "no annotator" and
        /// "the annotator refused" were one indistinguishable empty list.
        public var annotation: UnitAnnotationOutcome

        public init(
            contentHash: String,
            labels: [String] = [],
            indexedAt: Date = Date(),
            pinnedLabels: [String]? = nil,
            annotation: UnitAnnotationOutcome = .pending
        ) {
            self.contentHash = contentHash
            self.labels = labels
            self.indexedAt = indexedAt
            self.pinnedLabels = pinnedLabels
            self.annotation = annotation
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contentHash = try container.decode(String.self, forKey: .contentHash)
            labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
            indexedAt = try container.decode(Date.self, forKey: .indexedAt)
            pinnedLabels = try container.decodeIfPresent([String].self, forKey: .pinnedLabels)
            annotation = try container.decodeIfPresent(
                UnitAnnotationOutcome.self, forKey: .annotation) ?? .pending
        }

        public var effectiveLabels: [String] {
            let pinned = pinnedLabels ?? []
            return pinned.isEmpty ? labels : pinned
        }
    }

    public var formatVersion: Int
    /// Keyed by project-relative path.
    public var entries: [String: Entry]

    public init(formatVersion: Int = UnitIndexManifest.currentFormatVersion,
                entries: [String: Entry] = [:]) {
        self.formatVersion = formatVersion
        self.entries = entries
    }

    /// A manifest this build does not use is refused rather than half-read.
    /// The caller treats nil as "start fresh", which costs a re-crawl and
    /// never mixes two formats.
    public var isReadable: Bool {
        formatVersion == Self.currentFormatVersion
    }

    /// ISO-8601 and sorted keys, so the same manifest encodes to the same
    /// bytes twice. The application-schema manifest uses `.deferredToDate`
    /// (a float) while its sibling metadata uses ISO-8601 for the very same
    /// timestamp; one representation is enough.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// One canonicalizer and one hash for the whole indexing surface.
///
/// TWO ALREADY EXIST IN THIS CODEBASE AND THEY DISAGREE:
/// `DepositSubject.canonical` nils on empty and `TotemMemoryTopology.canonical`
/// does not. A third in the build this ports from stripped punctuation, so
/// `my-app` and `my app` collided there and nowhere else — the reason this is
/// stated as a rule rather than left to whoever writes the next one. A key
/// that is minted on one machine and resolved on another cannot be built on a
/// coin flip, so this is the one spelling for anything unit- or
/// tenet-addressed.
public enum UnitIndexHashing {

    /// Collapse whitespace, lowercase, keep everything else. Punctuation
    /// survives because a path separator and a hyphen are meaning, not noise.
    public static func canonical(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// FNV-1a 64. Deliberately not `Hasher`, which is per-process seeded and
    /// would mint a new document id every launch.
    public static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

public protocol AmbientUnitIndexSink: Sendable {
    func ingest(_ unit: IndexedUnit) async
    func reset() async
    /// The revision this file was last indexed at, or nil if it has never been
    /// seen. THE DIFFERENCE BETWEEN "NEW TO ME" AND "CHANGED" — a file being
    /// read for the first time and a file the user just rewrote are both
    /// "not what I have", and only the second is evidence about how they write.
    func knownContentHash(relativePath: String, projectID: String) async -> String?
}
