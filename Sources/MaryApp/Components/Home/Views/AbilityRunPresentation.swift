//
//  AbilityRunPresentation.swift
//  Mary
//
//  WHAT A DISPOSITION LOOKS LIKE, in one place.
//
//  The words and the colours lived privately inside AbilityRunInspectorSheet,
//  which was fine while the sheet was the only surface that showed a run's
//  state. The chip shows it now too, and two private copies of "what
//  `.unsettled` means" is how a chip comes to say one thing while the sheet
//  it opens says another.
//

import MaryBrain
import MaryFoundation
import SwiftUI

enum AbilityRunPresentation {

    /// The sheet's vocabulary, unchanged — plain words for what happened,
    /// never status codes.
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

    /// How long it took, once it has finished. Sub-second work is the common
    /// case and reads as noise at three decimals, so it rounds to tenths.
    static func duration(_ run: BehavioralActionRecord) -> String? {
        guard let duration = run.duration else { return nil }
        return duration < 1
            ? String(format: "%.0fms", duration * 1000)
            : String(format: "%.1fs", duration)
    }

    // MARK: - The chip's own state

    /// ONE CHIP, MANY CALLS. A chip names a Skill, and a reply may have called
    /// that Skill several times; the chip has room for one state.
    ///
    /// The order is a claim about what a person needs to know first, not a
    /// severity ranking: work still RUNNING outranks everything, because it is
    /// the only state that will change and the only one worth waiting on. A
    /// failure outranks a success, because three successes and a failure is a
    /// reply that did not fully land. Everything settled and fine is the quiet
    /// case, and looks exactly as chips always have.
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

    /// The state, said in words, for the chip's accessibility label and its
    /// tooltip. Nil when there is nothing to add — a settled chip reads as it
    /// always did.
    static func stateWord(_ runs: [BehavioralActionRecord]) -> String? {
        switch chipState(runs) {
        case .running:
            let count = runs.filter { $0.disposition == .unsettled }.count
            return count > 1 ? "\(count) still running" : "still running"
        case .attention:
            // The specific word, not a generic "problem" — "refused" and
            // "did not go through" are different things to a person.
            return runs.first { $0.disposition != .succeeded }.map(label)
        case .settled:
            return nil
        }
    }
}

/// The running chip's pulse. A slow opacity breath rather than a spinner: the
/// chip row is a quiet part of the page and a spinning indicator in it reads
/// as an error state.
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
