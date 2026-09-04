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

struct FakeStage: BrowserStaging {
    var succeeds = true
    var keepsFocus = true
    func bringForward(pid: pid_t) async -> Bool { succeeds }
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
        group: (kind: String, title: String?)? = nil
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
                affordance: row.affordance, labelSource: .textInside)
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

    @Test func aWindowThatWillNotComeForwardRefuses() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media()]),
            stage: FakeStage(succeeds: false))
        let outcome = await engine.controlMedia(.toggle, in: BrowsingFixtures.target())
        #expect(outcome.refusal == .activationRefused("A Browser"))
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
