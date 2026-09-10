//
//  MaryBrain+RepeatGuard.swift
//  MaryBrain
//
//  WHAT: The two repeats a lane refuses — the same call that just failed, and
//        the same act run again before anything has looked.
//  IN:   MaryBrain+Turn (Lane B and the engine seat) — before every dispatch
//  OUT:  a skillResult line in the lane's history; the lane ends (failed) or
//        continues (unproven)
//  PIN:  THE ROUND LOOP ASKS THE MODEL AGAIN AFTER EVERY DISPATCH, and nothing
//        on the dispatch path compared a call with the one before it. Measured:
//        "skip the ad" dispatched three times — once landing on a weak receipt,
//        then twice refused as ambiguous — because a refusal came back as a
//        plain failure and the model's answer to a failure is the same call.
//        A PROVEN REPEAT IS ALLOWED. "Next track" twice is two skips, and the
//        receipt proved each; only an UNPROVEN act is held, and only for the
//        one round it takes to look. Reads are never held: re-reading is how
//        one checks.
//

import Foundation

extension MaryBrain {

    /// The arguments as a comparable string: the same JSON object in any key
    /// order is the same call. Text that does not parse compares as written.
    static func canonical(_ argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let sorted = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: sorted, encoding: .utf8)
        else { return trimmed }
        return text
    }

    /// An earlier outcome of THIS lane for the same call that did not go
    /// through — not a confirmation park, not a deferred ack.
    static func alreadyFailed(
        _ call: ModelSkillInvocation, in outcomes: [LaneOutcome]
    ) -> LaneOutcome? {
        let arguments = canonical(call.argumentsJSON)
        return outcomes.first {
            $0.invocation == call.name
                && canonical($0.argumentsJSON) == arguments
                && !$0.ok && !$0.requested && !$0.deferred
        }
    }

    /// The MOST RECENT outcome of this lane is the same act, delivered but
    /// unproven — `ok` with no receipt — and nothing has looked since.
    static func alreadyRanUnproven(
        _ call: ModelSkillInvocation, in outcomes: [LaneOutcome],
        isRead: (String) -> Bool
    ) -> LaneOutcome? {
        guard let last = outcomes.last,
              last.invocation == call.name,
              canonical(last.argumentsJSON) == canonical(call.argumentsJSON),
              last.ok, !last.landed, !last.deferred, !last.foundNothing,
              !last.asksThePerson,
              !isRead(last.skillName)
        else { return nil }
        return last
    }

    /// What the model reads in place of a dispatch it will not get.
    static func repeatedFailureLine(_ name: String, prior: LaneOutcome) -> String {
        "Already tried \(name) with the same words this turn — \(prior.summary)"
    }

    static func unprovenRepeatLine(_ name: String) -> String {
        "\(name) already ran with those words and the change is unproven — look before running it again"
    }
}
