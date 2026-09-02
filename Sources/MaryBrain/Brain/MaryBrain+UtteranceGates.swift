//
//  MaryBrain+UtteranceGates.swift
//  MaryBrain
//
//  WHAT: The ACCEPTANCE gates — structure, not vocabulary. Ownership
//        precedence, referent liveness, adjacency, place agreement.
//  IN:   runTurnBody, with a DeterministicTier.Reading already taken
//  OUT:  bareAcceptance / acceptedProse
//  PIN:  discussedPassageLifetime lives here (bareAcceptance's only reader).
//        NO PHRASE SET BELONGS IN THIS FILE — rung 1 reads the tier's
//        decision, rung 6 asks `TurnTriage` whether she made an offer.
//
import MaryVoice
import Foundation

extension MaryBrain {

    private static let discussedPassageLifetime: TimeInterval = 5 * 60

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
}
