//
//  BrowserEngine+Media.swift
//  MaryPlugin
//
//  WHAT: The page's own player — look for its transport, describe it, drive one
//        control, and prove the state moved.
//  IN:   BrowserEngine.staged (the stage), PagePerceiving (the picture)
//  OUT:  describeMedia / controlMedia, and the pure decisions a media act makes
//  PIN:  EVERY EFFECT IS VERIFIED BY RE-PERCEIVING. The browser gives no return
//        value worth trusting — pressing a play button through synthetic input
//        succeeds whether or not anything played — so the receipt is a second
//        look, and a state that did not move is a REFUSAL, not a success with a
//        caveat. The clock and the geometry of the transport are in
//        BrowserEngine+MediaClock.swift; this file decides and acts.
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

extension BrowserEngine {
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
        // press — a second of hovering, settling and reading pixels. `press`
        // asks, and arrives by a hover: the transport exists while approached.
        guard await press(at: point, in: target, arriving: .hover) else {
            return refuse(.interrupted(atCommand: 0))
        }
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
}
