//
//  BrowserEngine+Navigation.swift
//  MaryPlugin
//
//  WHAT: Going somewhere and proving the page arrived — open, back, forward,
//        reload — and the two settles that decide "arrived".
//  IN:   BrowserShellReading (the shell), PageSettling (the page's own tree)
//  OUT:  navigate; settle / settleForResults; navigationReceipt; sameDestination
//  PIN:  A NAVIGATION IS PROVED BY THE SHELL, NOT BY TIME PASSING. `settle`
//        watches the address, the title and the history; `settleForResults`
//        watches the page's own tree stop growing. Neither is a sleep, and
//        `landed` comes from a receipt or it does not come.
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

extension BrowserEngine {
    // MARK: - Navigating

    public func navigate(_ request: NavigationRequest, in target: BrowserTarget) async -> BrowserOutcome {
        // Going somewhere keeps the stage: the person asked to see a page.
        await staged(target, after: .kept) { shell, _ in
            await navigated(request, in: target, shell: shell)
        }
    }

    private func navigated(
        _ request: NavigationRequest, in target: BrowserTarget, shell: WebSurfaceAX.Reading
    ) async -> BrowserOutcome {
        let schema = target.registration.schema

        switch request {
        case .open(let address):
            if dryRun { return refuse(.dryRun("opened \(address)")) }
            guard await seams.shell.openLocation(
                address, pid: target.processIdentifier, registration: target.registration,
                within: workingWindow)
            else { return refuse(.addressFieldNotFound) }
            emit(.acted("typed an address"))
            // OPENING THE PAGE YOU ARE ALREADY ON IS AN ARRIVAL.
            //
            // PIN: MEASURED — searching for the same words twice, and re-opening
            // the current page, both burn the whole budget and then report
            // `navigationDidNotSettle` about a page that is exactly where it was
            // asked to be. Nothing CAN change, so demanding a change is asking for
            // evidence that cannot exist.
            // AND SO IS SEARCHING FOR WHAT IS ALREADY SEARCHED. The same words
            // typed into a browser showing their results move nothing; the
            // query is typed all the same (a shortcut that skipped the typing
            // took a shop for the results — round 8), and quiet is the evidence.
            let alreadyHere = Self.sameDestination(shell.url, address)
                || (!SpokenAddress.looksLikeAnAddress(address)
                    && WebSearchRecipe.searched(for: address, shell: shell))
            let settled = await settle(
                target, from: shell, saying: "Opened",
                expecting: alreadyHere ? .arrival : .change)
            // A PAGE ASKED FOR CAN LAND BEHIND A HUMAN-CHECK. Answer its visible
            // control once, then look again — or hand it back. See PageChallenge.
            return await satisfyingChallenge(settled, in: target)

        case .back, .forward, .reload:
            let label: String
            let enabled: Bool?
            switch request {
            case .back: label = schema.backLabel; enabled = shell.canGoBack
            case .forward: label = schema.forwardLabel; enabled = shell.canGoForward
            default: label = schema.reloadLabel; enabled = true
            }
            // A DISABLED CONTROL IS AN OBSERVATION, NOT AN ERROR. There is simply
            // nowhere to go, and saying so is the right answer.
            if enabled == false {
                return BrowserOutcome(
                    ok: true,
                    spoken: request == .back
                        ? "There's nothing to go back to."
                        : "There's nothing to go forward to.",
                    shell: shell)
            }
            if dryRun { return refuse(.dryRun("pressed \(label)")) }
            guard await seams.shell.press(
                label: label, pid: target.processIdentifier, registration: target.registration,
                within: workingWindow)
            else { return refuse(.elementNotFound(label)) }
            emit(.acted("pressed \(label)"))
            // A RELOAD LANDS ON THE SAME TITLE BY DEFINITION, and a back or a
            // forward often does. What is owed is arrival, not difference.
            return await settle(
                target, from: shell,
                saying: request == .reload ? "Reloaded" : "Went \(request == .back ? "back" : "forward")",
                expecting: request == .reload ? .arrival : .history)

        case .scroll(let delta):
            guard let pageFrame = shell.pageFrame else { return refuse(.pageNotVisible) }
            if dryRun { return refuse(.dryRun("scrolled the page")) }
            await seams.hands.scroll(
                at: CGPoint(x: pageFrame.midX.rounded(), y: pageFrame.midY.rounded()),
                by: delta, pid: target.processIdentifier)
            emit(.acted("scrolled"))
            return BrowserOutcome(ok: true, spoken: "Scrolled.", shell: shell)

        case .newTab, .tab:
            // Realized by the browser's own package recipe, not here — a new tab is a
            // chord the expertise declares, and this engine does not own chords.
            return refuse(.notImplemented("switch tabs from here"))
        }
    }


    /// Is the browser already showing the address being opened?
    ///
    /// PIN: COMPARED THE WAY THE OMNIBOX DISPLAYS THEM — scheme and a leading
    /// "www." are presentation, not destination, and the same page reached two
    /// ways must read as the same page here or the settle asks for a change that
    /// cannot happen.
    public static func sameDestination(_ current: String?, _ intended: String) -> Bool {
        guard let current, !current.isEmpty else { return false }
        func stripped(_ value: String) -> String {
            var value = value.lowercased()
            for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
                value = String(value.dropFirst(scheme.count))
                break
            }
            if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
            while value.hasSuffix("/") { value = String(value.dropLast()) }
            return value
        }
        return stripped(current) == stripped(intended)
    }

    /// THE RECEIPT A NAVIGATION EARNS — rank one of the ladder.
    ///
    /// PIN: `landed` COMES FROM A RECEIPT OR IT DOES NOT COME. Round 0 measured
    /// six legs reporting proven work as unproven because a settled navigation
    /// carried nothing, and the search recipe answering that by setting `landed`
    /// by hand — a claim with no evidence behind it, which is the shape of the
    /// bug the ranked ladder exists to prevent.
    static func navigationReceipt(_ reading: WebSurfaceAX.Reading) -> PageCommandReceipt {
        PageCommandReceipt(
            sourceIndex: 0,
            kind: .navigate,
            target: nil,
            delivery: .delivered,
            effect: .verified(.navigation(title: reading.title ?? "the page")))
    }

    /// WHAT A NAVIGATION HAS TO SHOW BEFORE IT COUNTS AS DONE.
    ///
    /// PIN: "ARRIVED" AND "CHANGED" ARE NOT THE SAME CLAIM, and conflating them
    /// cost round 0 two legs and ten seconds each. Going somewhere new must
    /// CHANGE the address or the title — that is the strong evidence, and a
    /// settle that accepted a page which never moved would report a failed open
    /// as a success. But a reload, a back and a forward can legitimately land on
    /// a page with the identical title, and demanding a change there burns the
    /// whole budget and then reports `navigationDidNotSettle` about a page that
    /// arrived perfectly well.
    enum Arrival {
        /// The address or the title must differ. Opening somewhere new.
        case change
        /// The load must finish, and nothing else can be asked. A reload lands on
        /// the same address AND the same history, so quiet is the only evidence
        /// there is.
        case arrival
        /// The page moved, or the history did. Back and forward.
        ///
        /// PIN: QUIET ALONE IS TOO WEAK HERE, MEASURED LIVE. A back whose page had
        /// not changed within the quiet window was accepted, and Mary said "Went
        /// back" about a page she had not left — then "there's nothing to go
        /// forward to" a moment later, which is how the recording gave it away.
        /// A real back makes forward available; that flip is evidence, and it
        /// costs nothing because the shell reading already carries it.
        case history
    }

    /// How long a same-title arrival is given to start before it is judged, so a
    /// reload's blank frame is not read as the settled page.
    static let arrivalGrace = Duration.milliseconds(750)
    /// How many agreeing polls stand in for a load signal.
    ///
    /// PIN: MEASURED, BECAUSE CHROME PUBLISHES NO LOAD SIGNAL AT ALL. Its reload
    /// button keeps the title "Reload" throughout a navigation — it never becomes
    /// "Stop" — and its tree carries no busy node and no progress indicator
    /// (polled live through `mary-ax-probe` across a dozen loads). So a declared
    /// stop label would have been a schema field nothing could fill. Quiet
    /// agreement is the only evidence a browser gives here, and three polls is
    /// what makes it evidence rather than a coincidence.
    static let arrivalQuietPolls = 3

    /// Poll the shell until a reading satisfies `settled`, or the budget runs
    /// out. The reading that satisfied it, or nil — and the last reading seen
    /// either way, so a refusal can say what stood instead.
    ///
    /// PIN: ONE LOOP FOR EVERY "IS IT THERE YET". The dialog's dismissal, the
    /// human-check clearing and a tab switch were three copies of this skeleton
    /// with three chances to drift. `settle` below stays its own: arrival is a
    /// richer question than one predicate, and its rule is measured.
    func waitForShell(
        _ target: BrowserTarget, budget seconds: Double, poll: Duration = BrowserEngine.navigationPoll,
        until settled: (WebSurfaceAX.Reading) -> Bool
    ) async -> (settled: WebSurfaceAX.Reading?, latest: WebSurfaceAX.Reading?) {
        let deadline = seams.now().addingTimeInterval(seconds)
        var latest: WebSurfaceAX.Reading?
        while seams.now() < deadline {
            guard !Task.isCancelled, !(await seams.stage.preemptRequested()) else { return (nil, latest) }
            await seams.sleep(poll)
            guard let reading = await seams.shell.read(
                pid: target.processIdentifier, registration: target.registration,
                preferring: workingWindow)
            else { continue }
            latest = reading
            if settled(reading) { return (reading, reading) }
        }
        return (nil, latest)
    }

    /// Wait for the page to arrive — changed, or merely settled. See `Arrival`.
    func settle(
        _ target: BrowserTarget, from before: WebSurfaceAX.Reading, saying verb: String,
        expecting arrival: Arrival = .change
    ) async -> BrowserOutcome {
        var stable = 0
        var latest = before
        let started = seams.now()
        let deadline = started.addingTimeInterval(
            Double(Self.navigationBudget.components.seconds))
        while seams.now() < deadline {
            await seams.sleep(Self.navigationPoll)
            // SOMEBODY ELSE ASKED FOR THE STAGE — stop waiting, say where it got to.
            if await seams.stage.preemptRequested() { return refuse(.interrupted(atCommand: 0)) }
            guard let reading = await seams.shell.read(
                pid: target.processIdentifier, registration: target.registration,
                preferring: workingWindow)
            else { continue }
            // THE PAGE DID NOT MOVE — THE BROWSER ASKED SOMETHING INSTEAD. That is
            // the outcome of the act, not a failure to settle: a reload of a
            // posted page raises "Confirm Form Resubmission", and the only
            // honest sentence is its question.
            if let dialog = reading.dialog {
                lastChrome = reading
                return asked(dialog, shell: reading)
            }
            let changed = reading.url != before.url || reading.title != before.title
            // A SAME-TITLE ARRIVAL COUNTS ONCE IT HAS BEEN QUIET, and not before
            // the grace — a reload's first frame can read as the old page.
            let historyMoved = reading.canGoBack != before.canGoBack
                || reading.canGoForward != before.canGoForward
            let quiet = (arrival == .arrival || (arrival == .history && historyMoved))
                && seams.now() >= started.addingTimeInterval(
                    Double(Self.arrivalGrace.components.attoseconds) / 1e18
                        + Double(Self.arrivalGrace.components.seconds))
                && !(reading.title ?? "").isEmpty
            let moved = changed || quiet
            if moved && reading.title == latest.title && reading.url == latest.url {
                stable += 1
            } else {
                stable = moved ? 1 : 0
            }
            latest = reading
            // TWO AGREEING POLLS, because a title flickers to the bare host and then to
            // the page's real name; reporting the first one names the wrong page.
            // A QUIET ARRIVAL NEEDS MORE, because quiet is weaker evidence than change.
            let needed = changed ? 2 : Self.arrivalQuietPolls
            if stable >= needed {
                lastChrome = reading
                emit(.verified("the page changed"))
                let site = reading.siteName.map { " at \($0)" } ?? ""
                // ON THE STREAM AS WELL AS IN THE OUTCOME.
                //
                // PIN: EVERY WATCHER READS THE EVENTS. `PageActor` emits a
                // `.receipt` per command, and this did not — so a navigation's
                // receipt reached the caller and never the timeline, the bench, or
                // a trip recording. Measured: recordings showed `landed: true`
                // beside an empty receipt list, which reads exactly like the
                // hand-set claim this round removed.
                let receipt = Self.navigationReceipt(reading)
                emit(.receipt(receipt))
                return BrowserOutcome(
                    ok: true,
                    spoken: "\(verb) \(reading.title ?? "the page")\(site).",
                    shell: reading,
                    receipts: [receipt],
                    landed: true)
            }
        }
        return refuse(.navigationDidNotSettle)
    }

    /// WAIT FOR THE PAGE TO STOP ARRIVING, then read it once.
    ///
    /// PIN: A FLAT SLEEP READ A HALF-DRAWN PAGE. Measured across a round: the same
    /// search recorded readings of 79, 104, 107 and 108 rows, and on the 79 the
    /// results had not been grouped yet — so `openResult` had nothing to pick and
    /// the leg was filed as the detector's recall. This polls the browser's own
    /// tree, which is cheap, until the count holds still twice running, and only
    /// then hands over to the expensive read. The old sleep is the floor and the
    /// budget both: a page that never settles is read anyway, at the same moment
    /// it would have been before.
    func settleForResults(in target: BrowserTarget? = nil) async {
        guard let target, let frame = (await readShell(target)).shell?.pageFrame else {
            await seams.sleep(Self.resultsSettle)
            return
        }
        var stable = 0
        var last: Int?
        for _ in 0..<Self.resultsSettlePolls {
            await seams.sleep(Self.resultsSettleInterval)
            if await seams.stage.preemptRequested() { return }
            guard let now = await seams.settling.offering(
                pid: target.processIdentifier, pageFrame: frame)
            else {
                // NO SIGNAL IS NOT A SETTLED PAGE. Wait out the old budget.
                await seams.sleep(Self.resultsSettle)
                return
            }
            if now == last { stable += 1 } else { stable = 0 }
            last = now
            if stable >= Self.resultsQuietPolls { return }
        }
    }
}
