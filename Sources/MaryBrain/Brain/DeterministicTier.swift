//
//  DeterministicTier.swift
//  MaryBrain
//
//  WHAT: The whole deterministic tier — a bare yes or no, and nothing else.
//  IN:   runTurnBody, once, at entry
//  OUT:  Bool? — the confirm dispatch, the bare stop, the referent kills, and
//        AmbientEngine's top two rungs all read it.
//  PIN:  MEMBERSHIP RULE, and it is a HIGH BAR: a phrase belongs here only if
//        it is CONTENTLESS PROTOCOL — it names no domain, so no package corpus
//        could ever own it — AND a false positive would execute or cancel
//        something. "Yes" is not ABOUT anything, which is precisely why no
//        embedding can carry it and why it must be exact.
//        Everything with a subject — corrections name documents, dictation
//        controls name a writing mode — fails the rule and belongs to a
//        corpus. Nothing has ever been added to this file. Do not be first.
//
import Foundation

enum DeterministicTier {

    /// A spoken sentence arrives with punctuation nobody chose. Every literal
    /// comparison left in the app folds through this first.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm",
        "proceed", "do it", "go ahead", "go for it", "please do",
        "yes please", "sounds good", "yes go ahead", "okay do it",
        "yes do it", "yes proceed", "sure go ahead", "okay go ahead",
    ]

    private static let negatives: Set<String> = [
        "no", "nope", "cancel", "stop", "dont", "do not", "no thanks",
        "never mind", "nevermind", "leave it", "cancel it", "no cancel",
        "dont do it", "no stop", "cancel that",
    ]

    /// WHOLE-UTTERANCE AND EXACT. An answer carrying anything more ("yes,
    /// tighten it") has its own verb and belongs to the model.
    static func decision(in text: String) -> Bool? {
        let text = normalized(text)
        // Prioritizes affirms
        if affirmatives.contains(text) { return true }
        if negatives.contains(text) { return false }
        return nil
    }
}
