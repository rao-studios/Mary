//
//  ArtifactDomainLexicon.swift
//  MaryAmbient
//
//  The per-domain vocabulary the artifact machinery runs on — kind words,
//  deixis cues, and verb requirements. NOTHING in this file knows any domain:
//  the tables arrive compiled from admitted ability packages through
//  `AmbientArtifactLexiconProvider`, installed by the layer that owns package
//  trust. With nothing installed the classifier is DEAD and the gate's
//  synonym floors and precision veto stand down — the engine has no opinion
//  about what "oval" means until a package declares one. A baked-in default
//  would be one domain's table wearing a generic name, which is the exact
//  leak this seam removes.
//

import Foundation

/// One admitted domain's vocabulary, as plain values. Compiled OUTSIDE this
/// package (MaryBrain owns declaration trust and validation); everything
/// here is bounded lowercase tokens, never prose.
public struct ArtifactDomainLexicon: Sendable, Equatable {
    /// What a revision verb needs of its referent — "move" wants something
    /// with a spatial frame.
    public struct VerbRequirement: Sendable, Equatable {
        public var verbs: Set<String>
        public var requires: AmbientElementCapabilities

        public init(verbs: Set<String>, requires: AmbientElementCapabilities) {
            self.verbs = verbs
            self.requires = requires
        }
    }

    /// Spoken closed-class word → the provider kind words it admits.
    /// Several spoken words map to one provider kind ("circle" and
    /// "ellipse" both admit oval); one spoken word may admit several
    /// ("frame" admits artboard and group).
    public var synonyms: [String: Set<String>]
    /// Canonical provider kind → the capabilities the engine may assume.
    public var kindCapabilities: [String: AmbientElementCapabilities]
    /// Compact provider spellings → spoken forms ("shapepath" → "shape
    /// path") so the embedding sees language, not provider compounds.
    public var spokenForms: [String: String]
    /// Verbs that presuppose an existing artifact when aimed at a reference.
    public var reviseVerbs: Set<String>
    /// Verbs that open a creation.
    public var createVerbs: Set<String>
    /// Phrases marking "another one" — creation modeled on an exemplar.
    public var createMarkers: [String]
    /// Properties, not things — an `add` aimed at one is a revision.
    public var effectNouns: Set<String>
    /// The narrow verbs licensed to ADD a property to something existing.
    public var effectVerbs: Set<String>
    /// Closed generic object heads that carry no type identity of their own.
    public var deicticHeads: Set<String>
    public var verbRequirements: [VerbRequirement]

    /// Every provider kind word any synonym row admits — the vocabulary a
    /// provider itself speaks, which always self-matches. Precomputed once;
    /// the gate consults it per record.
    public let providerKinds: Set<String>

    public init(
        synonyms: [String: Set<String>] = [:],
        kindCapabilities: [String: AmbientElementCapabilities] = [:],
        spokenForms: [String: String] = [:],
        reviseVerbs: Set<String> = [],
        createVerbs: Set<String> = [],
        createMarkers: [String] = [],
        effectNouns: Set<String> = [],
        effectVerbs: Set<String> = [],
        deicticHeads: Set<String> = [],
        verbRequirements: [VerbRequirement] = []
    ) {
        self.synonyms = synonyms
        self.kindCapabilities = kindCapabilities
        self.spokenForms = spokenForms
        self.reviseVerbs = reviseVerbs
        self.createVerbs = createVerbs
        self.createMarkers = createMarkers
        self.effectNouns = effectNouns
        self.effectVerbs = effectVerbs
        self.deicticHeads = deicticHeads
        self.verbRequirements = verbRequirements
        self.providerKinds = Set(synonyms.values.joined())
            .union(kindCapabilities.keys)
    }

    // MARK: - Kind-word queries (the old AmbientKindLexicon API, per-domain)

    /// Every spoken kind word the phrase contains, in the order they appear.
    /// Word-boundary matching via `ReferenceResolver.mentions`, so "ovals"
    /// and "the oval." both count and "approval" does not.
    public func spokenKinds(in phrase: String) -> [String] {
        let lowered = phrase.lowercased()
        return synonyms.keys
            .filter { ReferenceResolver.mentions($0, in: lowered) }
            .sorted { first, second in
                (lowered.range(of: first)?.lowerBound ?? lowered.endIndex)
                    < (lowered.range(of: second)?.lowerBound ?? lowered.endIndex)
            }
    }

    /// True when an artifact of `providerKind` is one of the things `spoken`
    /// could mean. Falls back to plain containment so a provider kind this
    /// lexicon has never heard of still matches its own name.
    public func kind(_ providerKind: String, matches spoken: String) -> Bool {
        let kind = providerKind.lowercased()
        guard !kind.isEmpty else { return false }
        let word = spoken.lowercased()
        if let admitted = synonyms[word] { return admitted.contains(kind) }
        return ReferenceResolver.mentions(kind, in: word)
    }

    /// True when any spoken kind word in the phrase admits this artifact's
    /// kind — the form the ledger's matcher wants, where the phrase is a
    /// whole tail ("the header oval") rather than a single word.
    public func phrase(_ phrase: String, admits providerKind: String) -> Bool {
        spokenKinds(in: phrase).contains { kind(providerKind, matches: $0) }
    }

    /// A member of the closed class — either a spoken row or a provider's
    /// own kind word.
    public func isKnownKindWord(_ word: String) -> Bool {
        let lowered = word.lowercased()
        return synonyms[lowered] != nil || providerKinds.contains(lowered)
    }

    /// The provider kinds a word admits, or nil when the word is OPEN
    /// VOCABULARY — nil means the lexicon abstains and the semantic gate
    /// alone decides.
    public func admittedKinds(for word: String) -> Set<String>? {
        let lowered = word.lowercased()
        if let admitted = synonyms[lowered] { return admitted }
        if providerKinds.contains(lowered) { return [lowered] }
        return nil
    }

    // MARK: - Verb requirements

    /// Leading words that carry no verb: address, courtesy, and filler.
    private static let requirementSkipWords: Set<String> = [
        "can", "you", "please", "hey", "mary",
    ]

    /// What the utterance's leading verb requires of its referent — the
    /// slate filter that keeps "move it" from resolving to something with no
    /// frame to move. Empty when the verb carries no declared requirement.
    public func requirements(forUtterance utterance: String) -> AmbientElementCapabilities {
        let words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !Self.requirementSkipWords.contains($0) }
        guard let verb = words.first else { return [] }
        for requirement in verbRequirements where requirement.verbs.contains(verb) {
            return requirement.requires
        }
        return []
    }
}

/// Where the ambient layer looks for the lexicon of one application's
/// admitted artifact domain. The owner of package trust installs the whole
/// map at configuration; everything below reads through this. An inversion
/// rather than a direct call, because declarations live a layer above and
/// this package must not read them. The installed map is a frozen value —
/// rebuilt whole and swapped atomically, never mutated in place.
public enum AmbientArtifactLexiconProvider {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lexicons: [String: ArtifactDomainLexicon] = [:]

    /// Installs the live map, keyed by logical application id. Idempotent;
    /// the last caller wins.
    public static func install(_ lexicons: [String: ArtifactDomainLexicon]) {
        lock.lock()
        defer { lock.unlock() }
        Self.lexicons = lexicons
    }

    /// The lexicon governing one application, or nil when no admitted
    /// package declares a domain for it — the dead-until-installed answer.
    public static func lexicon(forApplication id: String) -> ArtifactDomainLexicon? {
        lock.lock()
        defer { lock.unlock() }
        return lexicons[id]
    }
}
