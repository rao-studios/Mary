//
//  EditReport.swift
//  MaryBrain
//
//  WHAT SHE SAYS AFTER SHE CHANGES THE USER'S WORDS.
//
//  THE LIVE FAILURE, in the user's own words. In Pages: "replace the Purpose
//  section with the tighter version." She called `type_at_cursor`, typed the
//  new prose wherever the caret happened to sit, and left the Purpose section
//  standing — "intended for live writing behavior rather than revision
//  behavior." Everything else in this phase is about making that impossible.
//  This file is about the aftermath of getting it RIGHT: a change landed
//  somewhere in a document the user was not watching, and unless she says
//  where, the only way to find out is to go looking.
//
//  AND THEN IT DIDN'T SPEAK AT ALL. Second live failure, same area: "Yeah
//  yeah exactly can you reword the whole thing for me." She replaced the
//  passage correctly — and then asked permission for it, out loud, after the
//  fact: "I'm on it, but I need a quick clarification — do you mean the whole
//  document, or the Background section?" This file was keyed on the CLASSIFIED
//  INTENT, the backchannel had unanchored the classifier, and so the one
//  deterministic sentence that would have told the user what had happened was
//  discarded on the turn it was written for. `report` is keyed on a landed
//  edit now; read its comment for the whole argument.
//
//  WHY IT CANNOT BE MODEL PROSE. Same discipline as the confirm relay,
//  `bareDecision` and `PassageEditRunner.report`: a sentence that reports what
//  was done to a document must say the same thing every time or it becomes one
//  more thing the model gets to interpret. It is built here, from the outcome,
//  by arithmetic.
//
//  BOUNDS IN WORDS, NEVER OFFSETS. The read persona already forbids speaking
//  character positions aloud and it is right — "I replaced characters twelve
//  thousand nine hundred and twenty-seven to thirteen thousand eight hundred
//  and thirty-five" is not a sentence anybody says, and printing those numbers
//  at a model is the exact channel that produced the `-1728`: `regionOutcome`
//  printed them, `AmbientBridge.parseBounds` scraped them back, and a
//  hand-written script addressed `document 1` by character number. The
//  recoverable bounds of a passage, for a person, are its EDGES: the words it
//  starts with, the words it ends with, and roughly how much sat between them.
//  Digits about POSITION still exist — in the chip, the AbilityExecutionLog and the
//  ambient fact. The transcript gets digits; the ear gets language.
//
//  THE UNDO OFFER IS EARNED, NOT ROUTINE. She decides unattended (the user's
//  own fixed decision: "ambiguous/missing target → read wider, then decide
//  alone"), so the one edit a user might not have meant is the one SHE chose
//  between candidates. Offering to undo every confident edit teaches them to
//  stop listening to the offer, which costs the one case it exists for.
//

import Foundation

/// The deterministic sentence a revision speaks about itself, and the shape it
/// speaks it in.
public struct EditReport: Sendable, Equatable {

    public enum Shape: String, Sendable, Equatable {
        /// Their own words named one thing and it matched whole.
        case replaced
        /// Same act, but WE chose which passage it was — `LocatedPassage.widened`.
        /// The only shape that offers the way back.
        case replacedAfterChoosing
        case inserted
        case deleted
        case moved
        /// A change was SENT and nothing confirmed it — neither "Done" nor a
        /// failure, and it may not borrow either one's words.
        case unconfirmedEdit
        /// She meant to revise, could not find the part, and typed instead.
        case couldNotLocate
    }

    public var shape: Shape
    /// Spoken as-is. One sentence in the ordinary case, two when she chose.
    public var sentence: String

    public init(shape: Shape, sentence: String) {
        self.shape = shape
        self.sentence = sentence
    }

    // MARK: - Which skills count as a revision

    /// THE PASSAGE EDIT VERBS, named explicitly rather than sniffed from a
    /// description — `caretWriteSkills`' rule, for `caretWriteSkills`' reason:
    /// adding one has to be a deliberate act, not an accident of wording.
    ///
    /// `find_passage` is absent because it changes nothing, and
    /// `revert_last_edit` is absent because it is not a revision — it is the
    /// undoing of one, it already speaks its own hash-guarded refusal or
    /// confirmation through `PassageEditRunner.revert`, and reporting "I
    /// replaced the part starting…" about an undo would describe the edit that
    /// was TAKEN BACK.
    static let replaceSkill = "replace_passage"
    static let insertSkill = "insert_passage"
    static let deleteSkill = "delete_passage"
    static let editSkills: Set<String> = [replaceSkill, insertSkill, deleteSkill]

    // MARK: - Building it

    /// The one entry point. Nil means THIS TURN HAS NOTHING TO REPORT, and nil
    /// is the common answer — every ordinary action turn, every read, every
    /// conversation.
    ///
    /// THE KEY IS A LANDED EDIT, NOT A CLASSIFIED INTENT — and it used to be the
    /// other way round, which is what silenced the live turn. The old first
    /// bound read "`intent` must be non-nil: a turn nobody classified as a
    /// revision never speaks a revision report, whatever skills it happened to
    /// call." The user said "Yeah yeah exactly can you reword the whole thing
    /// for me"; three words of backchannel unanchored `EditIntentClassifier`'s
    /// `^` anchors, the intent came back nil — and `REPLACE_PASSAGE` landed
    /// anyway, correctly, because the Skill execution lane read the sentence the way a
    /// person does. The guard then threw the report away and Lane A improvised
    /// over the silence: "I'm on it, but I need a quick clarification — do you
    /// mean the whole document, or the Background section?", spoken about a
    /// change that had already happened.
    ///
    /// `performed`'s own comment below already argued the opposite principle —
    /// "WHICH change is read off the skills that ran, not off the intent… on the
    /// turn those disagree the user needs to hear the second one." That turn WAS
    /// the disagreement, and the bound above it stopped the principle ever
    /// reaching it. So the key is `editSkills`: an explicit three-name allowlist
    /// carrying `caretWriteSkills`' discipline, which means a Skill joins this
    /// report by someone deliberately adding it here, never by a regex changing
    /// its mind about a sentence.
    ///
    /// WHAT IT COSTS, STATED HONESTLY. With no intent and no located passage
    /// there is no target text to read edges off, so the sentence degrades to
    /// "Done — I replaced the part they meant." — weak, but honest, and above
    /// all NOT a hedge. A vague true sentence about a change that happened is
    /// the thing the user was owed; a clarifying question about it is not.
    ///
    /// Three bounds remain, and each one closes a way this could become noise:
    ///
    ///   1. Something must have HAPPENED — a successful, non-deferred passage
    ///      edit — or the turn must be the shipped failure itself (located
    ///      nothing, typed at the caret). A revision that FAILED already speaks
    ///      through `unrecoveredFailure`, and two sentences about one failure is
    ///      one too many.
    ///   2. `.couldNotLocate` still requires BOTH a classified intent and a
    ///      caret write that actually ran, and the intent stays required THERE
    ///      because that shape is a claim about what she MEANT, not about what
    ///      she did: nothing was edited, so the skills cannot speak for it.
    ///      `EditIntentClassifier` is world-blind by design, so "fix the build"
    ///      and "update the header comment" are honest `.replace` intents with
    ///      nothing in any document to locate; narrating a miss at those would
    ///      be a lie about a turn that worked perfectly.
    ///   3. The undo offer is gated on `target.widened` alone.
    static func report(
        intent: EditIntent?,
        target: LocatedPassage?,
        writingTarget: AmbientWritingTarget? = nil,
        acceptedOffer: Bool = false,
        outcomes: [MaryBrain.LaneOutcome]
    ) -> EditReport? {
        if writingTarget == .selection,
           outcomes.contains(where: {
               $0.ok && !$0.deferred && $0.skillName == "type_at_cursor"
           }) {
            return EditReport(
                shape: .replaced,
                sentence: "Done — I revised the selected text.")
        }
        // CONFIRMED edits only. `ok` alone let this filter fabricate "Done —
        // I replaced…" over a write nothing verified: the runner's own
        // "couldn't confirm it landed" sentence was structurally unreachable
        // because this report replaced it on both the joined and detached
        // roads. `.unconfirmed` gets its own deterministic shape below;
        // `.unchanged` is excluded outright — nothing happened, and "Done"
        // about an untouched document is the same lie in a quieter register.
        let edits = outcomes.filter {
            $0.ok && !$0.deferred && editSkills.contains($0.skillName)
        }
        let landed = edits.filter {
            $0.editDisposition != .unconfirmed && $0.editDisposition != .unchanged
        }
        guard landed.isEmpty else {
            return performed(landed, target: target)
        }
        if edits.contains(where: { $0.editDisposition == .unconfirmed }) {
            let whereItIs = target.map {
                $0.documentTitle.isEmpty ? "" : " in \($0.documentTitle)"
            } ?? ""
            return EditReport(
                shape: .unconfirmedEdit,
                sentence: "I sent that change\(whereItIs) and couldn't confirm "
                    + "it landed — take a look before going on.")
        }

        // Nothing was revised. The ONE case still worth a sentence is the
        // shipped failure's own shape: she meant to revise, had no passage to
        // revise, and put the words in at the caret instead. The user watched
        // prose appear in the wrong place and was told nothing at all.
        guard intent != nil, target == nil,
              outcomes.contains(where: {
                  $0.ok && MaryBrain.caretWriteSkills.contains($0.skillName)
              })
        else {
            // THE ACCEPTED-OFFER SILENT MISS. An offer the user said yes to,
            // followed by a turn that landed no edit and typed nothing, is
            // the false completion's quieter sibling: an accepted promise
            // answered by silence. The action rhythm has already suppressed
            // the voice, so this sentence is the only one the turn has —
            // honest, deterministic, actionable.
            guard acceptedOffer else { return nil }
            return EditReport(
                shape: .couldNotLocate,
                sentence: "I couldn't find the passage we were talking about again — "
                    + "nothing was changed. Select it, or name the part, and I'll do it.")
        }
        // On an accepted offer the synthesized intent's one target is the
        // whole discussed paragraph — `missSentence` must not recite it.
        return EditReport(
            shape: .couldNotLocate,
            sentence: acceptedOffer
                ? missSentence(intent: nil, called: "the passage we were discussing")
                : missSentence(intent: intent))
    }

    /// A change that landed. WHICH change is read off the skills that ran, not
    /// off the intent — the intent is what she was ASKED for and the skills are
    /// what she DID, and on the turn those disagree the user needs to hear the
    /// second one.
    private static func performed(
        _ landed: [MaryBrain.LaneOutcome], target: LocatedPassage?
    ) -> EditReport {
        let skills = Set(landed.map(\.skillName))
        // A MOVE HAS NO RECIPE OF ITS OWN, and that is not an oversight: moving
        // a passage IS taking it out of one place and putting it in another, so
        // the lane performs it as a delete and an insert. Reading the pair back
        // as one act is the only way the report can describe what the user
        // actually asked for rather than narrating half of it twice.
        let shape: Shape
        if skills.contains(deleteSkill) && skills.contains(insertSkill) {
            shape = .moved
        } else if skills.contains(deleteSkill) {
            shape = .deleted
        } else if skills.contains(insertSkill) {
            shape = .inserted
        } else if target?.widened == true {
            shape = .replacedAfterChoosing
        } else {
            shape = .replaced
        }

        let part = edgePhrase(target)
        let whereItIs = target.map { $0.documentTitle.isEmpty ? "" : " in \($0.documentTitle)" } ?? ""
        var sentence: String
        switch shape {
        case .replaced, .replacedAfterChoosing:
            sentence = "Done — I replaced \(part)\(whereItIs)."
        case .inserted:
            sentence = "Done — I added the new wording next to \(part)\(whereItIs)."
        case .deleted:
            sentence = "Done — I took out \(part)\(whereItIs)."
        case .moved:
            sentence = "Done — I moved \(part)\(whereItIs)."
        case .couldNotLocate, .unconfirmedEdit:
            sentence = ""   // unreachable: this arm only runs on a landed edit
        }
        // THE OFFER, and ONLY here. `widened` is false on exactly one shape —
        // the first thing they called it, matched once and matched whole. Every
        // other route to a passage (a second-choice phrase, a fuzzy rung, the
        // fallback to whatever they had selected) was US deciding while they
        // were not watching, and an unattended pick is precisely the one a
        // person needs handed back.
        if target?.widened == true {
            sentence += " Their words matched more than one place and I took that one — say undo if I picked wrong."
        }
        return EditReport(shape: shape, sentence: sentence)
    }

    // MARK: - The edges

    /// How many words at each end. Five is what it takes to recognise a
    /// sentence you wrote and short enough that two of them fit inside one
    /// spoken clause without the clause becoming a recitation.
    static let edgeWords = 5

    /// The passage said as a person would say it: what it started with, what it
    /// ended with, and roughly how much.
    ///
    /// A SHORT PASSAGE IS QUOTED WHOLE. Below twice the edge width the two
    /// edges overlap, and "the part starting 'the tide came in slowly' and
    /// ending 'the tide came in slowly'" is a sentence that makes a listener
    /// think something went wrong.
    ///
    /// "THE PART THEY MEANT" IS THE DEGRADE, and since `report` was re-keyed off
    /// a landed edit it is a reachable one: a turn nobody classified as a
    /// revision located nothing, so there is no passage text to read edges off.
    /// It is deliberately the WEAKEST honest sentence rather than a second
    /// sentence-builder — the words that made the live turn go wrong were a
    /// question, and a vague true statement beats a precise question about a
    /// change that already happened. The only richer wording available is
    /// `PassageEditRunner.report`'s, and it arrives as one already-finished
    /// sentence carrying its `[S#]` handle: scraping edge words back out of it
    /// is the shape that produced the `-1728`, and speaking a handle aloud is
    /// what the read persona forbids.
    static func edgePhrase(_ target: LocatedPassage?) -> String {
        guard let target else { return "the part they meant" }
        let words = target.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return "the part they meant" }
        if words.count <= edgeWords * 2 {
            return "the part that read \"\(words.joined(separator: " "))\""
        }
        let opening = words.prefix(edgeWords).joined(separator: " ")
        let closing = words.suffix(edgeWords).joined(separator: " ")
        return "the part starting \"\(opening)\" and ending \"\(closing)\", \(extent(words.count))"
    }

    /// ROUGHLY HOW MUCH — `LocatedPassage.boundsLabel`'s arithmetic, reached
    /// through its own constant rather than copied. Under twenty the exact
    /// count IS the honest answer ("about eight words" about eight words is a
    /// hedge with nothing to hedge); above it, a person stops counting and
    /// starts estimating, so we round to the ten they would have said.
    static func extent(_ wordCount: Int) -> String {
        let counted = wordCount <= LocatedPassage.exactWordCount
            ? wordCount
            : Int((Double(wordCount) / 10).rounded()) * 10
        return "about \(counted) word\(counted == 1 ? "" : "s")"
    }

    // MARK: - The miss

    /// SHE LOOKED AND COULD NOT FIND IT — and this is deliberately not a bare
    /// "it isn't there". That denial is the exact shape of the bug this whole
    /// area exists to disprove: Mary told a user a section was not in their
    /// document while a targeted read was, at that moment, holding it.
    ///
    /// `PagesPlugin.targetedOutcome`'s honest miss names the two reasons a
    /// perfectly real passage fails to be found — the wording differs, or it
    /// lives in a header, a text box or a table cell that is outside the text
    /// she can read — and the reasons are what make the sentence actionable.
    /// The user can rephrase, or they can select it.
    ///
    /// It closes by saying where the words DID go, because they went somewhere:
    /// this shape only exists on a turn that fell back to typing at the caret,
    /// and prose appearing in an unexpected place with no explanation is the
    /// original complaint in a quieter register.
    static func missSentence(intent: EditIntent?, called override: String? = nil) -> String {
        let named = intent?.target.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let called = override ?? (named.isEmpty ? "the part you meant" : "\"\(named)\"")
        return "I couldn't find \(called) to change — the wording may differ from what you said, "
            + "or it may sit in a header, a text box or a table cell I can't read from here. "
            + "I've put the new words in at your cursor instead, so take a look before you keep going."
    }
}
