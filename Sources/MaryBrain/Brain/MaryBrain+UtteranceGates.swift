//
//  MaryBrain+UtteranceGates.swift
//  MaryBrain
//
//  WHAT: Deterministic whole-utterance gates — yes/no, correction, accepted-offer.
//  IN:   runTurnBody
//  OUT:  bareDecision / bareCorrection / bareAcceptance
//  PIN:  discussedPassageLifetime lives here (bareAcceptance's only reader).
//
import MaryVoice
import Foundation

extension MaryBrain {

    private static let discussedPassageLifetime: TimeInterval = 5 * 60

    /// A whole-utterance yes/no, or nil when the answer says anything more (conditions, changes, questions stay with the model).
    /// WHOLE-UTTERANCE AND EXACT, exactly as `bareDecision` is
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
        persistentLead: AmbientAttention?,
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
        // 6. OFFER EVIDENCE: Mary's own last reply asked a question whose words carry a transform verb — "Want me to tighten it up?".
        guard let lastAssistantText,
              lastAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("?"),
              AmbientRanker.namesTransform(lastAssistantText)
        else { return nil }
        // 7. WORLD CONFLICT CANCELS: the user who moved to another workspace
        //    and said "yes please" is answering something else.
        //    BOTH SIDES ARE PLACE-DERIVED. `persistentLead` comes off the store's
        //    lead place; reading the referent's lane through its place too means
        //    the comparison is in one vocabulary rather than two.
        if let persistentLead, persistentLead != referent.place.attention { return nil }
        return AcceptedOffer(referent: referent)
    }

    /// AN ACCEPTED PROSE OFFER — `bareAcceptance`'s sibling, in the same gate register, for the road that road cannot take.
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
        // 6. HISTORY STILL AGREES.
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
        
        // Prioritizes affirms
        if affirmatives.contains(normalized) { return true }
        if negatives.contains(normalized) { return false }
        return nil
    }
}
