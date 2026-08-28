//
//  StyleDimension.swift
//  MaryFoundation
//
//  THE CLOSED VOCABULARY, AND WHY IT IS THE WHOLE DESIGN.
//
//  A style profile is meant to travel — to another machine now, to someone
//  else's Totem later. But `docs/architecture/README.md` carries a standing
//  rule that a travelling artifact runs straight into:
//
//      "Package-authored prose is UI-only. Model instructions are compiled
//       from closed schema fields and Mary-owned literals, regardless of
//       signature or source."
//
//  The repo already solved this shape of problem once, and not with a better
//  consent dialog: executable content was REMOVED from dynamic packages
//  entirely, and `PluginRuntimePurityTests` now fails the build if the old
//  approval machinery so much as reappears by name. The problem was dissolved
//  by removing the capability.
//
//  Same move here. A tenet is split in two:
//
//    · the DIMENSION and its VALUE are closed enums, and Mary renders her
//      OWN sentence from them (`StyleTenet.rendered`);
//    · the statement and illustration are free prose and are inspector
//      metadata only — they never reach a model, exactly as
//      `AbilityPackageMetadata.summary` never does.
//
//  So an imported profile can bias a closed choice. It cannot introduce an
//  instruction, because there is no path from its bytes to a sentence Mary
//  did not already own. That is a capability boundary rather than a prompt
//  rule, which is the same reasoning that keeps peer context out of the lane
//  that can touch the machine.
//
//  ADDING A DIMENSION IS A DELIBERATE, REVIEWED ACT. This enum is the thing
//  standing between "a profile from elsewhere" and "a new instruction," so it
//  grows in code review and nowhere else.
//

import Foundation

/// A decision a person makes over and over without being asked to.
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
    // PROSE. Three dimensions a document corpus can answer by ARITHMETIC —
    // counting items, words and the presence of a synopsis file. Deliberately
    // not regex judgements: two of the Swift detectors have already been
    // confidently wrong on real code, and a wrong reading is worse here
    // because a manuscript has no compiler to contradict it.
    case annotationHabit
    case titlingStyle
    case sectionGranularity
    /// Not a choice — a bounded word list. Carried as DATA interpolated into a
    /// Mary-owned template, never as a sentence of its own. The one
    /// dimension that was cross-domain from the start: a "coordinator" means
    /// something in prose and in code.
    case roleVocabulary
    /// A dimension this build does not know. Reached only by decoding a
    /// profile written by a newer Mary.
    case unknown

    /// UNKNOWN VALUES DECAY, THEY NEVER THROW. `docs/TOTEM-MERGE.md` records
    /// the cost of the alternative: `Access` is a plain Codable string enum,
    /// and a rollback binary meeting a value it did not know made `restore()`
    /// throw, which re-seeded the registry empty and orphan-swept documents.
    /// A tenet on an unknown dimension is retained, inert, and invisible.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StyleDimension(rawValue: raw) ?? .unknown
    }

    /// The dimensions a profile actually reasons about.
    public static var known: [StyleDimension] {
        allCases.filter { $0 != .unknown }
    }

    /// The closed value set for this dimension, in no significant order.
    /// Empty for `roleVocabulary` (a word list) and `unknown`.
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

    // NOTHING GATES AN EDIT, deliberately. This carried an `isCheckable` flag
    // naming the five dimensions a checker could prove mechanically, on the
    // premise that those would block an edit that contradicted a settled
    // tenet. That gate cannot exist on the terms this feature is built for: a
    // refusal leaves a binding as `ok: false`, and `SkillOutcome.foundNothing`
    // documents what the turn does with one — the "silent success, SPOKEN
    // failure" rule says it aloud. The user would hear their own style rules
    // recited back as an edit failure, which is precisely the instructing this
    // whole mechanism exists to avoid.
    //
    // The corpus corrects itself without a gate anyway. Code that contradicts
    // a tenet lands, the user keeps it or rewrites it, the next crawl observes
    // whatever is actually there, and the per-source contributions replace.
    // Enforcement would only change how fast that happens, at the cost of
    // being audible.

    /// How broadly a tenet on this dimension can hold.
    ///
    /// THE ABILITY RUNG IS THE ONE THIS HANGS FROM, and it used to be empty.
    ///
    /// Nothing mapped here, so `.ability` — documented as "the load-bearing
    /// rung" — was never produced and the branch that files it was dead code.
    /// Worse, `concurrencyPrimitive` and `stateExposure` sat at `.application`,
    /// which is what made "xcode" the corpus's subject: `subjects(at:)` reads
    /// application identities, so a fact about SWIFT was filed under an EDITOR
    /// and could not follow the user to a second Swift editor.
    ///
    /// The line drawn here: a CRAFT habit (how you work, whatever you write it
    /// in) sits at `.ability`; a NOTATION habit sits at `.language`;
    /// `.application` is reserved for facts genuinely about one application's
    /// affordances, and nothing produces one yet; one repository's or one
    /// manuscript's arrangement stays at `.project`.
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

/// Every closed value across every dimension. One flat enum rather than one
/// per dimension: a tenet is stored, hashed, and transported as a pair, and a
/// nested associated-value shape would encode differently on either side of
/// the wire for no gain. `StyleDimension.accepts` is what keeps the pairing
/// honest.
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
    /// A value this build does not know — same decay rule as the dimension.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StyleValue(rawValue: raw) ?? .unknown
    }
}

/// How far a tenet reaches.
///
/// EVERY RUNG CARRIES AN IDENTITY (`StyleScope.identity`). It did not always:
/// `.application` was a bare tier with one static value for every application,
/// so an Xcode tenet and a Sketch tenet on the same dimension produced a
/// byte-identical `tenetKey` — and with it merged tallies, a merged identity
/// map, assert/veto bleed across crafts, and a persistence path that wrote one
/// application's evidence into another's document. Only Xcode ever produced,
/// so none of it had happened yet.
public enum StyleScopeKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// How this person writes one notation — identity is a language name.
    case language
    /// How this person does one KIND OF WORK, wherever they do it — identity
    /// is an `AbilityID` raw value.
    ///
    /// The load-bearing rung, and the one the whole chain hangs from: a tenet
    /// at `.ability("design")` is a fact about how you do design, so it
    /// travels to any application that realizes design. `AbilityParadigm` puts
    /// it exactly — a discipline is "portable semantics that outlive any one
    /// application", and application expertise "extends" it.
    case ability
    /// How they work in one application — identity is an application id.
    case application
    /// Vocabulary and structure specific to one repository.
    case project
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StyleScopeKind(rawValue: raw) ?? .unknown
    }

    /// Whether a tenet at this scope may be carried to another machine.
    /// Project tenets stay home — they are about one repository's furniture
    /// and mean nothing anywhere else.
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
