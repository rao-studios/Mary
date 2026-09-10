//
//  StyleDimension.swift
//  MaryFoundation
//
//  WHAT: Closed style dimensions and values. Grows in code review only.
//  IN:   PluginCorpusSchema style rules / StyleTenet.
//  OUT:  StyleRendering (Mary-owned sentence), StyleProfileCodec.
//  PIN:  Enum+value compile the instruction; statement/illustration are inspector-only.
//

import Foundation

/// Recurring craft choice. Closed enum; Mary owns the sentence (StyleRendering).
public enum StyleDimension: String, Codable, Hashable, Sendable, CaseIterable {
    case concurrencyPrimitive
    case stateExposure
    case errorPosture
    case testNaming
    case testFramework
    case bindingStyle
    case fileOrganization
    case accessDefault
    case commentPosture
    // Prose dimensions answered by arithmetic (counts), not regex.
    case annotationHabit
    case titlingStyle
    case sectionGranularity
    /// Bounded word list into a Mary-owned template. Cross-domain (prose and code).
    case roleVocabulary
    /// Newer-profile dimension. Decode-only.
    case unknown

    /// Unknown → `.unknown`, never throw. Tenet stays inert (rollback-safe).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StyleDimension(rawValue: raw) ?? .unknown
    }

    /// Known dimensions (excludes `.unknown`).
    public static var known: [StyleDimension] {
        allCases.filter { $0 != .unknown }
    }

    /// Closed values. Empty for `roleVocabulary` and `unknown`.
    public var values: [StyleValue] {
        switch self {
        case .concurrencyPrimitive: return [.lockBox, .actor, .serialQueue]
        case .stateExposure: return [.privateBoxedState, .publishedProperties]
        case .errorPosture: return [.degradeHonestly, .throwToCaller]
        case .testNaming: return [.sentence, .camelCaseUnit]
        case .testFramework: return [.swiftTesting, .xctest]
        case .bindingStyle: return [.guardEarlyReturn, .nestedConditional]
        case .fileOrganization: return [.extensionPerConcern, .singleFileType]
        case .accessDefault: return [.internalUnlessNeeded, .publicByDefault]
        case .commentPosture: return [.incidentAnchored, .apiDescriptive, .sparse]
        case .annotationHabit: return [.annotatesHeavily, .annotatesSparingly]
        case .titlingStyle: return [.sentenceTitles, .labelTitles]
        case .sectionGranularity: return [.manyShortSections, .fewLongSections]
        case .roleVocabulary, .unknown: return []
        }
    }

    public func accepts(_ value: StyleValue) -> Bool {
        values.contains(value)
    }

    // PIN: no edit gate. Corpus recrawls; spoken refusal would instruct.

    /// Widest StyleScopeKind: craft → `.ability`, notation → `.language`,
    /// repo layout → `.project`. `.application` reserved; unused yet.
    public var widestScope: StyleScopeKind {
        switch self {
        case .commentPosture, .errorPosture, .testNaming, .roleVocabulary,
             .annotationHabit, .titlingStyle:
            return .ability
        case .concurrencyPrimitive, .stateExposure, .bindingStyle,
             .accessDefault, .testFramework:
            return .language
        case .fileOrganization, .sectionGranularity, .unknown:
            return .project
        }
    }
}

/// Flat closed values. Pairing honesty: StyleDimension.accepts.
public enum StyleValue: String, Codable, Hashable, Sendable, CaseIterable {
    // concurrencyPrimitive
    case lockBox
    case actor
    case serialQueue
    // stateExposure
    case privateBoxedState
    case publishedProperties
    // errorPosture
    case degradeHonestly
    case throwToCaller
    // testNaming
    case sentence
    case camelCaseUnit
    // testFramework
    case swiftTesting
    case xctest
    // bindingStyle
    case guardEarlyReturn
    case nestedConditional
    // fileOrganization
    case extensionPerConcern
    case singleFileType
    // accessDefault
    case internalUnlessNeeded
    case publicByDefault
    // commentPosture
    case incidentAnchored
    case apiDescriptive
    case sparse
    // annotationHabit
    case annotatesHeavily
    case annotatesSparingly
    // titlingStyle
    case sentenceTitles
    case labelTitles
    // sectionGranularity
    case manyShortSections
    case fewLongSections
    /// Unknown value. Same decay as StyleDimension.unknown.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StyleValue(rawValue: raw) ?? .unknown
    }
}

/// How far a tenet reaches. Every rung carries StyleScope.identity.
public enum StyleScopeKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// One notation. Identity = language name.
    case language
    /// Kind of work. Identity = AbilityID. Travels with the discipline.
    case ability
    /// One application. Identity = application id.
    case application
    /// One repository's furniture.
    case project
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StyleScopeKind(rawValue: raw) ?? .unknown
    }

    /// May travel. Project/unknown stay home.
    public var isTransferable: Bool {
        switch self {
        case .language, .ability, .application: return true
        case .project, .unknown: return false
        }
    }

    /// Broadest first, so a presentation can order rungs without a second
    /// table that could disagree with this one.
    public var breadth: Int {
        switch self {
        case .ability: return 0
        case .language: return 1
        case .application: return 2
        case .project: return 3
        case .unknown: return 4
        }
    }
}
