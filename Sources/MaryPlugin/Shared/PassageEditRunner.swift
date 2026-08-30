//
//  PassageEditRunner.swift
//  MaryBrain
//
//  THE GUARD CHAIN, WRITTEN ONCE. Everything a revision has to be sure of
//  before a document changes, for every world, in one function that each
//  world's writer hangs off the end of.
//
//  IT IS `XcodePlugin.editRecipe`'S CHAIN, GENERALIZED — and `editRecipe` is
//  deliberately NOT refactored to call this. That path is the flagship coding
//  edit, pinned in the tweak allowlist, documented, and proven against a live
//  IDE; rewriting proven machinery to prove a point is how it breaks. What is
//  shared instead is the dangerous arithmetic: `PassageEdit` computes,
//  `PassageResolver` re-anchors, `PassageWidening` locates, and
//  `CodeSurfaceWriter` reads and hashes the file directly through Foundation
//  — no `XcodePlugin` survives the port, only the shape of what it proved.
//
//  THE NINE STEPS, and every one of them is a failure someone already paid for:
//
//    1 RESOLVE      a handle to a `Passage`, or mint one by locating the words
//                   the user used. The ladder decides ALONE — "read wider,
//                   then decide" — and records which rung fired.
//    2 SNAPSHOT     the live body, through the world's own reader.
//    3 CLEAN-CHECK  world-specific, and it lives INSIDE the writer, because
//                   what "clean" means is a fact about the app: Xcode refuses
//                   a dirty buffer (its scripting has no save verb), Pages
//                   proves the front document is still the one we measured.
//                   A generic clean-check here would be a fourth opinion about
//                   three different questions.
//    4 IDENTITY     `PassageResolver` re-locates by TEXT. The stored range is
//                   a hint; a body that drifted gets searched, not adjusted.
//                   It refuses rather than resolving to moved text.
//    5 COMPUTE      `PassageEdit`, pure, producing the anchor/replacement pair
//                   a ranged writer sends — words to find, never an offset.
//    6 RE-CHECK     the body hash, immediately before writing. Steps 1–5 take
//                   hundreds of milliseconds and the user is typing in the
//                   document the whole time. "You typed while I was working —
//                   try that again" is `editRecipe`'s own sentence for it.
//    7 APPLY        the world's writer, or an honest refusal naming the verb
//                   that does work there (`writer: nil` is Scrivener's answer,
//                   on evidence).
//    8 VERIFY       READ THE DOCUMENT BACK. "I wrote it" and "it says what I
//                   meant" are different claims, and she is deciding
//                   unattended, so only the second one is worth reporting.
//                   A write that cannot be confirmed CHANGES THE SENTENCE —
//                   it is never silently passed off as a success.
//    9 RE-MINT      the new text gets a handle and the old one forwards to it,
//                   so "make it shorter still" two turns later still lands on
//                   the right words instead of "I don't know what [S1] is".
//
//  HEADLESS-SAFE: Foundation only. Every app-facing call goes through
//  `PassageBacking`'s closures, which is what lets the whole chain be driven by
//  a test with no Pages, no Xcode and no Accessibility grant.
//

import Foundation

public enum PassageEditRunner {

    /// THE PASSAGE PATH'S PRIOR-CONTENT LEDGER, and `revert_last_edit` is the
    /// client `ContentUndoStore`'s own header has always named ("Content-app
    /// plugins WITHOUT version control underneath build their own revert
    /// revert Skills on this store").
    ///
    /// KEYED BY `documentKey` — Pages' `documentIdentity`, Xcode's file path,
    /// Scrivener's `projectPath#uuid` — because that is the identity the whole
    /// contract already uses for "which document", and a ledger keyed on
    /// anything else would be a second answer to that question.
    ///
    /// `CodeSurfaceWriter` uses THIS store too, through the very same `edit`
    /// entry point every other writer goes through — no separate ledger, no
    /// separate write path. A code surface's `documentKey` is the file's own
    /// resolved location (`CodeSurfaceWriter.fileURL(fromDocumentKey:)`), so
    /// it agrees with every other write recorded here by construction rather
    /// than by coincidence.
    public static let undoStore = ContentUndoStore()

    // MARK: - What one lookup produced

    /// A passage, the body it was found in, and where in that body it now sits.
    public struct Located: Sendable {
        public var passage: Passage
        public var snapshot: BodySnapshot
        /// Where the passage sits in `snapshot.text` RIGHT NOW — the resolver's
        /// answer, never the stored hint. See `PassageResolver`.
        public var range: Range<Int>
        /// The unit's own name when there is one ("Purpose"), "" otherwise.
        /// Carried separately because `Passage` stores the words and the kind
        /// but not the heading they sat under.
        public var label: String
        /// Nil when the model handed back a handle and nothing had to be
        /// decided; set when the ladder chose between candidates this call.
        public var confidence: PassageConfidence?
        public var rung: PassageRung?
        public var runnerUp: PassageCandidate?
        /// The handle the model actually used, when it had been superseded by
        /// an earlier edit. Spoken back, so "that was [S1] — it's [S4] now" is
        /// an answer the conversation can carry on from.
        public var forwardedFrom: String?
        public var trace: [String]
    }

    public enum Lookup: Sendable {
        case found(Located)
        /// Spoken. `looked` says whether the document was actually SEARCHED —
        /// and it decides which of two incompatible flags a read answers with.
        ///
        /// `PassageResolver.refusal`'s doctrine, applied one level up: a search
        /// that ran and came back empty is an ANSWER (`ok: true`,
        /// `foundNothing: true` — honest, and barred from being recited as
        /// though it were the passage). Never being able to look at all —
        /// nothing open, no words to look for, a handle that means nothing — is
        /// a FAILURE, and `ok: false` is the only flag that makes the user hear
        /// it. Collapsing the two would either speak every miss aloud or
        /// swallow every "I can't see your document" in silence.
        case refused(String, looked: Bool)
    }

}
