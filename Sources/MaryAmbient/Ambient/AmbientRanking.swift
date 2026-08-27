// Ranking and bounded rendering for short-term ambient facts.

import Foundation

public enum AmbientRanker {

    /// How much text the held-facts section may spend in the VOICE's
    /// instructions. Sits below the watchers' own 1200-character contribution
    /// cap on purpose: the live block is the authority, this is what she is
    /// still holding beside it.
    public static let voiceBudget = 1400
    /// The orchestrator lane's budget. Smaller — Lane B acts, it does not
    /// recite, and its prompt already carries every plugin's fragment.
    public static let abilityBudget = 700
    /// No more than this many facts render in FULL, whatever the budget
    /// allows: three passages is a briefing, six is a document dump.
    public static let maxBlocks = 3

}
