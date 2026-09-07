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

    // MARK: - The page

    /// Look at the page, revealing the transport first when the intent needs it.
    func perceive(
        _ target: BrowserTarget,
        shell: WebSurfaceAX.Reading,
        intent: VisionPageReader.Intent,
        reveal: Bool,
        previous: MediaControlReading? = nil,
        patience: Int = BrowserEngine.revealAttempts
    ) async -> Result<VisionPageReader.Reading, BrowserRefusal> {
        guard let pageFrame = shell.pageFrame, pageFrame.width > 32, pageFrame.height > 32
        else { return .failure(.pageNotVisible) }

        if reveal {
            // A PLAYER HIDES ITS CONTROLS UNTIL THE POINTER MOVES OVER IT, so reading
            // without moving there reports "no transport" for a video that plainly has
            // one. `reveal` moves across the picture rather than to a point, because a
            // single event at a fixed coordinate is not movement. Real pointer acts,
            // monitored like any others.
            await seams.hands.reveal(over: pageFrame, pid: target.processIdentifier)
            await seams.sleep(Self.revealSettle)
        }

        // AND IF NOTHING SHOWED, WIGGLE AND LOOK AGAIN.
        //
        // PIN: REVEALING IS NOT RELIABLE ON THE FIRST TRY, and pretending otherwise
        // produces the worst answer this lane can give: "this page has no player" about
        // a page that plainly has one. Measured on YouTube across many runs — the same
        // page, the same pointer position, controls sometimes drawn and sometimes not,
        // depending on where the animation and the auto-hide timer happened to be. A
        // person in this situation moves the mouse again; so does this.
        var attempt = 0
        /// Where the picture is, once anything has said. Kept across retries so
        /// the extra read happens at most once.
        var playerFrame: CGRect?
        while true {
            let result = await lookOnce(
                target, shell: shell, pageFrame: pageFrame, intent: intent,
                previous: previous)
            guard case .success(let reading) = result else { return result }
            let found = intent != .media
                || reading.media.map(Self.hasTransport) == true
            // PATIENCE IS FOR A TRANSPORT NOBODY ELSE CAN PLACE. When the page's
            // own rows have already placed the button, looking again for the
            // pixels' version costs six seconds a verb (round 12) and proves
            // nothing the rows did not.
            if found || !reveal || attempt >= patience {
                return .success(reading)
            }
            emit(.acted("looked again — the transport was not showing"))
            // ASK WHERE THE PICTURE IS, ONCE.
            //
            // PIN: A MEDIA READ CARRIES NO ROWS, WHICH MADE THE REGION FIX INERT.
            // `playerRegion` reads `reading.rows`, and a `.media` reading has
            // none — so it always answered nil and every retry went on hovering
            // fractions of the whole page, which is what it was written to stop.
            // Measured: four hovers, one of them above the video entirely, on a
            // page whose player sits well below the middle. One `.elements` read
            // on the FIRST retry answers it, and only on the path where the blind
            // look already failed.
            if playerFrame == nil, attempt == 0,
               case .success(let seen) = await lookOnce(
                   target, shell: shell, pageFrame: pageFrame, intent: .elements,
                   previous: nil) {
                playerFrame = Self.playerRegion(in: seen, page: pageFrame)
                if playerFrame != nil { emit(.acted("found the picture to hover")) }
            }
            // OVER THE PICTURE ITSELF, WHEN THE READING FOUND ONE.
            //
            // PIN: MEASURED — A PLAYER IS NOT ALWAYS IN THE MIDDLE OF THE PAGE.
            // The retries hovered fractions down the whole captured region, which
            // is right for a watch page whose picture fills the top two thirds and
            // wrong for a file page, a wiki article or an embedded clip, where the
            // player is a modest rectangle somewhere else entirely. On such a page
            // every depth landed on prose and the lane reported "no transport" for
            // a page that plainly has one — two legs of round 0, and six more that
            // could not be staged because of it. The reading already knows where
            // the picture is; aiming at it is generic, and needs no site.
            let region = playerFrame ?? Self.playerRegion(in: reading, page: pageFrame) ?? pageFrame
            await seams.hands.reveal(
                over: region, at: Self.revealDepths[attempt], pid: target.processIdentifier)
            await seams.sleep(Self.revealSettle)
            attempt += 1
        }
    }

    /// IS THERE ANYTHING TO DRIVE — a control row, or the circle over the picture?
    ///
    /// PIN: `controlsVisible` MEANS "A BAR WAS FOUND", AND THAT IS NOT THE SAME
    /// QUESTION. A paused player often draws no bar at all and one big play glyph
    /// instead; refusing there says "I can't find the player's controls" about a
    /// control the person is looking at. What each VERB needs is a separate
    /// matter and `target(for:in:)` still decides it — volume, seek and full
    /// screen have no centre glyph to fall back to and still refuse by name.
    static func hasTransport(_ media: MediaControlReading) -> Bool {
        media.controlsVisible || media.centerGlyph != nil
    }

    /// THE PICTURE ON THE PAGE, WHEN THE READING HELD ONE.
    ///
    /// PIN: SHAPE AND SIZE, NEVER A SITE. A player reads as a large image-like
    /// row: at least a fifth of the page's area, and wider than it is tall in the
    /// way video is. The largest such row is the one worth hovering. A page with
    /// no such row answers nil and the whole page is used, exactly as before.
    static func playerRegion(
        in reading: VisionPageReader.Reading, page: CGRect
    ) -> CGRect? {
        // The seal's own rule, shared — see `PagePlayerDerivation`.
        PagePlayerDerivation.playerFrame(rows: reading.rows, pageFrame: page)
    }

    /// Where each retry puts the pointer, as a fraction down the captured region.
    static let revealDepths: [Double] = [0.55, 0.22, 0.42]
    /// How many extra tries the reveal gets before the answer is "no transport".
    static var revealAttempts: Int { revealDepths.count }

    func lookOnce(
        _ target: BrowserTarget,
        shell: WebSurfaceAX.Reading,
        pageFrame: CGRect,
        intent: VisionPageReader.Intent,
        previous: MediaControlReading?
    ) async -> Result<VisionPageReader.Reading, BrowserRefusal> {
        do {
            let reading = try await seams.page.read(
                pid: target.processIdentifier,
                windowID: shell.windowID,
                pageFrame: pageFrame,
                intent: intent,
                appName: target.spokenName,
                windowTitle: shell.title ?? "",
                previousFraction: previous?.progress?.fraction,
                previousElapsed: previous?.elapsed)
            emit(.perceived(
                controls: reading.media?.others.count ?? reading.elements.count,
                playback: reading.media?.playback.rawValue ?? "—",
                duration: reading.duration))
            if let media = reading.media { lastMedia = media }
            return .success(reading)
        } catch let failure as VisionPageReader.Failure {
            switch failure {
            case .pageNotVisible: return .failure(.pageNotVisible)
            default:
                return .failure(.visionUnavailable(
                    failure.errorDescription ?? String(describing: failure)))
            }
        } catch {
            return .failure(.visionUnavailable(String(describing: error)))
        }
    }

    /// Say what the page's player is doing.
    ///
    /// PIN: THIS CLAIMS THE STAGE, AND THAT IS NOT AN OVERSIGHT. A player only draws its
    /// transport while the pointer is moving over it, and a browser window that is not
    /// active ignores the movement — measured, twice: the same page read as "no controls
    /// on this page" inactive and read correctly the moment it was frontmost. Seeing what
    /// is playing therefore requires bringing the window forward, so this verb stages
    /// even though it changes nothing about the page.
    public func describeMedia(in target: BrowserTarget) async -> BrowserOutcome {
        // A question about the player gives the stage back — see `staged`.
        await staged(target, after: .givenBack) { shell, _ in
            await describedMedia(target, shell: shell)
        }
    }

    private func describedMedia(
        _ target: BrowserTarget, shell: WebSurfaceAX.Reading
    ) async -> BrowserOutcome {
        switch await perceive(target, shell: shell, intent: .media, reveal: true) {
        case .failure(let refusal):
            return refuse(refusal)
        case .success(let reading):
            guard let media = reading.media, Self.hasTransport(media) else {
                return refuse(.controlsNotFound)
            }
            return BrowserOutcome(
                ok: true, spoken: media.spoken, shell: shell, media: media)
        }
    }

    // MARK: - Driving the player

    /// Press the page's own transport, then prove the state moved.
    public func controlMedia(_ action: MediaAction, in target: BrowserTarget) async -> BrowserOutcome {
        // Driving the player gives the stage back — "mute the video" from an
        // editor leaves the editor in front. See `staged`.
        await staged(target, after: .givenBack) { shell, _ in
            await drove(action, in: target, shell: shell)
        }
    }

    private func drove(
        _ asked: MediaAction, in target: BrowserTarget, shell: WebSurfaceAX.Reading
    ) async -> BrowserOutcome {
        // THE PAGE'S OWN ROWS, READ ONCE, BESIDE THE PIXELS. A player's buttons,
        // its slider and its clock are rows in the page's tree, named for what
        // they do and placed where they are; the pixels keep every witness
        // they can give, and the rows fill what the pixels could not place or
        // could not read. One elements read serves every fill — four separate
        // reads put "play it again" ten seconds over its budget (round 12) —
        // and a page that has placed the act's button spares the pixels their
        // patience.
        var action = asked
        let seen = await seePlayer(in: target, shell: shell)
        let placed = seen.map { Self.pagePlaces(asked, in: $0) } ?? false
        var before: MediaControlReading
        switch await perceive(
            target, shell: shell, intent: .media, reveal: true,
            patience: placed ? 0 : Self.revealAttempts
        ) {
        case .failure(let refusal): return refuse(refusal)
        case .success(let reading):
            guard let media = reading.media else { return refuse(.controlsNotFound) }
            before = media
        }
        before = fromThePage(before, for: asked, seen: seen)

        // NOTHING TO ACT ON — no bar, no circle, no row named for the act — is
        // the honest refusal; a player that already is what was asked needs
        // none of them (a poster nobody has started is paused).
        if !Self.hasTransport(before), Self.target(for: asked, in: before) == nil,
           Self.alreadySatisfied(asked, by: before) == nil, !asked.isTimeSeek {
            return refuse(.controlsNotFound)
        }

        // "PLAY IT FROM THE START" ON A PLAYER NOBODY HAS STARTED. Measured on
        // a file page: a poster, one play circle over the picture, a duration
        // badge, and no bar at all until the first play — so the seek to the
        // start refused "not its progress control" about a video already at
        // its start. Pressing play IS playing it from the start; the bar
        // arrives with it. Only at the start, and only with no track.
        if Self.seeksTheStart(asked), before.progress == nil, before.playback != .playing,
           before.centerGlyph != nil || before.playPause != nil {
            action = .play
            emit(.acted("the player has not started — playing is the start"))
        }

        // A TIME IS A PLACE ON THE TRACK, ONCE THE VIDEO'S LENGTH IS KNOWN.
        //
        // PIN: "GO BACK TWO MINUTES" WAS UNSAYABLE. The seek took a fraction and
        // nothing else, so a person had to know the video's length and divide.
        // The reading knows the clock — VisionAX reads it off the transport,
        // the page's rows carry it as text, and the page's slider publishes its
        // range — and once it does, a time is a fraction like any other. When
        // no lane can read the length, the refusal names the length, not the
        // track.
        if action == asked, asked.isTimeSeek {
            guard let clock = Self.clock(from: before),
                  let fraction = Self.fraction(
                      for: asked, elapsed: clock.elapsed, duration: clock.duration)
            else { return refuse(.videoLengthUnknown) }
            // A PLACE PAST THE END IS NOT THE END. Clamping "go to three
            // minutes" on a video read as 1:40 long jumped to the end and
            // called it done — measured, when the clock's OCR misread 10:34
            // as 1:40. A refusal that names the length is right whether the
            // video or the reading is short, and the person can tell which.
            if case .seekTo(let seconds) = asked, seconds > clock.duration + 1 {
                return refuse(.beyondTheEnd(clock.duration))
            }
            emit(.acted("\(asked.spokenPast.lowercased()) is \(Int((fraction * 100).rounded()))% of \(SpokenDuration.clock(clock.duration))"))
            action = .seek(fraction: fraction)
        }

        // ASKING FOR THE STATE IT IS ALREADY IN IS A SUCCESS THAT PRESSES NOTHING.
        // Pressing play on a playing video pauses it, which is the opposite of what
        // was asked for — the most annoying possible way to be wrong.
        if let settled = Self.alreadySatisfied(action, by: before) {
            // ALREADY TRUE IS STILL PROVEN. The reading says so, and a turn that
            // reported this as unproven would be nudged to do it again.
            let receipt = PageCommandReceipt(
                sourceIndex: 0, kind: .click, target: Self.controlNoun(for: action),
                delivery: .delivered, effect: .verified(.mediaState(settled)))
            // ON THE STREAM TOO — every watcher reads the events.
            emit(.receipt(receipt))
            return BrowserOutcome(
                ok: true, spoken: settled, shell: shell, media: before,
                receipts: [receipt], landed: true)
        }

        if case .volume = action {
            // REVEAL THE SLIDER FIRST. A player draws its volume track only while the
            // pointer is over the volume control, so the first reading has no track to
            // aim at — that is not the control being absent, it is the slider not being
            // asked for yet.
            guard let control = before.volume else {
                return refuse(.controlNotFound("volume"))
            }
            await seams.hands.glide(to: control.clickPoint, pid: target.processIdentifier)
            await seams.sleep(Self.revealSettle)
            switch await perceive(target, shell: shell, intent: .media, reveal: false) {
            case .failure(let refusal): return refuse(refusal)
            case .success(let reading):
                guard let media = reading.media, media.volumeTrack != nil else {
                    return refuse(.controlNotFound("volume slider"))
                }
                before = media
            }
        }

        guard let (point, what) = Self.target(for: action, in: before) else {
            return refuse(.controlNotFound(Self.controlNoun(for: action)))
        }

        if dryRun {
            return refuse(.dryRun("clicked \(what) at (\(Int(point.x)), \(Int(point.y)))"))
        }
        // SOMEBODY ELSE MAY HAVE TAKEN THE MACHINE between the reveal and the
        // press — a second of hovering, settling and reading pixels. A click
        // posted into whatever came forward is the strongest wrong gesture there
        // is; the page plan checks this before every command, and so does this.
        guard await seams.stage.holdsFocus(pid: target.processIdentifier) else {
            return refuse(.interrupted(atCommand: 0))
        }
        await seams.hands.hover(at: point, pid: target.processIdentifier)
        await seams.sleep(Self.pressSettle)
        await seams.hands.click(at: point, pid: target.processIdentifier)
        emit(.acted("clicked \(what)"))
        await seams.sleep(Self.actSettle)

        // THE SECOND LOOK IS TAKEN WITH THE POINTER BACK ON THE CONTROL — the
        // volume track exists only while it is hovered.
        if case .volume = action, let control = before.volume {
            await seams.hands.glide(to: control.clickPoint, pid: target.processIdentifier)
            await seams.sleep(Self.pressSettle)
        }
        var after: MediaControlReading
        switch await perceive(
            target, shell: shell, intent: .media,
            reveal: {
                if case .volume = action { return false }
                return true
            }(),
            previous: before,
            patience: placed ? 0 : Self.revealAttempts
        ) {
        case .failure(let refusal): return refuse(refusal)
        case .success(let reading):
            guard let media = reading.media else { return refuse(.controlsNotFound) }
            after = media
        }
        // AND THE PAGE'S ROWS AGAIN, FOR THE WITNESS: the button named for the
        // opposite act, the slider's new position, the clock.
        after = fromThePage(after, for: action, seen: await seePlayer(in: target, shell: shell))
        if case .seek = action { after = Self.clocked(after) }

        let verdict: String
        switch Self.verdict(action, before: before, after: after) {
        case .proved(let proof):
            verdict = proof
        case .unchanged:
            return refuse(.stateUnchanged(
                expected: Self.expected(action),
                observed: Self.observed(action, in: after)))
        case .unreadable(let why):
            // DELIVERED, EFFECT UNVERIFIED — rank five of the ladder, and the
            // honest answer when there was nothing to compare. Not `landed`,
            // because nothing proved it; not a refusal either, because the press
            // happened and saying it did not would be the wrong lie.
            let receipt = PageCommandReceipt(
                sourceIndex: 0, kind: .click, target: what, delivery: .delivered)
            emit(.receipt(receipt))
            return BrowserOutcome(
                ok: true,
                spoken: "\(asked.spokenPast), though \(why).",
                shell: shell, media: after, receipts: [receipt], landed: false)
        }
        emit(.verified(verdict))
        // THE RECEIPT THE MEDIA LANE NEVER GAVE.
        //
        // PIN: THE LAST OF THE THREE PLACES `landed` WAS CLAIMED WITHOUT ONE.
        // This lane verified in prose — it re-perceives and refuses
        // `stateUnchanged` when nothing moved, which is real proof — and then
        // returned it as a sentence, so `SkillOutcome.landed` was false for a
        // mute that had demonstrably worked and the turn tried again with
        // something else. That is the reported "mute the video runs a web search"
        // in its final form. `mediaState` is rank one's sibling in the ladder and
        // exists for exactly this; the verdict `verify` already produced IS the
        // evidence, so nothing new is measured, only reported.
        let receipt = PageCommandReceipt(
            sourceIndex: 0,
            kind: .click,
            target: what,
            delivery: .delivered,
            effect: .verified(.mediaState(verdict)))
        emit(.receipt(receipt))
        return BrowserOutcome(
            ok: true, spoken: "\(asked.spokenPast) — \(after.spoken)",
            shell: shell, media: after, receipts: [receipt], landed: true)
    }

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

    // MARK: - The browser's own question

    /// The refusal every blocked verb gives: the browser's question, with the
    /// shell attached so a caller can see what stood in the way.
    func asked(_ dialog: WebSurfaceAX.Dialog, shell: WebSurfaceAX.Reading) -> BrowserOutcome {
        let refusal = BrowserRefusal.browserIsAsking(
            question: dialog.question, choices: dialog.choices)
        emit(.refused(refusal))
        return BrowserOutcome(ok: false, spoken: refusal.summary, refusal: refusal, shell: shell)
    }

    /// How long a pressed choice gets to take the dialog away.
    static let dialogAnswerBudget: Double = 3

    /// Answer the browser's question with the person's words — and only when
    /// those words name one of its choices.
    ///
    /// PIN: NEVER A GUESS, NEVER A DEFAULT. "Continue" on a resubmission is a
    /// write the person did once already; pressing it because it is the
    /// rightmost button, or because the person said "yes", would be Mary
    /// deciding what they meant. The words either carry a choice or the
    /// question is put back to them.
    func answer(
        _ dialog: WebSurfaceAX.Dialog, with phrase: String,
        in target: BrowserTarget, shell: WebSurfaceAX.Reading
    ) async -> BrowserOutcome {
        let matching = Self.choices(named: phrase, among: dialog.choices)
        guard matching.count == 1, let choice = matching.first else {
            return asked(dialog, shell: shell)
        }
        if dryRun { return refuse(.dryRun("answered \(choice)")) }
        guard await seams.shell.press(
            label: choice, pid: target.processIdentifier, registration: target.registration,
            within: workingWindow)
        else { return refuse(.elementNotFound(choice)) }
        emit(.acted("answered \(choice)"))

        // GONE IS THE RECEIPT. The dialog was a shell fact; the shell says
        // whether it still stands.
        let deadline = seams.now().addingTimeInterval(Self.dialogAnswerBudget)
        var latest = shell
        while seams.now() < deadline {
            await seams.sleep(Self.navigationPoll)
            guard let reading = await seams.shell.read(
                pid: target.processIdentifier, registration: target.registration,
                preferring: workingWindow)
            else { continue }
            latest = reading
            if reading.dialog == nil {
                lastChrome = reading
                let receipt = PageCommandReceipt(
                    sourceIndex: 0, kind: .click, target: choice,
                    delivery: .delivered, effect: .verified(.dialogAnswered(choice)))
                emit(.receipt(receipt))
                return BrowserOutcome(
                    ok: true, spoken: "Answered \(choice).", shell: reading,
                    receipts: [receipt], landed: true)
            }
        }
        return BrowserOutcome(
            ok: false,
            spoken: BrowserRefusal.stateUnchanged(
                expected: "the question answered", observed: "it is still asking").summary,
            refusal: .stateUnchanged(expected: "the question answered", observed: "it is still asking"),
            shell: latest)
    }

    /// The choices the person's words name. A choice is named when its whole
    /// label appears in the words, as words — "press continue" names
    /// "Continue"; "continue the video" does too, and that is the person's to
    /// say while the browser is asking.
    static func choices(named phrase: String, among choices: [String]) -> [String] {
        let said = words(phrase)
        guard !said.isEmpty else { return [] }
        return choices.filter { choice in
            let wanted = words(choice)
            guard !wanted.isEmpty, wanted.count <= said.count else { return false }
            return (0...(said.count - wanted.count)).contains { start in
                Array(said[start..<(start + wanted.count)]) == wanted
            }
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    // MARK: - The human check

    /// How long the auto-clearing kind of check gets before anything is pressed.
    /// "Checking your browser…" runs its own test and moves on by itself; reading
    /// the page and pressing during it is wasted, and pressing is not nothing.
    static let challengeGrace: Double = 3
    /// How long a pressed check gets to clear before it is handed back.
    static let challengeBudget: Double = 8

    /// If the navigation landed on a human-verification interstitial, press its
    /// visible control once and look again; otherwise the outcome stands.
    ///
    /// PIN: A NO-OP ON AN ORDINARY PAGE. `PageChallenge.isChallenge` reads the
    /// title the shell already carries, so this touches nothing unless the tab
    /// is literally titled like an interstitial. Then, in order: WAIT, because
    /// the common kind clears itself and pressing during it is pointless; READ
    /// the page from pixels and aim at the box, not the sentence; PRESS ONCE
    /// through the same glide-and-click every page control gets — the real
    /// cursor, which is what a rendered page sees; LOOK AGAIN. If one press did
    /// not clear it, hand it back. Hammering a challenge is the thing this is not.
    func satisfyingChallenge(
        _ settled: BrowserOutcome, in target: BrowserTarget
    ) async -> BrowserOutcome {
        guard settled.ok, let shell = settled.shell,
              PageChallenge.isChallenge(title: shell.title)
        else { return settled }

        emit(.acted("a human-check stands on the page"))
        // THE AUTO-CLEARING KIND, given its moment first.
        if let cleared = await challengeCleared(in: target, within: Self.challengeGrace) {
            return clearedOutcome(cleared, target: target)
        }

        // THE STAGE IS ALREADY HELD — this runs inside the navigation that found
        // the challenge — so the question is only whether it is still ours.
        guard await seams.stage.holdsFocus(pid: target.processIdentifier) else {
            return refuse(.interrupted(atCommand: 0))
        }
        let cursor = await seams.hands.cursorLocation()
        defer { Task { await seams.hands.restoreCursor(to: cursor) } }

        // READ, AND AIM AT THE BOX.
        guard case .success(let roster) = await read(target, shell: shell),
              let aim = PageChallenge.aim(in: roster.rows)
        else {
            // Nothing to press. It may still clear on its own; otherwise it is theirs.
            if let cleared = await challengeCleared(in: target, within: Self.challengeBudget) {
                return clearedOutcome(cleared, target: target)
            }
            return refuse(.humanCheck)
        }

        // PRESS ONCE, THE WAY EVERY PAGE CONTROL IS PRESSED.
        await seams.hands.glide(to: aim.point, pid: target.processIdentifier)
        await seams.sleep(Self.pressSettle)
        await seams.hands.click(at: aim.point, button: .left, count: 1, pid: target.processIdentifier)
        emit(.acted("pressed \(aim.named)"))

        // LOOK AGAIN.
        if let cleared = await challengeCleared(in: target, within: Self.challengeBudget) {
            return clearedOutcome(cleared, target: target)
        }
        return refuse(.humanCheck)
    }

    private func clearedOutcome(
        _ cleared: WebSurfaceAX.Reading, target: BrowserTarget
    ) -> BrowserOutcome {
        lastChrome = cleared
        emit(.verified("the human-check cleared"))
        return BrowserOutcome(
            ok: true,
            spoken: Self.spoken(cleared, browser: target.spokenName),
            shell: cleared)
    }

    /// Poll the shell title until it is no longer an interstitial, or the budget
    /// runs out. Returns the cleared reading, or nil if it never cleared.
    func challengeCleared(
        in target: BrowserTarget, within seconds: Double = 8
    ) async -> WebSurfaceAX.Reading? {
        let deadline = seams.now().addingTimeInterval(seconds)
        while seams.now() < deadline {
            guard !Task.isCancelled else { return nil }
            await seams.sleep(Self.navigationPoll)
            guard let reading = await seams.shell.read(
                pid: target.processIdentifier, registration: target.registration,
                preferring: workingWindow)
            else { continue }
            if !PageChallenge.isChallenge(title: reading.title) { return reading }
        }
        return nil
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

    // MARK: - Pure decisions

    /// Whether the request is already true, and what to say if so.
    static func alreadySatisfied(_ action: MediaAction, by media: MediaControlReading) -> String? {
        switch action {
        case .play where media.playback == .playing:
            return "It's already playing — \(media.spoken)"
        case .pause where media.playback == .paused:
            return "It's already paused — \(media.spoken)"
        case .mute where media.isMuted == true:
            return "The sound is already off."
        case .unmute where media.isMuted == false:
            return "The sound is already on."
        default:
            return nil
        }
    }

    /// A seek to the very beginning, however it was said.
    static func seeksTheStart(_ action: MediaAction) -> Bool {
        switch action {
        case .seek(let fraction): return fraction <= 0.01
        case .seekTo(let seconds): return seconds <= 0.5
        default: return false
        }
    }

    /// Where to click, and what to call it.
    static func target(
        for action: MediaAction, in media: MediaControlReading
    ) -> (CGPoint, String)? {
        switch action {
        case .play, .pause, .toggle:
            // THE BAR FIRST, THEN THE CIRCLE IN THE MIDDLE.
            //
            // PIN: A PAUSED PLAYER OFTEN DRAWS NO BAR AT ALL. Measured live on a
            // real watch page: paused, poster showing, one big play circle over
            // the picture and no control row anywhere — hovering it added only a
            // volume icon. The lane refused `controlsNotFound` about a control a
            // person would press without thinking. The centre glyph is that
            // control, and it is only ever used for the verbs it can serve:
            // volume, seek and full screen still need the bar and still say so.
            if let control = media.playPause { return (control.clickPoint, "the transport") }
            guard let centre = media.centerGlyph else { return nil }
            return (centre.clickPoint, "the play button over the picture")
        case .mute, .unmute:
            guard let control = media.volume else { return nil }
            return (control.clickPoint, "the volume control")
        case .fullscreen:
            guard let control = media.fullscreen else { return nil }
            return (control.clickPoint, "the full screen control")
        case .seek(let fraction):
            guard let point = media.seekPoint(fraction: fraction) else { return nil }
            return (point, "the progress bar")
        case .seekTo, .seekBy:
            // Resolved into a fraction before anything is aimed — see `drove`.
            return nil
        case .volume(let fraction):
            // THE TRACK ONLY EXISTS WHILE THE POINTER IS ON THE CONTROL, so this is nil
            // on a first read and found on the second — see `drove`, which hovers the
            // volume glyph and looks again before asking.
            guard let point = media.volumePoint(fraction: fraction) else { return nil }
            return (point, "the volume slider")
        }
    }

    static func controlNoun(for action: MediaAction) -> String {
        switch action {
        case .play, .pause, .toggle: return "play"
        case .mute, .unmute: return "volume"
        case .volume: return "volume slider"
        case .fullscreen: return "full screen"
        case .seek, .seekTo, .seekBy: return "progress"
        }
    }

    // MARK: - A time, as a place on the track

    /// The video's clock, from whichever lane could read it: the reading's own
    /// (VisionAX reads the elapsed and total times off the transport), else
    /// the page's progress slider, whose range IS the length. Nil when neither
    /// answered, which a time seek must refuse by name rather than guess.
    ///
    /// PIN: THE SLIDER IS A SLIDER, NOT A SITE. A player's progress bar is an
    /// `AXSlider` inside the picture whose maximum is the duration in seconds;
    /// that is a role and a range, published by the page, and is the same on
    /// every player that publishes one. MEASURED on the staged watch page:
    /// `slider "Progress Bar" 879×5` while playing, nothing while paused.
    static func clock(
        from media: MediaControlReading
    ) -> (elapsed: TimeInterval, duration: TimeInterval)? {
        if let duration = media.duration, duration > 0 {
            return (media.elapsed ?? 0, duration)
        }
        // ONE TIME AND A FRACTION ARE A WHOLE CLOCK. Measured in round 10: a
        // player just started shows "0:22 / 10:34" and the OCR made out only
        // the "10:34" — the elapsed sits in a highlighted box — so the reading
        // carried a lone time as the elapsed and no length, and a seek refused
        // "I can't tell how long the video is" three seconds into a video
        // whose length was on screen. A lone time at the very start of the
        // track is the length; a lone time further in, with the track's own
        // fraction, gives the length by division. The fraction is the page's
        // slider where it publishes one (`withSliderTrack`), which is what
        // makes this arithmetic and not a guess.
        guard let lone = media.elapsed, lone > 0,
              let fraction = media.progress?.fraction
        else { return nil }
        if fraction < Self.startOfTheTrack { return (0, lone) }
        return (lone, lone / fraction)
    }

    /// How far in still counts as the start, when a lone time is judged.
    static let startOfTheTrack = 0.05

    /// The page's rows near the player, read once for every fill below.
    struct PlayerSeen {
        let rows: [PageRow]
        let player: CGRect?
    }

    func seePlayer(in target: BrowserTarget, shell: WebSurfaceAX.Reading) async -> PlayerSeen? {
        guard let pageFrame = shell.pageFrame,
              case .success(let seen) = await lookOnce(
                  target, shell: shell, pageFrame: pageFrame, intent: .elements, previous: nil)
        else { return nil }
        return PlayerSeen(rows: seen.rows, player: Self.playerRegion(in: seen, page: pageFrame))
    }

    /// Whether the page's rows place the button this act needs.
    static func pagePlaces(_ action: MediaAction, in seen: PlayerSeen) -> Bool {
        let rows = seen.rows, player = seen.player
        switch action {
        case .play, .pause, .toggle:
            return playerButton(named: ["\(MediaAction.play)", "\(MediaAction.pause)"], in: rows, player: player) != nil
        case .mute, .unmute:
            return volumeState(in: rows, player: player) != nil
        case .fullscreen:
            return playerButton(named: ["full", "fullscreen"], in: rows, player: player) != nil
        case .seek, .seekTo, .seekBy:
            return progressSlider(in: rows, player: player) != nil
        case .volume:
            return false
        }
    }

    /// The reading, with what the page's own rows can add for this act.
    ///
    /// PIN: THE ROWS ARE THE WITNESS THE PIXELS COULD NOT BE. Measured, one
    /// per round: the film's first ten seconds are a pink sky that barely
    /// moves and "play" read as "still paused" at 0:05; the crossed speaker
    /// read as sound on and "mute" unmuted; the OCR made out only the length
    /// three seconds in; the centre glyph sat sixty points from the play
    /// circle in a wide window. A player's buttons are rows named for the act
    /// they would do next — a button offering to pause is a player that is
    /// playing — its slider is a row whose range is the length, and its clock
    /// is text beside the bar. Each fills only what the pixels left empty or
    /// contradicted; the pixels keep the rest.
    func fromThePage(
        _ media: MediaControlReading, for action: MediaAction, seen: PlayerSeen?
    ) -> MediaControlReading {
        guard let seen else { return media }
        var filled = media
        let rows = seen.rows, player = seen.player

        // Playback, and the play/pause button's place.
        if let button = Self.playerButton(named: ["\(MediaAction.pause)"], in: rows, player: player) {
            filled.playback = .playing
            filled.playPause = .init(frame: button.frame, glyph: .pause, confidence: 1)
        } else if let button = Self.playerButton(named: ["\(MediaAction.play)"], in: rows, player: player) {
            filled.playback = .paused
            filled.playPause = .init(frame: button.frame, glyph: .play, confidence: 1)
        }
        // The sound, and the mute button's place.
        if let state = Self.volumeState(in: rows, player: player) {
            filled.volume = .init(frame: state.frame, glyph: state.muted ? .muted : .volume, confidence: 1)
        }
        // Full screen's place, when the pixels found none.
        if filled.fullscreen == nil,
           let button = Self.playerButton(named: ["full", "fullscreen"], in: rows, player: player) {
            filled.fullscreen = .init(frame: button.frame, glyph: .fullscreen, confidence: 1)
        }
        // The clock the page publishes, before the one the pixels show.
        if let clock = Self.clockRows(in: rows, player: player) {
            if filled.elapsed == nil, let elapsed = clock.elapsed { filled.elapsed = elapsed }
            if filled.duration == nil, let duration = clock.duration { filled.duration = duration }
        }
        // The slider as the track, and its range as the length.
        if action.isTimeSeek || { if case .seek = action { return true }; return false }() {
            filled = withSliderTrack(filled, seen: seen)
        }
        if filled.playback != media.playback || filled.volume?.glyph != media.volume?.glyph {
            emit(.acted("took the page's own buttons: \(filled.playback.rawValue)"
                + (filled.isMuted.map { $0 ? ", muted" : ", sound on" } ?? "")))
        }
        return filled
    }

    /// The first pressable row near the player whose name carries one of the
    /// act's own words.
    static func playerButton(
        named words: [String], in rows: [PageRow], player: CGRect?
    ) -> PageRow? {
        func near(_ frame: CGRect) -> Bool {
            guard let player else { return true }
            return frame.intersects(player.insetBy(dx: -8, dy: -player.height * 0.4))
        }
        return rows.first { row in
            guard row.affordance == .press, near(row.frame) else { return false }
            let named = row.label.lowercased().split { !$0.isLetter }.map(String.init)
            return words.contains { named.contains($0) }
        }
    }

    /// The mute button among the page's rows near the player, and what it
    /// says: a button offering to unmute is a player that is muted.
    static func volumeState(
        in rows: [PageRow], player: CGRect?
    ) -> (frame: CGRect, muted: Bool)? {
        let offersToMute = "\(MediaAction.mute)"
        let offersToUnmute = "\(MediaAction.unmute)"
        func near(_ frame: CGRect) -> Bool {
            guard let player else { return true }
            return frame.intersects(player.insetBy(dx: -8, dy: -player.height * 0.4))
        }
        for row in rows where row.affordance == .press && near(row.frame) {
            let words = row.label.lowercased()
                .split { !$0.isLetter }
                .map(String.init)
            if words.contains(offersToUnmute) { return (row.frame, true) }
            if words.contains(offersToMute) { return (row.frame, false) }
        }
        return nil
    }

    /// The times the page's own rows carry near the player, left to right —
    /// the elapsed first, the length last. One lone time is handed on as the
    /// elapsed, for `clock(from:)` to judge against the track.
    static func clockRows(
        in rows: [PageRow], player: CGRect?
    ) -> (elapsed: TimeInterval?, duration: TimeInterval?)? {
        func near(_ frame: CGRect) -> Bool {
            guard let player else { return true }
            return frame.intersects(player.insetBy(dx: -8, dy: -player.height * 0.4))
        }
        let times = rows
            .filter { near($0.frame) }
            .sorted { $0.frame.minX < $1.frame.minX }
            .flatMap { row in Self.times(in: row.label).map { (x: row.frame.minX, seconds: $0) } }
        guard let first = times.first else { return nil }
        if times.count == 1 { return (first.seconds, nil) }
        let longest = times.map(\.seconds).max() ?? first.seconds
        let shortest = times.map(\.seconds).min() ?? first.seconds
        return (shortest, longest)
    }

    /// Every m:ss or h:mm:ss in a label, in order.
    static func times(in label: String) -> [TimeInterval] {
        let pattern = try! NSRegularExpression(pattern: "\\b(?:(\\d{1,2}):)?(\\d{1,2}):(\\d{2})\\b")
        let text = label as NSString
        return pattern.matches(in: label, range: NSRange(location: 0, length: text.length)).map { match in
            let hours = match.range(at: 1).location == NSNotFound ? 0 : Double(text.substring(with: match.range(at: 1))) ?? 0
            let minutes = Double(text.substring(with: match.range(at: 2))) ?? 0
            let seconds = Double(text.substring(with: match.range(at: 3))) ?? 0
            return hours * 3600 + minutes * 60 + seconds
        }
    }

    /// The page's progress slider: an adjustable row inside the picture whose
    /// range is a length, wide and thin like a track. The widest range wins —
    /// a volume slider is a fraction, a progress bar is minutes.
    static func progressSlider(in rows: [PageRow], player: CGRect?) -> PageRow? {
        // ON THE PICTURE OR JUST UNDER IT. A player draws its bar over the
        // bottom of the picture or in a strip beneath it — measured, both — and
        // a bar a screen away belongs to something else.
        func belongsToThePlayer(_ frame: CGRect) -> Bool {
            guard let player else { return true }
            guard frame.maxX > player.minX, frame.minX < player.maxX else { return false }
            return frame.intersects(player)
                || (frame.minY >= player.maxY && frame.minY <= player.maxY + player.height * 0.3)
        }
        return rows
            .filter { row in
                row.affordance == .adjust
                    && (row.maximumValue ?? 0) > (row.minimumValue ?? 0)
                    && belongsToThePlayer(row.frame)
                    && row.frame.width > row.frame.height * 4
            }
            .max { ($0.maximumValue ?? 0) < ($1.maximumValue ?? 0) }
    }

    /// The reading, with whatever the page's own slider can add: a track to
    /// aim at when the picture showed none, and a length and a position when
    /// the clock was not legible. One elements read, only when something is
    /// missing.
    ///
    /// PIN: MEASURED — the picture lane finds the track on one look and loses
    /// it on the next, because a player hides its bar on a timer; the tree
    /// publishes the same bar as a slider for as long as it is drawn, with its
    /// value and range. "I can see the player but not its progress control"
    /// was said about a track that was 879 points wide in the tree.
    func withSliderTrack(
        _ media: MediaControlReading, in target: BrowserTarget, shell: WebSurfaceAX.Reading
    ) async -> MediaControlReading {
        withSliderTrack(media, seen: await seePlayer(in: target, shell: shell))
    }

    func withSliderTrack(
        _ media: MediaControlReading, seen: PlayerSeen?
    ) -> MediaControlReading {
        guard let seen else { return media }
        var filled = media
        let player = seen.player
        guard let slider = Self.progressSlider(in: seen.rows, player: player),
              let maximum = slider.maximumValue
        else { return Self.clocked(filled) }
        let minimum = slider.minimumValue ?? 0
        let length = maximum - minimum
        guard length > 0 else { return media }
        // THE PAGE'S RECTANGLE, OVER THE PICTURE'S. MEASURED: the pixel lane's
        // bar was a rectangle a click on which moved nothing, and reported
        // 0.6% for a video at 3:10 of 10:34; the same click on the slider the
        // tree publishes moved the video exactly. Where the position is read
        // from is decided by `clocked`; here the frame is the page's.
        let fraction = slider.value.map { min(max(($0 - minimum) / length, 0), 1) }
            ?? filled.progress?.fraction ?? 0
        filled.progress = .init(frame: slider.frame, fraction: fraction)
        emit(.acted("took the page's own slider as the track"))
        // TWO LANES AGREE ON A LENGTH, OR ONE OF THEM IS WRONG. The slider's
        // position and the clock's elapsed time give a length between them —
        // `elapsed / fraction` — that owes nothing to how the clock's digits
        // were read. MEASURED: the OCR read 10:34 as 1:40 on two runs out of
        // six; the slider stood at 0.5% with 0:03 elapsed, which is a video
        // about ten minutes long, not one. A length the clock says that is
        // off from that by more than a factor of two is the reading's, not the
        // video's; when the clock says nothing, the estimate stands alone.
        if let elapsed = filled.elapsed, slider.value != nil, fraction >= 0.002 {
            let estimated = elapsed / fraction
            if let read = filled.duration, read > 0,
               estimated / read > 2 || read / estimated > 2 {
                emit(.acted("the clock read \(SpokenDuration.clock(read)) long; the slider says about \(SpokenDuration.clock(estimated))"))
                filled.duration = estimated
            } else if filled.duration == nil {
                filled.duration = estimated
            }
        }
        if filled.duration == nil, length > 100 {
            // A range in seconds — a slider whose maximum IS the length.
            filled.duration = length
            if filled.elapsed == nil, slider.value != nil { filled.elapsed = (slider.value ?? minimum) - minimum }
        }
        return Self.clocked(filled)
    }

    /// The position, read from the clock when there is one. The transport's
    /// "3:10 of 10:34" is text the reading OCRs and is right; the bar's filled
    /// fraction is a guess about a few pixels and, measured on a thin bar, was
    /// wrong by a factor of fifty. When both exist the clock wins.
    static func clocked(_ media: MediaControlReading) -> MediaControlReading {
        guard let elapsed = media.elapsed, let duration = media.duration, duration > 0,
              var progress = media.progress
        else { return media }
        progress.fraction = min(max(elapsed / duration, 0), 1)
        var read = media
        read.progress = progress
        return read
    }

    /// A time seek as the fraction the track takes. Clamped to the video.
    static func fraction(
        for action: MediaAction, elapsed: TimeInterval, duration: TimeInterval
    ) -> Double? {
        let target: TimeInterval
        switch action {
        case .seekTo(let seconds): target = seconds
        case .seekBy(let seconds): target = elapsed + seconds
        default: return nil
        }
        guard duration > 0 else { return nil }
        return min(max(target / duration, 0), 1)
    }

    /// Did it land. Nil means it did not, and the caller refuses.
    ///
    /// PIN: MUTE HAS NO TEMPORAL WITNESS. Sound is not visible, so the only evidence is
    /// the glyph flipping — a weaker receipt than playback's, and the reason this
    /// returns a sentence naming which evidence was used rather than a bare Bool.
    /// WHAT A SECOND LOOK CAN SAY ABOUT AN ACT.
    ///
    /// PIN: "I CANNOT SEE WHETHER IT WORKED" IS NOT "IT DID NOT WORK", and
    /// collapsing the two makes Mary tell the person the stronger, wrong thing.
    /// Measured: a mute on a player whose volume glyph the reading could not make
    /// out in either look was reported as `stateUnchanged` — "I pressed it, but
    /// it's still unmuted" — about a video that had in fact gone silent. Sound is
    /// not visible; sometimes there is genuinely nothing to see, and the ranked
    /// ladder already has a rung for that: delivered, effect unverified.
    enum MediaVerdict {
        /// The second look proved it, and says how.
        case proved(String)
        /// The second look was legible and nothing moved.
        case unchanged
        /// There was nothing legible to compare — the act was delivered and its
        /// effect cannot be seen from a picture.
        case unreadable(String)
    }

    static func verdict(
        _ action: MediaAction, before: MediaControlReading, after: MediaControlReading
    ) -> MediaVerdict {
        if let proof = verify(action, before: before, after: after) {
            return .proved(proof)
        }
        switch action {
        case .mute, .unmute:
            // The glyph answered nothing in either look, so nothing was legible.
            guard after.isMuted != nil || (before.volume != nil && after.volume != nil)
            else { return .unreadable("the volume control is not legible in the picture") }
            return .unchanged
        case .fullscreen:
            guard before.bar != nil, after.bar != nil
            else { return .unreadable("the player's bar is not visible to compare") }
            return .unchanged
        case .volume:
            guard after.volumeTrack != nil
            else { return .unreadable("the volume track is not visible to compare") }
            return .unchanged
        case .seek, .seekTo, .seekBy:
            guard after.progress != nil
            else { return .unreadable("the progress track is not visible to compare") }
            return .unchanged
        case .play, .pause, .toggle:
            guard after.playback != .unknown
            else { return .unreadable("whether it is playing cannot be told from the picture") }
            return .unchanged
        }
    }

    static func verify(
        _ action: MediaAction, before: MediaControlReading, after: MediaControlReading
    ) -> String? {
        switch action {
        case .play:
            return after.playback == .playing ? "it is playing" : nil
        case .pause:
            return after.playback == .paused ? "it is paused" : nil
        case .toggle:
            guard before.playback != .unknown, after.playback != .unknown,
                  before.playback != after.playback
            else { return nil }
            return "playback flipped to \(after.playback.rawValue)"
        case .mute, .unmute:
            // MUTE HAS NO TEMPORAL WITNESS — sound is not visible — so the evidence is
            // the button itself. When the glyph is legible it answers directly; when it
            // is not, a CHANGE in what the button looks like is still evidence that the
            // press did something, and the receipt says which of the two it was rather
            // than claiming the stronger one.
            let wanted = action == .mute
            if let now = after.isMuted {
                return now == wanted ? "the volume glyph shows \(wanted ? "muted" : "sound")" : nil
            }
            guard let was = before.volume, let now = after.volume else { return nil }
            let moved = was.glyph != now.glyph
                || abs(was.confidence - now.confidence) > 0.05
            return moved ? "the volume control changed, though its shape is not legible" : nil
        case .fullscreen:
            // Vision cannot answer this: full screen replaces the whole picture, so the
            // reading after is of a different layout entirely. The honest evidence is
            // that the transport moved to the bottom of a much larger frame — or, when
            // no bar is legible either side, that the PAGE grew, which the shell reads
            // for free and which full screen changes unmistakably (measured live: the
            // frame went from the window below the toolbar to the whole window).
            if before.pageFrame.height > 0,
               after.pageFrame.height > before.pageFrame.height * 1.2 {
                return "the page filled the screen"
            }
            guard let beforeBar = before.bar, let afterBar = after.bar else { return nil }
            return afterBar.height > beforeBar.height * 1.2 ? "the player grew" : nil
        case .volume(let fraction):
            guard let now = after.volumeTrack?.fraction else { return nil }
            if abs(now - fraction) <= 0.08 { return "the volume is where it was asked for" }
            guard let was = before.volumeTrack?.fraction else { return nil }
            return abs(now - was) > 0.03 ? "the volume moved" : nil
        case .seek(let fraction):
            guard let now = after.progress?.fraction else { return nil }
            if abs(now - fraction) <= 0.05 { return "the position is where it was asked for" }
            guard let was = before.progress?.fraction else { return nil }
            return abs(now - was) > 0.02 ? "the position moved" : nil
        case .seekTo, .seekBy:
            // Never verified as such: resolved into a fraction first. See `drove`.
            return nil
        }
    }

    static func expected(_ action: MediaAction) -> String {
        switch action {
        case .play: return "playing"
        case .pause: return "paused"
        case .toggle: return "a different state"
        case .mute: return "muted"
        case .unmute: return "unmuted"
        case .fullscreen: return "full screen"
        case .seek(let fraction): return "\(Int((fraction * 100).rounded()))% through"
        case .seekTo(let seconds): return "at \(SpokenDuration.clock(seconds))"
        case .seekBy(let seconds):
            return "\(SpokenDuration.clock(seconds)) \(seconds < 0 ? "earlier" : "later")"
        case .volume(let fraction): return "the volume at \(Int((fraction * 100).rounded()))%"
        }
    }

    static func observed(_ action: MediaAction, in media: MediaControlReading) -> String {
        switch action {
        case .mute, .unmute:
            switch media.isMuted {
            case true: return "muted"
            case false: return "unmuted"
            default: return "unreadable"
            }
        case .seek:
            guard let fraction = media.progress?.fraction else { return "unreadable" }
            return "\(Int((fraction * 100).rounded()))% through"
        case .volume:
            guard let fraction = media.volumeTrack?.fraction else {
                return "a slider I can't see"
            }
            return "the volume at \(Int((fraction * 100).rounded()))%"
        case .fullscreen:
            return "the same size"
        default:
            return media.playback.rawValue
        }
    }
}

private extension MediaControlReading {
    /// The transport band, derived from what was found in it. Full screen is verified
    /// by this growing, since a fullscreen player's controls span the whole display.
    var bar: CGRect? {
        let frames = ([playPause, volume, fullscreen].compactMap { $0 }.map(\.frame))
            + (progress.map { [$0.frame] } ?? [])
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
