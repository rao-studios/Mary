// Defines durable archive identity and the retrieval scope that mirrors it.

import Foundation

// `ArchivePolicy` is NOT here. It travels on `SkillOutcome`, in MaryPlugin,
// because the binding that produces an outcome is the thing that knows what
// the outcome means for memory — and MaryAmbient sits below MaryPlugin, so
// a copy here could only ever be a second answer drifting from the first.

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

    /// SEER'S OWN long-term memory groups — not Mary's. Written by the
    /// server on every conversation, and therefore the only place the user's
    /// history across projects survives. Ids verified verbatim against the
    /// seer-server sources (this is the ONE place they are spelled):
    ///
    ///   `memory-<ownerId>`     — `Core/Seer+AutoMemory.swift`
    ///                            (`id: "memory-\(request.ownerId)"`,
    ///                             `label: Seer.autoMemoryGroupLabel` = "Memory")
    ///   `resonance-<ownerId>`  — `API/Routes/Handles/handleChatStreamCompletions.swift`
    ///                            and `API/Routes/Realtime/Realtime.swift`
    ///                            (`id: "resonance-\(seerRequest.ownerId)"`,
    ///                             `label: Sinatra.resonanceGroupLabel` = "Resonance")
    ///
    /// The owner id is interpolated RAW, exactly as the server does — no
    /// canonicalization. Lowercasing it here would mint a group the server
    /// never writes to, which fails the way every bug in this file fails:
    /// silently, as an empty result set.
    ///
    /// THE REGRESSION THIS EXISTS FOR: scoping a focused turn to the document
    /// group ALONE (`aggregate: false`, one `mary-scope-…`) blacked out
    /// long-term memory on nearly every turn, because "focused" is the normal
    /// state, not the exception. Worse, on the first turn in a project the
    /// scope group does not exist yet, so retrieval returned literally
    /// nothing. Carrying these two groups alongside Mary's Personal
    /// interaction group is what makes a never-yet-created scope group
    /// harmless: an unknown group contributes no candidates, and the turn
    /// still retrieves memory instead of collapsing to zero results.
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
    /// The document as a STABLE name: project-relative path for code, the
    /// document or manuscript name for prose. A name that wobbles between
    /// deposits is a new document every time, which is the bug this slice
    /// closes — so callers pass the same canonical spelling the prompt and
    /// the knowledge graph use.
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

    /// Names the WORKSPACE — the retrieval unit. The project when there is
    /// one (sibling files in one repo are one memory); the document itself
    /// when there isn't (a Pages document is its own world).
    ///
    /// Owner-qualified because one Totem DB holds many owners: Totem drops a
    /// group id already owned by someone else, so an un-owned group name
    /// would silently swallow a second user's deposits on a shared node.
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

    /// The deterministic document id for a `.stateSnapshot`. Nil when there
    /// is no document identity to key on — the caller must fall back to an
    /// episodic uuid rather than invent one, or two unrelated deposits would
    /// start overwriting each other.
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

    /// FNV-1a 64, hex. Swift's `Hasher` is seeded per PROCESS — using it here
    /// would mint a different document id on every launch, which is exactly
    /// the append-only behavior being removed. This is deliberately a plain
    /// arithmetic hash: no CryptoKit dependency in a package that must build
    /// for macOS 14, and trivially pinnable by a test.
    public static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(value.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
