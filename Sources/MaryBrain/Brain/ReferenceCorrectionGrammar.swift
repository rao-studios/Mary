//
//  ReferenceCorrectionGrammar.swift
//  MaryBrain
//
//  WHAT: "No, the other one" — the phrases that re-aim a resolved reference.
//  IN:   runTurnBody
//  OUT:  ReferenceFocus.applyCorrection
//  PIN:  CONDEMNED. Every phrase here names a document or a note, so this is a
//        LANE vocabulary, not protocol — it fails `DeterministicTier`'s
//        membership rule and only sits in code because no corpus owns it yet.
//        It becomes a seed family on the reference/writing packages; this file
//        deletes when it does. Do not extend it — a paraphrase this set
//        refuses is the argument for finishing the migration, not for a
//        sixteenth literal.
//
import Foundation

enum ReferenceCorrectionGrammar {

    private static let corrections: Set<String> = [
        "no the other one", "the other one", "not that one", "not that note",
        "wrong one", "wrong note", "the wrong one", "the wrong note",
        "i meant the other one", "i meant the other note", "the other note",
        "no not that one", "no wrong one", "not that document",
        "the other document", "no the other note",
    ]

    /// WHOLE-UTTERANCE AND EXACT, exactly as `DeterministicTier.decision` is.
    static func isCorrection(_ text: String) -> Bool {
        corrections.contains(DeterministicTier.normalized(text))
    }
}
