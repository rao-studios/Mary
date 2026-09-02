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
}
