//
//  Trip.swift
//  WebProbe — `mary-web-probe --trip`
//
//  WHAT: A whole browsing journey against a live browser, judged and written down.
//  OUT:  a verdict table on stdout; <trip>.probe.recording.json beside the trip
//  PIN:  ENGINE-LEVEL, AND HONEST ABOUT IT. This dispatches the browsing
//        adapter's own `SkillBinding` closures — the ones `AbilityRuntime` calls
//        — so the argument gates, the address admission and `SkillOutcome.landed`
//        are real. What it CANNOT answer is which skill the words would have
//        reached and on which lane: that needs a turn, and Sand's runner is
//        where a leg's `routing` block is judged. A leg's routing expectations
//        are therefore left unjudged here rather than guessed at.
//        IT ASKS BEFORE IT NAVIGATES SOMEBODY'S TAB. A trip marked `navigates`
//        opens pages in the browser the person is looking at.
//

import AppKit
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation
import MaryPlugin

enum TripCommand {

    /// One leg's line in the verdict table.
    static func line(_ record: TripLegRecording) -> String {
        let mark: String
        switch record.verdict {
        case .passed: mark = "✓"
        case .failed: mark = "✗"
        case .pending: mark = "·"
        case .unstageable: mark = "~"
        }
        let layer = record.layer.map { " [\($0.rawValue)]" } ?? ""
        let said = record.say.count > 46
            ? String(record.say.prefix(46)) + "…"
            : record.say
        return String(
            format: "  %@ %-48@%6dms%@%@",
            mark as NSString, said as NSString, record.elapsedMilliseconds,
            layer as NSString,
            (record.because.map { " — \($0)" } ?? "") as NSString)
    }

    /// Ask before doing something to the person's own browser.
    static func confirm(_ question: String) -> Bool {
        print("\n  \(question) [y/N] ", terminator: "")
        guard let answer = readLine()?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    // MARK: - Running one trip

    static func run(
        trip: BrowsingTrip,
        adapter: WebSurfaceAdapter,
        engine: BrowserEngine,
        runner: TripRunner,
        setup: TripRunner.Setup,
        assumeYes: Bool
    ) async -> TripRecording {
        var recording = TripRecording(
            tripID: trip.id, category: trip.category,
            runner: setup.runner, round: setup.round, browser: setup.browser)

        let bindings = Dictionary(
            adapter.skillBindings.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })

        for (index, leg) in trip.legs.enumerated() {
            if let only = setup.onlyLeg, only != index { continue }

            // A LEG WAITING ON A ROUND IS COUNTED, NOT RUN.
            if let round = leg.pending {
                recording.legs.append(TripLegRecording(
                    index: index, say: leg.say, verdict: .pending,
                    because: "waiting on \(round)"))
                print(line(recording.legs[recording.legs.count - 1]))
                continue
            }

            // The words this leg actually says.
            let spoken: String
            switch TripArguments.spoken(leg) {
            case .ready(let words): spoken = words["say"] ?? leg.say
            case .unstageable(let why):
                recording.legs.append(
                    TripRunner.unstageable(index: index, say: leg.say, because: why))
                print(line(recording.legs[recording.legs.count - 1]))
                continue
            }

            guard let skill = leg.routing?.skill, let binding = bindings[skill] else {
                recording.legs.append(TripRunner.unstageable(
                    index: index, say: spoken,
                    because: (leg.routing?.skill).map {
                        "\($0) is not a binding this adapter offers"
                    } ?? "the leg names no skill, so an engine-level run has nothing to call"))
                print(line(recording.legs[recording.legs.count - 1]))
                continue
            }

            let arguments: [String: String]
            switch TripArguments.resolve(
                leg: leg, spoken: spoken, parameters: binding.parameters,
                pageClass: trip.stage.pageClass) {
            case .ready(let filled): arguments = filled
            case .unstageable(let why):
                recording.legs.append(
                    TripRunner.unstageable(index: index, say: spoken, because: why))
                print(line(recording.legs[recording.legs.count - 1]))
                continue
            }

            if trip.navigates, !assumeYes, index == 0,
               !confirm("\"\(trip.id)\" navigates the browser you are looking at. Go on?") {
                recording.legs.append(TripRunner.unstageable(
                    index: index, say: spoken, because: "declined at the prompt"))
                print(line(recording.legs[recording.legs.count - 1]))
                break
            }

            await runner.beginLeg()
            let before = ambient()
            let outcome: SkillOutcome
            switch binding.backing {
            case .native(let call):
                do {
                    // THE UTTERANCE IS PART OF THE CONTEXT, because
                    // `SpokenAddress.admit` reads it — a deep link nobody said
                    // is refused, and a trip must meet that gate like a turn does.
                    outcome = try await call(
                        arguments,
                        AbilityExecutionContext(projects: [:], utterance: spoken))
                } catch {
                    outcome = SkillOutcome(
                        ok: false, summary: "threw: \(String(describing: error))")
                }
            case .typedNative:
                recording.legs.append(TripRunner.unstageable(
                    index: index, say: spoken,
                    because: "\(skill) is typed-native; the probe drives the native lane"))
                print(line(recording.legs[recording.legs.count - 1]))
                continue
            }
            let after = ambient()

            var record: TripLegRecording = await runner.finishLeg(
                index: index, say: spoken,
                outcome: TripRunner.LegOutcome(
                    ok: outcome.ok,
                    landed: outcome.landed,
                    summary: outcome.summary,
                    refusal: refusalName(in: outcome),
                    providerApplicationID: outcome.applicationID),
                before: before, after: after)
            record.observableLayers = TripLegRecording.probeLayers
            let judged = TripLayer.judge(leg: leg, recording: record)
            record.verdict = judged.verdict
            record.layer = judged.layer
            record.because = judged.because
            recording.legs.append(record)
            print(line(record))
            if let last = recording.legs.last, last.verdict == .failed {
                // WHAT IT SAID, under the verdict — the sentence a person reads
                // first when a leg fails.
                print("      \(last.outcomeSpoken)")
            }
        }
        await runner.stopWatching()
        return recording
    }

    /// The machine model, as much of it as an engine-level run can see.
    ///
    /// PIN: THE LEAD AND THE FRONT, NOT THE TURN'S WHOLE WORLD. A probe run has
    /// no turn, so there is no route and no provider ladder; what it can state
    /// honestly is who leads, who is in front, and whether a pin stands.
    static func ambient() -> RecordedAmbient {
        let store = AmbientContextStore.shared
        return RecordedAmbient(
            lead: store.leadPlace()?.token,
            frontApplicationID: NSWorkspace.shared.frontmostApplication?
                .bundleIdentifier.flatMap {
                    AmbientApplicationIndexProvider.current.registration(bundleID: $0)?.id
                },
            pinned: WorkspaceFocusTracker.shared.pinned()?.applicationID)
    }

    /// The refusal class an outcome carries, when it failed.
    ///
    /// PIN: MATCHED ON THE ENGINE'S OWN SENTENCES, because a `SkillOutcome`
    /// carries the summary and not the case. The alternative is widening the
    /// outcome for a diagnostic, which would put a debugging concern into every
    /// adapter in the codebase.
    static func refusalName(in outcome: SkillOutcome) -> String? {
        guard !outcome.ok else { return nil }
        let summary = outcome.summary
        for refusal in TripRefusal.allCases
        where summary == sentence(for: refusal) || matches(summary, refusal) {
            return refusal.rawValue
        }
        return nil
    }

    static func sentence(for refusal: TripRefusal) -> String? {
        switch refusal {
        case .noBrowser: return BrowserRefusal.noBrowser.summary
        case .pageNotVisible: return BrowserRefusal.pageNotVisible.summary
        case .controlsNotFound: return BrowserRefusal.controlsNotFound.summary
        case .navigationDidNotSettle: return BrowserRefusal.navigationDidNotSettle.summary
        case .addressFieldNotFound: return BrowserRefusal.addressFieldNotFound.summary
        case .searchCompletedElsewhere: return BrowserRefusal.searchCompletedElsewhere.summary
        case .outOfTime: return BrowserRefusal.outOfTime.summary
        default: return nil
        }
    }

    /// The refusals whose sentence carries a page's own words — matched on the
    /// part that is the lane's, never on the part that is the page's.
    static func matches(_ summary: String, _ refusal: TripRefusal) -> Bool {
        switch refusal {
        case .elementNotFound: return summary.hasPrefix("I couldn't find \"")
        case .ambiguousElement: return summary.contains("There's more than one")
        case .controlNotFound: return summary.hasPrefix("I can see the player but not")
        case .stateUnchanged: return summary.hasPrefix("I pressed it, but it's still")
        case .notFillable: return summary.contains("isn't something I can type into")
        case .notAdjustable: return summary.contains("isn't a slider")
        case .interrupted: return summary.contains("took over at step")
        case .activationRefused: return summary.hasSuffix("wouldn't come forward.")
        case .ambiguousBrowser: return summary.hasPrefix("I can see ") && summary.hasSuffix("which one?")
        case .shellUnreadable: return summary.hasPrefix("I couldn't read ")
        case .visionUnavailable: return summary.hasPrefix("I couldn't look at the page")
        case .planInvalid: return summary.hasPrefix("I can't run that:")
        case .notImplemented: return summary.hasPrefix("I can't ") && summary.hasSuffix("yet.")
        default: return false
        }
    }

    // MARK: - Scoring a directory

    static func score(root: URL, writing document: String?, round: String?) -> Int {
        let found = TripRecording.all(under: root)
        for (url, problem) in found.unreadable {
            print("  ✗  \(url.lastPathComponent) — \(problem)")
        }
        guard !found.recordings.isEmpty else {
            print("  no recordings under \(root.path)")
            return found.unreadable.isEmpty ? 0 : 1
        }
        let board = TripScoreboard.score(found.recordings.map(\.1), round: round)
        print("")
        print(board.markdown())
        guard let document else { return found.unreadable.isEmpty ? 0 : 1 }

        let url = URL(fileURLWithPath: document)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        do {
            try board.merged(into: existing).write(to: url, atomically: true, encoding: .utf8)
            print("\n  wrote \(document)")
        } catch {
            print("\n  ✗  could not write \(document): \(error)")
            return 1
        }
        return found.unreadable.isEmpty ? 0 : 1
    }
}
