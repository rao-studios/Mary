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
import MaryBrain
import MaryComputerUse
import MaryFoundation
import MaryPlugin

/// Whether the operator says they have set the stage by hand.
enum SandStageless {
    static func staged(_ setup: TripRunner.Setup) -> Bool { setup.staged }
}

enum TripCommand {

    /// One leg's line in the verdict table.
    static func line(_ record: TripLegRecording) -> String {
        let mark: String
        switch record.verdict {
        case .passed: mark = "✓"
        case .failed: mark = "✗"
        case .pending: mark = "·"
        case .unstageable: mark = "~"
        case .unmeasured: mark = "·"
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

    /// Put a named application in front, by its registered profile.
    ///
    /// PIN: THE PACKAGES NAME IT, NOT THIS FILE. A trip says `front: "textedit"`,
    /// which is an application id some installed package declares along with its
    /// bundle identifiers; this looks it up the same way a turn does. An id
    /// nothing declares cannot be staged and says so by returning false, rather
    /// than guessing at a bundle id from the spelling.
    static func bringForward(_ applicationID: String) async -> Bool {
        // THE INSTALLED PACKAGES' PROFILES, not the native adapters' own. A
        // native adapter carries a profile for the surface it IS; an application
        // a trip stages ("textedit", "xcode") is declared by a package, and the
        // library is where those live.
        let profiles = AbilityLibrary.shared.snapshot().plugins.applicationProfiles
        guard let profile = profiles.first(where: {
            $0.id.caseInsensitiveCompare(applicationID) == .orderedSame
        }) else { return false }
        // THE SAME LADDER EVERY ACT USES — the regular member of the family,
        // never a helper, and a window raised when activation alone does not take.
        for bundleID in profile.applicationIdentifiers {
            if await VerifiedActivation.bringForward(bundleID: bundleID).succeeded {
                return true
            }
        }
        return false
    }

    /// Minimize the browser's front window — the stage the activation ladder's
    /// raise road exists for, made through the same window primitives.
    static func minimizeFrontWindow(of pid: pid_t) -> Bool {
        guard let windows = try? AccessibilityWindowCore.axWindows(of: pid, standardOnly: true),
              let window = windows.first
        else { return false }
        return (try? AccessibilityWindowCore.minimize(window.element)) != nil
    }

    // MARK: - Running one trip

    static func run(
        trip: BrowsingTrip,
        adapter: WebSurfaceAdapter,
        engine: BrowserEngine,
        target: BrowserTarget,
        runner: TripRunner,
        setup: TripRunner.Setup,
        assumeYes: Bool
    ) async -> TripRecording {
        var recording = TripRecording(
            tripID: trip.id, category: trip.category,
            runner: setup.runner, round: setup.round, browser: setup.browser)

        // A STAGE THIS RUNNER CANNOT SET IS NOT A STAGE IT MAY IGNORE.
        //
        // PIN: THE SAME FALSE PASS AS AN UNSTAGED PAGE CLASS, ONE FIELD OVER. A
        // trip that says an editor leads, or that music is playing, or that a
        // second window is open, is asking what the browser does when it is NOT
        // the whole machine — and this runner drives the browser and nothing
        // else. Running it anyway with Chrome in front answers a different
        // question and reports a pass. `--staged` is the operator saying they
        // have set it up by hand; without it, these are Sand's or a person's.
        var missing: [String] = []
        if trip.stage.front != "browser" {
            // AN APPLICATION IN FRONT IS A STAGE THE RUNNER CAN MAKE, and for
            // six rounds it was filed as one only a person could.
            //
            // PIN: `recovery` NEVER RAN A SINGLE LEG, and eight of `context`'s
            // eleven unstageable legs said the same sentence: "textedit has to
            // be in front". Bringing a named application forward is exactly what
            // `VerifiedActivation` does for every act this engine performs, and
            // the browser is brought forward by it constantly. The distinction
            // that matters is the one below — music playing, a hand on the page,
            // a second window — which are states of the WORLD nobody can
            // synthesize. Which application has focus is not one of them.
            // IT IS STILL VERIFIED, not merely requested: an activation that
            // does not take leaves the leg unstageable rather than running it
            // against whatever is actually in front, which is the false pass
            // this whole block exists to prevent.
            if await TripCommand.bringForward(trip.stage.front) == false {
                missing.append("\(trip.stage.front) has to be in front")
            }
        }
        // A HAND ON THE PAGE CANNOT BE SET UP IN ADVANCE, so `--staged` does not
        // cover it. Running anyway answers a different question: measured, the
        // leg then routed as `result` — correctly, because nothing had
        // invalidated the session — and was reported as a routing failure for
        // doing the right thing about a stage nobody had set.
        if trip.stage.handNavigateBeforeLeg != nil {
            missing.append("somebody has to navigate the page by hand mid-trip")
        }
        if !SandStageless.staged(setup) {
            if trip.stage.musicPlaying == true { missing.append("music has to be playing") }
            if trip.stage.twoWindows == true { missing.append("a second window has to be open") }
            if trip.stage.pin != nil { missing.append("\(trip.stage.pin ?? "") has to be pinned") }
        }
        if !missing.isEmpty {
            for (index, leg) in trip.legs.enumerated() {
                recording.legs.append(TripRunner.unstageable(
                    index: index, say: leg.say,
                    because: missing.joined(separator: "; ")))
                print(line(recording.legs[recording.legs.count - 1]))
            }
            return recording
        }

        // THE STAGE IS PART OF THE QUESTION, AND AN UNSTAGED RUN IS A FALSE PASS.
        // Measured while building this: `what-can-i-click` staged `resultsPage`
        // and ran against whatever tab happened to be open, then reported a
        // pass — a verdict about a page the trip was not asking about. A class
        // the machine has no address for cannot be staged, and saying so is the
        // honest answer; `any` and `blank` ask for nothing.
        let wanted = trip.stage.pageClass
        if wanted != .any, wanted != .blank {
            guard let seed = TripStaging.seed(for: wanted) else {
                for (index, leg) in trip.legs.enumerated() {
                    recording.legs.append(TripRunner.unstageable(
                        index: index, say: leg.say,
                        because: TripStaging.missingSeedAdvice(for: wanted)))
                    print(line(recording.legs[recording.legs.count - 1]))
                }
                return recording
            }
            guard assumeYes || confirm(
                "staging \"\(wanted.rawValue)\" navigates the browser you are looking at. Go on?")
            else {
                for (index, leg) in trip.legs.enumerated() {
                    recording.legs.append(TripRunner.unstageable(
                        index: index, say: leg.say, because: "declined at the prompt"))
                }
                print("  ~  not staged")
                return recording
            }
            let staged = await engine.navigate(.open(seed), in: target)
            guard staged.ok else {
                for (index, leg) in trip.legs.enumerated() {
                    recording.legs.append(TripRunner.unstageable(
                        index: index, say: leg.say,
                        because: "could not stage \(wanted.rawValue) — \(staged.spoken)"))
                    print(line(recording.legs[recording.legs.count - 1]))
                }
                return recording
            }
            print("  staged \(wanted.rawValue)")
        }

        // THE STAGE, MADE AGAIN AFTER THE PAGE IS. Staging a page class brings
        // the browser forward, so a trip that says an editor leads — or that
        // the browser's window is minimized — means it is so when the leg is
        // SAID, not before the runner navigated. Measured: `window-behind`
        // recorded the browser in front before its own leg, and "restored"
        // was judged against a stage nobody had set.
        func unstageable(_ because: String) -> TripRecording {
            for (index, leg) in trip.legs.enumerated() {
                recording.legs.append(TripRunner.unstageable(
                    index: index, say: leg.say, because: because))
                print(line(recording.legs[recording.legs.count - 1]))
            }
            return recording
        }
        if trip.stage.mediaPlaying == true {
            // THE ENGINE'S OWN VERB, proved like any act. A video that will not
            // play is a stage nobody set, not a failure of the leg.
            let played = await engine.controlMedia(.play, in: target)
            guard played.ok else {
                return unstageable("the video has to be playing — \(played.spoken)")
            }
            // A FEW SECONDS IN, LIKE A PERSON. Nobody says "go to three minutes"
            // half a second after pressing play; and measured, the transport's
            // clock is not legible to the reading in its first second, which
            // made a leg about seeking into a leg about a clock.
            try? await Task.sleep(for: .seconds(3))
            print("  the video is playing")
        }
        if trip.stage.twoTabs == true {
            // IDEMPOTENT, BECAUSE A STAGE IS A STATE AND NOT A GESTURE. A first
            // rule pressed the new-tab chord every run, and six runs left six
            // tabs — three of them called the same thing, which made "the blank
            // tab" genuinely ambiguous and the leg's refusal correct about a
            // window nobody meant to build.
            let open = await engine.readShell(target).shell?.tabs.count ?? 0
            if open < 2 {
                // THE BROWSER'S OWN NEW-TAB CHORD, aimed at it — the probe stages
                // the machine; the engine owns no chords. A blank tab, so its
                // name is a word a person can say.
                guard let prefix = target.registration.bundleIdentifiers.first,
                      KeyChordPress.press(key: .t, modifiers: [.command], targetPrefix: prefix)
                else { return unstageable("a second tab has to be open") }
                try? await Task.sleep(for: .milliseconds(600))
                let blank = await engine.navigate(.open("about:blank"), in: target)
                guard blank.ok else {
                    return unstageable("a second tab has to be open — \(blank.spoken)")
                }
            }
            // AND THE TRIP BEGINS ON THE PAGE IT IS ABOUT.
            let back = await engine.switchTab("the first tab", in: target)
            guard back.ok else {
                return unstageable("the first tab has to be in front — \(back.spoken)")
            }
            print("  a second tab is open")
        }
        if trip.stage.minimized == true {
            guard minimizeFrontWindow(of: target.processIdentifier) else {
                return unstageable("the browser's window has to be minimized")
            }
            print("  minimized the browser's window")
        }
        if trip.stage.front != "browser" {
            guard await bringForward(trip.stage.front) else {
                return unstageable("\(trip.stage.front) has to be in front")
            }
        }

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
            // A LEG THAT ASSERTS ONLY WHERE ITS WORDS SHOULD GO IS NOT THIS
            // RUNNER'S TO PASS. See `TripVerdict.unmeasured`.
            if leg.routing != nil, leg.page == nil, leg.engine == nil, leg.ambient == nil {
                record.verdict = .unmeasured
                record.because = "only its routing is stated, and a probe routes nothing"
                recording.legs.append(record)
                print(line(record))
                continue
            }
            // WHICH ROAD A JOURNEY TOOK, asked of the engine that took it.
            record.journeyRoad = await engine.snapshot().lastWatchRoad
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
