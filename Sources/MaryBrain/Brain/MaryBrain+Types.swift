//
//  MaryBrain+Types.swift
//  MaryBrain
//
//  The brain's nested judgement types, moved out of MaryBrain.swift:
//  `RevisionVeto`, `WorldVeto`
//  (and its `Arming`), plus the statics they judge with —
//  `designRequirements(for:)` and `caretWriteSkills`. The instance methods
//  that resolve these targets (`locateTarget`,
//  `revisionReport`) stay with the actor's turn machinery.
//
//  Moved verbatim; no behavior change. No access promotions were needed.
//  NOTE: `WorldVeto` is a known upcoming migration-rename site (the
//  AmbientPlace taxonomy migration).
//

import MaryVoice
import Foundation

extension MaryBrain {

    /// G3, factored — the revision veto, as a judgement rather than as a copy.
    ///
    /// THE FAILURE THIS MAKES IMPOSSIBLE, in the user's own words: "replace the
    /// Purpose section with the tighter version" → `type_at_cursor`, the
    /// tighter version typed wherever the caret happened to sit, the Purpose
    /// section left standing. "Intended for live writing behavior rather than
    /// revision behavior."
    ///
    /// BOTH SKILL LOOPS OWN ONE. The orchestrator lane and the legacy loop are
    /// different turn shapes with different emission channels and different
    /// history bookkeeping, but the JUDGEMENT — is this a caret write, is there
    /// a real passage to redirect it to, and has the allowance already been
    /// spent — is one thing, and two copies of it is how one of them rots. This
    /// type is the judgement; each loop keeps its own three lines of plumbing.
    ///
    /// TWO BOUNDS, both of them in here. `target` is the first: with nothing to
    /// redirect TO, typing is the honest fallback and the veto never runs at
    /// all. `spent` is the second: it fires AT MOST ONCE per loop, because a
    /// model that comes back with a second caret write has told us it cannot
    /// use the edit path this round, and at that point typing beats nothing —
    /// the user asked for words, and refusing twice produces silence, which is
    /// the one outcome worse than prose in the wrong place.
    struct RevisionVeto {
        private let target: LocatedPassage?
        private var spent = false

        init(target: LocatedPassage?) {
            self.target = target
        }

        /// The synthetic Skill result to answer this call with INSTEAD of
        /// dispatching it, or nil to dispatch normally. Consumes the single
        /// allowance when it answers.
        ///
        /// WHAT COMES BACK IS AN OUTCOME, NOT A SCOLDING. `LocatedPassage
        /// .Brief.redirect` opens by saying nothing was typed and then names
        /// the binding and the handle — a Skill result that reads as a failure
        /// gets RETRIED by a small model, and the retry is the same wrong call
        /// again.
        mutating func redirect(for skillName: String) -> String? {
            guard let target, !spent,
                  MaryBrain.caretWriteSkills.contains(skillName) else { return nil }
            spent = true
            return target.brief.redirect
        }
    }

    /// G3 FOR THE WORLD BOUNDARY — `RevisionVeto`'s third sibling. A read or
    /// act the model aims at a RIVAL watched world, on a writing-led turn
    /// whose words named no such world, is answered with an outcome that
    /// names the leading world's own targeted read.
    ///
    /// THE FAILURE THIS FIXES (live, in Pages): looking for "the passage",
    /// the model called `search_manuscript` (Scrivener) and `textedit_text` /
    /// `textedit_windows` (TextEdit) on a turn that was entirely about the
    /// Pages document in front of the user — and quoted what it found there
    /// as if it were the document. Roster pruning removes the temptation;
    /// this veto is the backstop for the call that arrives anyway, from
    /// history or hallucination, because `dispatch` deliberately stays total
    /// on exact names.
    ///
    /// Same two bounds as both siblings: no arming, no veto (a turn that is
    /// not writing-led, or a lead with no targeted read, passes everything
    /// through); and it fires AT MOST ONCE per loop — a model that repeats a
    /// rival call after being told the alternative is exercising the
    /// capability the eyes doctrine guarantees, and blocking twice produces
    /// silence.
    struct WorldVeto {
        struct Arming: Sendable {
            /// The leading writing world this turn belongs to.
            var lead: AmbientWorld
            /// Worlds this turn's words re-admitted — named, referent, or
            /// mentioned. A call into any of these is the user's own ask.
            var admitted: Set<AmbientWorld>
            /// The lead's targeted read, for the redirect sentence.
            var read: (binding: String, parameter: String)
        }

        private let arming: Arming?
        private var spent = false

        init(arming: Arming?) {
            self.arming = arming
        }

        /// The synthetic Skill result to answer this call with INSTEAD of
        /// dispatching it, or nil to dispatch normally. An OUTCOME, not a
        /// scolding: it opens by saying nothing ran and then names the exact
        /// right call.
        mutating func redirect(for skillName: String, world: AmbientWorld?) -> String? {
            guard let arming, !spent, let world, world.hasEyes,
                  world != arming.lead,
                  !arming.admitted.contains(world) else { return nil }
            spent = true
            return "Nothing ran in \(world.displayName) — the user's work this turn is "
                + "the \(arming.lead.displayName) document in front of them. Look there "
                + "instead: call \(arming.read.binding) with \(arming.read.parameter) set "
                + "to the words they used, or without it for the whole document."
        }
    }

    // What an invocation needs of its target is DECLARED now — the domain's
    // `verbRequirements` table, consumed through the turn lexicon's
    // `requirements(forUtterance:)`. The engine carries no verb table.

    /// THE SKILLS THAT WRITE AT THE CARET — the whole set, named explicitly.
    ///
    /// NOT SNIFFED FROM A DESCRIPTION, and not derived from `stage` or from
    /// `isReadOnly`. Both of those would have caught these two today and both
    /// would silently swallow the next one: `replace_passage` claims the stage
    /// as well (the Pages backing may fall back to keystrokes), so a
    /// stage-based test would veto the very binding the veto redirects TO.
    /// Adding a Skill here has to be a deliberate act by someone who has read
    /// this comment.
    ///
    /// WHAT THEY ARE FOR IS STILL RIGHT. Typing at the cursor is LIVE
    /// COMPOSITION — new words, going in where the user is looking, as they
    /// watch — and it is the correct answer to "write a paragraph about the
    /// budget". The veto does not distrust them; it distrusts them on the one
    /// turn where a passage has already been located, because on that turn the
    /// caret is wherever the user last clicked and the passage is somewhere
    /// else entirely.
    static let caretWriteSkills: Set<String> = ["type_at_cursor", "resume_typing"]
}
