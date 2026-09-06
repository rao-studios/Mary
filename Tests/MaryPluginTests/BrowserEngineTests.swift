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

// MARK: - Fakes

final class FakeShell: BrowserShellReading, @unchecked Sendable {
    var readings: [WebSurfaceAX.Reading?]
    var opened: [String] = []
    var pressed: [String] = []
    var openSucceeds = true
    var pressSucceeds = true

    init(_ readings: [WebSurfaceAX.Reading?]) { self.readings = readings }

    func read(pid: pid_t, registration: WebSurfaceRegistration) async -> WebSurfaceAX.Reading? {
        readings.count > 1 ? readings.removeFirst() : readings.first ?? nil
    }

    func openLocation(_ address: String, pid: pid_t, registration: WebSurfaceRegistration) async -> Bool {
        opened.append(address)
        return openSucceeds
    }

    func press(label: String, pid: pid_t, registration: WebSurfaceRegistration) async -> Bool {
        pressed.append(label)
        return pressSucceeds
    }
}

final class FakePage: PagePerceiving, @unchecked Sendable {
    var readings: [MediaControlReading?]
    var failure: VisionPageReader.Failure?
    var reads = 0
    /// Rosters served to `.elements`, one per read; the last one repeats.
    var pages: [(elements: [AXScreenElement], map: PageMapSummary)] = []
    var elementReads = 0

    init(_ readings: [MediaControlReading?], failure: VisionPageReader.Failure? = nil) {
        self.readings = readings
        self.failure = failure
    }

    convenience init(pages: [(elements: [AXScreenElement], map: PageMapSummary)]) {
        self.init([nil])
        self.pages = pages
    }

    func read(
        pid: pid_t, windowID: CGWindowID?, pageFrame: CGRect,
        intent: VisionPageReader.Intent, appName: String, windowTitle: String,
        previousFraction: Double?, previousElapsed: TimeInterval?
    ) async throws -> VisionPageReader.Reading {
        if let failure { throw failure }
        reads += 1
        if intent == .elements {
            let index = min(elementReads, max(0, pages.count - 1))
            elementReads += 1
            let page: (elements: [AXScreenElement], map: PageMapSummary) =
                pages.isEmpty ? (elements: [], map: PageMapSummary()) : pages[index]
            return VisionPageReader.Reading(
                elements: page.elements, pageFrame: pageFrame, pixelsPerPoint: 1,
                classified: true, map: page.map)
        }
        let media = readings.count > 1 ? readings.removeFirst() : readings.first ?? nil
        return VisionPageReader.Reading(
            media: media, pageFrame: pageFrame, pixelsPerPoint: 1)
    }
}

final class FakeHands: BrowserHands, @unchecked Sendable {
    var clicks: [CGPoint] = []
    var hovers: [CGPoint] = []
    var glides: [CGPoint] = []
    var drags: [(CGPoint, CGPoint)] = []
    var scrolls: [Double] = []
    var restored: [CGPoint?] = []

    func move(to point: CGPoint, pid: pid_t) async {}
    func click(
        at point: CGPoint, button: PluginPointerButton, count: Int, pid: pid_t
    ) async {
        clicks.append(point)
    }
    func scroll(at point: CGPoint, by delta: Double, pid: pid_t) async {
        scrolls.append(delta)
    }
    func hover(at point: CGPoint, pid: pid_t) async { hovers.append(point) }
    func glide(to point: CGPoint, pid: pid_t) async { glides.append(point) }
    func drag(from: CGPoint, to: CGPoint, duration: Double, pid: pid_t) async {
        drags.append((from, to))
    }
    func cursorLocation() async -> CGPoint? { CGPoint(x: 5, y: 5) }
    func restoreCursor(to point: CGPoint?) async { restored.append(point) }
}

final class FakeKeys: BrowserKeys, @unchecked Sendable {
    var typed: [String] = []
    var pressed: [PageInteractionKey] = []
    var typeSucceeds = true

    func type(_ text: String, targetPrefix: String) async -> Bool {
        typed.append(text)
        return typeSucceeds
    }

    func press(_ key: PageInteractionKey) async -> Bool {
        pressed.append(key)
        return true
    }
}

final class FakeStage: BrowserStaging, @unchecked Sendable {
    var succeeds = true
    var keepsFocus = true
    /// Who is in front before the act — the process the stage may be owed to.
    var front: pid_t?
    /// Every pid the stage was taken for, in order.
    var taken: [pid_t] = []
    /// Every stand-down, with the pid the stage was given back to (nil: kept).
    var stoodDown: [pid_t?] = []

    init(succeeds: Bool = true, keepsFocus: Bool = true, front: pid_t? = nil) {
        self.succeeds = succeeds
        self.keepsFocus = keepsFocus
        self.front = front
    }

    func frontmost() async -> pid_t? { front }
    func bringForward(pid: pid_t) async -> Activation {
        taken.append(pid)
        return succeeds ? Activation(road: .cooperative, failure: nil) : .lost(.refused)
    }
    func standDown(givingBackTo previous: pid_t?) async { stoodDown.append(previous) }
    func holdsFocus(pid: pid_t) async -> Bool { keepsFocus }
}

// MARK: - Support

enum BrowsingFixtures {

    static let pageFrame = CGRect(x: 100, y: 200, width: 800, height: 600)

    static func target() -> BrowserTarget {
        BrowserTarget(
            registration: WebSurfaceRegistration(
                applicationID: "a-browser",
                bundleIdentifiers: ["test.browser"],
                displayName: "A Browser",
                schema: PluginWebSurfaceSchema(
                    addressFieldLabel: "address",
                    backLabel: "Back", forwardLabel: "Forward", reloadLabel: "Reload")),
            processIdentifier: 1234)
    }

    static func shell(
        title: String = "A Page", url: String? = "https://example.com/x",
        canGoBack: Bool? = true
    ) -> WebSurfaceAX.Reading {
        WebSurfaceAX.Reading(
            title: title, url: url, pageFrame: pageFrame, pageFrameSource: "test",
            canGoBack: canGoBack, canGoForward: false, tabs: ["A Page"],
            windowFrame: pageFrame)
    }

    static func media(
        playing: MediaControlReading.Playback = .paused,
        fraction: Double = 0.2,
        muted: Bool? = nil,
        controlsVisible: Bool = true
    ) -> MediaControlReading {
        let volume: MediaControlReading.Control? = muted.map {
            .init(frame: CGRect(x: 180, y: 700, width: 20, height: 20),
                  glyph: $0 ? .muted : .volume, confidence: 0.6)
        }
        return MediaControlReading(
            pageFrame: pageFrame,
            controlsVisible: controlsVisible,
            playback: playing,
            playPause: .init(
                frame: CGRect(x: 120, y: 700, width: 20, height: 20),
                glyph: playing == .playing ? .pause : .play, confidence: 0.7),
            volume: volume,
            progress: .init(
                frame: CGRect(x: 110, y: 680, width: 780, height: 4), fraction: fraction))
    }

    /// One page's worth of rows, with the map that describes them.
    static func page(
        _ rows: [(role: String, label: String, affordance: SeenAffordance)],
        group: (kind: String, title: String?)? = nil,
        source: SeenAffordanceSource = .classifier,
        labelSource: SeenLabelSource = .textInside,
        hints: [Int: [String]] = [:],
        confidence: Double = 0
    ) -> (elements: [AXScreenElement], map: PageMapSummary) {
        var elements: [AXScreenElement] = []
        var annotations: [Int: SeenElementAnnotation] = [:]
        for (index, row) in rows.enumerated() {
            let ordinal = index + 1
            elements.append(AXScreenElement(
                ordinal: ordinal,
                id: AXNodeID(raw: UInt(ordinal)),
                pid: 1234,
                appName: "A Browser",
                windowID: AXNodeID(raw: 1),
                windowTitle: "A Page",
                role: row.role,
                category: AXNodeCategory.category(role: row.role),
                label: row.label,
                frame: CGRect(
                    x: 140, y: 240 + CGFloat(index) * 60, width: 400, height: 40),
                containerTrail: group.map { [$0.title, $0.kind].compactMap { $0 } } ?? [],
                provenance: .seen))
            annotations[ordinal] = SeenElementAnnotation(
                affordance: row.affordance,
                affordanceSource: source,
                labelSource: labelSource,
                hints: hints[ordinal] ?? [],
                groupID: group == nil ? nil : 0,
                confidence: confidence)
        }
        let groups = group.map { described in
            [SeenGroup(
                id: 0, kind: described.kind, title: described.title,
                memberOrdinals: Array(1 ... max(1, rows.count)))]
        } ?? []
        return (elements, PageMapSummary(
            groups: groups, annotations: annotations, labeledFraction: 1))
    }

    /// PIN: THE CLOCK IS A FAKE TOO. The settle loop polls until a deadline, so a real
    /// `Date()` makes the stalled-navigation test wait the whole budget — ten seconds of
    /// a suite spent proving something arithmetic. This advances a second per reading.
    static func engine(
        shell: FakeShell, page: FakePage, hands: FakeHands = FakeHands(),
        keys: FakeKeys = FakeKeys(), stage: FakeStage = FakeStage(), dryRun: Bool = false
    ) -> BrowserEngine {
        let clock = Clock()
        return BrowserEngine(
            seams: .init(
                shell: shell, page: page, hands: hands, keys: keys, stage: stage,
                // ITS OWN SLATE. The suite runs in parallel and the shared one is
                // process-wide, so two engines publishing into it answered each other's
                // questions — a failure that appeared and vanished with test order.
                slate: AmbientElementIndexStore(),
                sleep: { _ in clock.advance(1) }, now: { clock.now }),
            dryRun: dryRun)
    }

    final class Clock: @unchecked Sendable {
        private let start = Date(timeIntervalSince1970: 1_000_000)
        private var elapsed: TimeInterval = 0
        var now: Date { start.addingTimeInterval(elapsed) }
        func advance(_ seconds: TimeInterval) { elapsed += seconds }
    }
}

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

    /// THE ORDINARY CASE: what was typed, plus whatever the omnibox appended.
    @Test func theFullAddressWithATrailingSuggestionLands() {
        #expect(LiveBrowserShell.addressLanded(
            intended: "https://youtube.com",
            fieldValue: "https://youtube.com/results?search_query=old+history+entry"))
        #expect(LiveBrowserShell.addressLanded(
            intended: "a fred again video on youtube", fieldValue: "a fred again video on youtube"))
    }

    /// CHROME ELIDES WHAT IT DISPLAYS. Once a typed address is recognised — and
    /// especially once it is in history and being completed — the omnibox shows
    /// it without its scheme and without a leading "www.". MEASURED LIVE: the
    /// same navigation worked while the address was new and failed three times
    /// over, as "couldn't find the address bar", once it was in history. A correct
    /// type that reads back elided has landed.
    @Test func anElidedReadbackOfTheSameAddressLands() {
        #expect(LiveBrowserShell.addressLanded(
            intended: "https://en.wikipedia.org/wiki/Ski_touring",
            fieldValue: "en.wikipedia.org/wiki/Ski_touring"))
        #expect(LiveBrowserShell.addressLanded(
            intended: "https://www.ecosia.org/search?q=alpine",
            fieldValue: "ecosia.org/search?q=alpine"))
        // And a scheme that stayed still lands, elided or not.
        #expect(LiveBrowserShell.addressLanded(
            intended: "https://www.ecosia.org/", fieldValue: "https://ecosia.org/"))
    }

    /// AND ONLY THE SAME ADDRESS. A completion to a DIFFERENT destination must
    /// still fail here, because failing is what lets forward-delete remove it
    /// before Return accepts it — the measured "swift concurrency opened
    /// YouTube" defect. Looser than an elision would put that bug back.
    @Test func aCompletionToADifferentAddressStillDoesNotLand() {
        #expect(!LiveBrowserShell.addressLanded(
            intended: "https://en.wikipedia.org/wiki/Ski_touring",
            fieldValue: "en.wikipedia.org/wiki/Skiing"))
        #expect(!LiveBrowserShell.addressLanded(
            intended: "https://example.com/", fieldValue: "example.org/"))
    }

    /// THE MEASURED FAILURE. A chunk-boundary race replaces the field's own selection
    /// rather than appending to it, so what survives is a SUFFIX of what was typed —
    /// never a prefix match against the intended string.
    @Test func aChunkThatWipedTheFrontDoesNotLand() {
        #expect(!LiveBrowserShell.addressLanded(
            intended: "Let's watch a fred again video on youtube",
            fieldValue: "red again video on youtube"))
    }

    /// NOTHING READABLE IS NOT PROOF OF ANYTHING.
    @Test func noFieldValueAtAllDoesNotLand() {
        #expect(!LiveBrowserShell.addressLanded(intended: "https://youtube.com", fieldValue: nil))
    }

    /// A SHORTER FIELD THAN INTENDED — focus lost mid-run, or a stale read — is not a
    /// prefix of itself against the fuller intended string.
    @Test func aTruncatedTailDoesNotLand() {
        #expect(!LiveBrowserShell.addressLanded(
            intended: "a fred again video on youtube", fieldValue: "a fred again vid"))
    }
}
