//
//  PassageEditRunner.swift
//  MaryBrain
//
//  WHAT: Revision guard chain. Every world writer hangs off APPLY.
//  IN:   handle | locating words → PassageResolver → world snapshot
//  OUT:  world writer | refusal → ContentUndoStore (documentKey)
//  PIN:  XcodePlugin.editRecipe is a separate allowlisted path, not this.
//        Headless via PassageBacking.
//  STEPS: resolve → snapshot → clean-check(in writer) → identity → PassageEdit
//         → hash re-check → apply → verify readback → remint
//
//  Splits:
//    PassageEditRunner+ResolveAndFind.swift      steps 1–4
//    PassageEditRunner+Edit.swift                steps 5–9
//    PassageEditRunner+MinimalChange.swift       two-ended trim
//    PassageEditRunner+NarrationAndRevert.swift  spoken report + revert
//

import Foundation

public enum PassageEditRunner {

    /// Prior-content ledger for `revert_last_edit`.
    /// OUT: ContentUndoStore keyed by documentKey (same identity as the write).
    public static let undoStore = ContentUndoStore()

    // MARK: - What one lookup produced

    /// A passage, the body it was found in, and where in that body it now sits.
    public struct Located: Sendable {
        public var passage: Passage
        public var snapshot: BodySnapshot
        /// Live range in `snapshot.text` — PassageResolver's answer, not the stored hint.
        public var range: Range<Int>
        /// Heading name when there is one; "" otherwise. Passage holds words and kind, not this.
        public var label: String
        /// Set when the ladder chose this call; nil when a handle needed no decision.
        public var confidence: PassageConfidence?
        public var rung: PassageRung?
        public var runnerUp: PassageCandidate?
        /// Superseded handle the model used, if any. Spoken so the conversation can follow.
        public var forwardedFrom: String?
        public var trace: [String]
    }

    public enum Lookup: Sendable {
        case found(Located)
        /// Spoken refusal. `looked` = the document was searched.
        /// PIN: empty search is an answer; never being able to look is a failure.
        case refused(String, looked: Bool)
    }

}
