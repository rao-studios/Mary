//
//  ApplicationProviderResolver.swift
//  MaryBrain
//
//  WHICH APPLICATION ANSWERS A PROVIDER-NEUTRAL SKILL THIS TURN — the
//  per-turn resolver DYNAMIC-APPLICATION-ABILITIES.md reserves: "select and
//  memoize an application-aware provider per turn before chip emission."
//
//  THE FAILURE THIS FIXES. `design.create-shape` is realized by Sketch at
//  preference 320 and by Keynote at 200, and static preference was the ONLY
//  arbiter: with Keynote frontmost and Sketch merely installed, "add a
//  shape" drew in Sketch. Preference is package data — a tuning signal, not
//  a claim about what the person is looking at.
//
//  THE PRECEDENCE IS THE SPEC'S OWN (doc §realizations): a NAMED application
//  outranks the interaction's source, which outranks a pinned choice, which
//  outranks the FOCUSED application, which outranks static preference. Words
//  beat pointing beats posture beats packaging.
//
//  BOUNDED BY CONSTRUCTION: the resolver chooses among
//  `snapshot.compatibleBindings(for:)` and nothing else — the compatibility
//  evaluator already refused unavailable manifests, missing permissions, and
//  missing capabilities, so no signal can resurrect a provider the
//  evaluator rejected. Skills realized by a single application never get a
//  CHOICE entry; every consumer falls back to `selectedBinding`,
//  byte-for-byte today's behavior — unless the turn's own signals prove
//  that binding wrong, below.
//
//  THE MISMATCH LEDGER. The choice map cannot express "no compatible
//  provider serves the application this turn asserted": with Keynote
//  frontmost, "group these shapes" has exactly one candidate — Sketch — and
//  falling back to `selectedBinding` edited an application the person was
//  not looking at, silently. The strongest non-empty signal rung is compared
//  with the skill's candidates. If that rung is disjoint, the skill gets a
//  MISMATCH entry instead of a choice and dispatch abstains with both app
//  names in hand. Ambiguity remains conservative within one rung, but a
//  lower focused app cannot rescue a different application the user named.
//  This deliberately supersedes the old silent
//  fallback for a named-but-denied provider: named-Keynote with grants
//  refused now abstains honestly instead of substituting Sketch.
//

import Foundation

/// What this turn KNOWS about applications, gathered once by the runtime —
/// the resolver itself is pure and synchronous, like `AmbientEngine.resolve`.
struct ApplicationProviderSignals: Hashable, Sendable {
    /// Applications the words named (route gate + lead + attention source
    /// aliases, exactly the set `abilityRoutingContext()` assembles).
    var namedApplicationIDs: Set<String> = []
    /// The application that OWNS this turn's accepted interaction packet —
    /// a selection the route admitted as the referent.
    var interactionApplicationID: String?
    /// Reserved: no pinning surface exists yet. Always nil until one does,
    /// kept so the precedence ladder is the spec's, not a subset of it.
    var pinnedApplicationID: String?
    /// The application whose window is frontmost, when it maps to a profile.
    var focusedApplicationID: String?
}

/// The turn's frozen provider choices, keyed by Skill. Memoized by
/// `AbilityRuntime` at first use and cleared in `beginTurn()`, so schema
/// projection, chip emission, and dispatch all read the SAME answer — a chip
/// can never name Sketch while execution uses Keynote.
struct ProviderTurnSelection: Sendable {
    enum Rationale: String, Sendable {
        case named, interaction, pinned, focused, staticPreference
    }

    struct Choice: Sendable {
        var binding: InstalledAdapterBinding
        var provider: AdapterProviderProvenance?
        var rationale: Rationale
    }

    /// The turn asserted an application no compatible candidate serves —
    /// dispatch abstains and names both sides instead of silently editing
    /// an application the person is not looking at.
    struct Mismatch: Sendable {
        var wantedApplicationID: String
        var wantedTitle: String
        var rationale: Rationale
        var availableApplicationIDs: Set<String>
        var availableTitles: [String]
    }

    var choices: [SkillID: Choice] = [:]
    var mismatches: [SkillID: Mismatch] = [:]
    /// Every application id this turn's signals asserted (named ∪ interaction
    /// ∪ pinned ∪ focused), resolved against registered profiles. Empty means
    /// "no signals" — static behavior everywhere. Diagnostics retain this
    /// complete set.
    var assertedApplicationIDs: Set<String> = []
    /// The strongest non-empty signal rung. Execution boundaries use this
    /// rather than the full union so focus cannot override a literal name.
    var decisiveApplicationIDs: Set<String> = []

    static let empty = ProviderTurnSelection()

    func choice(for id: SkillID) -> Choice? { choices[id] }
    func operation(for id: SkillID) -> String? { choices[id]?.binding.operation }
    func mismatch(for id: SkillID) -> Mismatch? { mismatches[id] }
}

enum ApplicationProviderResolver {

    /// Resolve every multi-application Skill's provider for this turn.
    /// Skills with zero or one candidate application are omitted — absence
    /// means "use `selectedBinding`", which keeps the single-provider world
    /// untouched.
    static func resolve(
        snapshot: AbilityRuntimeSnapshot,
        signals: ApplicationProviderSignals,
        /// EVERY registered application — native profiles included. Signal
        /// tokens resolve against this list, not only the dynamic one: with
        /// Keynote a Native Plugin, "make the circle blue in Keynote" said
        /// while Sketch leads must still ASSERT keynote so the dynamic-only
        /// skill mismatches honestly instead of silently editing Sketch.
        /// Nil falls back to the snapshot's dynamic profiles — the pre-native
        /// behavior, and what resolver-only tests exercise.
        profiles: [ApplicationProfile]? = nil
    ) -> ProviderTurnSelection {
        var selection = ProviderTurnSelection()
        let known = profiles ?? snapshot.plugins.applicationProfiles
        // The rungs are turn facts, not skill facts — resolved once.
        let rungs: [(Set<String>, ProviderTurnSelection.Rationale)] = [
            (resolveIDs(signals.namedApplicationIDs, in: known), .named),
            (resolveIDs(signals.interactionApplicationID, in: known), .interaction),
            (resolveIDs(signals.pinnedApplicationID, in: known), .pinned),
            (resolveIDs(signals.focusedApplicationID, in: known), .focused),
        ]
        let asserted = rungs.reduce(into: Set<String>()) { $0.formUnion($1.0) }
        selection.assertedApplicationIDs = asserted
        selection.decisiveApplicationIDs = rungs.first { !$0.0.isEmpty }?.0 ?? []
        for runtime in snapshot.skills {
            let candidates = snapshot.compatibleBindings(for: runtime.skill.id)
            guard !candidates.isEmpty else { continue }
            let attributed: [(binding: InstalledAdapterBinding, applicationID: String?)] =
                candidates.map { candidate in
                    (candidate, providerApplicationID(of: candidate, in: snapshot))
                }
            let distinctApplications = Set(attributed.compactMap(\.applicationID))

            // THE MISMATCH TEST follows provider-choice precedence. A named
            // unsupported application is not diluted by a lower focused
            // signal merely because that lower provider can serve. Multiple
            // identities inside the winning rung remain conservative: any
            // overlap keeps normal provider choice reachable. A candidate
            // carrying no application identity cannot be proven mismatched.
            let wantedRung = rungs.first { !$0.0.isEmpty }
            if !distinctApplications.isEmpty,
               let (wantedIDs, rationale) = wantedRung,
               wantedIDs.isDisjoint(with: distinctApplications),
               let wantedID = wantedIDs.sorted().first {
                    selection.mismatches[runtime.skill.id] = ProviderTurnSelection.Mismatch(
                        wantedApplicationID: wantedID,
                        wantedTitle: title(of: wantedID, in: known),
                        rationale: rationale,
                        availableApplicationIDs: distinctApplications,
                        availableTitles: distinctApplications
                            .map { title(of: $0, in: known) }
                            .sorted())
                continue
            }

            guard candidates.count > 1, distinctApplications.count > 1 else { continue }
            var chosen: (InstalledAdapterBinding, ProviderTurnSelection.Rationale)?
            for (wanted, rationale) in rungs where !wanted.isEmpty {
                let matchedApplications = distinctApplications.intersection(wanted)
                // Exactly one application answers this rung. Two named apps
                // both providing is a genuine ambiguity — fall through and
                // let a more grounded rung (or static preference) settle it.
                guard matchedApplications.count == 1,
                      let application = matchedApplications.first,
                      let winner = attributed.first(where: {
                          $0.applicationID == application
                      })?.binding
                else { continue }
                chosen = (winner, rationale)
                break
            }
            let (binding, rationale) = chosen ?? (candidates[0], .staticPreference)
            selection.choices[runtime.skill.id] = ProviderTurnSelection.Choice(
                binding: binding,
                provider: snapshot.adapterManifest(id: binding.adapterID)?.resolvedProvider,
                rationale: rationale)
        }
        return selection
    }

    /// The human name chips and blocked outcomes print for an application
    /// id — its registered profile title, or the id itself when no profile
    /// carries one.
    private static func title(
        of applicationID: String, in profiles: [ApplicationProfile]
    ) -> String {
        profiles.first { $0.id.lowercased() == applicationID }?.title ?? applicationID
    }

    /// The application a compatible candidate drives, via its adapter's
    /// frozen provenance — the same authority chips print.
    private static func providerApplicationID(
        of binding: InstalledAdapterBinding,
        in snapshot: AbilityRuntimeSnapshot
    ) -> String? {
        snapshot.adapterManifest(id: binding.adapterID)?
            .resolvedProvider.applicationID?.lowercased()
    }

    /// Normalize spoken/routed tokens to registered application ids: a
    /// signal may carry the logical id, an alias, or a bundle identifier,
    /// exactly like `abilityRoutingContext()`'s profile matching.
    private static func resolveIDs(
        _ token: String?, in profiles: [ApplicationProfile]
    ) -> Set<String> {
        token.map { resolveIDs(Set([$0]), in: profiles) } ?? []
    }

    private static func resolveIDs(
        _ tokens: Set<String>, in profiles: [ApplicationProfile]
    ) -> Set<String> {
        guard !tokens.isEmpty else { return [] }
        let normalized = Set(tokens.map { $0.lowercased() })
        var resolved: Set<String> = []
        for profile in profiles {
            let id = profile.id.lowercased()
            if normalized.contains(id)
                || profile.applicationIdentifiers.contains(where: {
                    normalized.contains($0.lowercased())
                })
                || profile.aliases.contains(where: {
                    normalized.contains($0.lowercased())
                }) {
                resolved.insert(id)
            }
        }
        return resolved
    }
}
