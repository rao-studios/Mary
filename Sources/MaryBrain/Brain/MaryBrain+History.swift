//
//  MaryBrain+History.swift
//  MaryBrain
//
//  WHAT: Epoch-guarded history bookkeeping.
//  IN:   MaryBrain.swift stored history / openExchange
//  OUT:  append / remove / trim / spokenMessages
//  PIN:  Split members: treat as private.
//
import MaryVoice
import Foundation
import os

extension MaryBrain {

    // MARK: - Epoch-guarded history writes

    /// A turn may only write history while it is still the current turn
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

    /// Overlap-supersede removal: the superseded turn's user turn through end.
    // internal for file split — treat as private
    func removeExchange(anchoredAt userTurnID: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == userTurnID }) else { return }
        history.removeSubrange(idx..<history.endIndex)
    }

    /// True while the exchange anchored at `userTurnID` has no non-empty assistant turn yet — nothing the user would recognize as a reply.
    // internal for file split — treat as private
    func exchangeIsOpen(anchoredAt userTurnID: UUID) -> Bool {
        guard let idx = history.firstIndex(where: { $0.id == userTurnID }) else { return false }
        return !history[(idx + 1)...].contains { $0.role == .assistant && !$0.text.isEmpty }
    }

    /// Close a cancelled turn's exchange in history. A SUPERSEDED turn's epoch is stale, so every append here drops and the replacing turn owns the exchange.
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

    /// The follow-up joins the ORIGINATING exchange's assistant turn ("\n\n") so history keeps alternating
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

    /// Belt-and-braces over the engine-level interception: prose that will be SPOKEN or persisted as an assistant turn is stripped of Skill-call syntax.
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

    /// Post-automemory retention: everything before the final exchange is now server-side memory
    // internal for file split — treat as private
    func truncateAfterAutomemory() {
        guard let lastUser = history.lastIndex(where: { $0.role == .user }) else { return }
        history.removeSubrange(0..<lastUser)
    }

    /// TEST SEAM: model "a selection brief armed the referent on the last completed turn" without driving the live attention machinery.
    func seedDiscussedPassageReferent(text: String, attention: AmbientAttention) {
        discussedPassageReferent = DiscussedPassageReferent(
            text: text, attention: attention, applicationID: nil, subject: nil,
            armedAt: Date(), armedByExchange: lastUserTurnID ?? UUID())
    }

    /// ARM THE PROSE OFFER, if this reply carried one.
    /// PIN: Called from every site that finalizes an assistant turn, with the SPOKEN text
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

    /// Trim whole exchanges (a .user turn through just before the next .user turn) from the front until the spoken-message count fits the limit.
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
