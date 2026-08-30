//
//  FocusOverride.swift
//  MaryAmbient
//
//  WHAT: What the words themselves say about which world is meant, before any window.
//  OUT:  WorkspaceFocus (per-turn override). Window truth stays on WorkspaceFocusTracker.
//  PIN:  Conservative. Ambiguous words never trigger. Cues from both sides cancel to nil.
//        Whole words, not prefixes (`build` must not match `building`).
//
import Foundation

public enum FocusOverride {

    /// Classifies an utterance's evident domain from unambiguous cue words, used as a per-turn
    /// focus override so naming a domain always routes there even when window focus is on the
    /// other app. Deliberately conservative: only distinctive words count. Ambiguous terms.
    public static func classifyOverride(utterance: String) -> WorkspaceFocus? {
        let text = utterance.lowercased()
        // WHOLE WORDS, NOT PREFIXES.
        func mentions(_ words: [String]) -> Bool {
            words.contains { word in
                let core = word.trimmingCharacters(in: .whitespaces)
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: core) + "s?\\b"
                return text.range(of: pattern, options: .regularExpression) != nil
            }
        }
        let coding = mentions([
            "code", "coding", "function", "func", "method", "class", "classes",
            "struct",
            "compile", "compiles", "compiling", "compiler", "build", "builds",
            "rebuild", "refactor", "refactoring", "swift", "variable",
            "bug", "debug", "debugging", "debugger", "unit test",
            "breakpoint", "linker", "import", "protocol", "enum",
            // The prose-shaped half of the coding vocabulary. These are what a developer is
            // proofreading or documenting when they use a writing verb, and without them "proofread my
            // README" hands the turn to Pages.
            "readme", "comment", "docstring", "parser", "api",
        ])
        // "paragraph" is bare now : "proofread this paragraph" while Xcode happened to be
        // frontmost classified as CODING, which routed the live document out of the prompt
        // entirely. "document" is a VERB at least as often as a noun here.
        let documentNoun = utterance.range(
            of: "\\b(the|this|that|these|those|my|your|our|his|her|their|an?)\\s+documents?\\b",
            options: [.regularExpression, .caseInsensitive]) != nil
        let writing = documentNoun || mentions([
            "manuscript", "chapter", "scene", "novel", "prose", "draft",
            "drafting", "binder", "synopsis", "storyline",
            "narrative", "paragraph", "the story", "my book", "the book",
            "character", "proofread", "proofreading", "proof-read",
        ])
        switch (coding, writing) {
        case (true, false): return .coding
        case (false, true): return .writing
        default:            return nil   // neither or both — defer to focus
        }
    }
}
