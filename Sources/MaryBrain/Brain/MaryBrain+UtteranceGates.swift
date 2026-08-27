//
//  MaryBrain+UtteranceGates.swift
//  MaryBrain
//
//  The deterministic whole-utterance gates, moved out of MaryBrain.swift:
//  `bareDecision` (yes/no), `bareCorrection` ("no, the other one"), and
//  `bareAcceptance` with its `AcceptedOffer` verdict — the mechanisms that
//  answer a bare utterance without the model.
//
//  Moved verbatim; no behavior change, no wording change.
//  `discussedPassageLifetime` moved with `bareAcceptance` (its only reader);
//  it is a static let, so it may live in this extension and stays private.
//  No access promotions were needed.
//

import MaryVoice
import Foundation

extension MaryBrain {

    private static let discussedPassageLifetime: TimeInterval = 5 * 60

    /// A whole-utterance yes/no, or nil when the answer says anything more
    /// (conditions, changes, questions stay with the model). Conservative on
    /// purpose: false positives would execute a protected action.
    /// A ONE-WORD CORRECTION OF A REFERENCE — "no, the other one".
    ///
    /// `bareDecision`'s twin, and the third clause of the tree's own doctrine
    /// finally given a mechanism. The shipped voice prompt says: "take the
    /// reading they most likely meant and say plainly which one you took, **so
    /// they can correct you in one word**." Acting was built. Announcing was
    /// half-built. Correcting was PROSE — "say undo", "say the word and I'll put
    /// it back" — with nothing behind it, so the model had to notice and reach
    /// for a binding, where a yes/no bypasses the model entirely.
    ///
    /// WHOLE-UTTERANCE AND EXACT, exactly as `bareDecision` is, and for a
    /// sharper reason: a false positive here silently re-aims which document the
    /// NEXT command lands in. "not that one, the third one" must not match —
    /// that names a specific alternative and belongs to the resolver's ordinal
    /// rung, not here.
    ///
    /// It does NOT undo. What already landed stays; this makes the next command
    /// land in the right place.
    static func bareCorrection(in text: String) -> Bool {
        let normalized = text.lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
            .split(separator: " ")
            .joined(separator: " ")
        let corrections: Set<String> = [
            "no the other one", "the other one", "not that one", "not that note",
            "wrong one", "wrong note", "the wrong one", "the wrong note",
            "i meant the other one", "i meant the other note", "the other note",
            "no not that one", "no wrong one", "not that document",
            "the other document", "no the other note",
        ]
        return corrections.contains(normalized)
    }

    /// AN ACCEPTED OFFER — the fourth mechanism.
    ///
    /// The tree has replaced an ignored instruction with a mechanism three
    /// times (`ActionClassifier`, `bareDecision`, `hasPendingSkillConfirmation`); a
    /// spoken offer accepted with a bare "yes please" was the fourth ignored
    /// instruction with no mechanism. This is it: a deterministic verdict
    /// that the yes means "do the edit you just offered, to the passage we
    /// were just discussing" — which the hook below turns into an ordinary
    /// anaphoric revision so every existing gate (locate-first, targetBrief,
    /// RevisionVeto, EditReport) is inherited rather than rebuilt.
    ///
    /// SEVEN GATES, all mechanical, all required. The expensive direction to
    /// be wrong is a FALSE POSITIVE — it forces the silent action rhythm onto
    /// a conversational yes ("want me to read it aloud?" answered by
    /// silence), so every ambiguous case answers nil and falls through to
    /// today's behaviour, which costs nothing.
    struct AcceptedOffer: Sendable, Equatable {
        var referent: DiscussedPassageReferent
    }

    static func bareAcceptance(
        bareDecision: Bool?,
        hadPendingAction: Bool,
        routinesAtEntry: Int,
        referent: DiscussedPassageReferent?,
        precedingUserTurnID: UUID?,
        lastAssistantText: String?,
        persistentLead: AmbientWorld?,
        now: Date
    ) -> AcceptedOffer? {
        // 1. A whole-utterance affirmative — the same closed set a CONFIRM
        //    answers with. A partial affirmative ("yes, tighten it") carries
        //    its own verb and belongs to `EditIntentClassifier`.
        guard bareDecision == true else { return nil }
        // 2. A parked CONFIRM owns the yes, unconditionally — the
        //    deterministic decision path already ran and won.
        guard !hadPendingAction else { return nil }
        // 3. A bare yes while routines run answers the routine.
        guard routinesAtEntry == 0 else { return nil }
        // 4. A live referent: something was actually discussed, recently.
        guard let referent,
              now.timeIntervalSince(referent.armedAt) <= discussedPassageLifetime
        else { return nil }
        // 5. ADJACENCY: the arming turn is the immediately preceding
        //    exchange. "What's the weather" in between means the offer is no
        //    longer what the yes is about.
        guard referent.armedByExchange == precedingUserTurnID else { return nil }
        // 6. OFFER EVIDENCE: Mary's own last reply asked a question whose
        //    words carry a transform verb — "Want me to tighten it up?". A
        //    closed-vocabulary membership check over a sentence already in
        //    history, not prose parsing. "Do you want me to read it aloud?"
        //    fails it and the yes stays conversational; a verbless offer
        //    ("Want me to take a pass at it?") falls through to today's
        //    behaviour — the accepted false negative.
        guard let lastAssistantText,
              lastAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("?"),
              AmbientRanker.namesTransform(lastAssistantText)
        else { return nil }
        // 7. WORLD CONFLICT CANCELS: the user who moved to another workspace
        //    and said "yes please" is answering something else.
        if let persistentLead, persistentLead != referent.world { return nil }
        return AcceptedOffer(referent: referent)
    }

    /// AN ACCEPTED PROSE OFFER — `bareAcceptance`'s sibling, in the same
    /// gate register, for the road that road cannot take.
    ///
    /// `bareAcceptance` answers a bare "yes please" and runs the REVISION
    /// spine against the user's own selection. This answers "please write
    /// that" and writes back the prose Mary offered. The two can never both
    /// fire on one utterance: `bareDecision`'s affirmative set contains no
    /// write verb, and gate 7 here requires one.
    ///
    /// INERT WITHOUT AN ARMED OFFER, and that is the whole safety argument:
    /// with `referent == nil` every byte of behaviour is exactly what it is
    /// today, and the only turns that can reach the write are ones where
    /// Mary asked a question, framed a draft in quotes, and the user
    /// answered with a write verb pointed at nothing else.
    static func acceptedProse(
        utterance: String,
        bareDecision: Bool?,
        hadPendingAction: Bool,
        routinesAtEntry: Int,
        referent: OfferedProseReferent?,
        precedingUserTurnID: UUID?,
        lastAssistantText: String?,
        applicationAliases: Set<String>,
        now: Date
    ) -> OfferedProseReferent? {
        // 1. An explicit "no" is never an acceptance, whatever else it says.
        guard bareDecision != false else { return nil }
        // 2. A parked CONFIRM owns the turn, unconditionally — the
        //    deterministic decision path already ran and won.
        guard !hadPendingAction else { return nil }
        // 3. An answer while routines run answers the routine.
        guard routinesAtEntry == 0 else { return nil }
        // 4. A live offer: she actually proposed something, recently.
        guard let referent,
              now.timeIntervalSince(referent.armedAt) <= discussedPassageLifetime
        else { return nil }
        // 5. ADJACENCY: the offer was made in the immediately preceding
        //    exchange. Anything in between and the yes is about something else.
        guard referent.armedByExchange == precedingUserTurnID else { return nil }
        // 6. HISTORY STILL AGREES. Re-derive the offer from what Mary is
        //    recorded as having said and require the same bytes. A referent
        //    that no longer matches history — superseded, trimmed, or spoken
        //    over — is stale, and spending it would write prose the user can
        //    no longer see above the fold.
        guard OfferedProse.offer(in: lastAssistantText) == referent.text else { return nil }
        // 7. THE YES CARRIES A WRITE VERB AIMED AT NOTHING ELSE.
        guard OfferedProse.accepts(utterance),
              !OfferedProse.namesAnotherTarget(
                utterance, applicationAliases: applicationAliases)
        else { return nil }
        return referent
    }

    static func bareDecision(in text: String) -> Bool? {
        let normalized = text.lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
            .split(separator: " ")
            .joined(separator: " ")
        let affirmatives: Set<String> = [
            "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm",
            "proceed", "do it", "go ahead", "go for it", "please do",
            "yes please", "sounds good", "yes go ahead", "okay do it",
            "yes do it", "yes proceed", "sure go ahead", "okay go ahead",
        ]
        let negatives: Set<String> = [
            "no", "nope", "cancel", "stop", "dont", "do not", "no thanks",
            "never mind", "nevermind", "leave it", "cancel it", "no cancel",
            "dont do it", "no stop", "cancel that",
        ]
        if affirmatives.contains(normalized) { return true }
        if negatives.contains(normalized) { return false }
        return nil
    }
}
