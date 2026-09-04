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
import MaryComputerUse
import MaryFoundation
import os

public actor BrowserEngine {

    // MARK: - Seams

    public struct Seams: Sendable {
        public var shell: any BrowserShellReading
        public var page: any PagePerceiving
        public var hands: any BrowserHands
        public var stage: any BrowserStaging
        public var sleep: @Sendable (Duration) async -> Void
        public var now: @Sendable () -> Date

        public init(
            shell: any BrowserShellReading,
            page: any PagePerceiving,
            hands: any BrowserHands,
            stage: any BrowserStaging,
            sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.shell = shell
            self.page = page
            self.hands = hands
            self.stage = stage
            self.sleep = sleep
            self.now = now
        }

        public static var live: Seams {
            Seams(
                shell: LiveBrowserShell(),
                page: LivePagePerception(),
                hands: LiveBrowserHands(),
                stage: LiveBrowserStaging())
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

    private let seams: Seams
    private let dryRun: Bool
    private let startedAt: Date
    private var lastBrowser: String?
    private var lastChrome: WebSurfaceAX.Reading?
    private var lastMedia: MediaControlReading?
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
            lastMedia: lastMedia,
            lastRefusal: lastRefusal,
            acts: acts,
            refusals: refusals,
            perceptions: perceptions,
            recent: recent)
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

    private func emit(_ event: BrowserEngineEvent) {
        for continuation in observers.values { continuation.yield(event) }
        let line: String
        switch event {
        case .resolved(let browser, let pid): line = "resolved \(browser) (pid \(pid))"
        case .shellRead(let title, let site, _):
            line = "shell \(site ?? "—") · \(title ?? "untitled")"
        case .perceived(let controls, let playback, let duration):
            perceptions += 1
            line = "perceived \(controls) controls · \(playback) · \(duration)"
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

    private func refuse(_ refusal: BrowserRefusal) -> BrowserOutcome {
        emit(.refused(refusal))
        return .refused(refusal)
    }

    // MARK: - Reading

    /// The browser's shell: what page it is on, and where that page is on screen.
    public func readShell(_ target: BrowserTarget) async -> BrowserOutcome {
        lastBrowser = target.spokenName
        emit(.resolved(browser: target.spokenName, pid: target.processIdentifier))
        guard let reading = await seams.shell.read(
            pid: target.processIdentifier, registration: target.registration)
        else {
            return refuse(.shellUnreadable(target.spokenName))
        }
        lastChrome = reading
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
    private func perceive(
        _ target: BrowserTarget,
        shell: WebSurfaceAX.Reading,
        intent: VisionPageReader.Intent,
        reveal: Bool,
        previous: MediaControlReading? = nil
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
        while true {
            let result = await lookOnce(
                target, shell: shell, pageFrame: pageFrame, intent: intent,
                previous: previous)
            guard case .success(let reading) = result else { return result }
            let found = intent != .media || reading.media?.controlsVisible == true
            if found || !reveal || attempt >= Self.revealAttempts {
                return .success(reading)
            }
            emit(.acted("looked again — the transport was not showing"))
            // A DIFFERENT DEPTH EACH TIME. A page is a player over only part of what was
            // captured, and one fraction cannot be right for every layout — a watch page
            // puts the picture in the top two thirds, an embedded player fills the frame,
            // and a page scrolled halfway puts it anywhere.
            await seams.hands.reveal(
                over: pageFrame, at: Self.revealDepths[attempt], pid: target.processIdentifier)
            await seams.sleep(Self.revealSettle)
            attempt += 1
        }
    }

    /// Where each retry puts the pointer, as a fraction down the captured region.
    static let revealDepths: [Double] = [0.55, 0.22, 0.42]
    /// How many extra tries the reveal gets before the answer is "no transport".
    static var revealAttempts: Int { revealDepths.count }

    private func lookOnce(
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
        let shellOutcome = await readShell(target)
        guard let shell = shellOutcome.shell else { return shellOutcome }
        guard await seams.stage.bringForward(pid: target.processIdentifier) else {
            return refuse(.activationRefused(target.spokenName))
        }
        // WHERE THE POINTER WAS IS PUT BACK — and IN ORDER.
        //
        // PIN: RESTORED BEFORE RETURNING, NEVER IN A DEFERRED TASK. A `defer` that spawns
        // a Task returns immediately and the restore lands whenever the scheduler gets to
        // it — measured, that was DURING the next operation's read, dragging the cursor
        // off the player mid-look so the transport vanished and a page divider won the
        // scan instead. An act that moves the machine finishes before the verb that
        // caused it reports.
        let cursor = await seams.hands.cursorLocation()
        let outcome = await describedMedia(target, shell: shell)
        await seams.hands.restoreCursor(to: cursor)
        return outcome
    }

    private func describedMedia(
        _ target: BrowserTarget, shell: WebSurfaceAX.Reading
    ) async -> BrowserOutcome {
        switch await perceive(target, shell: shell, intent: .media, reveal: true) {
        case .failure(let refusal):
            return refuse(refusal)
        case .success(let reading):
            guard let media = reading.media, media.controlsVisible else {
                return refuse(.controlsNotFound)
            }
            return BrowserOutcome(
                ok: true, spoken: media.spoken, shell: shell, media: media)
        }
    }

    // MARK: - Driving the player

    /// Press the page's own transport, then prove the state moved.
    public func controlMedia(_ action: MediaAction, in target: BrowserTarget) async -> BrowserOutcome {
        let shellOutcome = await readShell(target)
        guard let shell = shellOutcome.shell else { return shellOutcome }

        guard await seams.stage.bringForward(pid: target.processIdentifier) else {
            return refuse(.activationRefused(target.spokenName))
        }
        // See `describeMedia`: restored in order, not in a deferred Task.
        let cursor = await seams.hands.cursorLocation()
        let outcome = await drove(action, in: target, shell: shell)
        await seams.hands.restoreCursor(to: cursor)
        return outcome
    }

    private func drove(
        _ action: MediaAction, in target: BrowserTarget, shell: WebSurfaceAX.Reading
    ) async -> BrowserOutcome {
        let before: MediaControlReading
        switch await perceive(target, shell: shell, intent: .media, reveal: true) {
        case .failure(let refusal): return refuse(refusal)
        case .success(let reading):
            guard let media = reading.media, media.controlsVisible else {
                return refuse(.controlsNotFound)
            }
            before = media
        }

        // ASKING FOR THE STATE IT IS ALREADY IN IS A SUCCESS THAT PRESSES NOTHING.
        // Pressing play on a playing video pauses it, which is the opposite of what
        // was asked for — the most annoying possible way to be wrong.
        if let settled = Self.alreadySatisfied(action, by: before) {
            return BrowserOutcome(ok: true, spoken: settled, shell: shell, media: before)
        }

        guard let (point, what) = Self.target(for: action, in: before) else {
            return refuse(.controlNotFound(Self.controlNoun(for: action)))
        }

        if dryRun {
            return refuse(.dryRun("clicked \(what) at (\(Int(point.x)), \(Int(point.y)))"))
        }
        // MOVE TO IT, THEN PRESS IT — the way a hand does, and the way the page needs.
        // A posted click alone lands on whatever the page believes is under the pointer,
        // which after the reveal is the middle of the picture, not the button: measured,
        // as a click that reported success and paused nothing.
        await seams.hands.hover(at: point, pid: target.processIdentifier)
        await seams.sleep(Self.pressSettle)
        await seams.hands.click(at: point, pid: target.processIdentifier)
        emit(.acted("clicked \(what)"))
        await seams.sleep(Self.actSettle)

        // Keep the pointer over the page so the transport stays up for the second look.
        let after: MediaControlReading
        switch await perceive(
            target, shell: shell, intent: .media, reveal: true, previous: before
        ) {
        case .failure(let refusal): return refuse(refusal)
        case .success(let reading):
            guard let media = reading.media else { return refuse(.controlsNotFound) }
            after = media
        }

        guard let verdict = Self.verify(action, before: before, after: after) else {
            return refuse(.stateUnchanged(
                expected: Self.expected(action),
                observed: Self.observed(action, in: after)))
        }
        emit(.verified(verdict))
        return BrowserOutcome(
            ok: true, spoken: "\(action.spokenPast) — \(after.spoken)",
            shell: shell, media: after)
    }

    // MARK: - Navigating

    public func navigate(_ request: NavigationRequest, in target: BrowserTarget) async -> BrowserOutcome {
        let shellOutcome = await readShell(target)
        guard let shell = shellOutcome.shell else { return shellOutcome }
        guard await seams.stage.bringForward(pid: target.processIdentifier) else {
            return refuse(.activationRefused(target.spokenName))
        }
        let schema = target.registration.schema

        switch request {
        case .open(let address):
            if dryRun { return refuse(.dryRun("opened \(address)")) }
            guard await seams.shell.openLocation(
                address, pid: target.processIdentifier, registration: target.registration)
            else { return refuse(.addressFieldNotFound) }
            emit(.acted("typed an address"))
            return await settle(target, from: shell, saying: "Opened")

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
                label: label, pid: target.processIdentifier, registration: target.registration)
            else { return refuse(.elementNotFound(label)) }
            emit(.acted("pressed \(label)"))
            return await settle(
                target, from: shell,
                saying: request == .reload ? "Reloaded" : "Went \(request == .back ? "back" : "forward")")

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

    /// Wait for the address or the title to change, and stay changed.
    private func settle(
        _ target: BrowserTarget, from before: WebSurfaceAX.Reading, saying verb: String
    ) async -> BrowserOutcome {
        var stable = 0
        var latest = before
        let deadline = seams.now().addingTimeInterval(
            Double(Self.navigationBudget.components.seconds))
        while seams.now() < deadline {
            await seams.sleep(Self.navigationPoll)
            guard let reading = await seams.shell.read(
                pid: target.processIdentifier, registration: target.registration)
            else { continue }
            let moved = reading.url != before.url || reading.title != before.title
            if moved && reading.title == latest.title && reading.url == latest.url {
                stable += 1
            } else {
                stable = moved ? 1 : 0
            }
            latest = reading
            // TWO AGREEING POLLS, because a title flickers to the bare host and then to
            // the page's real name; reporting the first one names the wrong page.
            if stable >= 2 {
                lastChrome = reading
                emit(.verified("the page changed"))
                let site = reading.siteName.map { " at \($0)" } ?? ""
                return BrowserOutcome(
                    ok: true,
                    spoken: "\(verb) \(reading.title ?? "the page")\(site).",
                    shell: reading)
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

    /// Where to click, and what to call it.
    static func target(
        for action: MediaAction, in media: MediaControlReading
    ) -> (CGPoint, String)? {
        switch action {
        case .play, .pause, .toggle:
            guard let control = media.playPause else { return nil }
            return (control.clickPoint, "the transport")
        case .mute, .unmute:
            guard let control = media.volume else { return nil }
            return (control.clickPoint, "the volume control")
        case .fullscreen:
            guard let control = media.fullscreen else { return nil }
            return (control.clickPoint, "the full screen control")
        case .seek(let fraction):
            guard let point = media.seekPoint(fraction: fraction) else { return nil }
            return (point, "the progress bar")
        }
    }

    static func controlNoun(for action: MediaAction) -> String {
        switch action {
        case .play, .pause, .toggle: return "play"
        case .mute, .unmute: return "volume"
        case .fullscreen: return "full screen"
        case .seek: return "progress"
        }
    }

    /// Did it land. Nil means it did not, and the caller refuses.
    ///
    /// PIN: MUTE HAS NO TEMPORAL WITNESS. Sound is not visible, so the only evidence is
    /// the glyph flipping — a weaker receipt than playback's, and the reason this
    /// returns a sentence naming which evidence was used rather than a bare Bool.
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
            // that the transport moved to the bottom of a much larger frame.
            guard let beforeBar = before.bar, let afterBar = after.bar else { return nil }
            return afterBar.height > beforeBar.height * 1.2 ? "the player grew" : nil
        case .seek(let fraction):
            guard let now = after.progress?.fraction else { return nil }
            if abs(now - fraction) <= 0.05 { return "the position is where it was asked for" }
            guard let was = before.progress?.fraction else { return nil }
            return abs(now - was) > 0.02 ? "the position moved" : nil
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
