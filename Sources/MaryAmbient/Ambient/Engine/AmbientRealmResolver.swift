//
//  AmbientRealmResolver.swift
//  MaryAmbient
//
//  WHAT: Who could serve this turn, and which of them did — computed once, read by everyone.
//  IN:   AbilityCapabilityIndex / cue discipline
//  OUT:  AmbientRealm → AmbientPlace
//  PIN:  Need → realm (candidates) → place (decided where).
//

import Foundation
import MaryFoundation

public enum AmbientRealmResolver {

    /// Everything the resolution reads. Injected rather than fetched so the
    /// whole thing stays a pure function of stated inputs — which is what
    /// lets a test state a turn instead of arranging a world.
    public struct Inputs: Sendable {
        public var utterance: String
        /// Ability nomination query. Nil — `utterance`. Names still use `utterance`.
        public var abilityQuery: String?
        /// Places the user NAMED. A name is an address, not a signal: it
        /// stands the cue's guess down and decides the place outright.
        public var namedPlaces: Set<AmbientPlace>
        /// The discipline a cue read the turn as, if any.
        public var discipline: WorkspaceFocus?
        /// Which signal settled the turn's intent — carried through so the
        /// realm can say what decided it rather than inferring.
        public var decidedBy: AmbientSignal?
        public var focus: FocusSignal
        public var evidence: [AmbientPlace: FocusEvidence]
        public var registrations: [ApplicationRegistration]
        public var abilities: (any AbilityCapabilityIndex)?
        public var now: Date

        public init(
            utterance: String,
            abilityQuery: String? = nil,
            namedPlaces: Set<AmbientPlace> = [],
            discipline: WorkspaceFocus? = nil,
            decidedBy: AmbientSignal? = nil,
            focus: FocusSignal = FocusSignal(),
            evidence: [AmbientPlace: FocusEvidence] = [:],
            registrations: [ApplicationRegistration]? = nil,
            abilities: (any AbilityCapabilityIndex)? = nil,
            now: Date = Date()
        ) {
            self.utterance = utterance
            self.abilityQuery = abilityQuery
            self.namedPlaces = namedPlaces
            self.discipline = discipline
            self.decidedBy = decidedBy
            self.focus = focus
            self.evidence = evidence
            self.registrations = registrations
                ?? AmbientApplicationIndexProvider.current.all
            self.abilities = abilities
            self.now = now
        }
    }

    // MARK: - The whole resolution

    public static func resolve(_ inputs: Inputs) -> AmbientRealm {
        let need = need(inputs)
        let candidates = candidates(for: need, inputs)
        let place = place(among: candidates, need: need, inputs)
        return AmbientRealm(
            need: need,
            candidates: candidates,
            place: place,
            decidedBy: place == nil ? nil : inputs.decidedBy)
    }

    // MARK: - 1. The need

    /// What the query asked for. AN EMPTY NEED IS A REAL ANSWER, not a failed classification.
    public static func need(_ inputs: Inputs) -> AmbientNeed {
        let index = inputs.abilities ?? AmbientCapabilityIndexProvider.current
        return AmbientNeed(
            abilities: index.requestedAbilities(
                in: inputs.abilityQuery ?? inputs.utterance),
            discipline: inputs.discipline)
    }

    // MARK: - 2. The realm

    /// Every application that conforms, with the evidence for and against it. SORTED BY PLACE
    /// TOKEN, not by score. The candidates are a RECORD, and a record whose order depends on a
    /// hash seed is a record that differs between two runs of the same turn.
    public static func candidates(
        for need: AmbientNeed, _ inputs: Inputs
    ) -> [AmbientCandidate] {
        inputs.registrations.compactMap { registration -> AmbientCandidate? in
            let place = registration.place
            let conformsByAbilities = need.abilities
                .intersection(registration.profile.abilities)
            let conformsByDiscipline = need.discipline != nil
                && place.focus == need.discipline

            // AN EMPTY NEED ADMITS EVERYONE WITH EYES. Nothing was asked for, so nothing can fail to
            // conform — and the alternative, an empty realm, would say "no application could have
            // served this", which for "what's on my screen" is simply false.
            let conforms = need.isEmpty
                ? registration.hasEyes
                : (!conformsByAbilities.isEmpty || conformsByDiscipline)
            guard conforms else { return nil }

            let evidence = inputs.evidence[place]
            return AmbientCandidate(
                place: place,
                conformsByAbilities: conformsByAbilities,
                conformsByDiscipline: conformsByDiscipline,
                // THE FIELD NOTHING HAS EVER READ. A package declares which routing classes it accepts
                // and, until this line, no code anywhere consulted the declaration — so an author could
                // describe exactly what their application handles and never be matched on a word of it.
                targetClasses: registration.profile.targetClasses,
                hasEyes: registration.hasEyes,
                evidence: evidence?.kind,
                evidenceAgeSeconds: evidence.map {
                    inputs.now.timeIntervalSince($0.at)
                })
        }
        .sorted { $0.place.token < $1.place.token }
    }

    // MARK: - 3. The place

    /// Which candidate the turn is about.
    /// STEPS: named place (address, not evidence) → conforming focus lead
    ///        → strongest conforming co-active → nothing.
    /// PIN: Name outranks focus and conformance. Don't pick a conforming app
    ///      the user hasn't touched today.
    public static func place(
        among candidates: [AmbientCandidate], need: AmbientNeed, _ inputs: Inputs
    ) -> AmbientPlace? {
        let conforming: Set<AmbientPlace> = {
            // An empty need admitted everyone with eyes. `AmbientCandidate.conforms`
            // is ability/discipline axes only, so "what's that?" would otherwise
            // find candidates and then refuse every lead.
            if need.isEmpty {
                return Set(candidates.map(\.place))
            }
            return Set(candidates.filter(\.conforms).map(\.place))
        }()

        if !inputs.namedPlaces.isEmpty {
            // Sorted so several named places resolve the same way twice.
            let named = inputs.namedPlaces.sorted { $0.token < $1.token }
            return named.first(where: conforming.contains) ?? named.first
        }
        if let lead = inputs.focus.lead, conforming.contains(lead) {
            return lead
        }
        return inputs.focus.coActive.first(where: conforming.contains)
    }
}
