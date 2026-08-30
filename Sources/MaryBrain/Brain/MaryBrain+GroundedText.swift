//
//  MaryBrain+GroundedText.swift
//  MaryBrain
//
//  WHAT: Skill outcomes → grounded-results / read-passage / fallback follow-up.
//  IN:   MaryBrain.swift (statics, no stored state)
//  OUT:  prompt blocks + spoken fallback lines
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
            // FAILURES ARE LABELLED, because this block is the follow-up's ONLY evidence and `followUpNudge` asks the voice to "confirm the outcome in one short spoken…
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

    /// A READ's text for the voice — same plumbing as `groundedResultsBlock`, deliberately different numbers.
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

    /// DID THIS LANE GO THROUGH? — asked once, in one place, because two paths ask it and they used to answer differently.
    static func unrecoveredFailure(in outcomes: [LaneOutcome]) -> LaneOutcome? {
        guard outcomes.last?.ok == false else { return nil }
        return outcomes.first(where: { !$0.ok })
    }

    /// HOW LONG A DETERMINISTIC FOLLOW-UP MAY SPEAK IN ONE BREATH
    static let spokenLineClamp = 160

    /// One outcome's summary as the deterministic line would speak it: FIRST LINE ONLY, then clamped.
    static func spokenBrief(_ summary: String) -> String {
        let firstLine = summary
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? summary
        return firstLine.count > spokenLineClamp
            ? String(firstLine.prefix(spokenLineClamp)) + "…"
            : firstLine
    }

    /// TRUE when `spokenBrief` would take NOTHING off — the summary already IS, exactly, what the mouth would say.
    /// PIN: Stated as "the clamp is a no-op on this" rather than as an independent length-and-newline test
    static func isWholeSpokenSentence(_ summary: String) -> Bool {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return spokenBrief(summary) == summary
    }

    /// WOULD THE COMPOSER ONLY SAY BACK WHAT IS ALREADY IN HAND? — asked before paying twenty seconds to find out.
    /// THE INVARIANT IT BUYS, and it is the whole safety argument: whenever this is true
    /// PIN: THREE CONJUNCTS, EACH LOAD-BEARING.
    static func composeWouldOnlyRestate(_ grounded: [LaneOutcome]) -> Bool {
        guard grounded.count == 1, let only = grounded.first else { return false }
        guard only.foundNothing, unrecoveredFailure(in: grounded) == nil else { return false }
        return isWholeSpokenSentence(only.summary)
    }

    /// Seer-offline follow-up: a plain deterministic report
    static func namesForeignApplication(
        _ composed: String,
        groundedBlock: String,
        outcomes: [LaneOutcome],
        profiles: [ApplicationProfile],
        owner: (String) -> AmbientAttention?
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
        // A MISS IS NOT A COMPLETION EITHER, and this line is the last place one could still be dressed as one.
        // The attached document cannot follow it out: a Pages miss puts the body after a newline and `spokenBrief` keeps the…
        if let delivered = outcomes.last(where: { !$0.foundNothing }) {
            return "That's done — \(spokenBrief(delivered.summary))"
        }
        // THE FOURTH ARM, and its selector is STRUCTURAL rather than editorial.
        // The selector is `composeWouldOnlyRestate` ITSELF, not a private copy of its third conjunct
        if composeWouldOnlyRestate(outcomes) {
            return last.summary
        }
        return "I couldn't find that — \(spokenBrief(last.summary))"
    }
}
