//
//  MaryBrain+History.swift
//  MaryBrain
//
//  The brain's history bookkeeping, moved out of MaryBrain.swift: the
//  epoch-guarded writes (appendHistory, removeLastExchange,
//  removeExchange(anchoredAt:), exchangeIsOpen, appendCancelledEpilogue),
//  the follow-up merge and its origin lookup, sanitizedSpoken,
//  spokenMessages, truncateAfterAutomemory, seedDiscussedPassageReferent,
//  lastSpokenAssistantText, pruneSyntheticTurns, trimHistory, spokenCount.
//
//  Moved verbatim; no behavior change. Depends on the internal-for-split
//  promotions of `history`, `openExchange`, `turnBox`, `laneLog`,
//  `dispatcher`, `discussedPassageReferent`, `lastUserTurnID`, and
//  `historyMessageLimit` in the core file; treat those as private.
//

import MaryVoice
import Foundation
import os

extension MaryBrain {

    // MARK: - Epoch-guarded history writes

    /// A turn may only write history while it is still the current turn —
    /// stale (superseded) turns unwinding out of skills must not pollute the
    /// replacing turn's context.
    // internal for file split — treat as private
    func appendHistory(_ turn: BrainTurn, epoch: UInt64) {
        guard turnBox.isCurrent(epoch) else { return }
        history.append(turn)
    }

    /// Batch variant: tool_use/tool_result pairs must land atomically — an
    /// epoch flip between two single appends would orphan a pair.
    // internal for file split — treat as private
    func appendHistory(contentsOf turns: [BrainTurn], epoch: UInt64) {
        guard turnBox.isCurrent(epoch), !turns.isEmpty else { return }
        history.append(contentsOf: turns)
    }

    /// The mirror of truncateAfterAutomemory: drop the last exchange (final
    /// .user turn through end — partial replies and Skill pairs go with it).
    // internal for file split — treat as private
    func removeLastExchange() {
        guard let lastUser = history.lastIndex(where: { $0.role == .user }) else { return }
        history.removeSubrange(lastUser..<history.endIndex)
    }

    /// Overlap-supersede removal: the superseded turn's user turn through
    /// end. The open exchange is by construction the last exchange, but
    /// anchoring by id (not position) makes the removal a no-op if the
    /// anchor is already gone — race-tolerant against the old turn's unwind
    /// and trimHistory. Side effects are NOT rolled back: an overlap
    /// cancelling a turn mid-dispatch removes the RECORD, not the executed
    /// action — consistent with the existing supersede doctrine.
    // internal for file split — treat as private
    func removeExchange(anchoredAt userTurnID: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == userTurnID }) else { return }
        history.removeSubrange(idx..<history.endIndex)
    }

    /// True while the exchange anchored at `userTurnID` has no non-empty
    /// assistant turn yet — nothing the user would recognize as a reply.
    /// (The open exchange is by construction the last one, so the whole
    /// tail after the anchor belongs to it.)
    // internal for file split — treat as private
    func exchangeIsOpen(anchoredAt userTurnID: UUID) -> Bool {
        guard let idx = history.firstIndex(where: { $0.id == userTurnID }) else { return false }
        return !history[(idx + 1)...].contains { $0.role == .assistant && !$0.text.isEmpty }
    }

    /// Close a cancelled turn's exchange in history. A SUPERSEDED turn's
    /// epoch is stale, so every append here drops and the replacing turn
    /// owns the exchange. A still-CURRENT cancelled turn (a follow-up
    /// preempt, or barge-in with no replacement) must never strand its user
    /// turn: spokenMessages() drops empty assistants, and a reply-less
    /// exchange puts two consecutive user roles on the next request —
    /// breaking Seer-wire and Mistral-family alternation. The marker is
    /// factual, never spoken, and anchors a detached routine's follow-up
    /// merge.
    // internal for file split — treat as private
    func appendCancelledEpilogue(
        spokenText: String, actionTurn: Bool,
        outcomes: [LaneOutcome], epoch: UInt64
    ) {
        if !spokenText.isEmpty {
            appendHistory(
                BrainTurn(role: .assistant, text: sanitizedSpoken(spokenText)),
                epoch: epoch)
        } else if turnBox.isCurrent(epoch) {
            let skills = outcomes.map(\.skillName)
            let marker: String
            if !skills.isEmpty {
                marker = "(ran: \(skills.joined(separator: ", ")))"
            } else {
                marker = actionTurn ? "(on it)" : "(interrupted)"
            }
            appendHistory(BrainTurn(role: .assistant, text: marker), epoch: epoch)
        }
    }

    /// The follow-up joins the ORIGINATING exchange's assistant turn
    /// ("\n\n") so history keeps alternating — anchored by originUserTurnID
    /// and BOUNDED to that exchange (never past the next user turn). If the
    /// origin is gone (trimmed by the rolling window, or removed by an
    /// overlap-supersede) or its assistant slot never materialized, the
    /// merge is DROPPED: a follow-up must never attach to an unrelated
    /// exchange. The results still exist — executor AbilityExecutionLog rows, Totem
    /// deposits, and the spoken follow-up/chips already delivered them;
    /// only model-visible history skips the epilogue.
    ///
    /// DELIBERATELY EPOCH-UNGUARDED: routines outlive their spawning turn's
    /// epoch by design — the epoch guard kills a SUPERSEDED TURN's writes,
    /// not a surviving routine's. The id anchor IS the guard here: when
    /// supersede removed the origin, the anchor misses and the merge drops.
    /// The origin exchange's assistant text — the same anchored lookup the
    /// merge performs, exposed so a follow-up can ask "was this already said?"
    /// BEFORE anything is yielded. Empty on a miss, which disables the guard
    /// rather than inventing a baseline.
    // internal for file split — treat as private
    func originAssistantText(originUserTurnID: UUID?) -> String {
        guard let originID = originUserTurnID,
              let userIdx = history.firstIndex(where: { $0.id == originID })
        else { return "" }
        let after = history.index(after: userIdx)
        let exchangeEnd = history[after...].firstIndex(where: { $0.role == .user }) ?? history.endIndex
        return history[after..<exchangeEnd]
            .first(where: { $0.role == .assistant && !$0.text.isEmpty })?.text ?? ""
    }

    // internal for file split — treat as private
    func mergeFollowUpIntoHistory(_ text: String, originUserTurnID: UUID?) {
        guard !text.isEmpty else { return }
        guard let originID = originUserTurnID,
              let userIdx = history.firstIndex(where: { $0.id == originID }) else {
            Self.laneLog.info("follow-up merge dropped — origin exchange gone")
            return
        }
        let after = history.index(after: userIdx)
        let exchangeEnd = history[after...].firstIndex(where: { $0.role == .user }) ?? history.endIndex
        guard let target = history[after..<exchangeEnd]
            .firstIndex(where: { $0.role == .assistant && !$0.text.isEmpty }) else {
            Self.laneLog.info("follow-up merge dropped — origin has no assistant slot")
            return
        }
        history[target].text += "\n\n" + text
    }

    /// Belt-and-braces over the engine-level interception: prose that will
    /// be SPOKEN or persisted as an assistant turn is stripped of Skill-call
    /// syntax. A leaked blob in history would be replayed to Seer on every
    /// later turn via spokenMessages() and parroted back — the
    /// self-reinforcing loop behind the "plescript{…}" screenshot.
    // internal for file split — treat as private
    func sanitizedSpoken(_ text: String) -> String {
        SkillCallTextInterceptor.stripToolCallSyntax(
            from: text,
            knownSkillNames: Set((dispatcher?.schemas ?? []).map(\.name)))
    }

    /// The spoken history as Seer wire messages: user turns and non-empty
    /// assistant turns; Skill plumbing stays local.
    // internal for file split — treat as private
    func spokenMessages() -> [SeerChatMessage] {
        history.compactMap { turn in
            switch turn.role {
            case .user:
                return SeerChatMessage(role: "user", content: turn.text)
            case .assistant:
                return turn.text.isEmpty ? nil : SeerChatMessage(role: "assistant", content: turn.text)
            case .skillResult:
                return nil
            }
        }
    }

    /// Post-automemory retention: everything before the final exchange is now
    /// server-side memory; keep the last user turn through the end (Skill
    /// pairs of the current exchange ride along intact).
    // internal for file split — treat as private
    func truncateAfterAutomemory() {
        guard let lastUser = history.lastIndex(where: { $0.role == .user }) else { return }
        history.removeSubrange(0..<lastUser)
    }

    /// TEST SEAM: model "a selection brief armed the referent on the last
    /// completed turn" without driving the live attention machinery. The
    /// adjacency stamp is the previous turn's own id, exactly as the real
    /// arming site would have left it.
    func seedDiscussedPassageReferent(text: String, world: AmbientWorld) {
        discussedPassageReferent = DiscussedPassageReferent(
            text: text, world: world, applicationID: nil, subject: nil,
            armedAt: Date(), armedByExchange: lastUserTurnID ?? UUID())
    }

    /// ARM THE PROSE OFFER, if this reply carried one.
    ///
    /// Called from every site that finalizes an assistant turn, with the
    /// SPOKEN text — not the history text, whose `(ran: …)` markers are
    /// plumbing rather than prose. `OfferedProse.offer` answers nil for the
    /// overwhelming majority of replies, and a nil clears rather than keeps:
    /// a reply that offered nothing must not leave the previous offer standing
    /// for a "please write that" two exchanges later.
    func noteOfferedProse(spoken: String?, place: AmbientPlace?) {
        guard let text = OfferedProse.offer(in: spoken) else {
            offeredProseReferent = nil
            return
        }
        offeredProseReferent = OfferedProseReferent(
            text: text,
            place: place,
            armedAt: Date(),
            armedByExchange: openExchange?.userTurnID ?? lastUserTurnID ?? UUID())
    }

    /// TEST SEAM, `seedDiscussedPassageReferent`'s sibling: model "Mary
    /// offered this prose on the last completed turn" without driving the
    /// spoken lane.
    func seedOfferedProseReferent(text: String, place: AmbientPlace? = nil) {
        offeredProseReferent = OfferedProseReferent(
            text: text, place: place,
            armedAt: Date(), armedByExchange: lastUserTurnID ?? UUID())
    }

    /// The last thing Mary SAID — the sentence gate 6 reads the offer out
    /// of. Skill plumbing and empty carrier turns are skipped.
    // internal for file split — treat as private
    func lastSpokenAssistantText() -> String? {
        for turn in history.reversed() where turn.role == .assistant {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    // internal for file split — treat as private
    func pruneSyntheticTurns() {
        history.removeAll {
            $0.role == .user && ($0.text == Self.confirmRelayNudge || $0.text == Self.budgetNudge)
        }
    }

    /// Trim whole exchanges (a .user turn through just before the next .user
    /// turn) from the front until the spoken-message count fits the limit.
    /// Exchange-boundary trimming can never orphan a Skill result — Anthropic
    /// requires tool_result to follow its tool_use.
    // internal for file split — treat as private
    func trimHistory() {
        while spokenCount(of: history) > historyMessageLimit {
            guard let firstUser = history.firstIndex(where: { $0.role == .user }) else { break }
            let nextUser = history[(firstUser + 1)...].firstIndex { $0.role == .user }
            let dropEnd = nextUser ?? history.endIndex
            guard dropEnd > 0, dropEnd <= history.endIndex, firstUser < dropEnd else { break }
            // Drop everything through the end of the first exchange (any
            // pre-exchange stragglers included).
            history.removeSubrange(0..<dropEnd)
            if nextUser == nil { break }   // one giant exchange — keep it
        }
    }

    private func spokenCount(of turns: [BrainTurn]) -> Int {
        turns.reduce(0) { count, turn in
            switch turn.role {
            case .user: return count + 1
            case .assistant: return turn.text.isEmpty ? count : count + 1
            case .skillResult: return count
            }
        }
    }
}
