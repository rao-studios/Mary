//
//  DepositSubject.swift
//  MaryAmbient
//
//  WHAT: Durable archive identity and the retrieval scope that mirrors it.
//  OUT:  Totem. ArchivePolicy lives on SkillOutcome in MaryPlugin — not a copy here.
//

import Foundation

// `ArchivePolicy` is NOT here.

/// How a workspace identifies the item being archived.
public enum ContentIdentityKind: String, Sendable, Equatable {
    case document
    case file
}

/// WHERE retrieval may look this turn. Mirrors the two fields Seer's
/// `SeerRequest` actually steers on (`groups`, `aggregate`).
public struct RetrievalScope: Sendable, Equatable {

    /// The id is what Seer's fan-out reads (`request.groups?.map(\.id)`); the
    /// label rides along because the server's `Seer.Group` requires it to
    /// decode at all.
    public struct Group: Sendable, Equatable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    /// Groups the search is restricted to. Empty = unrestricted.
    public var groups: [Group]
    /// Seer's semantics verbatim: `true` → search all of the owner's
    /// documents across every group; `false` → search only the groups given.
    public var aggregate: Bool
    /// Small relationship-family cues sent alongside the user's utterance.
    /// Totem uses these to form a predicate vector; they never replace the
    /// primary semantic query or become a separate conversation history.
    public var relationshipHints: [String]

    public init(
        groups: [Group] = [],
        aggregate: Bool = true,
        relationshipHints: [String] = []
    ) {
        self.groups = groups
        self.aggregate = aggregate
        self.relationshipHints = Array(Set(relationshipHints)).sorted()
    }

    /// Nothing specific in view — general memory.
    public static let general = RetrievalScope()

    /// SEER'S OWN long-term memory groups.
    public static func memoryGroups(ownerID: String) -> [Group] {
        [
            Group(id: "memory-\(ownerID)", label: "Memory"),
            Group(id: "resonance-\(ownerID)", label: "Resonance"),
        ]
    }
}

/// The focused world a deposit belongs to, captured at archive time (not at
/// deposit time — the deposit is detached and the user's focus may have moved
/// on by the time it lands).
public struct DepositSubject: Sendable, Equatable {

    /// Canonical app key in the focus arbiter's own vocabulary — "xcode",
    /// "pages", "scrivener". Nil = no app owned this turn.
    public var app: String?
    /// The document as a STABLE name: project-relative path for code, the document or
    /// manuscript name for prose.
    public var documentIdentity: String?
    /// The workspace enclosing the document (project root, .scriv package).
    /// Nil when the document IS the workspace, as in Pages.
    public var projectIdentity: String?
    /// Keeps file-backed work distinct from prose documents without teaching
    /// the archive a list of application names.
    public var contentKind: ContentIdentityKind
    /// When the focus was read. Rides the deposit metadata so a future
    /// recency filter has something to filter on — `PartitionHit` carries no
    /// `createdAt`, so today this is a record, not a lever.
    public var capturedAt: Date

    public init(
        app: String? = nil,
        documentIdentity: String? = nil,
        projectIdentity: String? = nil,
        contentKind: ContentIdentityKind = .document,
        capturedAt: Date = Date()
    ) {
        self.app = app
        self.documentIdentity = documentIdentity
        self.projectIdentity = projectIdentity
        self.contentKind = contentKind
        self.capturedAt = capturedAt
    }

    /// Nothing specific is in view. Deposits skip rather than filing into an
    /// owner-wide bag; retrieval stays general.
    public static var unfocused: DepositSubject { DepositSubject() }

    /// True when a specific document or project is in view. THE decision the
    /// whole slice turns on: scoped retrieval when true, general when false.
    public var isFocused: Bool { scopeKey != nil }

    // MARK: - Keys (the single source of both ids)

    /// Names the WORKSPACE — the retrieval unit. The project when there is one.
    public func scopeKey(ownerID: String) -> String? {
        guard let app = Self.canonical(app),
              let place = Self.canonical(projectIdentity) ?? Self.canonical(documentIdentity)
        else { return nil }
        return "\(Self.canonical(ownerID) ?? "")|\(app)|\(place)"
    }

    /// Names the DOCUMENT, scope-qualified — the same relative path in two
    /// projects is two documents.
    public func documentKey(ownerID: String) -> String? {
        guard let scope = scopeKey(ownerID: ownerID),
              let document = Self.canonical(documentIdentity) else { return nil }
        return "\(scope)|\(document)"
    }

    /// Un-owned form, for tests and for reasoning about identity without a
    /// session. Never sent anywhere.
    public var scopeKey: String? { scopeKey(ownerID: "") }

    // MARK: - Ids on the wire

    /// The Totem group this deposit lands in. Nil = skip — there is no
    /// owner-wide bag.
    public func groupID(ownerID: String) -> String? {
        scopeKey(ownerID: ownerID).map { "mary-scope-\(Self.stableHash($0))" }
    }

    /// The deterministic document id for a `.stateSnapshot`. Nil when there is no document
    /// identity to key on — the caller must fall back to an episodic uuid rather than invent
    /// one, or two unrelated deposits would start overwriting each other.
    public func stateDocumentID(ownerID: String) -> String? {
        documentKey(ownerID: ownerID).map { "mary-doc-\(Self.stableHash($0))" }
    }

    /// Human-readable group label — the only part of the scheme a person ever
    /// reads (Totem library, the inspector's group column).
    public var groupLabel: String {
        let place = projectIdentity ?? documentIdentity
        let leaf = place.map { ($0 as NSString).lastPathComponent } ?? ""
        let appName = app?.capitalized ?? "Mary"
        return leaf.isEmpty ? "\(appName) context" : "\(appName) — \(leaf)"
    }

    /// The read half for project-scoped corpus work: this project's group
    /// plus Seer's own memory/resonance. Spoken turns use
    /// `TotemMemoryTopology.seerPersonalScope` instead (interactions + memory).
    public func retrievalScope(ownerID: String) -> RetrievalScope {
        guard let groupID = groupID(ownerID: ownerID) else { return .general }
        return RetrievalScope(
            groups: [.init(id: groupID, label: groupLabel)]
                + RetrievalScope.memoryGroups(ownerID: ownerID),
            aggregate: false)
    }

    // MARK: - Canonicalization + hashing

    /// Trim, collapse internal whitespace, lowercase. Empty → nil, so an
    /// empty string can never masquerade as an identity.
    public static func canonical(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return collapsed.isEmpty ? nil : collapsed
    }

    /// FNV-1a 64, hex. Swift's `Hasher` is seeded per PROCESS — using it here would mint a
    /// different document id on every launch, which is exactly the append-only behavior being
    /// removed.
    public static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(value.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
