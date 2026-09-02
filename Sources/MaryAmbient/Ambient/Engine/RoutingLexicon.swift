//
//  RoutingLexicon.swift
//  MaryAmbient
//
//  WHAT: CLOSED-CLASS GRAMMAR the surviving structural classifiers share —
//        function words, not content words.
//  IN:   EditIntentClassifier and its siblings
//  OUT:  one spelling of each family, instead of four drifting copies
//  PIN:  THE LINE THIS FILE DRAWS: grammar lives in code, vocabulary lives in
//        packages. "What" and "why" are how English forms a question and no
//        Ability will ever author them; "play", "tighten", "refactor" name a
//        domain and belong to a corpus. Nothing that names a domain may be
//        added here — it goes in a `.mary` package's triggers instead.
//
import Foundation

public enum RoutingLexicon {

    /// Openers that mean the user wants an ANSWER — always spoken rhythm.
    /// Used as a VETO: a clause that opens this way is a question, whatever
    /// verb follows it.
    public static let questionOpeners: Set<String> = [
        "what", "what's", "why", "how", "when", "who", "where", "which",
        "is", "are", "am", "do", "does", "did", "can", "could", "would",
        "should", "tell", "read", "show", "list", "search", "find",
        "check", "describe", "explain", "summarize", "give",
    ]

    /// HOW THE USER ADDRESSES HER. One idea, and it was spelled twice — once
    /// for peeling a preamble off an edit request, once for deciding whether a
    /// dictated line was meant for Mary or for the page.
    public static let addressWords: Set<String> = ["hey", "mary", "ok", "okay"]

    // MARK: - What deliberately did NOT move here
    //
    // MEASURED, NOT ASSUMED. Several families look like duplicates and are
    // not; merging them would hand each one words that break its job.
    //
    // `AmbientRanker.stopWords` (56) vs `ReferenceResolver.stopWords` (23):
    // the first is ordinary English filler, the second additionally drops
    // "document", "window", "rewrite" — words that must not DISTINGUISH one
    // container from another, but which the ranker still needs to read.
    //
    // `PassageWidening.partNouns` vs `NamedPartClassifier.partNouns`: same
    // size, different halves — "func", "declaration", "lines" against
    // "appendix", "footnote", "excerpt". One widens a span in code, the other
    // names a part of prose.
    //
    // `EditIntentClassifier.replaceVerbs` vs the three-way rule's
    // `continuationVerbs`: overlapping members, different questions. The first
    // asks "does this verb presuppose an existing passage", the second "does
    // this clause continue the last one". A single list could answer neither.
    //
    // The transform verbs that DID belong to one idea are already gone: they
    // are a package-authored seed family now — see `SemanticSeedFamilyIndex`.
}
