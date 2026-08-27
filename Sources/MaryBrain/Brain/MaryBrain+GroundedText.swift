//
//  MaryBrain+GroundedText.swift
//  MaryBrain
//
//  The pure-static grounded-text cluster, moved out of MaryBrain.swift:
//  how finished Skill outcomes become the grounded-results block, the read
//  passage block, and the honest fallback follow-up sentence
//  (`groundedResultsBlock`, `readPassageClamp`, `readPassageTotalClamp`,
//  `readPassageBlock`, `unrecoveredFailure`, `spokenLineClamp`, `spokenBrief`,
//  `isWholeSpokenSentence`, `composeWouldOnlyRestate`, `fallbackFollowUpLine`).
//
//  Moved verbatim; no behavior change, no wording change. All members are
//  statics with no stored state; no access promotions were needed.
//

import MaryVoice
import Foundation

extension MaryBrain {

    /// Skill results, clamped, as the grounded-results block for the follow-up
    /// instructions (~500 chars per Skill, ~4000 total).
    static func groundedResultsBlock(outcomes: [LaneOutcome]) -> String {
        var lines: [String] = []
        var total = 0
        for outcome in outcomes {
            let clamped = outcome.summary.count > 500
                ? String(outcome.summary.prefix(500)) + "…"
                : outcome.summary
            // FAILURES ARE LABELLED, because this block is the follow-up's ONLY
            // evidence and `followUpNudge` asks the voice to "confirm the
            // outcome in one short spoken sentence". Unlabelled, "- pages_body:
            // The script failed: …(-1728)" arrived formatted identically to a
            // result that worked, under a heading that says these are grounded
            // results — and the only reading left to a model is that it worked.
            // Four words of prose are not a gate; the prefix is.
            //
            // A MISS IS NOT LABELLED as a failure, because it is not one: the
            // read ran and this is its honest answer. It reaches here only under
            // the ACTION persona, which is the whole point of `speakable`.
            let label = outcome.ok ? "\(outcome.skillName):" : "\(outcome.skillName) FAILED:"
            let line = "- \(label) \(clamped)"
            total += line.count
            if total > 4000 {
                lines.append("- (further results omitted)")
                break
            }
            lines.append(line)
        }
        return "=== Grounded results ===\n" + lines.joined(separator: "\n")
    }

    /// A READ's text for the voice — same plumbing as `groundedResultsBlock`,
    /// deliberately different numbers.
    ///
    /// THE FAILURE THIS FIXES: reusing `groundedResultsBlock` for a read
    /// clamps each summary at 500 characters, and `PagesPlugin.regionSpan` is
    /// 1800 — so the passage the user asked to hear would arrive amputated to
    /// 28% of itself, with the tail (where the answer usually is) gone. A read
    /// IS the answer, so the clamp is sized to carry a whole region plus its
    /// bounds header, and several of them.
    ///
    /// No Skill names and no "=== Grounded results ===" banner: this text lands
    /// inside the LIVE block, where the surrounding sentences already say what
    /// it is, and the read persona forbids speaking Skill names aloud. Each
    /// summary already carries its own bounds label ("… — characters
    /// 12927–13835 of 15775, from \"batteries\""), which is exactly the window
    /// framing the rest of this change installs.
    ///
    /// ITS PRODUCER IS `speakRoutineFollowUp`, on a routine whose every
    /// concrete outcome is a READ. It was inert for one slice — its only
    /// caller had been `speakInTurnRead`, the second Seer pass that was
    /// removed — and being inert is what let "I checked your calendar for you"
    /// ship with no events in it: the follow-up used the ACTION persona and
    /// its 500-character clamp for a turn that existed only to recite. Kept
    /// then (unlike `ReadRoute.spokenInTurn`, which was deleted) because this
    /// is a prompt-BUILDING capability rather than a diagnostic claiming to
    /// describe what happened; wired now, which is what that note anticipated.
    static let readPassageClamp = 2_400
    static let readPassageTotalClamp = 8_000

    static func readPassageBlock(outcomes: [LaneOutcome]) -> String {
        var blocks: [String] = []
        var total = 0
        for outcome in outcomes {
            let clamped = outcome.summary.count > readPassageClamp
                ? String(outcome.summary.prefix(readPassageClamp)) + "…"
                : outcome.summary
            total += clamped.count
            if total > readPassageTotalClamp {
                blocks.append("(there is more, beyond what I can hold here)")
                break
            }
            blocks.append(clamped)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// DID THIS LANE GO THROUGH? — asked once, in one place, because two paths
    /// ask it and they used to answer differently.
    ///
    /// Only an UNRECOVERED failure counts: a mid-chain `!ok` the model retried
    /// past (the lane ends on ok) genuinely succeeded, so the GATE is the last
    /// outcome. What gets NAMED is the FIRST thing that went wrong — the mistake
    /// that started the trouble, not whatever the model was flailing at when it
    /// gave up.
    ///
    /// THE FAILURE THIS FIXES, in the user's own words: "That's done — The
    /// script failed: 374:441: execution error: Pages got an error: Can't get
    /// text from character 68 to character 916 of body text of document 1.
    /// (-1728)". `runTurn` had this predicate and spoke honestly;
    /// `fallbackFollowUpLine` had no predicate at all and said "That's done"
    /// whatever `ok` held. Two roads, two ideas of what "failed" means, and the
    /// quieter road was the wrong one. One function is what stops them drifting
    /// again — a second copy would only be correct until someone edited one.
    static func unrecoveredFailure(in outcomes: [LaneOutcome]) -> LaneOutcome? {
        guard outcomes.last?.ok == false else { return nil }
        return outcomes.first(where: { !$0.ok })
    }

    /// HOW LONG A DETERMINISTIC FOLLOW-UP MAY SPEAK IN ONE BREATH — hoisted out
    /// of `fallbackFollowUpLine`'s local `brief`, where it was a bare `160` no
    /// other code could see.
    ///
    /// It is shared because a PREDICATE now depends on it: `composeWouldOnlyRestate`
    /// decides to skip the composer precisely when this clamp would take nothing
    /// off, and the producer that speaks instead must clamp by the same rule. Two
    /// copies of a rule is exactly how this file got here — `runTurn` and
    /// `fallbackFollowUpLine` held two ideas of what "failed" meant and the
    /// quieter road was the wrong one (see `unrecoveredFailure`, directly above).
    /// A second, re-derived `count <= 160 && !contains("\n")` would go the same
    /// way: the skip would fire on a line the producer then truncated, and the
    /// user would hear a fragment nobody had paid to compose.
    ///
    /// 160 characters, unchanged in value and only moved. Its arithmetic is a
    /// RATIO to its neighbours rather than a measurement: `groundedResultsBlock`
    /// clamps at 500 (~3×) and `readPassageClamp` at 2,400 (15×), because those
    /// two are sized to what a MODEL reads and this one to what a MOUTH says.
    static let spokenLineClamp = 160

    /// One outcome's summary as the deterministic line would speak it: FIRST
    /// LINE ONLY, then clamped. A script error's second line is a stack of
    /// AppleScript coordinates nobody can hear, and a Pages targeted miss puts
    /// the whole document after a newline.
    static func spokenBrief(_ summary: String) -> String {
        let firstLine = summary
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? summary
        return firstLine.count > spokenLineClamp
            ? String(firstLine.prefix(spokenLineClamp)) + "…"
            : firstLine
    }

    /// TRUE when `spokenBrief` would take NOTHING off — the summary already IS,
    /// exactly, what the mouth would say.
    ///
    /// Stated as "the clamp is a no-op on this" rather than as an independent
    /// length-and-newline test, deliberately: it is the producer's own function
    /// asked about itself, so it cannot come to disagree with the producer the
    /// way a re-derived copy eventually would.
    ///
    /// A BLANK SUMMARY IS NOT A WHOLE SPOKEN SENTENCE. The clamp is a no-op on
    /// "" too, so without this guard a wordless miss would qualify — and be
    /// "spoken" as silence, which is the one thing a miss may never be: it still
    /// owes the user a word.
    static func isWholeSpokenSentence(_ summary: String) -> Bool {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return spokenBrief(summary) == summary
    }

    /// WOULD THE COMPOSER ONLY SAY BACK WHAT IS ALREADY IN HAND? — asked before
    /// paying twenty seconds to find out.
    ///
    /// THE FAILURE THIS FIXES (confirmed against a live user session): the user
    /// asked for "the latest note I made in the Notes app" and waited a long
    /// time to hear "That's done — Notes isn't open — show_note opens it if you
    /// name a note." The wait was never the read: the cold-launch check is
    /// microseconds. The turn spent its whole `followUpSpeechBudget` asking a
    /// hosted model to restate one sentence, got nothing back, left a
    /// `.chainStalled` row, and spoke the deterministic line it had been holding
    /// since t = 0.
    ///
    /// THREE CONJUNCTS, EACH LOAD-BEARING.
    ///
    /// 1. `count == 1`. `fallbackFollowUpLine` names exactly ONE outcome, so
    ///    skipping over a two-miss set would throw the other one away. A lane
    ///    that missed twice gets the composer, which can say "neither".
    ///
    /// 2. `foundNothing`. The only class with nothing to RECITE and nothing to
    ///    SUMMARIZE: `speakable` is empty by construction, so what the action
    ///    persona is handed is `followUpNudge` — "confirm the outcome in one
    ///    short spoken sentence… never repeat the content" — over a non-event.
    ///    A FAILURE IS DELIBERATELY EXCLUDED. "374:441: execution error: Pages
    ///    got an error: … (-1728)" is exactly the text a voice should PHRASE
    ///    rather than recite, and `DetachedRoutineTests` pins that a concrete
    ///    failure is composed. `unrecoveredFailure` is what states that here —
    ///    the same function `fallbackFollowUpLine`'s FIRST arm reads, so the two
    ///    cannot drift about a shape neither expects. No binding produces
    ///    `ok: false` with `foundNothing` set today, and that is the argument for
    ///    closing it rather than against: the invariant below is only an
    ///    invariant while it stays executable instead of inherited.
    ///
    /// 3. `isWholeSpokenSentence`. The plain line must lose NOTHING to the
    ///    clamp. This is what keeps a Pages targeted miss on the COMPOSING road:
    ///    its summary runs ~250 characters of reasons with the whole document
    ///    behind a newline, so the fallback would speak a fragment where the
    ///    composer says "there's no section five in that one". It is also why
    ///    six calendar events can never qualify — a read that needed summarizing
    ///    is multi-line and long by construction.
    ///
    /// THE CANDIDATES THIS IS NOT, and the evidence is a test that already
    /// passes. "A single outcome" alone, and "short enough to speak verbatim"
    /// alone, BOTH fire on `slowLaneDetachesAndFollowsUp`: one outcome, "probe
    /// says 42", thirteen characters, one line — and the composer's whole job
    /// there is to turn `42` into `forty two` for the speaker. A one-line
    /// outcome WITH CONTENT IN IT does need composing. "A refusal" is the right
    /// idea, but it is expressed STRUCTURALLY through the flag and never by
    /// sniffing the summary for a prefix; this tree already calls a
    /// grep-held-together predicate out by name.
    ///
    /// THE INVARIANT IT BUYS, and it is the whole safety argument: whenever this
    /// is true, `fallbackFollowUpLine` returns that outcome's own summary,
    /// VERBATIM. The sentence we decline to pay for and the sentence we speak
    /// are the same sentence.
    static func composeWouldOnlyRestate(_ grounded: [LaneOutcome]) -> Bool {
        guard grounded.count == 1, let only = grounded.first else { return false }
        guard only.foundNothing, unrecoveredFailure(in: grounded) == nil else { return false }
        return isWholeSpokenSentence(only.summary)
    }

    /// Seer-offline follow-up: a plain deterministic report — and the line the
    /// user actually heard, because the follow-up's Seer round trip is the one
    /// most likely to be timed out or offline when a lane has just spent five
    /// minutes failing. It carried the ONLY unconditional "That's done" in the
    /// tree, and it had zero test pins, which is why it shipped.
    ///
    /// IT IS ALSO NO LONGER ONLY A FALLBACK. When `composeWouldOnlyRestate`
    /// holds, `speakRoutineFollowUp` never asks the model at all and this is the
    /// first and only producer — which is why its fourth arm and that predicate
    /// share their selector rather than each having an opinion.
    /// THE FOLLOW-UP'S NOUN CHECK — the first application the composed
    /// sentence names that its evidence does not, or nil when the sentence
    /// is grounded. An application counts as grounded when the grounded
    /// block's own text mentions it (a `textedit_text` summary says
    /// "TextEdit") or one of the outcomes' skills belongs to its world.
    /// Union-conservative like the mismatch mirror: any legitimate mention
    /// passes; only a name with NO evidence anywhere is foreign.
    static func namesForeignApplication(
        _ composed: String,
        groundedBlock: String,
        outcomes: [LaneOutcome],
        profiles: [ApplicationProfile],
        owner: (String) -> AmbientWorld?
    ) -> String? {
        for profile in profiles {
            guard profile.isMentioned(in: composed) else { continue }
            if profile.isMentioned(in: groundedBlock) { continue }
            if outcomes.contains(where: { owner($0.skillName)?.pluginOwner == profile.id }) {
                continue
            }
            return profile.title
        }
        return nil
    }

    static func fallbackFollowUpLine(outcomes: [LaneOutcome]) -> String {
        if let failure = unrecoveredFailure(in: outcomes) {
            return "That didn't go through — \(spokenBrief(failure.summary))"
        }
        guard let last = outcomes.last else { return "" }
        // A MISS IS NOT A COMPLETION EITHER, and this line is the last place one
        // could still be dressed as one. `foundNothing` is ok and non-deferred,
        // so it walks straight past the failure gate above — and every OTHER
        // consumer of a miss was closed this phase (`speakable` keeps it out of
        // the voice's passage block, `detachedReads` keeps it off the ledger),
        // which leaves exactly this fallback as the one road by which a miss's
        // own words still reach the mouth. "That's done — Draft has no
        // "Purpose" in its body text" is the (-1728) sentence in a quieter
        // register: a non-answer wearing a completion's clothes.
        //
        // What it narrates is therefore the last outcome with something IN it.
        // A turn that read one thing and missed another reports the read; a turn
        // that only missed says it only missed, and says WHY — the miss summary's
        // first line is its reasons (headers, text boxes, table cells), which is
        // the honest answer to "did you find it?" and the one the user asked for.
        //
        // The attached document cannot follow it out: a Pages miss puts the body
        // after a newline and `spokenBrief` keeps the first line only. That is
        // the second guard, not the first — `speakable` is the first.
        if let delivered = outcomes.last(where: { !$0.foundNothing }) {
            return "That's done — \(spokenBrief(delivered.summary))"
        }
        // THE FOURTH ARM, and its selector is STRUCTURAL rather than editorial.
        //
        // "I couldn't find that" is true of a search that ran and missed. It is
        // FALSE of a world that is shut — nothing was searched for, because
        // there was nothing to search. The line the user heard was the other
        // half of the same mistake: "That's done — Notes isn't open — show_note
        // opens it if you name a note", a lead contradicting the sentence it
        // introduced, twice over.
        //
        // So the summary decides. When the clamp would take NOTHING off it, the
        // summary already IS a finished spoken sentence, and any lead in front
        // of it can only argue with it: speak it verbatim. When the clamp DOES
        // bite — a Pages targeted miss, whose reasons run past the clamp and
        // whose document sits behind a newline — what is being handed over is a
        // FRAGMENT, and a fragment needs its frame.
        //
        // The selector is `composeWouldOnlyRestate` ITSELF, not a private copy
        // of its third conjunct, and that identity is what makes the skip in
        // `speakRoutineFollowUp` safe: the sentence the guard declines to pay
        // for is exactly the sentence this returns. Its `count == 1` conjunct
        // still does real work down here: everything that reaches this line is
        // all-misses, but a lane that missed TWICE would have one of its two
        // sentences dropped by a verbatim return, so it keeps the framed line.
        if composeWouldOnlyRestate(outcomes) {
            return last.summary
        }
        return "I couldn't find that — \(spokenBrief(last.summary))"
    }
}
