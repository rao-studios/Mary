//
//  BrowserEngine.swift
//  MaryPlugin
//
//  WHAT: The browsing engine — resolve a browser, read its shell, perceive its page,
//        act once, and PROVE the act landed.
//  IN:   BrowserEngine.Seams (shell / page / hands / stage)
//  OUT:  BrowserOutcome; BrowserEngineSnapshot + events() for anything watching
//  PIN:  ONE ACT IS ONE DECISION, ALWAYS RECORDED — including the ones that refused.
//        An engine that skips silently cannot be watched, and browsing is the lane most
//        able to go wrong quietly: a click that lands on nothing looks exactly like a
//        click that worked.
//        EVERY EFFECT IS VERIFIED BY RE-PERCEIVING. The browser gives no return value
//        worth trusting — pressing a play button through synthetic input succeeds
//        whether or not anything played — so the receipt is a second look, and a state
//        that did not move is a REFUSAL, not a success with a caveat.
//        NO SITE SHORTCUTS, NO MEDIA KEYS, NO SCRIPTING. Playback is driven by clicking
//        the control the page draws, found in pixels. A media key would reach whatever
//        holds the system's now-playing role, which on a machine with a music player
//        open is not this tab at all.
//        `dryRun` IS THE OBSERVE-ONLY MODE, and it is what the probe uses to show a
//        person what would happen before anything does.
//        SPLIT BY CONCERN. This file is the actor itself: seams, timings, state,
//        the monitor, the stage and the shell read. The verbs are extensions
//        beside it — +Page, +Media, +MediaClock, +Navigation, +Dialog,
//        +Challenge, and PageActor (the one executor).
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation
import os

public actor BrowserEngine {

    // MARK: - Seams

    public struct Seams: Sendable {
        public var shell: any BrowserShellReading
        public var page: any PagePerceiving
        public var hands: any BrowserHands
        public var keys: any BrowserKeys
        public var stage: any BrowserStaging
        /// The cheap signal a settle watches. See `PageSettling`.
        public var settling: any PageSettling
        /// Where a page read publishes what the screen is offering.
        ///
        /// PIN: A SEAM, NOT `.shared` REACHED FOR IN PLACE. The slate is process-wide in
        /// production — one machine, one screen — but reaching for the global directly
        /// made the engine's answers depend on whatever else had published recently,
        /// which is unprovable in a test and, in a suite that runs in parallel, silently
        /// wrong.
        public var slate: AmbientElementIndexStore
        public var sleep: @Sendable (Duration) async -> Void
        public var now: @Sendable () -> Date

        public init(
            shell: any BrowserShellReading,
            page: any PagePerceiving,
            hands: any BrowserHands,
            keys: any BrowserKeys = LiveBrowserKeys(),
            stage: any BrowserStaging,
            settling: any PageSettling = NothingToSettle(),
            slate: AmbientElementIndexStore = .shared,
            sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.shell = shell
            self.page = page
            self.hands = hands
            self.keys = keys
            self.stage = stage
            self.settling = settling
            self.slate = slate
            self.sleep = sleep
            self.now = now
        }

        public static var live: Seams {
            Seams(
                shell: LiveBrowserShell(),
                page: LivePagePerception(),
                hands: LiveBrowserHands(),
                keys: LiveBrowserKeys(),
                stage: LiveBrowserStaging(),
                settling: LivePageSettling())
        }
    }

    // MARK: - Timings

    /// How long to wait after the pointer arrives before the transport is on screen.
    ///
    /// PIN: MEASURED, NOT GUESSED, AND NOT TIGHT. YouTube animates its controls in; a
    /// capture 60ms after the pointer lands shows bare video, one at 250ms shows the
    /// whole bar. 400 leaves room for a busier machine, and the cost of waiting is a
    /// third of a second while the cost of being early is a confident "this page has no
    /// player".
    static let revealSettle = Duration.milliseconds(400)
    /// How long the pointer rests on a control before pressing it, so the page has
    /// registered the hover the press belongs to.
    static let pressSettle = Duration.milliseconds(140)
    /// How long to wait after a click before believing the page repainted.
    static let actSettle = Duration.milliseconds(450)
    /// How long a navigation gets to settle before it is called stalled.
    static let navigationBudget = Duration.seconds(10)
    static let navigationPoll = Duration.milliseconds(250)

    /// How long after a page command before the page is believed to have reacted.
    static let commandSettle = Duration.milliseconds(220)
    /// A click gets longer, because a press that navigates needs the shell to catch up.
    static let clickSettle = Duration.milliseconds(450)
    /// How many times a shell that has NOT moved is asked again before it is
    /// believed. Two, because a navigation commits its address within a few
    /// hundred milliseconds and the settle before this has already spent that.
    /// See `settledShell`.
    static let shellQuietPolls = 2

    /// How long the results have to draw before they are read.
    static let resultsSettle = Duration.milliseconds(900)
    /// How often the results settle asks the tree. Sized under the old flat wait
    /// so a page that IS ready is read sooner than it used to be, not later.
    static let resultsSettleInterval = Duration.milliseconds(150)
    /// How many times before it gives up and reads whatever is there — 900ms of
    /// polling, the same budget the flat sleep spent.
    static let resultsSettlePolls = 6
    /// Two tree counts the same is a page that has stopped arriving — the same
    /// number as `shellQuietPolls`, for the same reason. See `settleForResults`;
    /// `arrivalQuietPolls`, beside `settle`, is the third and asks one more.
    static let resultsQuietPolls = 2

    // MARK: - State

    let seams: Seams
    let dryRun: Bool
    private let startedAt: Date
    private var lastBrowser: String?
    var lastChrome: WebSurfaceAX.Reading?
    var lastMedia: MediaControlReading?
    /// The page as the last read saw it. Set and cleared with the slate, by
    /// `publishSlate` / `retractSlate` — see the PIN on those.
    var lastRoster: PageRoster?
    /// The last goal this engine routed, and what it made of every row.
    ///
    /// PIN: CLEARED WITH THE SLATE, for the slate's own reason. A route is a verdict
    /// about rows that no longer exist the moment the page changes, and a debugger still
    /// showing it would be explaining a decision about a screen that is gone.
    var lastRoute: PageRouteTrace?
    /// WHAT THIS PAGE IS A LIST OF ANSWERS TO, when it is one.
    ///
    /// PIN: A FOLLOW-UP IS A CONTINUATION, NOT A NEW REQUEST. "Open the second
    /// one" after a search means the second RESULT — but a bare click routes
    /// with `.press`, which counts every row on the page, so it opened the
    /// second thing in reading order (a nav chip, the search box) while the
    /// answers sat below. Only `search_web` ever used `.openResult`, and it
    /// forgot the query the moment it returned. Held here with the same
    /// lifetime as the slate, and for the same reason: the moment the page
    /// changes, this describes a list that is no longer on screen.
    var lastResultQuery: String?
    /// THE WINDOW MARY WORKS IN — the one the last shell read was about, kept
    /// for every read, press and raise after it. See `AXWindowIdentity`.
    var workingWindow: CGWindowID?
    /// NAMED BY A RUNNER, not learned from a read — and then a read of any
    /// other window is a refusal, not a new working window.
    var pinnedWindow: CGWindowID?
    /// Which road the last journey took — the results, or the site's own search.
    var lastWatchRoad: WatchRecipe.Road?
    private var lastRefusal: BrowserRefusal?
    private var acts = 0
    private var refusals = 0
    private var perceptions = 0
    private var recent: [String] = []
    private var observers: [UUID: AsyncStream<BrowserEngineEvent>.Continuation] = [:]

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "browsing")

    public init(seams: Seams = .live, dryRun: Bool = false) {
        self.seams = seams
        self.dryRun = dryRun
        self.startedAt = seams.now()
    }

    /// The engine the adapter drives. One per process, because a browsing turn is a
    /// transaction over one machine.
    public static let live = BrowserEngine()

    // MARK: - Monitoring

    public func snapshot() -> BrowserEngineSnapshot {
        BrowserEngineSnapshot(
            startedAt: startedAt,
            dryRun: dryRun,
            lastBrowser: lastBrowser,
            lastChrome: lastChrome,
            lastWatchRoad: lastWatchRoad?.rawValue,
            lastMedia: lastMedia,
            lastRoster: lastRoster,
            lastRoute: lastRoute,
            workingWindow: workingWindow,
            lastRefusal: lastRefusal,
            acts: acts,
            refusals: refusals,
            perceptions: perceptions,
            recent: recent)
    }

    /// THE SLATE AND THE ROSTER ARE ONE FACT, so they are written in one place.
    ///
    /// PIN: A ROSTER LEFT BEHIND AFTER A RETRACT IS A DRAWN PAGE THAT IS NOT THERE. The
    /// retract exists because a navigation makes every offer wrong; a debugger still
    /// showing the old rows would be telling the person the opposite of what the engine
    /// now believes. Two call sites got this right by hand; a third would not have.
    func publishSlate(_ roster: PageRoster) {
        lastRoster = roster
        AffordanceSlatePublisher.publish(roster, store: seams.slate)
    }

    func retractSlate() {
        lastRoster = nil
        lastRoute = nil
        lastResultQuery = nil
        AffordanceSlatePublisher.retract(store: seams.slate)
    }

    /// Live activity. Anything watching reads this instead of polling.
    public func events() -> AsyncStream<BrowserEngineEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BrowserEngineEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// End every open `events()` stream. For a probe that wants its collector to finish
    /// and report — a watcher that runs for the life of a process never needs this.
    public func closeObservers() {
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }

    func emit(_ event: BrowserEngineEvent) {
        for continuation in observers.values { continuation.yield(event) }
        let line: String
        switch event {
        case .resolved(let browser, let pid): line = "resolved \(browser) (pid \(pid))"
        case .shellRead(let title, let site, _):
            line = "shell \(site ?? "—") · \(title ?? "untitled")"
        case .perceived(let controls, let playback, let duration):
            perceptions += 1
            line = "perceived \(controls) controls · \(playback) · \(duration)"
        case .read(let rows, let named, let groups):
            perceptions += 1
            line = "read \(rows) rows · \(named) named · \(groups) groups"
        case .routed(let trace):
            line = "routed \"\(trace.goal)\" → "
                + (trace.selected.first?.label ?? "nothing")
                + " (\(trace.eligibleCount) of \(trace.decisions.count) eligible)"
        case .matched(let phrase, let label):
            line = "matched \"\(phrase)\" → \"\(label)\""
        case .receipt(let receipt):
            line = "receipt \(receipt.spoken)"
        case .acted(let what):
            acts += 1
            line = "acted \(what)"
        case .verified(let what): line = "verified \(what)"
        case .refused(let refusal):
            refusals += 1
            lastRefusal = refusal
            line = "refused \(refusal.summary)"
        }
        recent.append(line)
        if recent.count > 64 { recent.removeFirst(recent.count - 64) }
        Self.log.info("\(line, privacy: .public)")
    }

    func refuse(_ refusal: BrowserRefusal) -> BrowserOutcome {
        emit(.refused(refusal))
        return .refused(refusal)
    }

    /// Work in this window from now on — a runner that opened a window for
    /// the session names it, and the first read does not have to guess.
    public func adopt(window: CGWindowID?) {
        workingWindow = window
        pinnedWindow = window
    }

    // MARK: - The stage

    /// What an act does with the stage when it is done.
    ///
    /// PIN: A VERB THAT CHANGES WHERE THE PERSON IS LOOKING KEEPS THE STAGE; A
    /// VERB THAT ANSWERS A QUESTION OR DRIVES THE PLAYER GIVES IT BACK. "Open
    /// youtube.com" said from an editor is a request to see the browser; "mute
    /// the video" said from the same editor is not, and leaving the browser in
    /// front afterwards is invariant 3 broken — the browser reachable from
    /// anywhere, and the person's place given back.
    enum StageAfter: Equatable { case kept, givenBack }

    /// How many staged acts are open. An act inside an act — a search that
    /// navigates, reads and presses — holds the stage once, through the outer.
    private var stagedDepth = 0

    /// What a verb does when the browser is asking something of its own.
    ///
    /// PIN: THE DIALOG IS MODAL, SO THE DEFAULT IS TO STOP. A page behind a
    /// "Confirm Form Resubmission" cannot be scrolled, read from pixels, or
    /// pressed — measured, a read went ahead and listed the page under the
    /// dialog, and a reload settled as done. Every verb refuses with the
    /// browser's own question unless it is the verb that reads the question
    /// (a read describes it) or the one that can answer it (a press names a
    /// choice). Nothing answers it on Mary's own account.
    enum DialogStance { case blocked, described, answered }

    /// Take the stage for one act, read the shell of the window that is NOW in
    /// front, run the act, and put the machine back.
    ///
    /// PIN: THE SHELL IS READ AFTER THE STAGE IS TAKEN, NOT BEFORE. Eight verbs
    /// read it first and staged second, so the page frame every pointer act
    /// aimed at was measured while the window could still be behind another
    /// or on another Space — and the window that came forward was not always
    /// the one measured. Every act pays the same courtesies in the same order:
    /// the stage, the shell, the pointer put back where it was (before
    /// returning, never in a deferred Task — measured, a deferred restore
    /// landed DURING the next operation's read), and the stage given back
    /// when it is owed.
    func staged(
        _ target: BrowserTarget,
        after: StageAfter,
        asking stance: DialogStance = .blocked,
        _ act: (WebSurfaceAX.Reading, CGPoint?) async -> BrowserOutcome
    ) async -> BrowserOutcome {
        await holding(target, after: after) {
            let shellOutcome = await readShell(target)
            guard let shell = shellOutcome.shell else { return shellOutcome }
            if let dialog = shell.dialog {
                switch stance {
                case .blocked: return asked(dialog, shell: shell)
                case .described:
                    emit(.verified("the browser is asking something"))
                    return BrowserOutcome(ok: true, spoken: dialog.spoken, shell: shell, landed: true)
                case .answered: break
                }
            }
            let cursor = await seams.hands.cursorLocation()
            let outcome = await act(shell, cursor)
            await seams.hands.restoreCursor(to: cursor)
            return outcome
        }
    }

    /// Take the stage for a journey — several verbs said as one — and hold it
    /// through all of them. A journey has no shell of its own: each verb inside
    /// it reads the page it is on, as it would said alone.
    func journey(
        _ target: BrowserTarget,
        after: StageAfter,
        _ body: () async -> BrowserOutcome
    ) async -> BrowserOutcome {
        await holding(target, after: after, body)
    }

    private func holding(
        _ target: BrowserTarget,
        after: StageAfter,
        _ body: () async -> BrowserOutcome
    ) async -> BrowserOutcome {
        // INSIDE AN ACT THAT HOLDS THE STAGE ALREADY. Taking it twice would
        // wait on our own lease; giving it back halfway would hand the person's
        // editor forward between a search's navigation and its press.
        if stagedDepth > 0 { return await body() }

        let previous = await seams.stage.frontmost()
        let activation = await seams.stage.bringForward(
            pid: target.processIdentifier, raising: workingWindow)
        guard activation.succeeded else {
            return refuse(.activationRefused(target.spokenName, activation.failure))
        }
        stagedDepth += 1
        defer { stagedDepth -= 1 }

        let outcome = await body()

        var owed: pid_t?
        if after == .givenBack, let previous, previous != target.processIdentifier {
            owed = previous
            emit(.acted("gave the stage back"))
        }
        await seams.stage.standDown(givingBackTo: owed)
        return outcome
    }

    // MARK: - One press

    /// How the pointer travels to a control before it is pressed.
    enum Approach {
        /// A short travel from wherever it is — a page control.
        case glide
        /// A long approach into the picture — a player's transport, which only
        /// exists while the pointer arrives over it. See `BrowserHands.hover`.
        case hover
    }

    /// One press on something the page draws, the way every one is pressed:
    /// confirm the stage is still ours, put the pointer on it, let the page
    /// register the hover, click. False when somebody else took the machine
    /// meanwhile — a click posted into whatever came forward is the strongest
    /// wrong gesture there is, so the check is here, once, for every press.
    ///
    /// PIN: THE MEDIA PRESS, THE HUMAN-CHECK PRESS AND EVERY PLAN COMMAND WERE
    /// THREE COPIES OF THIS, two of them checking focus their own way and one
    /// restoring the cursor from a deferred Task the `staged` PIN forbids.
    func press(
        at point: CGPoint, in target: BrowserTarget, arriving: Approach = .glide,
        button: PluginPointerButton = .left, count: Int = 1
    ) async -> Bool {
        guard await seams.stage.holdsFocus(pid: target.processIdentifier) else { return false }
        switch arriving {
        case .glide: await seams.hands.glide(to: point, pid: target.processIdentifier)
        case .hover: await seams.hands.hover(at: point, pid: target.processIdentifier)
        }
        await seams.sleep(Self.pressSettle)
        await seams.hands.click(
            at: point, button: button, count: count, pid: target.processIdentifier)
        return true
    }

    // MARK: - Reading

    /// The browser's shell: what page it is on, and where that page is on screen.
    public func readShell(_ target: BrowserTarget) async -> BrowserOutcome {
        lastBrowser = target.spokenName
        emit(.resolved(browser: target.spokenName, pid: target.processIdentifier))
        guard let reading = await seams.shell.read(
            pid: target.processIdentifier, registration: target.registration,
            preferring: workingWindow)
        else {
            return refuse(.shellUnreadable(target.spokenName))
        }
        // THE PINNED WINDOW OR NOTHING. A read that came back about another
        // window means the named one is gone, and the act stops here.
        // — unless the window is there and PRESENTING AS A PANEL: a find bar
        // stands in for the page's window in the accessibility tree until it
        // is closed, and Escape is how a person closes it. Once, then again.
        if let pinned = pinnedWindow, reading.windowID != pinned {
            if await seams.shell.presence(of: pinned, pid: target.processIdentifier) == .panel {
                emit(.acted("the window is showing a panel — closing it"))
                _ = await seams.keys.press(.escape)
                await seams.sleep(.milliseconds(200))
                if let again = await seams.shell.read(
                       pid: target.processIdentifier, registration: target.registration,
                       preferring: pinned),
                   again.windowID == pinned {
                    return noteShell(again, in: target)
                }
            }
            return refuse(.workingWindowGone)
        }
        return noteShell(reading, in: target)
    }

    /// The shell read that was just made: remembered, on the stream, spoken.
    private func noteShell(_ reading: WebSurfaceAX.Reading, in target: BrowserTarget) -> BrowserOutcome {
        lastChrome = reading
        if let window = reading.windowID, window != workingWindow {
            workingWindow = window
            emit(.acted("working in window \(window)"))
        }
        emit(.shellRead(
            title: reading.title, site: reading.siteName, pageFrame: reading.pageFrame))
        return BrowserOutcome(
            ok: true, spoken: Self.spoken(reading, browser: target.spokenName), shell: reading)
    }

    /// What the reading says, in one sentence. Shared with the perception publisher so
    /// the prompt line and the spoken answer never drift.
    public static func spoken(_ reading: WebSurfaceAX.Reading, browser: String) -> String {
        guard let title = reading.title, !title.isEmpty else {
            return "\(browser) is open, but I can't read what page it's on."
        }
        if let site = reading.siteName {
            return "You're on \(title), at \(site)."
        }
        return "You're on \(title)."
    }

    // MARK: - What a recipe tells the engine

    /// Which road a journey took, for the bench that draws it. Cleared with the
    /// slate, like every other verdict about a page that may be gone.
    func noteWatchRoad(_ road: WatchRecipe.Road) {
        lastWatchRoad = road
        emit(.acted("took the \(road.rawValue) road"))
    }

    /// One line of a journey's own narration.
    func emitJourney(_ line: String) { emit(.acted(line)) }

    /// THIS PAGE IS A LIST OF ANSWERS TO SOMETHING.
    ///
    /// PIN: THE SEARCH KNOWS, EVEN WHEN NOBODY NAMED A RESULT. This used to be
    /// set only inside an `.openResult` arbitration — so when a bare search
    /// stopped arbitrating (round 1 E), it stopped remembering, and the next
    /// "open the second one" routed as a bare press over the whole page. The
    /// recipe has just PROVED it made a results page; saying so is its own job.
    func noteResultQuery(_ query: String) {
        lastResultQuery = query
    }

    /// Whether the page in front is the results this engine put there for these
    /// words: the query it last searched for, AND a shell that reads as a search
    /// for it. Either alone is too loose — see the PIN on `searchAndOpen`.
    func resultsStanding(for query: String, shell: WebSurfaceAX.Reading) -> Bool {
        lastResultQuery == query && WebSearchRecipe.searched(for: query, shell: shell)
    }

}
