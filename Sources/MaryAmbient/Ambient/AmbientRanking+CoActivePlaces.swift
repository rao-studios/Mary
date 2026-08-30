//
//  AmbientRanking+CoActivePlaces.swift
//  MaryAmbient
//
//  WHAT: Compact prompt lines for places with fresh evidence beside the lead.
//  IN:   AmbientPlace + AmbientFact
//  OUT:  heldContext (keys seed alreadyRendered so a fact never renders twice)
//  PIN:  Full blocks are the lead's privilege; co-active facts are mention lines.
//
import Foundation

extension AmbientRanker {

    // MARK: - Co-active places (the merged-worlds section)

    /// How much one CO-ACTIVE place's compact lines may spend, and the cap across all of them.
    public static let coActivePlaceBudget = 280
    public static let coActiveTotalBudget = 900

    /// THE MERGED-WORLDS RENDERING: compact per-place lines for the places with fresh evidence
    /// beside the lead.
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
