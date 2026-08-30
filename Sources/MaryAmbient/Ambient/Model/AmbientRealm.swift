//
//  AmbientRealm.swift
//  MaryAmbient
//
//  WHAT: What could serve this turn — applications conforming to the need, held while where is decided.
//  IN:   AmbientRealmResolver
//  OUT:  AmbientPlace (the where, singular)
//  PIN:  World = Mary's standing lanes. Realm = candidates outside her. Place = decided where.
//

import Foundation
import MaryFoundation

/// WHAT THE QUERY REQUIRES — the need a realm is assembled against. Two axes because Mary
/// learns needs two ways and they are not the same kind of claim. `abilities` comes from
/// the capability graph: the words asked for something a package declares it can do.
public struct AmbientNeed: Sendable, Equatable {

    /// Abilities the utterance asked for, from the capability index.
    public var abilities: Set<AbilityID>

    /// The discipline the turn reads as, when a cue named one.
    public var discipline: WorkspaceFocus?

    public init(abilities: Set<AbilityID> = [], discipline: WorkspaceFocus? = nil) {
        self.abilities = abilities
        self.discipline = discipline
    }

    /// Nothing was asked for that names a capability or a craft. The realm assembled against
    /// this is every eligible application or none — the decision falls entirely to focus, which
    /// is correct: "what's that?" means the thing in front of the user.
    public var isEmpty: Bool { abilities.isEmpty && discipline == nil }
}

/// ONE APPLICATION THAT COULD SERVE, and the evidence for and against it. A candidate is
/// not a ranking — it is a record of conformance and standing. Scoring belongs to whoever
/// resolves; this carries what the scoring saw so the same facts reach the dataset.
public struct AmbientCandidate: Sendable, Equatable {

    /// Where this candidate is. One application, or one of Mary's lanes when
    /// a faculty is the thing that conforms.
    public var place: AmbientPlace

    /// The needed abilities this application declares — the INTERSECTION, not everything it can
    /// do.
    public var conformsByAbilities: Set<AbilityID>

    /// Whether it realizes the needed discipline.
    public var conformsByDiscipline: Bool

    /// The routing classes it declares.
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

    /// THE WHERE — nil while undecided, and nil is a real state rather than a missing value. A
    /// turn can name a need, find three applications that conform, and still have nothing to
    /// point at: nobody is in any of them and the user named none.
    public var place: AmbientPlace?

    /// WHICH SIGNAL CHOSE. The vocabulary already exists (`AmbientSignal`, a dozen cases from
    /// `namedLeadWorld` through `deixis` to `ambientSource`) and has never had a consumer; this
    /// is it.
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

    /// The candidate the realm settled on, when it settled on one that is actually in the set.
    public var chosen: AmbientCandidate? {
        guard let place else { return nil }
        return candidates.first { $0.place == place }
    }

    /// The candidates that conformed, which is usually all of them and deliberately not
    /// guaranteed: a resolver may carry a non-conforming place it was forced to consider (a
    /// named one) so the dataset can see that it was considered and why it lost.
    public var conforming: [AmbientCandidate] { candidates.filter(\.conforms) }

    /// Nothing could serve. Distinct from an empty need — this is "she
    /// understood what was wanted and knows nowhere that does it", which is a
    /// refusal with a reason rather than a shrug.
    public var isEmpty: Bool { candidates.isEmpty }
}
