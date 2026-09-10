//
//  AmbientCapability.swift
//  MaryAmbient
//
//  WHAT: Application metadata used by routing and the application-knowledge thread.
//  IN:   package declarations
//  OUT:  AmbientPlace / AmbientEngine / Thread knowledgeDocument
//  PIN:  Aliases vs bundle identifiers are unlike namespaces. Family prefix for versions; launch still uses exact id.
//
import Foundation

/// Application metadata used by routing and the application-knowledge thread.
public struct ApplicationProfile: Sendable, Equatable {
    public struct Skill: Sendable, Equatable {
        public var name: String
        public var description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public var id: String
    public var title: String
    public var summary: String
    public var abilities: Set<AbilityID>
    public var aliases: Set<String>
    /// Exact process/application identities this representation owns. Human aliases answer “did
    /// the user name Safari?”; bundle identifiers answer “did this source-owned Interaction
    /// actually come from Safari?”.
    public var applicationIdentifiers: Set<String>
    /// THE PROCESS FAMILY, when exact ids are not enough. An application ships one bundle id
    /// per major version (`…scrivener3`), so a roster keyed on exact ids alone recognises this
    /// year's build and loses next year's — silently, as "some app I don't know".
    public var applicationBundlePrefix: String?
    /// Validated, path-free `.app` bundle names supplied by an application
    /// representation. They enrich human routing and inspector/discovery
    /// metadata; bundle identifiers remain the process-identity authority.
    public var applicationBundleNames: Set<String>
    /// Closed routing classes an admitted application representation can
    /// satisfy when that exact logical/bundle identity leads the turn.
    public var targetClasses: Set<String>
    public var skills: [Skill]
    public var guidance: String?
    /// HOW THIS APPLICATION MAY BE OBSERVED, when its package asked to be watched rather than
    /// only operated.
    public var perception: ApplicationPerception?

    /// What this application calls ONE of its documents, singular.
    public var documentNoun: String?

    public init(
        id: String,
        title: String? = nil,
        summary: String,
        abilities: Set<AbilityID> = [],
        aliases: Set<String> = [],
        applicationIdentifiers: Set<String> = [],
        applicationBundlePrefix: String? = nil,
        applicationBundleNames: Set<String> = [],
        targetClasses: Set<String> = [],
        skills: [Skill] = [],
        guidance: String? = nil,
        perception: ApplicationPerception? = nil,
        documentNoun: String? = nil
    ) {
        self.id = id
        self.title = title ?? id
        self.summary = summary
        self.abilities = abilities
        self.aliases = aliases.union([id, title ?? id])
        self.applicationIdentifiers = applicationIdentifiers
        self.applicationBundlePrefix = applicationBundlePrefix
        self.applicationBundleNames = applicationBundleNames
        self.targetClasses = targetClasses
        self.skills = skills
        self.guidance = guidance
        self.perception = perception
        self.documentNoun = documentNoun
    }

    public func isMentioned(in utterance: String) -> Bool {
        let words = Self.normalizedWords(utterance)
        return aliases.contains { alias in
            let aliasWords = Self.normalizedWords(alias)
            return !aliasWords.isEmpty && words.windows(ofCount: aliasWords.count).contains(aliasWords)
        }
    }

    /// Canonical identity used when admission compares routing aliases. It is
    /// intentionally derived by the same tokenizer as `isMentioned`.
    public static func routingIdentity(for value: String) -> String? {
        let identity = normalizedWords(value).joined(separator: " ")
        return identity.isEmpty ? nil : identity
    }

    public var knowledgeDocument: String {
        var lines = [
            "Application: \(title)",
            "Purpose: \(summary)",
        ]
        if !abilities.isEmpty {
            lines.append("Abilities: \(abilities.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        // Bundle names remain routing/Studio metadata. They are package-authored filenames, not
        // model instructions, and therefore never enter Thread knowledge prose.
        if !skills.isEmpty {
            lines.append("Skills:")
            lines.append(contentsOf: skills.map { "- \($0.name): \($0.description)" })
        }
        if let guidance, !guidance.isEmpty {
            lines.append("Guidance: \(guidance)")
        }
        return lines.joined(separator: "\n")
    }

    private static func normalizedWords(_ value: String) -> [String] {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

private extension Array where Element == String {
    func windows(ofCount count: Int) -> [[String]] {
        guard count > 0, count <= self.count else { return [] }
        return indices.dropLast(count - 1).map { Array(self[$0..<($0 + count)]) }
    }
}
