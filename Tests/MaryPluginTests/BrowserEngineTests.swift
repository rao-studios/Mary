//
//  BrowserEngineTests.swift
//  MaryPluginTests
//
//  WHAT: The browsing engine's decisions, against fakes — including every way it
//        refuses.
//  OUT:  BrowserEngine.Seams
//  PIN:  THE REFUSALS ARE THE POINT. A browsing turn has a dozen ways not to happen and
//        the person is owed which one; a path nobody can reach in a test is a path
//        nobody has read. The seams exist so each is reachable without a browser.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryAmbient
import MaryComputerUse
@testable import MaryFoundation
@testable import MaryPlugin

// MARK: - Tests

@Suite struct BrowserEngineReadingTests {

    @Test func readingTheShellSaysThePageAndTheSite() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]), page: FakePage([nil]))
        let outcome = await engine.readShell(BrowsingFixtures.target())
        #expect(outcome.ok)
        #expect(outcome.spoken.contains("A Page"))
        #expect(outcome.spoken.contains("example"), "the site is named")
        #expect(!outcome.spoken.contains("https"), "the address is never spoken")
    }

    /// AN UNREADABLE WINDOW IS NAMED AS SUCH, not reported as an empty browser.
    @Test func anUnreadableWindowRefusesByName() async {
        let engine = BrowsingFixtures.engine(shell: FakeShell([nil]), page: FakePage([nil]))
        let outcome = await engine.readShell(BrowsingFixtures.target())
        #expect(!outcome.ok)
        #expect(outcome.refusal == .shellUnreadable("A Browser"))
    }

    @Test func aPageWithNoFrameCannotBeLookedAt() async {
        var shell = BrowsingFixtures.shell()
        shell.pageFrame = nil
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([shell]), page: FakePage([BrowsingFixtures.media()]))
        let outcome = await engine.describeMedia(in: BrowsingFixtures.target())
        #expect(outcome.refusal == .pageNotVisible)
    }

    /// Hidden controls are a STATE, and the engine looks again before believing it.
    @Test func hiddenControlsAreRetriedThenRefused() async {
        let page = FakePage([BrowsingFixtures.media(controlsVisible: false)])
        let engine = BrowsingFixtures.engine(shell: FakeShell([BrowsingFixtures.shell()]), page: page)
        let outcome = await engine.describeMedia(in: BrowsingFixtures.target())
        #expect(outcome.refusal == .controlsNotFound)
        #expect(page.reads > 1, "the engine looked again before giving up")
    }

    /// AND IT PUTS THE POINTER BACK, wherever the look ended.
    @Test func theCursorIsAlwaysRestored() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media()]), hands: hands)
        _ = await engine.describeMedia(in: BrowsingFixtures.target())
        #expect(hands.restored == [CGPoint(x: 5, y: 5)])
    }

    @Test func visionFailingIsReportedAsVisionFailing() async {
        let page = FakePage([], failure: .visionUnavailable("no engine"))
        let engine = BrowsingFixtures.engine(shell: FakeShell([BrowsingFixtures.shell()]), page: page)
        let outcome = await engine.describeMedia(in: BrowsingFixtures.target())
        guard case .visionUnavailable = outcome.refusal else {
            Issue.record("expected a vision refusal, got \(String(describing: outcome.refusal))")
            return
        }
    }
}

@Suite struct BrowserEngineDrivingTests {

    /// THE STATE MOVING IS THE RECEIPT. A press that changed nothing is a refusal, not a
    /// success with a caveat.
    @Test func aPressThatChangesNothingRefuses() async {
        let page = FakePage([BrowsingFixtures.media(playing: .paused)])
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]), page: page, hands: hands)
        let outcome = await engine.controlMedia(.toggle, in: BrowsingFixtures.target())
        #expect(!outcome.ok)
        #expect(outcome.refusal == .stateUnchanged(expected: "a different state", observed: "paused"))
        #expect(hands.clicks.count == 1, "it did press something")
    }

    @Test func aPressThatFlipsPlaybackIsAccepted() async {
        let page = FakePage([
            BrowsingFixtures.media(playing: .paused),
            BrowsingFixtures.media(playing: .playing),
        ])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]), page: page)
        let outcome = await engine.controlMedia(.toggle, in: BrowsingFixtures.target())
        #expect(outcome.ok)
        #expect(outcome.spoken.contains("Playing"))
    }

    /// ASKING FOR THE STATE IT IS ALREADY IN PRESSES NOTHING. Pressing play on a playing
    /// video pauses it — the opposite of what was asked.
    @Test func askingForTheStateItIsInPressesNothing() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media(playing: .playing)]), hands: hands)
        let outcome = await engine.controlMedia(.play, in: BrowsingFixtures.target())
        #expect(outcome.ok)
        #expect(hands.clicks.isEmpty)
        #expect(outcome.spoken.contains("already"))
    }

    /// A control the page does not show is named in the refusal.
    @Test func aMissingControlIsNamed() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media(muted: nil)]))
        let outcome = await engine.controlMedia(.mute, in: BrowsingFixtures.target())
        #expect(outcome.refusal == .controlNotFound("volume"))
    }

    /// A seek aims at the track, and lands where it was asked to.
    @Test func aSeekAimsAtTheTrackAndIsVerified() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([
                BrowsingFixtures.media(fraction: 0.1),
                BrowsingFixtures.media(fraction: 0.5),
            ]), hands: hands)
        let outcome = await engine.controlMedia(.seek(fraction: 0.5), in: BrowsingFixtures.target())
        #expect(outcome.ok)
        let click = try! #require(hands.clicks.first)
        #expect(click.x > 400 && click.x < 600, "the click is halfway along the track")
        #expect(abs(click.y - 682) < 6, "and on it")
    }

    /// THE OBSERVE-ONLY MODE TOUCHES NOTHING and says what it would have done.
    @Test func aDryRunActsOnNothing() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media()]), hands: hands, dryRun: true)
        let outcome = await engine.controlMedia(.toggle, in: BrowsingFixtures.target())
        #expect(hands.clicks.isEmpty)
        guard case .dryRun(let what) = outcome.refusal else {
            Issue.record("expected a dry run, got \(String(describing: outcome.refusal))")
            return
        }
        #expect(what.contains("transport"))
    }

    // MARK: - Tabs

    /// WHICH TAB A PHRASE MEANS: a position, "the other one", or a title with
    /// the asking removed.
    @Test func aTabIsNamedByPositionOtherOrTitle() {
        var shell = BrowsingFixtures.shell()
        shell.tabs = ["File:Big Buck Bunny 4K.webm - Wikimedia Commons", "about:blank"]
        shell.activeTabIndex = 0
        #expect(BrowserEngine.tabIndex(for: "the second tab", in: shell) == 1)
        #expect(BrowserEngine.tabIndex(for: "go to the first tab", in: shell) == 0)
        #expect(BrowserEngine.tabIndex(for: "the other one", in: shell) == 1)
        #expect(BrowserEngine.tabIndex(for: "switch to the blank tab", in: shell) == 1)
        #expect(BrowserEngine.tabIndex(for: "the big buck bunny tab", in: shell) == 0)
        #expect(BrowserEngine.tabIndex(for: "the weather tab", in: shell) == nil)
    }

    // MARK: - A time, as a place on the track

    /// "GO BACK TWO MINUTES" IS A FRACTION ONCE THE CLOCK IS KNOWN. The reading
    /// carries the clock; the seek is resolved against it and pressed on the
    /// track like any other, and the receipt speaks the time that was asked.
    @Test func aTimeSeekIsResolvedAgainstTheClockAndProved() async {
        var before = BrowsingFixtures.media(playing: .playing, fraction: 0.5)
        before.elapsed = 300
        before.duration = 600
        let after = BrowsingFixtures.media(playing: .playing, fraction: 0.3)
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([before, after]), hands: hands)
        let outcome = await engine.controlMedia(
            .seekBy(seconds: -120), in: BrowsingFixtures.target())
        #expect(outcome.ok)
        #expect(outcome.landed)
        #expect(outcome.spoken.hasPrefix("Went back 2:00"))
        // Pressed at 3/10 of the track: the fixture's track spans x 110...890.
        let expected = before.seekPoint(fraction: 0.3)
        #expect(hands.clicks.count == 1)
        #expect(hands.clicks.first.map { abs($0.x - (expected?.x ?? -1)) < 2 } == true)
    }

    @Test func anAbsoluteTimeSeekLandsAtThatTime() async {
        var before = BrowsingFixtures.media(playing: .playing, fraction: 0.5)
        before.elapsed = 300
        before.duration = 600
        let after = BrowsingFixtures.media(playing: .playing, fraction: 0.3)
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([before, after]))
        let outcome = await engine.controlMedia(
            .seekTo(seconds: 180), in: BrowsingFixtures.target())
        #expect(outcome.landed)
        #expect(outcome.spoken.hasPrefix("Went to 3:00"))
    }

    /// THE PAGE'S OWN SLIDER IS THE TRACK when the picture showed none. A player
    /// hides its bar on a timer; the tree publishes the same bar as a slider,
    /// with its value and range, for as long as it is drawn. MEASURED: "I can
    /// see the player but not its progress control" about a track 879 points
    /// wide in the tree.
    @Test func aSeekWithNoVisibleTrackTakesThePagesSlider() async {
        var blind = BrowsingFixtures.media(playing: .playing)
        blind.progress = nil
        let track = CGRect(x: 120, y: 690, width: 760, height: 5)
        func slider(at seconds: Double) -> PageRow {
            PageRow(
                ordinal: 1, frame: track, label: "Progress Bar", affordance: .adjust,
                kind: .slider, provenance: .accessibility,
                value: seconds, minimumValue: 0, maximumValue: 600)
        }
        let picture = PageRow(
            ordinal: 2, frame: CGRect(x: 100, y: 200, width: 800, height: 450),
            label: "the picture", kind: .image)
        let page = FakePage([blind, blind])
        page.rowPages = [[picture, slider(at: 300)], [picture, slider(at: 180)]]
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]), page: page, hands: hands)

        let outcome = await engine.controlMedia(
            .seekBy(seconds: -120), in: BrowsingFixtures.target())
        #expect(outcome.landed, Comment(rawValue: outcome.spoken))
        #expect(outcome.spoken.hasPrefix("Went back 2:00"))
        // Pressed on the slider's own frame, three tenths along.
        let click = hands.clicks.first
        #expect(click.map { track.contains($0) } == true, "\(String(describing: click))")
        #expect(click.map { abs($0.x - (track.minX + track.width * 0.3)) < track.width * 0.05 } == true)
    }

    /// NO CLOCK, NO GUESS: the refusal names the length, not the track.
    @Test func aTimeSeekWithNoClockRefusesByName() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media(playing: .playing)]), hands: hands)
        let outcome = await engine.controlMedia(
            .seekBy(seconds: -120), in: BrowsingFixtures.target())
        #expect(!outcome.ok)
        #expect(hands.clicks.isEmpty)
        #expect(outcome.spoken.contains("how long the video is"))
    }

    @Test func aWindowThatWillNotComeForwardRefusesAndSaysWhy() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media()]),
            stage: FakeStage(succeeds: false))
        let outcome = await engine.controlMedia(.toggle, in: BrowsingFixtures.target())
        #expect(outcome.refusal == .activationRefused("A Browser", .refused))
        // THE STAGE FACULTY'S OWN REASON, not one sentence for five conditions.
        #expect(outcome.spoken == "A Browser didn't come to the foreground.")
        #expect(
            BrowserRefusal.activationRefused("A Browser", .noVisibleWindow).summary
                != BrowserRefusal.activationRefused("A Browser", .notRunning).summary)
    }

    // MARK: - The stage

    /// THE SHELL IS READ AFTER THE STAGE IS TAKEN. A page frame measured while
    /// the window was behind another is the frame of a window nobody can see.
    @Test func theShellIsReadOnlyOnceTheStageIsTaken() async {
        let shell = FakeShell([BrowsingFixtures.shell()])
        let engine = BrowsingFixtures.engine(
            shell: shell, page: FakePage([BrowsingFixtures.media()]),
            stage: FakeStage(succeeds: false))
        _ = await engine.describeMedia(in: BrowsingFixtures.target())
        // A refused stage never reaches the shell: nothing was read at all.
        let snapshot = await engine.snapshot()
        #expect(snapshot.lastChrome == nil)
    }

    /// A VERB THAT ANSWERS A QUESTION GIVES THE STAGE BACK — invariant 3. "Mute
    /// the video" said from an editor leaves the editor in front.
    @Test func drivingThePlayerGivesTheStageBackToWhoeverHadIt() async {
        let stage = FakeStage(front: 777)
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([
                BrowsingFixtures.media(playing: .playing), BrowsingFixtures.media(playing: .paused),
            ]),
            stage: stage)
        _ = await engine.controlMedia(.pause, in: BrowsingFixtures.target())
        #expect(stage.taken == [BrowsingFixtures.target().processIdentifier])
        #expect(stage.stoodDown == [777])
    }

    /// A VERB THAT CHANGES WHERE THE PERSON IS LOOKING KEEPS THE STAGE. "Go to
    /// the site" from an editor is a request to see the browser.
    @Test func goingSomewhereKeepsTheStage() async {
        let stage = FakeStage(front: 777)
        let shell = FakeShell([
            BrowsingFixtures.shell(), BrowsingFixtures.shell(title: "Elsewhere", url: "https://example.org/"),
            BrowsingFixtures.shell(title: "Elsewhere", url: "https://example.org/"),
        ])
        let engine = BrowsingFixtures.engine(
            shell: shell, page: FakePage([nil]), stage: stage)
        _ = await engine.navigate(.open("https://example.org/"), in: BrowsingFixtures.target())
        #expect(stage.stoodDown == [nil])
    }

    /// THE BROWSER ALREADY IN FRONT IS OWED NOTHING. Giving the stage "back" to
    /// the browser would be an activation for its own sake.
    @Test func aBrowserAlreadyInFrontIsNotHandedBackToItself() async {
        let target = BrowsingFixtures.target()
        let stage = FakeStage(front: target.processIdentifier)
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media()]), stage: stage)
        _ = await engine.describeMedia(in: target)
        #expect(stage.stoodDown == [nil])
    }

    /// A DISABLED CONTROL IS AN OBSERVATION, NOT AN ERROR: there is simply nowhere to go.
    @Test func nowhereToGoBackToIsAnAnswerNotAFailure() async {
        let shell = FakeShell([BrowsingFixtures.shell(canGoBack: false)])
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]))
        let outcome = await engine.navigate(.back, in: BrowsingFixtures.target())
        #expect(outcome.ok)
        #expect(outcome.spoken.contains("nothing to go back to"))
        #expect(shell.pressed.isEmpty)
    }

    /// A navigation is proven by the page changing, and STAYING changed.
    @Test func aNavigationIsProvenByThePageChanging() async {
        let shell = FakeShell([
            BrowsingFixtures.shell(title: "Before", url: "https://before.example"),
            BrowsingFixtures.shell(title: "After", url: "https://after.example"),
            BrowsingFixtures.shell(title: "After", url: "https://after.example"),
            BrowsingFixtures.shell(title: "After", url: "https://after.example"),
        ])
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]))
        let outcome = await engine.navigate(
            .open("https://after.example"), in: BrowsingFixtures.target())
        #expect(outcome.ok)
        #expect(outcome.spoken.contains("After"))
        #expect(shell.opened == ["https://after.example"])
    }

    /// A PAGE THAT NEVER MOVES IS A STALLED NAVIGATION, not a quiet success.
    @Test func aPageThatNeverChangesIsAStall() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell(title: "Same")]), page: FakePage([nil]))
        let outcome = await engine.navigate(
            .open("https://elsewhere.example"), in: BrowsingFixtures.target())
        #expect(outcome.refusal == .navigationDidNotSettle)
    }
}

@Suite struct BrowserEngineWatchingTests {

    /// AN ENGINE THAT CANNOT BE WATCHED IS ONE NOBODY CAN EXPLAIN. Every act and every
    /// refusal reaches the snapshot, including the ones that did nothing.
    @Test func everyDecisionReachesTheSnapshot() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media(controlsVisible: false)]))
        _ = await engine.describeMedia(in: BrowsingFixtures.target())

        let snapshot = await engine.snapshot()
        #expect(snapshot.lastBrowser == "A Browser")
        #expect(snapshot.refusals > 0)
        #expect(snapshot.perceptions > 0)
        #expect(snapshot.lastRefusal == .controlsNotFound)
        #expect(!snapshot.recent.isEmpty, "the tail records what happened")
    }

    @Test func aWatcherSeesTheActsInOrder() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([
                BrowsingFixtures.media(playing: .paused),
                BrowsingFixtures.media(playing: .playing),
            ]))
        let events = await engine.events()
        let collected = Task { () -> [String] in
            var names: [String] = []
            for await event in events {
                switch event {
                case .resolved: names.append("resolved")
                case .shellRead: names.append("shellRead")
                case .perceived: names.append("perceived")
                case .acted: names.append("acted")
                case .read: names.append("read")
                case .routed: names.append("routed")
                case .matched: names.append("matched")
                case .receipt: names.append("receipt")
                case .verified: names.append("verified")
                case .refused: names.append("refused")
                }
                if names.contains("verified") { break }
            }
            return names
        }
        _ = await engine.controlMedia(.toggle, in: BrowsingFixtures.target())
        let names = await collected.value
        #expect(names.first == "resolved")
        #expect(names.contains("perceived"))
        #expect(names.contains("acted"))
        #expect(names.last == "verified")
    }
}

@Suite struct NavigationReceiptTests {

    /// A NAVIGATION IS RECEIPT RANK ONE, AND `landed` COMES FROM IT.
    ///
    /// PIN: MEASURED ACROSS SIX LEGS OF ROUND 0. A settled navigation returned
    /// success carrying no receipt at all, so every open, back, reload and search
    /// reported proven work as unproven — and the continuation nudge then asks the
    /// model for work that is already done.
    @Test func aSettledNavigationCarriesItsOwnReceipt() async {
        let shell = FakeShell([
            BrowsingFixtures.shell(title: "Before"),
            BrowsingFixtures.shell(title: "After"),
            BrowsingFixtures.shell(title: "After"),
            BrowsingFixtures.shell(title: "After"),
        ])
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]))

        let outcome = await engine.navigate(
            .open("https://example.com/"), in: BrowsingFixtures.target())

        #expect(outcome.ok)
        #expect(outcome.landed, "a proven navigation reported itself unproven")
        #expect(outcome.receipts.count == 1)
        #expect(outcome.receipts.first?.kind == .navigate)
        #expect(outcome.receipts.first?.landed == true)
        if case .verified(.navigation(let title)) = outcome.receipts.first?.effect {
            #expect(title == "After")
        } else {
            Issue.record("the receipt is not a verified navigation")
        }
    }

    /// A NAVIGATION THAT NEVER SETTLES CARRIES NOTHING, and says so.
    @Test func aStalledNavigationCarriesNoReceipt() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell(title: "Same")]),
            page: FakePage([nil]))

        let outcome = await engine.navigate(
            .open("https://example.com/"), in: BrowsingFixtures.target())

        #expect(outcome.refusal == .navigationDidNotSettle)
        #expect(outcome.receipts.isEmpty)
        #expect(!outcome.landed)
    }

    /// AND NO PLAN MAY AUTHOR ONE. It is the engine's own act, like a browser
    /// chord — refused with the same sentence as a kind nobody declared.
    @Test func aPlanMayNotNavigate() {
        let json = #"[{"kind": "navigate"}]"#
        switch PageInteractionPlanValidator.validate(planJSON: json) {
        case .valid:
            Issue.record("a model-authored plan was allowed to navigate")
        case .invalid(let issues):
            #expect(issues.contains { $0.code == .unknownKind })
        }
        #expect(PageInteractionCommandKind.navigate.isAuthorable == false)
        #expect(PageInteractionCommandKind.click.isAuthorable)
    }
}

@Suite struct MediaReceiptTests {

    static func reading(
        playing: Bool, centre: MediaControlReading.Control?, bar: Bool
    ) -> MediaControlReading {
        MediaControlReading(
            pageFrame: BrowsingFixtures.pageFrame,
            controlsVisible: bar,
            playback: playing ? .playing : .paused,
            playPause: bar
                ? .init(frame: CGRect(x: 120, y: 700, width: 20, height: 20),
                        glyph: playing ? .pause : .play, confidence: 0.7)
                : nil,
            centerGlyph: centre)
    }

    /// A PAUSED PLAYER OFTEN DRAWS NO BAR, AND THE CIRCLE IS THE CONTROL.
    ///
    /// PIN: MEASURED LIVE. A real watch page, paused, showed one big play circle
    /// over the picture and no control row anywhere — hovering it added only a
    /// volume icon. The lane refused `controlsNotFound` about a control the
    /// person was looking at. `controlsVisible` means "a bar was found", which is
    /// a different question from "is there anything to drive".
    @Test func aCentreGlyphIsATransport() {
        let centre = MediaControlReading.Control(
            frame: CGRect(x: 400, y: 400, width: 56, height: 56),
            glyph: .play, confidence: 0.4)
        #expect(BrowserEngine.hasTransport(
            Self.reading(playing: false, centre: centre, bar: false)))
        #expect(!BrowserEngine.hasTransport(
            Self.reading(playing: false, centre: nil, bar: false)))
    }

    /// AND IT IS PRESSED FOR THE VERBS IT CAN SERVE, AND ONLY THOSE. Volume,
    /// seek and full screen have no circle to fall back to and still refuse by
    /// name — a centre glyph is a play control, not a whole transport.
    @Test func theCentreGlyphServesPlayAndPauseOnly() {
        let centre = MediaControlReading.Control(
            frame: CGRect(x: 400, y: 400, width: 56, height: 56),
            glyph: .play, confidence: 0.4)
        let barless = Self.reading(playing: false, centre: centre, bar: false)

        #expect(BrowserEngine.target(for: .toggle, in: barless)?.0
            == CGPoint(x: 428, y: 428))
        #expect(BrowserEngine.target(for: .play, in: barless) != nil)
        #expect(BrowserEngine.target(for: .fullscreen, in: barless) == nil)
        #expect(BrowserEngine.target(for: .mute, in: barless) == nil)
    }

    /// THE BAR WINS WHEN THERE IS ONE. The circle is the fallback, not the
    /// preference — a drawn transport is the more precise control.
    @Test func theBarIsPreferredOverTheCircle() {
        let centre = MediaControlReading.Control(
            frame: CGRect(x: 400, y: 400, width: 56, height: 56),
            glyph: .play, confidence: 0.4)
        let both = Self.reading(playing: false, centre: centre, bar: true)
        #expect(BrowserEngine.target(for: .toggle, in: both)?.1 == "the transport")
    }
}

@Suite struct MediaVerdictTests {

    /// `bar` is DERIVED from the controls that were found (see the private
    /// extension in BrowserEngine), so a reading with no controls has no bar —
    /// which is exactly the case these tests are about.
    static func reading(
        muted: Bool? = nil, volume: Bool = false,
        page: CGRect = BrowsingFixtures.pageFrame,
        playback: MediaControlReading.Playback = .paused
    ) -> MediaControlReading {
        MediaControlReading(
            pageFrame: page,
            controlsVisible: volume,
            playback: playback,
            volume: volume
                ? .init(frame: CGRect(x: 180, y: 700, width: 20, height: 20),
                        glyph: muted == true ? .muted : .volume, confidence: 0.6)
                : nil)
    }

    /// "I CANNOT SEE WHETHER IT WORKED" IS NOT "IT DID NOT WORK".
    ///
    /// PIN: MEASURED. A mute on a player whose volume glyph the reading could not
    /// make out in either look was reported `stateUnchanged` — "I pressed it, but
    /// it's still unmuted" — about a video that had in fact gone silent. Sound is
    /// not visible; sometimes there is genuinely nothing to see.
    @Test func anIllegibleControlIsUnreadableRatherThanUnchanged() {
        let before = Self.reading(volume: false)
        let after = Self.reading(volume: false)
        guard case .unreadable(let why) = BrowserEngine.verdict(
            .mute, before: before, after: after) else {
            Issue.record("an illegible volume control was called unchanged")
            return
        }
        #expect(why.contains("not legible"))
    }

    /// AND A LEGIBLE CONTROL THAT DID NOT MOVE IS STILL `unchanged` — the
    /// distinction has to cut both ways or it is just a softer refusal.
    @Test func aLegibleControlThatDidNotMoveIsUnchanged() {
        let before = Self.reading(muted: false, volume: true)
        let after = Self.reading(muted: false, volume: true)
        guard case .unchanged = BrowserEngine.verdict(.mute, before: before, after: after)
        else {
            Issue.record("a legible control that did not move was excused")
            return
        }
    }

    /// FULL SCREEN IS READ FROM THE PAGE, WHICH THE SHELL ALREADY CARRIES.
    ///
    /// PIN: MEASURED LIVE — the frame went from the window below the toolbar to
    /// the whole window, 1266×765 to 1920×1080. The bar comparison this had could
    /// not fire, because no bar was legible on either side.
    @Test func fullScreenIsProvedByThePageGrowing() {
        let before = Self.reading(page: CGRect(x: 0, y: 0, width: 1266, height: 765))
        let after = Self.reading(page: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        guard case .proved(let proof) = BrowserEngine.verdict(
            .fullscreen, before: before, after: after) else {
            Issue.record("a page that filled the screen proved nothing")
            return
        }
        #expect(proof.contains("filled the screen"))
    }

    /// AND A PAGE THAT DID NOT GROW, WITH NO BAR EITHER SIDE, IS UNREADABLE.
    @Test func fullScreenWithNothingToCompareIsUnreadable() {
        let same = Self.reading(page: CGRect(x: 0, y: 0, width: 1266, height: 765))
        guard case .unreadable = BrowserEngine.verdict(
            .fullscreen, before: same, after: same) else {
            Issue.record("full screen with nothing legible was called unchanged")
            return
        }
    }
}

@Suite struct PlayerRegionTests {

    static func reading(_ frames: [CGRect]) -> VisionPageReader.Reading {
        VisionPageReader.Reading(
            rows: frames.enumerated().map { index, frame in
                PageRow(
                    ordinal: index + 1, frame: frame, label: "a row",
                    affordance: .none, kind: .image)
            },
            pageFrame: BrowsingFixtures.pageFrame,
            pixelsPerPoint: 1)
    }

    /// THE PICTURE, WHEN THE READING HELD ONE. A player is a large row shaped
    /// like video; hovering it is what makes the transport draw.
    ///
    /// PIN: MEASURED — the retries hovered fractions down the WHOLE page, which
    /// is right for a watch page whose picture fills the top two thirds and wrong
    /// for a file page or an article, where every depth landed on prose and the
    /// lane reported "no transport" for a page that plainly has one.
    @Test func theLargestVideoShapedRowIsThePlayer() {
        let page = BrowsingFixtures.pageFrame   // 800×600 at (100, 200)
        let player = CGRect(x: 200, y: 500, width: 480, height: 270)
        let found = BrowserEngine.playerRegion(
            in: Self.reading([
                CGRect(x: 110, y: 210, width: 300, height: 40),   // a banner, too thin
                player,
                CGRect(x: 120, y: 220, width: 60, height: 60),    // a thumbnail, too small
            ]),
            page: page)
        #expect(found == player)
    }

    /// A PAGE WITH NO PICTURE ANSWERS NOTHING, and the whole page is used —
    /// exactly the behaviour that was there before.
    @Test func aPageWithNoPictureAnswersNothing() {
        let page = BrowsingFixtures.pageFrame
        #expect(BrowserEngine.playerRegion(
            in: Self.reading([CGRect(x: 110, y: 210, width: 300, height: 20)]),
            page: page) == nil)
        #expect(BrowserEngine.playerRegion(in: Self.reading([]), page: page) == nil)
    }

    /// AND A TALL COLUMN IS NOT A PLAYER, however big it is.
    @Test func aTallColumnIsNotAPlayer() {
        let page = BrowsingFixtures.pageFrame
        #expect(BrowserEngine.playerRegion(
            in: Self.reading([CGRect(x: 110, y: 210, width: 300, height: 560)]),
            page: page) == nil)
    }
}

@Suite struct SettleArrivalTests {

    /// A RELOAD LANDS ON THE SAME TITLE, AND THAT IS AN ARRIVAL.
    ///
    /// PIN: MEASURED IN ROUND 0 — a reload and a back both burned the full ten
    /// second budget and reported `navigationDidNotSettle` about pages that had
    /// arrived perfectly well, because settle demanded the title DIFFER.
    @Test func aReloadOntoTheSameTitleArrives() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell(title: "A Page")]),
            page: FakePage([nil]))

        let outcome = await engine.navigate(.reload, in: BrowsingFixtures.target())

        #expect(outcome.ok, "a reload onto the same title was refused")
        #expect(outcome.landed)
        #expect(outcome.receipts.first?.kind == .navigate)
    }

    /// A BACK ONTO THE SAME TITLE ARRIVES WHEN THE HISTORY MOVED.
    ///
    /// PIN: QUIET ALONE WAS TOO WEAK, MEASURED LIVE. A back whose page had not
    /// changed within the quiet window was accepted, and Mary said "Went back"
    /// about a page she had not left — then "there's nothing to go forward to" a
    /// moment later, which is how the recording gave it away. A real back makes
    /// forward available, and that flip is free: the shell reading already
    /// carries it.
    @Test func aBackOntoTheSameTitleArrivesWhenHistoryMoved() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([
                BrowsingFixtures.shell(title: "A Page", canGoBack: true),
                BrowsingFixtures.shell(title: "A Page", canGoBack: false),
                BrowsingFixtures.shell(title: "A Page", canGoBack: false),
                BrowsingFixtures.shell(title: "A Page", canGoBack: false),
                BrowsingFixtures.shell(title: "A Page", canGoBack: false),
            ]),
            page: FakePage([nil]))

        let outcome = await engine.navigate(.back, in: BrowsingFixtures.target())

        #expect(outcome.ok)
        #expect(outcome.landed)
        #expect(outcome.receipts.first?.kind == .navigate)
    }

    /// AND A BACK THAT NEVER MOVED IS NOT AN ARRIVAL — the page is the same and
    /// the history is the same, so nothing happened and saying otherwise would be
    /// the lie this rule exists to stop.
    @Test func aBackThatNeverMovedIsRefused() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell(title: "A Page", canGoBack: true)]),
            page: FakePage([nil]))

        let outcome = await engine.navigate(.back, in: BrowsingFixtures.target())

        #expect(outcome.refusal == .navigationDidNotSettle)
        #expect(!outcome.landed)
    }

    /// BUT GOING SOMEWHERE NEW STILL HAS TO GO SOMEWHERE. Accepting a page that
    /// never moved would report a failed open as a success — the reason the two
    /// claims are kept apart rather than both loosened.
    @Test func anOpenOntoAPageThatNeverMovesIsStillRefused() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell(title: "A Page")]),
            page: FakePage([nil]))

        let outcome = await engine.navigate(
            .open("https://example.com/"), in: BrowsingFixtures.target())

        #expect(outcome.refusal == .navigationDidNotSettle)
        #expect(!outcome.landed)
    }

    /// A BLANK TITLE IS NOT AN ARRIVAL — a reload's empty frame must not be read
    /// as the settled page.
    @Test func aBlankFrameIsNotAnArrival() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell(title: "")]),
            page: FakePage([nil]))

        let outcome = await engine.navigate(.reload, in: BrowsingFixtures.target())

        #expect(outcome.refusal == .navigationDidNotSettle)
    }
}

@Suite struct AddressLandedTests {

    /// One readback of the address field against what was typed, and whether
    /// that counts as the address having landed.
    struct Readback: CustomTestStringConvertible {
        let claim: String
        let intended: String
        let field: String?
        let lands: Bool
        var testDescription: String { claim }
    }

    /// THE ORDINARY CASE LANDS: what was typed, plus whatever the omnibox appended.
    /// CHROME ELIDES WHAT IT DISPLAYS. Once a typed address is recognised — and
    /// especially once it is in history and being completed — the omnibox shows
    /// it without its scheme and without a leading "www.". MEASURED LIVE: the
    /// same navigation worked while the address was new and failed three times
    /// over, as "couldn't find the address bar", once it was in history. A correct
    /// type that reads back elided has landed.
    /// AND ONLY THE SAME ADDRESS. A completion to a DIFFERENT destination must
    /// still fail here, because failing is what lets forward-delete remove it
    /// before Return accepts it — the measured "swift concurrency opened
    /// YouTube" defect. Looser than an elision would put that bug back.
    /// THE MEASURED CHUNK RACE replaces the field's own selection rather than
    /// appending to it, so what survives is a SUFFIX of what was typed — never a
    /// prefix match. Nothing readable is not proof of anything, and a shorter
    /// field than intended — focus lost mid-run, or a stale read — is not a
    /// prefix of itself against the fuller intended string.
    static let readbacks: [Readback] = [
        Readback(claim: "the full address with a trailing suggestion",
                 intended: "https://youtube.com",
                 field: "https://youtube.com/results?search_query=old+history+entry", lands: true),
        Readback(claim: "a query read back as typed",
                 intended: "a fred again video on youtube",
                 field: "a fred again video on youtube", lands: true),
        Readback(claim: "the scheme elided",
                 intended: "https://en.wikipedia.org/wiki/Ski_touring",
                 field: "en.wikipedia.org/wiki/Ski_touring", lands: true),
        Readback(claim: "the scheme and www. elided",
                 intended: "https://www.ecosia.org/search?q=alpine",
                 field: "ecosia.org/search?q=alpine", lands: true),
        Readback(claim: "www. elided under a scheme that stayed",
                 intended: "https://www.ecosia.org/", field: "https://ecosia.org/", lands: true),
        Readback(claim: "a completion to a different page",
                 intended: "https://en.wikipedia.org/wiki/Ski_touring",
                 field: "en.wikipedia.org/wiki/Skiing", lands: false),
        Readback(claim: "a completion to a different host",
                 intended: "https://example.com/", field: "example.org/", lands: false),
        Readback(claim: "a chunk that wiped the front",
                 intended: "Let's watch a fred again video on youtube",
                 field: "red again video on youtube", lands: false),
        Readback(claim: "no field value at all",
                 intended: "https://youtube.com", field: nil, lands: false),
        Readback(claim: "a truncated tail",
                 intended: "a fred again video on youtube", field: "a fred again vid", lands: false),
    ]

    @Test(arguments: readbacks) func whatAReadbackProves(_ readback: Readback) {
        #expect(
            LiveBrowserShell.addressLanded(intended: readback.intended, fieldValue: readback.field)
                == readback.lands,
            "\(readback.claim)")
    }
}

// MARK: - The browser's own question

@Suite struct BrowserDialogEngineTests {

    static let asking = WebSurfaceAX.Dialog(
        title: "Confirm Form Resubmission",
        message: "Do you want to continue?",
        choices: ["Cancel", "Continue"])

    static func shell(asking dialog: WebSurfaceAX.Dialog? = asking) -> WebSurfaceAX.Reading {
        var reading = BrowsingFixtures.shell(title: "A Posted Page")
        reading.dialog = dialog
        return reading
    }

    /// THE DIALOG IS MODAL, SO A VERB THAT TOUCHES THE PAGE STOPS — with the
    /// browser's question and its choices, never with a scroll of a page nobody
    /// can see.
    @Test func aVerbOnThePageIsBlockedByTheQuestion() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([Self.shell()]), page: FakePage([nil]), hands: hands)
        let outcome = await engine.navigate(.scroll(by: 3), in: BrowsingFixtures.target())
        guard case .browserIsAsking(let question, let choices)? = outcome.refusal else {
            Issue.record("expected the browser's question, got \(outcome.spoken)")
            return
        }
        #expect(question.hasPrefix("Confirm Form Resubmission"))
        #expect(choices == ["Cancel", "Continue"])
        #expect(outcome.spoken.contains("\"Cancel\" or \"Continue\""))
        #expect(hands.scrolls.isEmpty)
        #expect(!outcome.landed)
    }

    /// A READ DESCRIBES THE QUESTION: it is what is on the page right now, and
    /// the rows underneath are not read.
    @Test func aReadDescribesTheQuestionInsteadOfThePage() async {
        let page = FakePage([nil])
        let engine = BrowsingFixtures.engine(shell: FakeShell([Self.shell()]), page: page)
        let outcome = await engine.readPage(in: BrowsingFixtures.target())
        #expect(outcome.ok)
        #expect(outcome.landed)
        #expect(outcome.spoken.hasPrefix("The browser is asking: Confirm Form Resubmission"))
        #expect(outcome.elements.isEmpty)
    }

    /// THE PERSON'S WORDS ANSWER IT. "press cancel" names a choice; the shell
    /// press sends it; the dialog gone from the next reading is the receipt.
    @Test func wordsThatNameAChoiceAnswerIt() async {
        let shell = FakeShell([Self.shell(), Self.shell(asking: nil)])
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]))
        let outcome = await engine.pressOnPage("press cancel", in: BrowsingFixtures.target())
        #expect(outcome.ok)
        #expect(outcome.landed)
        #expect(shell.pressed == ["Cancel"])
        #expect(outcome.receipts.first?.effect == .verified(.dialogAnswered("Cancel")))
        #expect(outcome.shell?.dialog == nil)
    }

    /// WORDS THAT NAME NO CHOICE PUT THE QUESTION BACK. Nothing is pressed on
    /// Mary's own account — a resubmission is a write the person did once.
    @Test func wordsThatNameNoChoicePressNothing() async {
        let shell = FakeShell([Self.shell()])
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]))
        let outcome = await engine.pressOnPage("the first link", in: BrowsingFixtures.target())
        guard case .browserIsAsking? = outcome.refusal else {
            Issue.record("expected the question back, got \(outcome.spoken)")
            return
        }
        #expect(shell.pressed.isEmpty)
        let vague = await engine.pressOnPage("yes go ahead", in: BrowsingFixtures.target())
        #expect(vague.refusal != nil)
        #expect(shell.pressed.isEmpty)
    }

    /// A NAVIGATION THAT RAISES THE QUESTION REPORTS THE QUESTION. Measured: a
    /// reload of a posted page settled as "Reloaded" with the dialog up.
    @Test func aNavigationThatRaisesTheQuestionReportsIt() async {
        let shell = FakeShell([Self.shell(asking: nil), Self.shell()])
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]))
        let outcome = await engine.navigate(.reload, in: BrowsingFixtures.target())
        #expect(shell.pressed == ["Reload"])
        guard case .browserIsAsking? = outcome.refusal else {
            Issue.record("expected the browser's question, got \(outcome.spoken)")
            return
        }
        #expect(!outcome.landed)
    }

    /// The choice is matched as whole words, so "continue" does not answer
    /// "Discontinue", and "cancel the order" still names "Cancel".
    @Test func aChoiceIsNamedByItsWholeWords() {
        let choices = ["Cancel", "Continue", "Don't save"]
        #expect(BrowserEngine.choices(named: "press continue", among: choices) == ["Continue"])
        #expect(BrowserEngine.choices(named: "cancel the order", among: choices) == ["Cancel"])
        #expect(BrowserEngine.choices(named: "don't save it", among: choices) == ["Don't save"])
        #expect(BrowserEngine.choices(named: "discontinue", among: choices).isEmpty)
        #expect(BrowserEngine.choices(named: "yes", among: choices).isEmpty)
    }
}

// MARK: - The window Mary works in

@Suite struct WorkingWindowTests {

    /// THE WINDOW OF THE LAST READ IS THE WINDOW OF THE NEXT ACT. Measured in
    /// round 9: a session working in "the main window" moved into the person's
    /// own window the moment they clicked it. The first read names a window;
    /// every read, press and raise after it asks for that one.
    @Test func theWindowReadOnceIsAskedForEverAfter() async {
        var first = BrowsingFixtures.shell(title: "A Page")
        first.windowID = 4242
        let shell = FakeShell([first, first, first, first])
        let stage = FakeStage()
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]), stage: stage)

        _ = await engine.navigate(.reload, in: BrowsingFixtures.target())
        #expect(stage.raised.first == .some(nil))
        #expect(shell.preferred.first == .some(nil))
        #expect(shell.preferred.dropFirst().allSatisfy { $0 == 4242 })
        #expect(shell.pressedWithin == [4242])
        #expect(await engine.snapshot().workingWindow == 4242)

        _ = await engine.navigate(.reload, in: BrowsingFixtures.target())
        #expect(stage.raised.last == 4242)
    }

    /// A RUNNER THAT OPENED THE WINDOW NAMES IT, and the first read does not guess.
    @Test func anAdoptedWindowIsAskedForFromTheFirstRead() async {
        let shell = FakeShell([BrowsingFixtures.shell(title: "A Page")])
        let stage = FakeStage()
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]), stage: stage)
        await engine.adopt(window: 77)
        _ = await engine.readShell(BrowsingFixtures.target())
        #expect(shell.preferred == [77])
        _ = await engine.navigate(.scroll(by: 1), in: BrowsingFixtures.target())
        #expect(stage.raised == [77])
    }
}

// MARK: - The clock, from one time

@Suite struct LoneClockTests {

    private static func media(elapsed: TimeInterval?, duration: TimeInterval?, fraction: Double?) -> MediaControlReading {
        var reading = BrowsingFixtures.media(playing: .playing, fraction: fraction ?? 0)
        reading.elapsed = elapsed
        reading.duration = duration
        if fraction == nil { reading.progress = nil }
        return reading
    }

    /// Measured: "0:22 / 10:34" read as a lone "10:34" three seconds in. At the
    /// start of the track a lone time is the length; further in, the track's
    /// own fraction turns one time into both.
    @Test(arguments: [
        (lone: 634.0, fraction: 0.01, elapsed: 0.0, duration: 634.0),
        (lone: 300.0, fraction: 0.5, elapsed: 300.0, duration: 600.0),
    ]) func aLoneTimeAndAFractionAreAWholeClock(
        _ read: (lone: Double, fraction: Double, elapsed: Double, duration: Double)
    ) {
        let clock = BrowserEngine.clock(
            from: Self.media(elapsed: read.lone, duration: nil, fraction: read.fraction))
        #expect(clock?.elapsed == read.elapsed)
        #expect(clock?.duration == read.duration)
    }

    /// The page's own rows carry the clock as text: "Current Time 0:22" and
    /// "Duration 10:34" beside the bar. Left to right, shortest to longest.
    @Test func thePagesRowsCarryTheClock() {
        func row(_ ordinal: Int, _ label: String, x: CGFloat, y: CGFloat = 690) -> PageRow {
            PageRow(
                ordinal: ordinal, frame: CGRect(x: x, y: y, width: 40, height: 16),
                label: label, labelSource: .textInside, affordance: .none,
                affordanceSource: .classifier, kind: nil, facts: [])
        }
        let player = CGRect(x: 100, y: 200, width: 800, height: 500)
        let clock = BrowserEngine.clockRows(in: [
            row(1, "Current Time 0:22", x: 180), row(2, "Duration 10:34", x: 230),
            row(3, "Posted 12:00", x: 180, y: 1200),
        ], player: player)
        #expect(clock?.elapsed == 22)
        #expect(clock?.duration == 634)
        #expect(BrowserEngine.times(in: "1:02:03 of 2:00:00") == [3723, 7200])
        #expect(BrowserEngine.times(in: "no clock here").isEmpty)
    }

    /// A player's mute button is named for the act it would do next, so a
    /// button offering to unmute is a muted player.
    @Test func thePagesMuteButtonSaysWhichWayTheSoundIs() {
        func row(_ ordinal: Int, _ label: String, x: CGFloat, y: CGFloat = 690) -> PageRow {
            PageRow(
                ordinal: ordinal, frame: CGRect(x: x, y: y, width: 30, height: 30),
                label: label, labelSource: .textInside, affordance: .press,
                affordanceSource: .classifier, kind: .button, facts: [])
        }
        let player = CGRect(x: 100, y: 200, width: 800, height: 500)
        let muted = BrowserEngine.volumeState(in: [row(1, "Play", x: 110), row(2, "Unmute", x: 150)], player: player)
        #expect(muted?.muted == true)
        #expect(muted?.frame.minX == 150)
        let sounding = BrowserEngine.volumeState(in: [row(2, "Mute", x: 150)], player: player)
        #expect(sounding?.muted == false)
        // A "mute" button in the page's footer is not the player's.
        #expect(BrowserEngine.volumeState(in: [row(3, "Mute", x: 150, y: 1500)], player: player) == nil)
    }

    /// A poster's play button is a row named for the act, where it actually is.
    @Test func thePagesPlayButtonIsFoundByItsOwnWord() {
        func row(_ ordinal: Int, _ label: String, x: CGFloat, y: CGFloat) -> PageRow {
            PageRow(
                ordinal: ordinal, frame: CGRect(x: x, y: y, width: 60, height: 60),
                label: label, labelSource: .textInside, affordance: .press,
                affordanceSource: .classifier, kind: .button, facts: [])
        }
        let player = CGRect(x: 100, y: 200, width: 800, height: 500)
        let found = BrowserEngine.playerButton(
            named: ["play", "pause"],
            in: [row(1, "Download all sizes", x: 950, y: 220), row(2, "Play Video", x: 470, y: 420)],
            player: player)
        #expect(found?.ordinal == 2)
        #expect(BrowserEngine.playerButton(named: ["play"], in: [row(3, "Play", x: 100, y: 1500)], player: player) == nil)
    }

    /// And with no fraction there is nothing to divide by — the refusal stands.
    @Test func aLoneTimeWithNoTrackIsStillUnknown() {
        #expect(BrowserEngine.clock(from: Self.media(elapsed: 634, duration: nil, fraction: nil)) == nil)
        let whole = BrowserEngine.clock(from: Self.media(elapsed: 22, duration: 634, fraction: 0.03))
        #expect(whole?.elapsed == 22 && whole?.duration == 634)
    }
}
