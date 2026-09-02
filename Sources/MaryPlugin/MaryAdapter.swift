//
//  MaryAdapter.swift
//  MaryBrain
//
//  WHAT: Plugin contract — prompt fragment plus curated Skill bindings.
//  IN:   MaryAdapterCatalog / Ability runtime
//  OUT:  SkillBinding → SkillOutcome
//  PIN:  Backing is an implementation detail (Swift closure; AppleScript later).
//

import Foundation

/// Safety class. Reads run; writes wait for spoken go-ahead; tweaks are
/// reversible and immediate. Tweak set is pinned by an allowlist test.
public enum SkillAccessPolicy: Sendable, Equatable {
    case read
    case write
    case tweak
}

/// Turn-scoped surface selection. Default: live selection Mary observes now.
/// Only trusted referent resolution may request the previously-created surface.
public enum AbilitySurfaceReferent: Sendable, Equatable {
    case currentLiveSelection
    case previouslyCreatedSurface
    /// Prior result named, but no live opaque-token cache entry.
    /// OUT: refuse — do not fall back to live selection.
    case previouslyCreatedSurfaceUnavailable
}

/// The two bindings a provider offers Mary's own standing awareness of the
/// work in front of the user: the UNIT she is inside, and what SURROUNDS it.
///
/// PIN: the brain never learns a Skill name — this is `targetedRead`'s shape
/// and exists for the same reason. A provider says which of its bindings
/// answer these two questions; `AbilityRuntime` calls them, and the turn loop
/// only ever asks for "awareness".
public struct AwarenessRead: Sendable, Equatable {
    /// Binding returning the declaration/passage the cursor or highlight is in.
    public var unit: String
    /// Binding returning what reaches that unit and what it reaches.
    public var surroundings: String

    public init(unit: String, surroundings: String) {
        self.unit = unit
        self.surroundings = surroundings
    }
}

/// Carried into every binding execution.
public struct AbilityExecutionContext: Sendable {
    /// Configured project name → path on disk.
    public var projects: [String: String]
    /// Project the user is coding in; run_shell executes there.
    public var codingProjectRoot: String?
    /// Pair-coding with permissions off: edit-type commands skip CONFIRM.
    public var codingPermissionFree: Bool
    /// Inverted "Ask before AppleScripts": mutating run_applescript skips CONFIRM.
    public var appleScriptPermissionFree: Bool
    /// Absolute Skill deadline. Pass remaining interval into subprocess/network.
    public var deadline: Date?
    /// Permission to consult Remote Hands' created-surface cache.
    /// PIN: reset to `.currentLiveSelection` each turn unless referent resolution proves otherwise.
    public var surfaceReferent: AbilitySurfaceReferent
    /// What the user said this turn — provenance for arguments (user vs model).
    /// PIN: empty = no provenance, never "refuse everything".
    public var utterance: String

    public init(
        projects: [String: String],
        codingProjectRoot: String? = nil,
        codingPermissionFree: Bool = false,
        appleScriptPermissionFree: Bool = false,
        deadline: Date? = nil,
        surfaceReferent: AbilitySurfaceReferent = .currentLiveSelection,
        utterance: String = ""
    ) {
        self.projects = projects
        self.codingProjectRoot = codingProjectRoot
        self.codingPermissionFree = codingPermissionFree
        self.appleScriptPermissionFree = appleScriptPermissionFree
        self.deadline = deadline
        self.surfaceReferent = surfaceReferent
        self.utterance = utterance
    }

    public var remainingTime: TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSinceNow) }
    }
}

/// Typed adapter ingress. `inputs` is authoritative when a workflow supplies
/// a ValueEnvelope; `arguments` is the provider/string bridge during migration.
public struct TypedSkillInvocation: Sendable {
    public var arguments: [String: String]
    public var inputs: [String: ValueEnvelope]
    public var context: AbilityExecutionContext

    public init(
        arguments: [String: String] = [:],
        inputs: [String: ValueEnvelope] = [:],
        context: AbilityExecutionContext
    ) {
        self.arguments = arguments
        self.inputs = inputs
        self.context = context
    }
}

/// Typed adapter egress. Runtime merges `outputs` into `outcome.typedOutputs`.
public struct TypedSkillResult: Sendable {
    public var outcome: SkillOutcome
    public var outputs: [String: ValueEnvelope]

    public init(
        outcome: SkillOutcome,
        outputs: [String: ValueEnvelope] = [:]
    ) {
        self.outcome = outcome
        self.outputs = outputs
    }
}

/// Named command a plugin contributes. Exposed to the model as its own Skill.
public struct SkillBinding: Sendable {
    public enum Backing: Sendable {
        case native(@Sendable ([String: String], AbilityExecutionContext) async throws -> SkillOutcome)
        /// Schema-typed Value ports. Prefer this; `.native` still bridges.
        case typedNative(@Sendable (TypedSkillInvocation) async throws -> TypedSkillResult)
    }

    /// snake_case Skill name, e.g. "list_events".
    public var name: String
    /// LLM-facing description — say when to call it.
    public var description: String
    public var parameters: [ModelSkillSchema.Parameter]
    public var access: SkillAccessPolicy
    public var backing: Backing
    /// Spoken CONFIRM question (write bindings). May read; must not mutate.
    public var confirmationPreview: (@Sendable ([String: String], AbilityExecutionContext) async -> String)?
    /// Appended to failure summaries ("— check the automation permission").
    public var spokenFailureHint: String?
    /// Claims the stage (focus / synthetic input). Preempts the current holder.
    /// PIN: catalog stage-set test.
    public var stage: Bool
    /// Changes the document without the passage contract (caret verbs).
    /// PIN: not `access != .read` — delegate_coding is a write but must be false
    ///      (deferred; buffer changes later). Catalog `unroutedWriteSetIsPinned`.
    public var unroutedWrite: Bool
    /// Prepares a surface (create/open/raise) rather than delivering the work.
    /// OUT: lane continuation treats these like reads so create→type continues.
    public var preparesSurface: Bool

    public init(
        name: String,
        description: String,
        parameters: [ModelSkillSchema.Parameter] = [],
        access: SkillAccessPolicy,
        backing: Backing,
        confirmationPreview: (@Sendable ([String: String], AbilityExecutionContext) async -> String)? = nil,
        spokenFailureHint: String? = nil,
        stage: Bool = false,
        unroutedWrite: Bool = false,
        preparesSurface: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.access = access
        self.backing = backing
        self.confirmationPreview = confirmationPreview
        self.spokenFailureHint = spokenFailureHint
        self.stage = stage
        self.unroutedWrite = unroutedWrite
        self.preparesSurface = preparesSurface
    }

    public var schema: ModelSkillSchema {
        ModelSkillSchema(name: name, description: description, parameters: parameters)
    }
}

/// A Mary plugin: knowledge plus curated Skill bindings.
public protocol MaryAdapter: Sendable {
    /// Stable snake_case id, e.g. "calendar".
    var name: String { get }
    /// One line for the system-prompt roster.
    var summary: String { get }
    /// Usage guidance injected into the system prompt while installed.
    var promptFragment: String? { get }
    var skillBindings: [SkillBinding] { get }
    /// Typed inventory for the executable adapter this Plugin installs.
    var adapterManifest: InstalledAdapterManifest { get }
    /// Cross-application abilities this plugin can carry out.
    var abilities: Set<AbilityID> { get }
    /// Names that can identify this application in natural language.
    var applicationAliases: Set<String> { get }
    /// Exact bundle/process ids. Machine identity, not aliases.
    var applicationIdentifiers: Set<String> { get }
    /// Binding that reads a named part, plus the phrase parameter.
    /// PIN: brain never learns Skill names; pre-read reuses the model's targeting.
    var targetedRead: (binding: String, parameter: String)? { get }
    /// Extra owner keys that share this adapter's `targetedRead`.
    var targetedReadAliases: [String] { get }
    /// Bindings that answer what the user is looking at, and what surrounds it.
    /// Nil for every provider that is not an awareness faculty.
    var awarenessRead: AwarenessRead? { get }
    /// Addressable containers. Nil for a single-document world.
    /// OUT: ReferenceResolver. PIN: ContainerRoster.cached must not spawn.
    var containerRoster: ContainerRoster? { get }

    /// Closed-world refusals: summaries when nothing was attempted.
    /// PIN: catalog `refusalSetIsPinned`. Not a ran-and-untrusted read.
    var refusals: [String] { get }

    /// Binding that changes a located passage, plus the handle parameter.
    /// Nil = compose but not revise. PIN: from passageBacking when that lands.
    var targetedEdit: (binding: String, parameter: String)? { get }

    /// Ambient world this provider serves. Default: plugin id.
    /// PIN: observation adapters whose identity lives on a package must declare this.
    var servedAttention: AmbientAttention? { get }
}

public extension MaryAdapter {
    var promptFragment: String? { nil }
    /// Honest minimal manifest for compiled adapters. Empty typed lists mean
    /// "not yet specified", not "cannot carry a Value". Override for a full contract.
    var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: applicationProfile.title,
            transport: .native,
            operations: skillBindings.map { binding in
                InstalledAdapterBinding(
                    adapterID: adapterID,
                    operation: binding.name)
            })
    }
    var abilities: Set<AbilityID> { [] }
    var applicationAliases: Set<String> { [name] }
    var applicationIdentifiers: Set<String> { [] }
    var targetedRead: (binding: String, parameter: String)? { nil }
    var targetedReadAliases: [String] { [] }
    var awarenessRead: AwarenessRead? { nil }
    var containerRoster: ContainerRoster? { nil }
    var refusals: [String] { [] }

    /// Plugin id is its world, for every plugin that is one.
    var servedAttention: AmbientAttention? { AmbientAttention.from(pluginOwner: name) }

    /// Nil until passage machinery lands; then derived from passageBacking.
    var targetedEdit: (binding: String, parameter: String)? { nil }

    var applicationProfile: ApplicationProfile {
        ApplicationProfile(
            id: name,
            // Display name: user-facing. Worldless natives keep the id via `title ?? id`.
            title: AmbientAttention.from(pluginOwner: name)?.displayName,
            summary: summary,
            abilities: abilities,
            aliases: applicationAliases,
            applicationIdentifiers: applicationIdentifiers,
            skills: skillBindings.map { .init(name: $0.name, description: $0.description) },
            guidance: promptFragment)
    }
}
