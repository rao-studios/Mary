//
//  ComputerUseMonitorTests.swift
//  MaryComputerUseTests
//
//  WHAT: The monitor counts, names, remembers a bounded tail, and replays.
//  OUT:  ComputerUseMonitor
//  PIN:  Each test owns its monitor — the shared one is the process's memory
//        of what it really did, and a test must never edit that.
//

import Foundation
import Testing
@testable import MaryComputerUse

@Suite struct ComputerUseMonitorTests {

    static func monitor(trusted: Bool = true) -> ComputerUseMonitor {
        ComputerUseMonitor(
            now: { Date(timeIntervalSince1970: 1_787_821_200) },
            trusted: { trusted },
            screenRecording: { true })
    }

    /// A FRESH MONITOR CLAIMS NOTHING. "No acts" must be distinguishable from
    /// "not watching", or an empty snapshot reads as an all-clear.
    @Test func afreshMonitorHasNoHistory() {
        let snapshot = Self.monitor().snapshot()
        #expect(snapshot.totalActs == 0)
        #expect(snapshot.totalRefusals == 0)
        #expect(snapshot.lastRefusal == nil)
        #expect(snapshot.recentActs.isEmpty)
        #expect(snapshot.sense.walks == 0)
    }

    @Test func actsAreCountedPerLane() {
        let monitor = Self.monitor()
        monitor.note(lane: .keyboard, act: "keyChord", detail: "command+s")
        monitor.note(lane: .keyboard, act: "keyChord", detail: "command+n")
        monitor.note(lane: .pointer, act: "click", detail: "(10,10)")

        let snapshot = monitor.snapshot()
        #expect(snapshot.lanes[.keyboard]?.acts == 2)
        #expect(snapshot.lanes[.pointer]?.acts == 1)
        #expect(snapshot.lanes[.menus] == nil)
        #expect(snapshot.totalActs == 3)
        #expect(snapshot.lanes[.keyboard]?.lastAct?.detail == "command+n")
    }

    /// THE REFUSAL CARRIES ITS REASON. This is the whole point: a skipped act
    /// that says only "false" leaves the person watching with no next step.
    @Test func aRefusalKeepsItsNamedReason() {
        let monitor = Self.monitor()
        monitor.note(lane: .pointer, refused: "resolve", reason: .noCapturedSpace("row"))

        let snapshot = monitor.snapshot()
        #expect(snapshot.lanes[.pointer]?.refusals == 1)
        #expect(snapshot.lastRefusal?.reason == .noCapturedSpace("row"))
        #expect(snapshot.lastRefusal?.reason.summary == "no captured region named row")
        #expect(snapshot.lanes[.pointer]?.acts == 0)
    }

    /// Every named reason says something a person can act on — no case may
    /// render as an empty string, which is the failure mode this type replaced.
    @Test(arguments: [
        ComputerUseRefusalReason.accessibilityUntrusted,
        .eventNotCreated, .noKeyCode("f13"), .noFocusedWindow,
        .noCapturedSpace("row"), .anchorNotUnique, .elementHasNoFrame,
        .pressRefused("Save"), .itemDisabled("Move To"), .menuLevelMissing("File"),
        .notRunning("TextEdit"), .activationRefused("TextEdit"),
        .targetLostFocus(nil), .cancelled, .processLaunchFailed("git"),
        .processTimedOut(seconds: 30), .screenRecordingUnavailable("denied"),
        .other("something"),
    ])
    func everyReasonReadsAsASentence(_ reason: ComputerUseRefusalReason) {
        #expect(!reason.summary.isEmpty)
    }

    /// SEQUENCE IS MONOTONIC ACROSS BOTH KINDS, so a watcher that sees a gap
    /// knows it dropped events rather than that nothing happened.
    @Test func sequenceIsMonotonicAcrossActsAndRefusals() {
        let monitor = Self.monitor()
        monitor.note(lane: .keyboard, act: "keyChord")
        monitor.note(lane: .pointer, refused: "resolve", reason: .noFocusedWindow)
        monitor.note(lane: .windows, act: "raise")

        let snapshot = monitor.snapshot()
        let sequences = snapshot.recentActs.map(\.sequence) + snapshot.recentRefusals.map(\.sequence)
        #expect(Set(sequences).count == sequences.count)
        #expect(sequences.max() == 3)
    }

    /// THE TAIL IS BOUNDED. A monitor that kept everything would be a
    /// recording of the user's session; it keeps enough to answer "what just
    /// happened" and no more.
    @Test func theRecentTailIsBounded() {
        let monitor = Self.monitor()
        for n in 0..<(ComputerUseMonitor.ringCapacity + 20) {
            monitor.note(lane: .pointer, act: "click", detail: "\(n)")
        }
        let snapshot = monitor.snapshot()
        #expect(snapshot.recentActs.count == ComputerUseMonitor.ringCapacity)
        #expect(snapshot.lanes[.pointer]?.acts == ComputerUseMonitor.ringCapacity + 20)
        // Newest survives; oldest is what falls off.
        #expect(snapshot.recentActs.last?.detail == "\(ComputerUseMonitor.ringCapacity + 19)")
    }

    /// A WALK IS COUNTED, NOT ANNOUNCED — the ambient poll would otherwise
    /// drown the stream it shares with the acts.
    @Test func senseIsTalliedWithoutAnEvent() async {
        let monitor = Self.monitor()
        let stream = monitor.events()
        monitor.noteSense(nodes: 1_200, duration: 0.4, truncated: true)
        monitor.note(lane: .keyboard, act: "keyChord")

        var received: [ComputerUseEvent] = []
        for await event in stream {
            received.append(event)
            if received.count == 2 { break }
        }
        // The replayed snapshot, then the key chord. No sense event between.
        guard case .snapshot = received[0] else { return #expect(Bool(false), "expected replay") }
        guard case .act(let act) = received[1] else { return #expect(Bool(false), "expected act") }
        #expect(act.name == "keyChord")

        let snapshot = monitor.snapshot()
        #expect(snapshot.sense.walks == 1)
        #expect(snapshot.sense.lastNodes == 1_200)
        #expect(snapshot.sense.truncatedWalks == 1)
    }

    /// A LATE WATCHER STILL SEES WHERE THINGS LANDED. Subscribing after the
    /// interesting refusal must not mean watching an empty stream forever.
    @Test func subscribingReplaysCurrentStateFirst() async {
        let monitor = Self.monitor()
        monitor.note(lane: .stage, refused: "bringForward", reason: .notRunning("TextEdit"))

        var iterator = monitor.events().makeAsyncIterator()
        let first = await iterator.next()
        guard case .snapshot(let replayed) = first else {
            return #expect(Bool(false), "the first event must be the current state")
        }
        #expect(replayed.lastRefusal?.reason == .notRunning("TextEdit"))
    }

    /// Two watchers both see the same act — the fan-out is not first-come.
    @Test func everyWatcherSeesTheSameAct() async {
        let monitor = Self.monitor()
        var one = monitor.events().makeAsyncIterator()
        var two = monitor.events().makeAsyncIterator()
        _ = await one.next()   // replayed snapshots
        _ = await two.next()

        monitor.note(lane: .menus, act: "menuChoose", detail: "File → Save")

        guard case .act(let a) = await one.next(), case .act(let b) = await two.next() else {
            return #expect(Bool(false), "both watchers must receive the act")
        }
        #expect(a == b)
        #expect(a.detail == "File → Save")
    }

    /// A dropped watcher stops being fanned out to, so a long session does not
    /// accumulate continuations for streams nobody reads.
    @Test func aFinishedWatcherIsForgotten() async {
        let monitor = Self.monitor()
        do {
            let stream = monitor.events()
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            #expect(monitor.observerCount == 1)
        }
        // Termination is delivered asynchronously; give it a beat.
        for _ in 0..<50 where monitor.observerCount > 0 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(monitor.observerCount == 0)
    }

    /// The grant is read at snapshot time, not cached from construction — it
    /// changes underneath a running app, which is exactly the case the app's
    /// own delegate watches for.
    @Test func theAccessibilityGrantIsReportedHonestly() {
        #expect(Self.monitor(trusted: false).snapshot().accessibilityTrusted == false)
        #expect(Self.monitor(trusted: true).snapshot().accessibilityTrusted == true)
    }
}
