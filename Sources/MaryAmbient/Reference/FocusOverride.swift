//
//  FocusOverride.swift
//
//  WHAT THE WORDS THEMSELVES SAY ABOUT WHICH WORLD IS MEANT, before any
//  window is consulted.
//
//  "Proofread this paragraph" is a writing turn even with Xcode frontmost;
//  "document the parser" is a coding turn even with Pages frontmost. This is
//  the utterance-only half of focus arbitration, and it is pure text — no
//  process, no adapter, no window. It belongs to the ambient layer for that
//  reason; the half that renders an adapter's live context into a prompt
//  line stays in MaryBrain with the adapters it names.
//

import Foundation

public enum FocusOverride {

    /// Classifies an utterance's evident domain from unambiguous cue words,
    /// used as a per-turn focus override so naming a domain always routes
    /// there ("add a scene…" → writing, "fix the build…" → coding) even when
    /// window focus is on the other app.
    ///
    /// Deliberately conservative: only distinctive words count. Ambiguous
    /// terms that are the whole reason focus exists — "file", "write", "note",
    /// "save", "open" — never trigger. Cues from both sides cancel to nil (let
    /// focus decide). Returns nil when nothing distinctive appears.
    ///
    /// The writing side gained the vocabulary a PROOFREADING request actually
    /// uses ("proofread", "document", bare "paragraph"). Without it, "proofread
    /// this paragraph" asked while Xcode was frontmost routed to `.coding` —
    /// which collapses the live document to an ambient line, and the voice
    /// then answers about it from retrieval.
    ///
    /// That addition immediately over-reached, and this is the correction:
    /// "document the parser" and "proofread my README" flipped CODING turns
    /// into the writing world. The coding table therefore also carries the
    /// words that live next to prose verbs in a developer's mouth — a
    /// README, a comment, a docstring, a parser, an API — so a request naming
    /// both sides cancels to nil (focus decides) instead of asserting the
    /// wrong world. An over-eager CODING cue is the cheap direction to err:
    /// `lead` only promotes coding when Xcode actually contributed this turn,
    /// so a coding override with no Xcode in sight falls through to writing
    /// anyway. A wrong WRITING override has no such brake.
    public static func classifyOverride(utterance: String) -> WorkspaceFocus? {
        let text = utterance.lowercased()
        // WHOLE WORDS, NOT PREFIXES. The old matcher (`text.contains(" \(w)")`)
        // matched a cue as a PREFIX at any word start — and "build" is a cue,
        // so "What BUILDing is this", asked about a YouTube video, classified
        // the turn `.coding`, masked the tracker's correct browser lead,
        // minted "led: Xcode" with Xcode not even running, and blocked
        // TextEdit behind "this turn is about xcode" — the whole incident from
        // one gerund. `\b…\b` bounds both edges; the optional `s?` keeps the
        // free plural coverage prefixing gave (bugs, chapters, functions)
        // without admitting "building" (`build` + `s?` ≠ "building").
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
            "rebuild", "xcode", "refactor", "refactoring", "swift", "variable",
            "bug", "debug", "debugging", "debugger", "unit test",
            "breakpoint", "linker", "import", "protocol", "enum",
            // The prose-shaped half of the coding vocabulary. These are what
            // a developer is proofreading or documenting when they use a
            // writing verb, and without them "proofread my README" hands the
            // turn to Pages.
            "readme", "comment", "docstring", "parser", "api",
        ])
        // "paragraph" is bare now (it was "paragraph about"): "proofread this
        // paragraph" while Xcode happened to be frontmost classified as
        // CODING, which routed the live document out of the prompt entirely.
        // Nothing in the coding vocabulary competes for the word — a
        // paragraph is prose in every register Mary speaks.
        //
        // "document" is a VERB at least as often as a noun here, and the verb
        // is a CODING word: "document the parser", "document this function".
        // Matching the bare word steered those turns into the writing world,
        // where the live Xcode file collapses to one ambient line. A
        // determiner in front is what separates the noun ("the document", "my
        // documents") from the imperative — and the \b…\b tail still keeps
        // "documentation"/"documenting" out, which is why it was written this
        // way in the first place.
        let documentNoun = utterance.range(
            of: "\\b(the|this|that|these|those|my|your|our|his|her|their|an?)\\s+documents?\\b",
            options: [.regularExpression, .caseInsensitive]) != nil
        let writing = documentNoun || mentions([
            "manuscript", "chapter", "scene", "novel", "prose", "draft",
            "drafting", "scrivener", "binder", "synopsis", "storyline",
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
