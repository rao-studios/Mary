//
//  AmbientRanking+CoActivePlaces.swift
//

import Foundation

extension AmbientRanker {

    // MARK: - Co-active places (the merged-worlds section)

    /// How much one CO-ACTIVE place's compact lines may spend, and the cap
    /// across all of them. Deliberately small: the lead keeps today's full
    /// budgets untouched; co-active places are context beside it, ranked by
    /// recency, degrading place-by-place back to today's one-liners (never
    /// silence) when the total runs out.
    public static let coActivePlaceBudget = 280
    public static let coActiveTotalBudget = 900

    /// THE MERGED-WORLDS RENDERING: compact per-place lines for the places
    /// with fresh evidence beside the lead. Facts render as their MENTION
    /// lines (bounds + age, never full content — full blocks are the lead's
    /// privilege), newest first, under the per-place and total budgets. The
    /// rendered keys come back so `heldContext` can seed `alreadyRendered`
    /// and the same fact never renders twice in one prompt.
    public static func coActiveLines(
        places: [(place: AmbientPlace, glanced: Bool)],
        facts: [AmbientFact],
        placeBudget: Int = coActivePlaceBudget,
        totalBudget: Int = coActiveTotalBudget,
        at now: Date = Date()
    ) -> (lines: [String], keys: Set<AmbientKey>) {
        var lines: [String] = []
        var keys: Set<AmbientKey> = []
        var remaining = totalBudget
        for entry in places {
            guard remaining > 0 else { break }
            let placeFacts = facts
                .filter { $0.place == entry.place }
                .sorted { $0.capturedAt > $1.capturedAt }
            let marker = entry.glanced ? " (glanced)" : ""
            var line = "— \(entry.place.displayName)\(marker):"
            var spent = line.count
            var carried = 0
            for fact in placeFacts {
                let mention = " " + fact.mentionLine(at: now)
                guard spent + mention.count <= placeBudget,
                      remaining - (spent + mention.count) >= 0
                else { break }
                line += mention
                spent += mention.count
                keys.insert(fact.key)
                carried += 1
            }
            // A place with no renderable facts still earns its name — the
            // signal says the user is (or was just) there, and naming it is
            // the compact section's floor.
            if carried == 0 {
                line += entry.glanced
                    ? " you just looked at it."
                    : " the user was just working there."
            }
            lines.append(line)
            remaining -= line.count
        }
        return (lines, keys)
    }

}
