//
//  AmbientRealm.swift
//  MaryAmbient
//
//  WHAT COULD SERVE THIS TURN — the applications conforming to what the query
//  needs, held together while the where is being decided.
//
//  THE THREE WORDS, and this file is the middle one:
//
//    WORLD  (`AmbientWorld`)  — what Mary IS: her standing lanes and the
//                               faculties she can invoke. Internal.
//    REALM  (this file)       — what is OUTSIDE her that could serve: the set
//                               of applications conforming to the need, and
//                               the place that won. External.
//    PLACE  (`AmbientPlace`)  — the WHERE, singular and decided. A realm
//                               HOSTS one.
//
//  THE SHAPE OF A TURN, in the user's own framing: a query implies a NEED —
//  typing, writing, both. The realm is every application that understands
//  that need, and an application that conforms to typing AND writing is seen
//  in both, once, carrying both conformances. Then the query and the focus
//  signal decide WHICH of them the turn is actually about, and that answer is
//  the realm's `place`.
//
//  WHY THE SET SURVIVES THE DECISION rather than collapsing into the winner.
//  A behavioural episode that records only "she typed into TextEdit" teaches
//  a future model the association and nothing about the judgement. The same
//  episode recording "three applications could have taken this; TextEdit led
//  by activation four seconds ago; the other two conformed but were cold"
//  teaches the CHOICE. Bonnie kept the equivalent of this set for exactly one
//  expression — an inline scan collapsed to a boolean, discarded in the same
//  statement — which is why its dataset could never answer "why there".
//
//  PURE DATA, DELIBERATELY, AND NOTHING CONSTRUCTS ONE YET. The resolver that
//  COMPUTES a realm belongs with roster arbitration: it needs the capability
//  index installed (the words → `Set<AbilityID>` map that exists and is not
//  yet wired), the live roster, and the focus signal — machinery that arrives
//  with the brain. Until then the type is the vocabulary and the codec field,
//  and an episode honestly carries no realm rather than a guessed one.
//
//  THE DUPLICATE IT WILL RETIRE, named now so it is not forgotten:
//  `AmbientRanker.namedPlacesForRanking` scans the roster for registrations
//  matching a discipline cue. That is a realm computed inline, over a
//  two-value need, thrown away immediately. When the resolver lands, that
//  scan becomes a read of this — one spelling of "who conforms", read by the
//  ranking, the arbiter and the capture alike.
//

import Foundation
import MaryFoundation

/// WHAT THE QUERY REQUIRES — the need a realm is assembled against.
///
/// Two axes because Mary learns needs two ways and they are not the same
/// kind of claim. `abilities` comes from the capability graph: the words
/// asked for something a package declares it can do. `discipline` comes from
/// a cue: the turn smells like writing without naming a verb. A need may
/// carry either, both, or neither — and "neither" is a real turn (small talk,
/// a general question), not a failure to classify.
public struct AmbientNeed: Sendable, Equatable {

    /// Abilities the utterance asked for, from the capability index.
    public var abilities: Set<AbilityID>

    /// The discipline the turn reads as, when a cue named one.
    public var discipline: WorkspaceFocus?

    public init(abilities: Set<AbilityID> = [], discipline: WorkspaceFocus? = nil) {
        self.abilities = abilities
        self.discipline = discipline
    }

    /// Nothing was asked for that names a capability or a craft. The realm
    /// assembled against this is every eligible application or none — the
    /// decision falls entirely to focus, which is correct: "what's that?"
    /// means the thing in front of the user.
    public var isEmpty: Bool { abilities.isEmpty && discipline == nil }
}

/// ONE APPLICATION THAT COULD SERVE, and the evidence for and against it.
///
/// A candidate is not a ranking — it is a record of conformance and standing.
/// Scoring belongs to whoever resolves; this carries what the scoring saw so
/// the same facts reach the dataset.
public struct AmbientCandidate: Sendable, Equatable {

    /// Where this candidate is. One application, or one of Mary's lanes when
    /// a faculty is the thing that conforms.
    public var place: AmbientPlace

    /// The needed abilities this application declares — the INTERSECTION, not
    /// everything it can do. An application conforming to typing and writing
    /// appears ONCE with both, rather than twice with one each: it is one
    /// candidate, and splitting it would let the same place compete with
    /// itself.
    public var conformsByAbilities: Set<AbilityID>

    /// Whether it realizes the needed discipline.
    public var conformsByDiscipline: Bool

    /// The routing classes it declares. Read here for the first time in
    /// either codebase — `ApplicationProfile.targetClasses` has been
    /// populated and consumed by nothing since Bonnie, which is precisely how
    /// a package could declare what it accepts and never be matched on it.
    public var targetClasses: Set<String>

    /// Whether anything is actually looking at it. Not a conformance — a
    /// place can be perfectly able to serve and be unobserved — but it is
    /// what separates "could act there" from "could act there knowingly".
    public var hasEyes: Bool

    /// The strongest live signal for this place, and its age. Nil when the
    /// user has done nothing here recently: a conforming application with no
    /// evidence is a real candidate and usually the wrong one.
    public var evidence: FocusEvidenceKind?
    public var evidenceAgeSeconds: Double?

    public init(
        place: AmbientPlace,
        conformsByAbilities: Set<AbilityID> = [],
        conformsByDiscipline: Bool = false,
        targetClasses: Set<String> = [],
        hasEyes: Bool = false,
        evidence: FocusEvidenceKind? = nil,
        evidenceAgeSeconds: Double? = nil
    ) {
        self.place = place
        self.conformsByAbilities = conformsByAbilities
        self.conformsByDiscipline = conformsByDiscipline
        self.targetClasses = targetClasses
        self.hasEyes = hasEyes
        self.evidence = evidence
        self.evidenceAgeSeconds = evidenceAgeSeconds
    }

    /// Whether this candidate conforms at all, by either axis.
    public var conforms: Bool {
        !conformsByAbilities.isEmpty || conformsByDiscipline
    }
}

/// THE CONFORMING SET, AND THE PLACE IT SETTLED ON.
public struct AmbientRealm: Sendable, Equatable {

    /// What the turn asked for.
    public var need: AmbientNeed

    /// Every application that could serve it, in the resolver's order.
    public var candidates: [AmbientCandidate]

    /// THE WHERE — nil while undecided, and nil is a real state rather than a
    /// missing value. A turn can name a need, find three applications that
    /// conform, and still have nothing to point at: nobody is in any of them
    /// and the user named none. Forcing a place there would invent a target,
    /// which is how an edit lands in the wrong document.
    public var place: AmbientPlace?

    /// WHICH SIGNAL CHOSE. The vocabulary already exists (`AmbientSignal`, a
    /// dozen cases from `namedLeadWorld` through `deixis` to `ambientSource`)
    /// and has never had a consumer; this is it. "TextEdit, because it was
    /// named" and "TextEdit, because it was frontmost" are different turns to
    /// learn from even when the place is identical.
    public var decidedBy: AmbientSignal?

    public init(
        need: AmbientNeed,
        candidates: [AmbientCandidate] = [],
        place: AmbientPlace? = nil,
        decidedBy: AmbientSignal? = nil
    ) {
        self.need = need
        self.candidates = candidates
        self.place = place
        self.decidedBy = decidedBy
    }

    /// The candidate the realm settled on, when it settled on one that is
    /// actually in the set. A resolved place that is NOT among the candidates
    /// is possible and is not a bug — the user can name somewhere that
    /// conforms to nothing — so this answers nil there rather than pretending.
    public var chosen: AmbientCandidate? {
        guard let place else { return nil }
        return candidates.first { $0.place == place }
    }

    /// The candidates that conformed, which is usually all of them and
    /// deliberately not guaranteed: a resolver may carry a non-conforming
    /// place it was forced to consider (a named one) so the dataset can see
    /// that it was considered and why it lost.
    public var conforming: [AmbientCandidate] { candidates.filter(\.conforms) }

    /// Nothing could serve. Distinct from an empty need — this is "she
    /// understood what was wanted and knows nowhere that does it", which is a
    /// refusal with a reason rather than a shrug.
    public var isEmpty: Bool { candidates.isEmpty }
}
