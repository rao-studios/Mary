//
//  DanceEngineTests.swift
//  MaryPluginTests
//
//  WHAT: The dance composes once, rehearses, keeps its beat inside the bounds,
//        and comes down — by the clock, by a stop, by a click, by a preempt.
//  OUT:  DanceEngine, DancePlugin.subject
//  PIN:  THE CLOCK IS A FAKE. Fifteen seconds of dance pass in the time it
//        takes to advance an integer; a suite that waited would be a suite
//        nobody runs.
//

import CoreGraphics
import Foundation
import MaryComputerUse
import Testing
@testable import MaryPlugin

final class FakeComposer: DanceComposing, @unchecked Sendable {
    var ready = true
    /// Replies in order; the last one repeats.
    var replies: [Result<DanceComposition, DanceComposerError>]
    private(set) var briefs: [DanceBrief] = []
    private let lock = NSLock()

    init(_ replies: [Result<DanceComposition, DanceComposerError>]) { self.replies = replies }

    static let good = DanceComposition(
        feeling: "Restless, mostly.",
        glsl: "```glsl\n" + ShaderPageTests.plasma + "\n```")
    static let bad = DanceComposition(feeling: "Broken.", glsl: "float a = 1.0;")

    func isReady() async -> Bool { ready }

    func compose(_ brief: DanceBrief) async throws -> DanceComposition {
        lock.lock(); defer { lock.unlock() }
        briefs.append(brief)
        let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
        return try reply.get()
    }
}

final class DanceClock: @unchecked Sendable {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var elapsed: TimeInterval = 0
    private let lock = NSLock()
    var now: Date { lock.lock(); defer { lock.unlock() }; return start.addingTimeInterval(elapsed) }
    func advance(_ seconds: TimeInterval) { lock.lock(); elapsed += seconds; lock.unlock() }
}

enum DanceFixtures {
    /// An engine over fake windows, a fake composer and a fake clock. `sleep`
    /// advances the clock by what was asked, so the beat runs at once.
    static func engine(
        composer: FakeComposer = FakeComposer([.success(FakeComposer.good)]),
        windows: FakeCanvasWindows = FakeCanvasWindows(),
        clock: DanceClock = DanceClock(),
        stage: StageArbiter = StageArbiter(),
        sleepAdvances: Bool = true,
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { range in
            (range.lowerBound + range.upperBound) / 2
        }
    ) -> (DanceEngine, CanvasService) {
        let canvas = CanvasFixtures.service(windows: windows, stage: stage)
        let engine = DanceEngine(seams: .init(
            canvas: canvas, compose: composer,
            sleep: { duration in
                if sleepAdvances { clock.advance(DanceEngine.seconds(duration)) }
                else { try? await Task.sleep(for: .milliseconds(2)) }
                await Task.yield()
            },
            now: { clock.now },
            random: random))
        return (engine, canvas)
    }

    static let brief = DanceBrief(subject: .dance, utterance: "Let's dance.")

    /// Wait for the engine to reach `phase`, briefly.
    static func settle(_ engine: DanceEngine, until phase: DancePhase) async -> DanceSnapshot {
        for _ in 0..<400 {
            let snapshot = await engine.snapshot()
            if snapshot.phase == phase { return snapshot }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await engine.snapshot()
    }
}

@Suite struct DanceEngineTests {

    @Test func aDanceStartsAtOnceAndFinishesByTheClock() async {
        let composer = FakeComposer([.success(FakeComposer.good)])
        let windows = FakeCanvasWindows()
        let stage = StageArbiter()
        let (engine, _) = DanceFixtures.engine(composer: composer, windows: windows, stage: stage)

        let outcome = await engine.dance(DanceFixtures.brief)
        #expect(outcome == .started(feeling: "Restless, mostly."))
        let started = await engine.snapshot()
        #expect(started.phase == .dancing || started.phase == .idle)
        #expect(composer.briefs[0].motifs.count == 3, "motifs are filled in by the engine")
        #expect(composer.briefs[0].variant == nil)

        let finished = await DanceFixtures.settle(engine, until: .idle)
        // ONE SHADER PER WINDOW: the first, then four variants composed together.
        #expect(composer.briefs.count == 5, "one composition and four variants")
        #expect(Set(composer.briefs.dropFirst().compactMap { $0.variant?.index }) == [2, 3, 4, 5])
        #expect(composer.briefs.dropFirst().allSatisfy { $0.variant?.of == 5 })
        #expect(windows.prepared.count == 5, "five pages, one per shader")
        #expect(finished.phase == .idle)
        #expect(finished.beats > 10, "fifteen seconds at half a second a beat — \(finished.recent)")
        #expect(finished.windows.isEmpty)
        #expect(windows.liveCount == 0)
        #expect(windows.peakVisible <= 5)
        #expect(windows.peakVisible >= 2, "a dance shows more than one window")
        #expect(stage.currentOwner() == nil)

        // NEVER THE MONITOR ITSELF: every window fits on the screen and none is it.
        let screen = windows.screen!
        #expect(!windows.shown.isEmpty)
        for shown in windows.shown {
            let frame = shown.placement.frame(on: screen)
            #expect(screen.contains(frame), "\(frame) is off screen")
            #expect(frame.width < screen.width && frame.height < screen.height, "\(frame) is the monitor")
            #expect(frame.width <= screen.width * DanceEngine.largestFraction + 1)
        }
    }

    /// A variant that will not compose takes the first shader with its own seed,
    /// so the troupe is still five.
    @Test func aVariantThatFailsFallsBackToTheFirstShader() async {
        let composer = FakeComposer([
            .success(FakeComposer.good),
            .failure(.failed("Seer is unreachable")),
        ])
        let windows = FakeCanvasWindows()
        let (engine, _) = DanceFixtures.engine(composer: composer, windows: windows)
        let events = await engine.events()
        _ = await engine.dance(DanceFixtures.brief)
        let finished = await DanceFixtures.settle(engine, until: .idle)
        #expect(finished.phase == .idle)
        #expect(windows.prepared.count == 5, "the troupe is whole")
        var joined: [Bool] = []
        for await event in events {
            if case .joined(_, let distinct) = event { joined.append(distinct) }
            if case .finished = event { break }
        }
        #expect(joined.count == 4)
        #expect(joined.allSatisfy { !$0 }, "every failed variant fell back to the first shader")
    }

    @Test func aStopTakesEverythingDown() async {
        let windows = FakeCanvasWindows()
        let stage = StageArbiter()
        let (engine, _) = DanceFixtures.engine(windows: windows, stage: stage, sleepAdvances: false)
        _ = await engine.dance(DanceFixtures.brief)
        #expect(await engine.snapshot().phase == .dancing)

        #expect(await engine.stop())
        let after = await engine.snapshot()
        #expect(after.phase == .idle)
        #expect(after.windows.isEmpty)
        #expect(windows.liveCount == 0)
        #expect(stage.currentOwner() == nil)
        #expect(await engine.stop() == false, "nothing left to stop")
    }

    @Test func aComposerThatIsNotReadyIsARefusalBeforeAnyWindow() async {
        let composer = FakeComposer([.success(FakeComposer.good)])
        composer.ready = false
        let windows = FakeCanvasWindows()
        let (engine, _) = DanceFixtures.engine(composer: composer, windows: windows)

        let outcome = await engine.dance(DanceFixtures.brief)
        #expect(outcome == .refused(.composerUnavailable("the composer isn't ready.")))
        #expect(windows.prepared.isEmpty)
        #expect(await engine.snapshot().phase == .idle)
    }

    @Test func aComposerThatFailsIsNamed() async {
        let composer = FakeComposer([.failure(.failed("Seer is unreachable: timeout"))])
        let (engine, _) = DanceFixtures.engine(composer: composer)
        #expect(await engine.dance(DanceFixtures.brief) == .refused(.composerFailed("Seer is unreachable: timeout")))
    }

    @Test func aRefusedShaderGetsOneRepair() async {
        let composer = FakeComposer([.success(FakeComposer.bad), .success(FakeComposer.good)])
        let (engine, _) = DanceFixtures.engine(composer: composer, sleepAdvances: false)
        let outcome = await engine.dance(DanceFixtures.brief)
        #expect(outcome == .started(feeling: "Restless, mostly."))
        #expect(composer.briefs.count == 2)
        #expect(composer.briefs[1].repair?.problem == ShaderRefusal.noMain.summary)
        #expect(composer.briefs[1].repair?.glsl == "float a = 1.0;")
        await engine.stop()
    }

    @Test func aShaderRefusedThreeTimesIsARefusal() async {
        let composer = FakeComposer([.success(FakeComposer.bad)])
        let windows = FakeCanvasWindows()
        let (engine, _) = DanceFixtures.engine(composer: composer, windows: windows)
        let outcome = await engine.dance(DanceFixtures.brief)
        #expect(outcome == .refused(.shaderRefused(ShaderRefusal.noMain.summary)))
        #expect(composer.briefs.count == 3, "one composition and two repairs")
        #expect(composer.briefs[2].repair?.problem == ShaderRefusal.noMain.summary)
        #expect(windows.prepared.isEmpty)
    }

    @Test func aPageThatFailsToCompileGetsOneRepair() async {
        let composer = FakeComposer([.success(FakeComposer.good)])
        let windows = FakeCanvasWindows()
        windows.failOnce["Mary dances"] = "ERROR: 0:7: 'foo' : undeclared identifier"
        let (engine, _) = DanceFixtures.engine(composer: composer, windows: windows, sleepAdvances: false)

        let outcome = await engine.dance(DanceFixtures.brief)
        #expect(outcome == .started(feeling: "Restless, mostly."))
        #expect(composer.briefs.count == 2)
        #expect(composer.briefs[1].repair?.problem == "It did not compile: ERROR: 0:7: 'foo' : undeclared identifier")
        #expect(windows.closed.count == 1, "the failed rehearsal came down")
        await engine.stop()
    }

    /// The compiler names an int on a line; Mary floats it and rehearses again
    /// before any model round.
    @Test func anIntegerSlipIsRepairedWithoutTheComposer() async {
        let composer = FakeComposer([.success(DanceComposition(
            feeling: "Sharp.",
            glsl: ShaderPageTests.plasma.replacingOccurrences(of: "p.x*3.2", with: "p.x*3")))])
        let windows = FakeCanvasWindows()
        windows.failOnce["How Mary feels"] = "ERROR: line 6: '*' : wrong operand types - 'float' and 'const int'"
        let (engine, _) = DanceFixtures.engine(composer: composer, windows: windows)
        let outcome = await engine.mood(DanceBrief(subject: .mary, utterance: "How are you feeling?"))
        #expect(outcome == .started(feeling: "Sharp."))
        #expect(composer.briefs.count == 1, "no model round was spent")
        #expect(windows.prepared.count == 2)
        await engine.stop()
    }

    @Test func aPageThatFailsTwiceIsARefusal() async {
        let windows = FakeCanvasWindows()
        windows.failing["How Mary feels"] = "ERROR: 0:2: syntax error"
        let stage = StageArbiter()
        let (engine, _) = DanceFixtures.engine(windows: windows, stage: stage)
        let outcome = await engine.mood(DanceBrief(subject: .mary, utterance: "How are you feeling?"))
        #expect(outcome == .refused(.compileFailed("ERROR: 0:2: syntax error")))
        #expect(windows.liveCount == 0)
        #expect(stage.currentOwner() == nil)
    }

    @Test func aMoodIsOneWindowHeldStill() async {
        let windows = FakeCanvasWindows()
        let clock = DanceClock()
        let (engine, canvas) = DanceFixtures.engine(windows: windows, clock: clock)
        let outcome = await engine.mood(DanceBrief(subject: .person, utterance: "What do you think I feel like?"))
        #expect(outcome == .started(feeling: "Restless, mostly."))
        clock.advance(60)
        let snapshot = await engine.snapshot()
        #expect(snapshot.phase == .mood)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.showing == 1)
        #expect(snapshot.beats == 0)
        #expect(windows.prepared.first?.title == "How you feel")
        let frame = windows.shown.first!.placement.frame(on: windows.screen!)
        #expect(frame.width < windows.screen!.width, "a mood is a large window, not the monitor")
        #expect(abs(frame.midX - windows.screen!.midX) < 1, "and it is centred")
        #expect(await canvas.snapshot().holdsStage)
        #expect(await engine.stop())
        #expect(await engine.snapshot().phase == .idle)
    }

    @Test func aClickOnTheMoodEndsIt() async {
        let windows = FakeCanvasWindows()
        let stage = StageArbiter()
        let (engine, _) = DanceFixtures.engine(windows: windows, stage: stage)
        _ = await engine.mood(DanceBrief(subject: .mary, utterance: "How are you feeling?"))
        let id = await engine.snapshot().windows[0]
        windows.click(id)
        let after = await DanceFixtures.settle(engine, until: .idle)
        #expect(after.phase == .idle)
        #expect(after.windows.isEmpty)
        #expect(stage.currentOwner() == nil)
    }

    @Test func aPreemptEndsADance() async {
        let windows = FakeCanvasWindows()
        let stage = StageArbiter()
        let (engine, _) = DanceFixtures.engine(windows: windows, stage: stage, sleepAdvances: false)
        _ = await engine.dance(DanceFixtures.brief)
        #expect(await engine.snapshot().phase == .dancing)
        await stage.preemptForNewClaim()
        let after = await DanceFixtures.settle(engine, until: .idle)
        #expect(after.phase == .idle)
        #expect(after.windows.isEmpty)
        #expect(windows.liveCount == 0)
        #expect(stage.currentOwner() == nil)
    }

    @Test func aNewDanceReplacesAMood() async {
        let windows = FakeCanvasWindows()
        let (engine, _) = DanceFixtures.engine(windows: windows, sleepAdvances: false)
        _ = await engine.mood(DanceBrief(subject: .mary, utterance: "How are you feeling?"))
        let mood = await engine.snapshot().windows
        _ = await engine.dance(DanceFixtures.brief)
        let snapshot = await engine.snapshot()
        #expect(snapshot.phase == .dancing)
        #expect(!snapshot.windows.contains(mood[0]))
        #expect(windows.closed.contains(mood[0]))
        await engine.stop()
    }

    @Test func theSubjectIsReadFromThePronouns() {
        #expect(DancePlugin.subject(argument: nil, utterance: "How are you feeling?") == .mary)
        #expect(DancePlugin.subject(argument: nil, utterance: "What do you think I feel like right now?") == .person)
        #expect(DancePlugin.subject(argument: nil, utterance: "Paint my mood.") == .person)
        #expect(DancePlugin.subject(argument: nil, utterance: "Show me your mood.") == .person)
        #expect(DancePlugin.subject(argument: "yours", utterance: "Show me your mood.") == .mary)
        #expect(DancePlugin.subject(argument: "mine", utterance: "How are you?") == .person)
        #expect(DancePlugin.subject(argument: nil, utterance: "Mood.") == .mary)
    }
}
