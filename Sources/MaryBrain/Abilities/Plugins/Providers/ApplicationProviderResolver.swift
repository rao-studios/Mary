//
//  ApplicationProviderResolver.swift
//  MaryBrain
//
//  WHAT: Which application answers a provider-neutral Skill this turn.
//  IN:   route signals (named ∪ interaction ∪ pin ∪ focus)
//  OUT:  memoized provider per Skill
//  PIN:  Words beat pointing beat posture beat static preference.
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
    /// The place the person planted a flag in — `WorkspaceFocusTracker.pin`.
    /// Above the frontmost window on purpose: a pin is a correction, and a
    /// correction that loses to whatever came forward is not one.
    var pinnedApplicationID: String?
    /// The application whose window is frontmost, when it maps to a profile.
    var focusedApplicationID: String?
    /// WHAT THIS PERSON REACHES FOR, asked per Ability — the rung that fills
    /// the silence when the words named nothing and no window answers. It is a
    /// closure rather than a value because the answer depends on which Skill
    /// is being resolved, and only the habitual pick is offered: a ranking
    /// with no history behind it is a default, and defaults already have a
    /// rung (`staticPreference`) below this one.
    var habitualApplicationID: @Sendable (AbilityID) -> String? = { _ in nil }

    static func == (
        lhs: ApplicationProviderSignals, rhs: ApplicationProviderSignals
    ) -> Bool {
        lhs.namedApplicationIDs == rhs.namedApplicationIDs
            && lhs.interactionApplicationID == rhs.interactionApplicationID
            && lhs.pinnedApplicationID == rhs.pinnedApplicationID
            && lhs.focusedApplicationID == rhs.focusedApplicationID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(namedApplicationIDs)
        hasher.combine(interactionApplicationID)
        hasher.combine(pinnedApplicationID)
        hasher.combine(focusedApplicationID)
    }
}

/// The turn's frozen provider choices, keyed by Skill.
struct ProviderTurnSelection: Sendable {
    enum Rationale: String, Sendable {
        case named, interaction, pinned, focused, habit, staticPreference
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
    /// Every application id this turn's signals asserted (named ∪ interaction ∪ pinned ∪ focused), resolved against registered profiles.
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
    static func resolve(
        snapshot: AbilityRuntime.Snapshot,
        signals: ApplicationProviderSignals,
        /// EVERY registered application — native profiles included.
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

            // THE MISMATCH TEST follows provider-choice precedence.
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
            // The turn's own rungs first, then the habit — posture beats a
            // remembered preference, and a remembered preference beats the
            // packages' declared order.
            let habitRung: [(Set<String>, ProviderTurnSelection.Rationale)] =
                signals.habitualApplicationID(runtime.ability.id).map {
                    [(resolveIDs($0, in: known), .habit)]
                } ?? []
            for (wanted, rationale) in rungs + habitRung where !wanted.isEmpty {
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
        in snapshot: AbilityRuntime.Snapshot
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
