//
//  SandTripRunner.swift
//  Sand
//
//  WHAT: A browsing trip taken through the WHOLE turn — routing, lane, provider,
//        dispatch, speech — rather than through the engine's bindings alone.
//  IN:   --trip <path> [--record <dir>] [--round N] [--staged] [--leg N]
//  OUT:  <trip>.turn.recording.json, and a verdict per leg on stdout
//  PIN:  THE HALF THE PROBE CANNOT ANSWER. `mary-web-probe --trip` dispatches the
//        binding directly, which measures the engine honestly and says nothing
//        about which skill the words would have reached, on which lane, with
//        which browser answering, or whether Mary said anything back. Those are
//        turn facts, and this bench already runs a real turn — the same
//        `MaryBrain.respond(to:)`, the same runtime, the same adapters — so it
//        is where a leg's `routing`, `provider` and `speech` blocks are judged.
//        HEADLESS ON PURPOSE. It drives the same objects the turn pane drives
//        and draws nothing of its own: a trip is a repeatable measurement, and a
//        measurement that needs somebody to click through a window is one that
//        gets taken once.
//        A ROUND ANSWERS ONLY WHEN THE LEG ALLOWS ONE. `--auto` answers whatever
//        the model is offered; a trip states its lane, so a leg claiming the
//        confidence lane must never be rescued by an answered round — that would
//        turn the finding this whole corpus exists to surface into a pass.
//

import AppKit
import Foundation
import MaryAmbient
import MaryBrain
import MaryComputerUse
import MaryFoundation
import MaryPlugin

@MainActor
final class SandTripRunner {

    private let host: SandTurnHost
    private let runtimeHost: SandRuntimeHost

    init(host: SandTurnHost, runtimeHost: SandRuntimeHost) {
        self.host = host
        self.runtimeHost = runtimeHost
    }

    /// Take the trip named on the command line, if one was.
    static func runIfAsked(host: SandTurnHost, runtimeHost: SandRuntimeHost) {
        guard let path = SandLaunchOptions.current.trip else { return }
        let runner = SandTripRunner(host: host, runtimeHost: runtimeHost)
        Task { await runner.run(path: path) }
    }

    // MARK: - One trip

    func run(path: String) async {
        let url = URL(fileURLWithPath: path)
        let trip: BrowsingTrip
        do {
            trip = try BrowsingTrip.load(from: url)
        } catch {
            print("  ✗  could not read a trip from \(path) — \(error)")
            return
        }
        let issues = BrowsingTripValidator.validate(trip)
        guard issues.isEmpty else {
            for issue in issues { print("  ✗  \(issue)") }
            return
        }

        print("\nthe trip — \(trip.id) (through the turn)")
        print("  \(trip.summary)")

        var recording = TripRecording(
            tripID: trip.id, category: trip.category, runner: "turn",
            round: SandLaunchOptions.current.round ?? "0",
            // WHICH BROWSER THE STAGE IS POINTED AT, asked of the roster rather
            // than assumed: nothing in Swift names a browser.
            browser: Self.stagedBrowser() ?? "")

        // A STAGE ONLY THE PROBE CAN MAKE IS NOT ONE THIS RUNNER PRETENDS TO.
        // A playing video, a second tab, a minimized window and a browser
        // asking something are all set through the engine's verbs and the
        // machine's primitives, which the probe holds; a turn driven against a
        // stage nobody set is a false verdict, not a pass.
        let probeOnly: [(Bool?, String)] = [
            (trip.stage.mediaPlaying, "the video has to be playing"),
            (trip.stage.twoTabs, "a second tab has to be open"),
            (trip.stage.minimized, "the browser's window has to be minimized"),
            (trip.stage.askedByBrowser, "the browser has to be asking"),
        ]
        if let (_, because) = probeOnly.first(where: { $0.0 == true }) {
            for (index, leg) in trip.legs.enumerated() {
                recording.legs.append(TripLegRecording(
                    index: index, say: leg.say, verdict: .unstageable,
                    because: "\(because) — the probe stages that"))
                print(Self.line(recording.legs[recording.legs.count - 1]))
            }
            Self.record(recording)
            return
        }

        // AN APPLICATION IN FRONT IS A STAGE THIS RUNNER CAN MAKE — through the
        // same faculty every act stages with, verified, and only called
        // unstageable when the activation does not take. The probe learned
        // this in round 7; the turn-level runner had kept filing every
        // context trip as a person's job.
        if trip.stage.front != "browser" {
            guard await Self.bringForward(trip.stage.front) else {
                for (index, leg) in trip.legs.enumerated() {
                    recording.legs.append(TripLegRecording(
                        index: index, say: leg.say, verdict: .unstageable,
                        because: "\(trip.stage.front) has to be in front"))
                    print(Self.line(recording.legs[recording.legs.count - 1]))
                }
                Self.record(recording)
                return
            }
            print("  \(trip.stage.front) in front")
        }

        // THE PIN IS PART OF THE STAGE, and it is the one stage condition this
        // runner can set for itself — every other one needs a person.
        if let pinned = trip.stage.pin {
            if let world = PinnedWorld.from(applicationID: pinned) {
                WorkspaceFocusTracker.shared.pin(world)
                print("  pinned \(pinned)")
            } else {
                print("  ~  could not pin \(pinned) — it declares no eyes or no discipline")
            }
        }

        for (index, leg) in trip.legs.enumerated() {
            if let only = SandLaunchOptions.current.leg, only != index { continue }
            if let round = leg.pending {
                recording.legs.append(TripLegRecording(
                    index: index, say: leg.say, verdict: .pending,
                    because: "waiting on \(round)"))
                print(Self.line(recording.legs[recording.legs.count - 1]))
                continue
            }
            // A STAGE CONDITION ONLY A PERSON CAN SET.
            if trip.stage.handNavigateBeforeLeg == index, SandLaunchOptions.current.staged {
                recording.legs.append(TripLegRecording(
                    index: index, say: leg.say, verdict: .unstageable,
                    because: "needs a hand on the page before this leg"))
                print(Self.line(recording.legs[recording.legs.count - 1]))
                continue
            }
            let spoken: String
            switch TripArguments.spoken(leg) {
            case .ready(let words): spoken = words["say"] ?? leg.say
            case .unstageable(let why):
                recording.legs.append(TripLegRecording(
                    index: index, say: leg.say, verdict: .unstageable, because: why))
                print(Self.line(recording.legs[recording.legs.count - 1]))
                continue
            }

            let record = await take(leg: leg, index: index, say: spoken)
            recording.legs.append(record)
            print(Self.line(record))
        }

        Self.record(recording)
        let failed = recording.legs.filter { $0.verdict == .failed }.count
        print("  \(recording.legs.count) leg(s), \(failed) failed\n")
    }

    /// Write the recording where `--record` asked, if it did.
    private static func record(_ recording: TripRecording) {
        guard let directory = SandLaunchOptions.current.record else { return }
        let folder = URL(fileURLWithPath: directory)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            try recording.encoded().write(
                to: folder.appendingPathComponent(recording.fileName), options: .atomic)
            print("  ✓  recorded \(recording.fileName)")
        } catch {
            print("  ✗  could not record — \(error)")
        }
    }

    /// Put a named application in front, by its registered profile — the
    /// probe's `TripCommand.bringForward`, which the condensation folds into
    /// one runner. THE PACKAGES NAME IT, NOT THIS FILE.
    private static func bringForward(_ applicationID: String) async -> Bool {
        let profiles = AbilityLibrary.shared.snapshot().plugins.applicationProfiles
        guard let profile = profiles.first(where: {
            $0.id.caseInsensitiveCompare(applicationID) == .orderedSame
        }) else { return false }
        for bundleID in profile.applicationIdentifiers {
            if await VerifiedActivation.bringForward(bundleID: bundleID).succeeded {
                return true
            }
        }
        return false
    }

    // MARK: - One leg, through the turn

    private func take(leg: TripLeg, index: Int, say: String) async -> TripLegRecording {
        let before = Self.ambient()
        let started = Date()
        host.run(say)
        // THE TURN'S OWN END IS THE SIGNAL, not a timer. `SandTurnHost` clears
        // `isRunning` when the stream finishes, which is the same moment the
        // pane stops showing the spinner.
        while host.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
            // A LEG THAT CLAIMS THE CONFIDENCE LANE MUST NOT BE RESCUED BY AN
            // ANSWERED ROUND. Declining is what turns "it needed the model" into
            // a finding rather than a pass.
            if let round = host.round {
                // A LEG THAT ALLOWS A MODEL ROUND GETS ONE, ANSWERED WITH ITS
                // OWN DECLARED ARGUMENTS — never with whatever was offered
                // first, which is `--auto`'s gesture and a different question.
                if leg.routing?.lane == .model,
                   let name = leg.routing?.skill,
                   round.skills.contains(where: { $0.name == name }) {
                    let json = (try? JSONSerialization.data(
                        withJSONObject: leg.routing?.arguments ?? [:],
                        options: [.sortedKeys])).flatMap {
                            String(data: $0, encoding: .utf8)
                        } ?? "{}"
                    host.answer(.invoke(name: name, argumentsJSON: json))
                } else {
                    // AND ONE THAT CLAIMS THE CONFIDENCE LANE IS NOT RESCUED.
                    // Answering here would turn the finding this corpus exists
                    // to surface into a pass.
                    host.answer(.abandon)
                }
            }
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let after = Self.ambient()

        var record = TripLegRecording(
            index: index, say: say,
            routing: Self.routing(host: host, say: say),
            ambientBefore: before, ambientAfter: after,
            ok: !host.reply.isEmpty || !host.dispatchedNames.isEmpty,
            outcomeSpoken: host.reply,
            speech: RecordedSpeech(
                spoken: host.reply,
                spokeInTurn: !host.reply.isEmpty,
                readRoutes: ReadDeliveryLedger.shared.recentRoutes()),
            // WHAT A TURN CAN ANSWER FOR. `landed` and which application
            // answered are consumed by the brain and never reach a record — the
            // probe measures those, against the same trip.
            observableLayers: TripLegRecording.turnLayers,
            elapsedMilliseconds: elapsed)
        let judged = TripLayer.judge(leg: leg, recording: record)
        record.verdict = judged.verdict
        record.layer = judged.layer
        record.because = judged.because
        return record
    }

    /// WHAT THE TURN DECIDED, from the roster the turn itself projected.
    ///
    /// PIN: THE TRACE THE TURN PUBLISHED, NEVER ONE RE-ARBITRATED AFTERWARDS.
    /// `SandTurnHost` already learned this the hard way — reading
    /// `abilityRosterTrace` outside the turn's task-locals describes a different
    /// machine — so this reads what the observer was handed.
    private static func routing(host: SandTurnHost, say: String) -> RecordedRouting {
        let trace = host.trace
        return RecordedRouting(
            // THE TURN'S OWN SEMANTIC VERDICT, carried on the trace rather than
            // re-read: the floor and margin come with it, so a reader compares
            // the numbers against the ones this turn actually used.
            intent: trace.semantic?.intent,
            intentScore: trace.semantic.map { Double($0.intentScore) },
            uniqueSkill: host.dispatchedNames.first,
            lane: host.askedTheModel ? "model" : "confidence",
            arguments: host.dispatchedArguments,
            offered: trace.decisions
                .filter { $0.disposition == .selected }
                .map(\.reference.invocationName)
                .sorted(),
            electionActive: trace.election.filter(\.isActive).map(\.abilityID.rawValue),
            electionStruck: Dictionary(
                trace.election.filter { !$0.isActive }.map { ($0.abilityID.rawValue, $0.reason) },
                uniquingKeysWith: { first, _ in first }),
            topAffinities: Dictionary(
                trace.decisions.compactMap { decision in
                    decision.affinity.map { (decision.reference.invocationName, Double($0)) }
                },
                uniquingKeysWith: { first, _ in first }))
    }

    /// The application the bench was pointed at, by its logical id.
    static func stagedBrowser() -> String? {
        guard let bundleID = SandLaunchOptions.current.targetBundleID else { return nil }
        return AmbientApplicationIndexProvider.current.registration(bundleID: bundleID)?.id
    }

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

    static func line(_ record: TripLegRecording) -> String {
        let mark: String
        switch record.verdict {
        case .passed: mark = "✓"
        case .failed: mark = "✗"
        case .pending: mark = "·"
        case .unstageable: mark = "~"
        case .unmeasured: mark = "·"
        }
        let said = record.say.count > 46
            ? String(record.say.prefix(46)) + "…" : record.say
        return String(
            format: "  %@ %-48@%6dms%@%@",
            mark as NSString, said as NSString, record.elapsedMilliseconds,
            (record.layer.map { " [\($0.rawValue)]" } ?? "") as NSString,
            (record.because.map { " — \($0)" } ?? "") as NSString)
    }
}
