//
//  MaryAdapter.swift
//  MaryBrain
//
//  The subshell's extension surface. A plugin is a knowledge pack for one
//  Mac application or capability: a prompt fragment that teaches the model
//  the app's scripting surface, plus curated Skill bindings — named operations the
//  model can call like any Skill. A binding's BACKING is an implementation
//  detail: an AppleScript template, or a native Swift closure (used where a
//  framework beats scripting, e.g. calendar data over EventKit).
//

import Foundation

/// Which safety class a binding belongs to. Reads run seamlessly; writes are
/// held by the Ability runtime for the user's spoken go-ahead; tweaks are reversible
/// mutations (volume, playback, appearance, checking off a reminder) that
/// execute immediately — the set of tweak Skill bindings is pinned by an allowlist
/// test so nothing rides the seamless path unreviewed.
public enum SkillAccessPolicy: Sendable, Equatable {
    case read
    case write
    case tweak
}

/// Turn-scoped semantic footing for application-surface selection. The
/// default means "operate on the live selection Mary observes now." Only
/// trusted upstream referent resolution may request the runtime-minted
/// previously-created surface; package data and plan JSON cannot set it.
public enum AbilitySurfaceReferent: Sendable, Equatable {
    case currentLiveSelection
    case previouslyCreatedSurface
    /// Trusted referent resolution named Mary's prior result, but no exact
    /// live opaque-token cache entry exists. Executors must refuse before
    /// navigation or semantic input rather than fall back to live selection.
    case previouslyCreatedSurfaceUnavailable
}

/// Carried into every binding execution.
public struct AbilityExecutionContext: Sendable {
    /// Configured project name → path on disk.
    public var projects: [String: String]
    /// The project the user is actively coding in (from the Xcode watcher);
    /// run_shell executes there so relative paths just work.
    public var codingProjectRoot: String?
    /// While pair-coding with permissions off (the default), edit-type
    /// commands run without CONFIRM. The destructive shell bank still stands.
    public var codingPermissionFree: Bool
    /// The "Ask before AppleScripts" toggle, inverted: true means a mutating
    /// run_applescript skips the CONFIRM parking and runs immediately.
    /// Defaults to false — asking is the default the settings sheet ships.
    public var appleScriptPermissionFree: Bool
    /// Absolute runtime deadline for the current Skill. Native adapters should
    /// pass the remaining interval into subprocess, Bluetooth, network, and
    /// automation calls and cooperate promptly with task cancellation.
    public var deadline: Date?
    /// Explicit, turn-scoped permission to consult Remote Hands' opaque
    /// created-surface cache. This must be reset to `.currentLiveSelection`
    /// for every new turn unless trusted referent resolution proves otherwise.
    public var surfaceReferent: AbilitySurfaceReferent
    /// WHAT THE USER ACTUALLY SAID this turn, for the one question no adapter
    /// can answer without it: did this argument come from THEM or from the
    /// model?
    ///
    /// A URL is the case that forced it. Mary is rigorous about never
    /// SHOWING a model a raw address — four separate suppression sites — so a
    /// deep link the model produces is one it invented, and it opened a dead
    /// YouTube video that way. But refusing every deep link then refused the
    /// links people read aloud from a page or a message, which is a perfectly
    /// ordinary thing to ask for. Provenance is the distinction, and the
    /// utterance is the only place it lives.
    ///
    /// Empty when nothing was said (a routine, a scheduled run). Callers must
    /// treat empty as "no provenance available", never as "the user said
    /// nothing, so refuse everything".
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

/// Typed adapter ingress. `arguments` keeps the current provider/string bridge
/// available during migration; `inputs` is the authoritative machine channel
/// whenever a workflow or Interaction can supply a validated ValueEnvelope.
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

/// Typed adapter egress. Outputs are merged into `outcome.typedOutputs` at the
/// runtime boundary so callers see one result shape regardless of backing.
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

/// A named, curated command a plugin contributes. Each binding is exposed to
/// the model as its own Skill — reliable for small models.
public struct SkillBinding: Sendable {
    public enum Backing: Sendable {
        /// Parametrized AppleScript. `{{name}}` placeholders substitute per
        /// the escaping spec (strings escaped inside quoted literals;
        /// integers validated; enums matched against enumValues) and run via
        /// /usr/bin/osascript with a 30 s timeout.
        case appleScript(template: String)
        /// Native Swift implementation.
        case native(@Sendable ([String: String], AbilityExecutionContext) async throws -> SkillOutcome)
        /// Native Swift implementation with schema-typed Value ports. New
        /// adapters should prefer this case; legacy `.native` closures remain
        /// source-compatible and bridge through the same execution funnel.
        case typedNative(@Sendable (TypedSkillInvocation) async throws -> TypedSkillResult)
    }

    /// snake_case Skill name, e.g. "list_events".
    public var name: String
    /// LLM-facing description — say when to call it.
    public var description: String
    public var parameters: [ModelSkillSchema.Parameter]
    public var access: SkillAccessPolicy
    public var backing: Backing
    /// Spoken question for the CONFIRM flow (write Skill bindings). May read stores
    /// to describe the target; must not mutate. Nil → a generic question.
    public var confirmationPreview: (@Sendable ([String: String], AbilityExecutionContext) async -> String)?
    /// Appended to failure summaries ("— check the automation permission").
    public var spokenFailureHint: String?
    /// True when the binding claims THE STAGE — frontmost focus and/or
    /// synthetic input (activates an app, drives menus, types, moves the
    /// editor caret). Stage Skill bindings preempt the current stage holder before
    /// running (the typer pauses resumably); background Skill bindings run freely
    /// in parallel. Pinned by the catalog's stage-set test.
    public var stage: Bool
    /// True when the binding CHANGES THE DOCUMENT WITHOUT GOING THROUGH THE
    /// PASSAGE CONTRACT — the two caret verbs, and nothing else so far.
    ///
    /// THE FAILURE THIS FIXES, live: Mary typed at the cursor, and the very
    /// next request — a whole-passage replace against a handle she was already
    /// holding — answered "it isn't in the document any more." It was. Her own
    /// keystrokes had landed INSIDE the stored words, so the passage's text no
    /// longer occurred anywhere in the body and `[S1]` named something that had
    /// ceased to exist one action after she was told about it. A plain
    /// re-anchor cannot recover that; the before/after pair can, because a
    /// caret write is one contiguous insertion by construction.
    ///
    /// A DECLARATION, and not `access != .read`, because `delegate_coding` is
    /// a write by any reading of the word and must be FALSE: it returns
    /// `deferred` and the buffer it changes changes minutes later on another
    /// channel, so a before/after pair captured around the call would compare a
    /// document to itself, refresh nothing, and charge two reads for it. The
    /// five passage verbs are false for the opposite reason — they maintain the
    /// invariant themselves at the end of the edit, and re-anchoring after one
    /// would burn two more reads recomputing what the mint just computed.
    ///
    /// Declared per binding, statically, exactly as `stage` is — the only shape
    /// that survives a new write verb being added by someone who never read
    /// this file. Pinned as a SET by the catalog's `unroutedWriteSetIsPinned`.
    public var unroutedWrite: Bool
    /// True when the binding PREPARES A SURFACE rather than delivering the
    /// asked-for work — creates a document, opens one, raises a window. A
    /// turn whose lane ran ONLY preparation on an acting request has not done
    /// the thing; the lane's continuation nudge treats these like reads so a
    /// create→type compound gets its second half instead of terminating on
    /// "Fresh page, ready" with nothing typed (the incident).
    ///
    /// A declaration, not `stage` — stage ops include the typer itself (which
    /// DELIVERS), and preparation includes non-stage opens.
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
    /// Typed, value-only inventory for the executable adapter this Plugin
    /// installs. Ability packages bind to this stable identity; closures and
    /// application handles remain private to the Plugin implementation.
    var adapterManifest: InstalledAdapterManifest { get }
    /// The cross-application abilities this plugin can carry out.
    var abilities: Set<AbilityID> { get }
    /// Names that can identify this application in natural language.
    var applicationAliases: Set<String> { get }
    /// Exact bundle/process application ids owned by this adapter. These are
    /// machine identity, not natural-language aliases.
    var applicationIdentifiers: Set<String> { get }
    /// The binding that reads a NAMED PART of whatever this app has open, and
    /// the parameter that carries the phrase to look for. Nil (the default)
    /// means the app has no such read and the fetch-first pre-read skips it.
    ///
    /// Declared here rather than hardwired in the brain so the brain never
    /// learns a plugin's Skill names, and so the pre-read reuses the SAME
    /// targeting the model uses — one read path, not two that can drift.
    var targetedRead: (binding: String, parameter: String)? { get }
    // NO PASSAGE BACKING YET. This is where an adapter says "my documents
    // are prose a passage can be cut from", handing the passage verbs a
    // reader and a writer. It arrives with the passage machinery in the stage
    // that ports it — declared on the protocol then, for the reason it was
    // declared on Bonnie's: the passage Skill bindings are registered once,
    // by the typer, and must not learn any adapter's internals to do it. A
    // place becomes editable by answering this and nothing else.
    /// EVERY SENTENCE THIS PLUGIN HANDS BACK INSTEAD OF ACTING — the closed
    /// world's refusals, declared. Empty (the default) is the honest answer for
    /// a plugin that has no world to be shut.
    ///
    /// SCOPE, because a roster nobody can bound is a roster nobody maintains:
    /// strings that leave this plugin as an `SkillOutcome.summary` when
    /// NOTHING WAS ATTEMPTED. A read that ran and could not be trusted
    /// (`MailPlugin.movingMessage`) is not one of these — something happened
    /// there, and the sentence is about what happened. Prompt fragments and
    /// watcher contributions are out too: naming the verb is the POINT there,
    /// and a fragment that says "open_in_pages brings a document up" is
    /// teaching, not refusing.
    ///
    /// DECLARED PER PLUGIN, statically, exactly as `stage` and `unroutedWrite`
    /// are — and for their reason rather than a new one. The two rules over
    /// this roster (a refusal names no registered binding; a refusal reads as no
    /// errand) are worth nothing if the next refusal is written by somebody who
    /// never read them, and that is precisely how these shipped: five apps, five
    /// authors, four sentences naming a verb that launches the app the guard
    /// exists not to launch. Pinned as a SET by the catalog's
    /// `refusalSetIsPinned`, so a sixth refusal is a conscious decision.
    /// THIS WORLD'S ADDRESSABLE CONTAINERS — nil for a world that has exactly
    /// one, which is most of them.
    ///
    /// The seam that makes "the other one" / "the last one" / "that note" work
    /// without any world knowing those words. A world says what it holds; the
    /// shared `ReferenceResolver` does the pointing. Optional-and-nil-by-default
    /// exactly like `targetedRead`, `targetedEdit` and `passageBacking`, so a
    /// single-document world stays silent and pays nothing.
    ///
    /// `ContainerRoster.cached` MAY NOT SPAWN. The resolver consults it on
    /// every turn, and the overwhelming majority of turns name no container at
    /// all.
    var containerRoster: ContainerRoster? { get }

    var refusals: [String] { get }
    /// THE SKILL BINDING THAT CHANGES A LOCATED PASSAGE in this world, and the
    /// parameter that carries the handle. Nil means this world can COMPOSE but
    /// not REVISE, and the revision gates skip it entirely — no body is read,
    /// no passage is located, nothing fires.
    ///
    /// `targetedRead`'s twin, declared for `targetedRead`'s reason: the brain
    /// must never learn a plugin's Skill names, and the world that leads the
    /// turn is the only thing that can honestly say what changing part of its
    /// document is called.
    ///
    /// THE FAILURE THIS ANSWERS. In Pages: "replace the Purpose section with
    /// the tighter version" → `type_at_cursor`, the new prose landing at the
    /// caret, the Purpose section still standing. The user: "intended for live
    /// writing behavior rather than revision behavior." Nothing between the
    /// classifier and the Skill lane could say what she SHOULD have called,
    /// because nothing had asked the world in front of her.
    var targetedEdit: (binding: String, parameter: String)? { get }

    /// WHICH AMBIENT WORLD THIS PROVIDER SERVES, declared rather than spelled.
    ///
    /// For the twenty-odd application plugins the answer is their own name, and
    /// the default below says exactly that — `AmbientWorld.from(pluginOwner:)`
    /// is the rule those lookups used to hand-roll from the plugin's id.
    ///
    /// It becomes a real question only for an OBSERVATION ADAPTER: a native
    /// provider that performs a world's reads without being that world's
    /// application identity, because the identity now belongs to a Dynamic
    /// package (`application-shadows-runtime` admits only one claimant,
    /// and `AmbientApplicationRoster` treats that disjointness as an invariant).
    /// Scrivener's reads are the case — the macUI engine cannot return data at
    /// all (`output-contract-unsupported`), so they stay native while
    /// the package owns the name.
    ///
    /// Without this declaration such an adapter's reads would file under the
    /// generic `.otherApps` lane keyed by the ADAPTER's id rather than the
    /// world's, and `targetedReadInvocation(forWorld:)` — which looks its table
    /// up by `world.pluginOwner` — would answer nil, silently taking fetch-first
    /// out of service for that world. Both are failures that report success.
    var servedWorld: AmbientWorld? { get }
}

public extension MaryAdapter {
    var promptFragment: String? { nil }
    /// Existing compiled application adapters receive an honest, minimally
    /// claimed manifest automatically. `.native` describes Mary's direct
    /// dispatch into this compiled provider, not every OS facility the provider
    /// may use internally. Exact operations are authoritative; empty
    /// typed claim lists deliberately mean "not yet specified" rather than
    /// falsely claiming the adapter cannot carry a Value or signal. A Plugin
    /// can override this property to publish its complete typed contract or a
    /// dynamic availability snapshot (including Bluetooth connectivity).
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
    var containerRoster: ContainerRoster? { nil }
    var refusals: [String] { [] }

    /// The plugin's own id IS its world, for every plugin that is one.
    var servedWorld: AmbientWorld? { AmbientWorld.from(pluginOwner: name) }

    /// Nil until the passage machinery lands, when this goes back to being
    /// DERIVED from the backing rather than answered here.
    var targetedEdit: (binding: String, parameter: String)? { nil }

    // TARGETED EDIT IS DERIVED FROM THE BACKING, so it waits for it. The
    // rule it makes true is worth keeping in view while it is away: a place
    // becomes editable by answering `passageBacking` and NOTHING ELSE. A
    // second hand-written declaration of the same fact would eventually
    // disagree with the first — a place that can write but forgot the second
    // line composes forever and nobody notices.

    var applicationProfile: ApplicationProfile {
        ApplicationProfile(
            id: name,
            // Display name, not the id: this title is USER-FACING — the
            // mismatch mirror's "— xcode is" printed lowercase because
            // native profiles defaulted title to the id. Worldless natives
            // (calendar, mac, …) keep the id via the init's `title ?? id`.
            title: AmbientWorld.from(pluginOwner: name)?.displayName,
            summary: summary,
            abilities: abilities,
            aliases: applicationAliases,
            applicationIdentifiers: applicationIdentifiers,
            skills: skillBindings.map { .init(name: $0.name, description: $0.description) },
            guidance: promptFragment)
    }
}
