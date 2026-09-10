//
//  AbilityRunPresentation.swift
//  Mary
//
//  WHAT: Shared words and colors for a run's disposition.
//  OUT:  AbilityBadgeRow / AbilityRunInspectorSheet
//

import MaryBrain
import MaryFoundation
import SwiftUI

enum AbilityRunPresentation {

    /// Sheet vocabulary — plain words, never status codes.
    static func label(_ run: BehavioralActionRecord) -> String {
        switch run.disposition {
        case .succeeded: return run.foundNothing ? "looked, found nothing" : "completed"
        case .failed: return "did not go through"
        case .blocked: return "refused"
        case .cancelled: return "stopped"
        case .deferred: return "handed off"
        case .requestedConfirmation: return "waiting on you"
        case .unsettled: return "running"
        case .unknown: return "unknown"
        }
    }

    static func color(_ run: BehavioralActionRecord) -> Color {
        switch run.disposition {
        case .succeeded: return run.foundNothing ? .maryGold : .maryGreen
        case .unsettled: return Color.primary.opacity(0.3)
        case .requestedConfirmation, .deferred: return .maryGold
        default: return .maryError
        }
    }

    /// Duration once finished. Sub-second rounds to tenths (or ms).
    static func duration(_ run: BehavioralActionRecord) -> String? {
        guard let duration = run.duration else { return nil }
        return duration < 1
            ? String(format: "%.0fms", duration * 1000)
            : String(format: "%.1fs", duration)
    }

    // MARK: - The chip's own state

    /// One chip, many calls. Running outranks; then failure; settled is quiet.
    enum ChipState {
        case running
        case attention
        case settled

        var isRunning: Bool { self == .running }
    }

    static func chipState(_ runs: [BehavioralActionRecord]) -> ChipState {
        guard !runs.isEmpty else { return .settled }
        if runs.contains(where: { $0.disposition == .unsettled }) { return .running }
        let needsAttention = runs.contains { run in
            switch run.disposition {
            case .failed, .blocked, .cancelled, .requestedConfirmation, .unknown:
                return true
            case .succeeded, .deferred, .unsettled:
                return false
            }
        }
        return needsAttention ? .attention : .settled
    }

    /// Chip tooltip/accessibility. Nil when settled (chip reads as it always did).
    static func stateWord(_ runs: [BehavioralActionRecord]) -> String? {
        switch chipState(runs) {
        case .running:
            let count = runs.filter { $0.disposition == .unsettled }.count
            return count > 1 ? "\(count) still running" : "still running"
        case .attention:
            // Specific word, not a generic "problem" (`refused` vs `did not go through`).
            return runs.first { $0.disposition != .succeeded }.map(label)
        case .settled:
            return nil
        }
    }
}

/// Running-chip pulse. Slow opacity breath, not a spinner (spinner reads as error).
struct RunningPulse: View {
    let tint: Color
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 5, height: 5)
            .opacity(animating ? 1 : 0.25)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: animating)
            .onAppear { animating = true }
    }
}
