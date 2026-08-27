//
//  AmbientRealmResolver.swift
//  MaryAmbient
//
//  WHO COULD SERVE THIS TURN, AND WHICH OF THEM DID — computed once, read by
//  everyone.
//
//  The three steps are the user's own framing of a turn:
//
//    1. THE NEED. The query asked for something. `abilities` comes from the
//       capability index — the words named a capability some package
//       declares. `discipline` comes from a cue — the turn smells like
//       writing without naming a verb. Either, both, or neither.
//    2. THE REALM. Every application that conforms to that need, each
//       carrying what it conformed BY and what standing it has. An
//       application answering two needs appears ONCE with both, because it is
//       one application and splitting it would let a place compete with
//       itself.
//    3. THE PLACE. The query and the focus signal decide which candidate the
//       turn is actually about, and `decidedBy` names the signal that decided.
//
//  THE SET SURVIVES THE DECISION, and that is the reason this exists rather
//  than a function returning a place. An episode recording "she typed into
//  the editor" teaches a future model an association. The same episode
//  recording "three applications conformed; this one led by activation four
//  seconds ago; the others were cold" teaches the JUDGEMENT. The version this
//  replaces computed the equivalent set inline, for one expression, collapsed
//  it to a boolean in the same statement, and discarded it — which is exactly
//  why its dataset could never answer "why there".
//
//  ONE SPELLING OF "WHO CONFORMS". `AmbientRanker.namedPlacesForRanking` used
//  to scan the roster for registrations matching a discipline cue: a realm,
//  computed inline, over a two-value need. It now reads this. Three consumers
//  — the ranking, the roster arbiter, the behavioral capture — see the same
//  answer because there is only one.
//
//  IT DECIDES NOTHING THE RANKER ALREADY DECIDED. Absent a name, `place` is
//  the focus signal's own lead, filtered by conformance; the resolver's job
//  is to RECORD the reasoning, not to re-run it with a second opinion. A
//  second opinion here would be a second place-picker, and the whole file
//  above is about not having two of anything.
//

import Foundation
import MaryFoundation

public enum AmbientRealmResolver {

    /// Everything the resolution reads. Injected rather than fetched so the
    /// whole thing stays a pure function of stated inputs — which is what
    /// lets a test state a turn instead of arranging a world.
    public struct Inputs: Sendable {
        public var utterance: String
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

    /// What the query asked for.
    ///
    /// AN EMPTY NEED IS A REAL ANSWER, not a failed classification. "What's
    /// that?" names no capability and no craft, and the honest realm for it
    /// is every eligible place with the decision falling entirely to focus —
    /// which is correct, because the thing in front of the user IS what
    /// "that" means.
    public static func need(_ inputs: Inputs) -> AmbientNeed {
        let index = inputs.abilities ?? AmbientCapabilityIndexProvider.current
        return AmbientNeed(
            abilities: index.requestedAbilities(in: inputs.utterance),
            discipline: inputs.discipline)
    }

    // MARK: - 2. The realm

    /// Every application that conforms, with the evidence for and against it.
    ///
    /// SORTED BY PLACE TOKEN, not by score. The candidates are a RECORD, and a
    /// record whose order depends on a hash seed is a record that differs
    /// between two runs of the same turn — which makes a dataset row
    /// impossible to diff against itself.
    public static func candidates(
        for need: AmbientNeed, _ inputs: Inputs
    ) -> [AmbientCandidate] {
        inputs.registrations.compactMap { registration -> AmbientCandidate? in
            let place = registration.place
            let conformsByAbilities = need.abilities
                .intersection(registration.profile.abilities)
            let conformsByDiscipline = need.discipline != nil
                && place.focus == need.discipline

            // AN EMPTY NEED ADMITS EVERYONE WITH EYES. Nothing was asked for,
            // so nothing can fail to conform — and the alternative, an empty
            // realm, would say "no application could have served this", which
            // for "what's on my screen" is simply false.
            let conforms = need.isEmpty
                ? registration.hasEyes
                : (!conformsByAbilities.isEmpty || conformsByDiscipline)
            guard conforms else { return nil }

            let evidence = inputs.evidence[place]
            return AmbientCandidate(
                place: place,
                conformsByAbilities: conformsByAbilities,
                conformsByDiscipline: conformsByDiscipline,
                // THE FIELD NOTHING HAS EVER READ. A package declares which
                // routing classes it accepts and, until this line, no code
                // anywhere consulted the declaration — so an author could
                // describe exactly what their application handles and never
                // be matched on a word of it.
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
    ///
    /// THE LADDER, in the order the rest of routing already uses:
    ///
    ///   1. A NAMED PLACE — conforming or not.
    ///
    ///      A NAME IS AN ADDRESS, NOT EVIDENCE, so it outranks every signal,
    ///      including a place the user is demonstrably looking at: "do it in
    ///      the other one" has to work. And it outranks CONFORMANCE too,
    ///      which is the part worth stating out loud — answering somewhere
    ///      else because the named application lacked a declared ability is
    ///      the most confusing thing Mary can do, and the realm records the
    ///      non-conformance, which is the useful half of knowing it.
    ///
    ///      Conformance only ORDERS several named places against each other.
    ///
    ///   2. THE FOCUS LEAD, if it conforms. The ranker's own answer, READ
    ///      rather than recomputed: `realm.place == capture.lead` is a pinned
    ///      invariant, and the way to keep an invariant true is to not have a
    ///      second opinion about it.
    ///   3. A CO-ACTIVE PLACE THAT CONFORMS, strongest evidence first — the
    ///      lead did not conform, so the turn is about something warm beside
    ///      it. `coActive` arrives already ranked.
    ///   4. NOTHING. A conforming application with no standing at all is a
    ///      real candidate and usually the wrong one; picking it because it
    ///      is the only one left is how a turn lands in an application the
    ///      user has not touched today.
    public static func place(
        among candidates: [AmbientCandidate], need: AmbientNeed, _ inputs: Inputs
    ) -> AmbientPlace? {
        let conforming = Set(candidates.filter(\.conforms).map(\.place))

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
