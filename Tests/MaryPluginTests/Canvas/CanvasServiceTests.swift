//
//  CanvasServiceTests.swift
//  MaryPluginTests
//
//  WHAT: The canvas shows what it was told, says what the page said, and holds
//        the stage exactly as long as something is up.
//  OUT:  CanvasService
//

import CoreGraphics
import Foundation
import MaryComputerUse
import Testing
@testable import MaryPlugin

@Suite struct CanvasServiceTests {

    @Test func aReadyPageIsShownAndTheStageIsHeld() async {
        let windows = FakeCanvasWindows()
        let stage = StageArbiter()
        let service = CanvasFixtures.service(windows: windows, stage: stage)

        let result = await service.present(CanvasFixtures.page("Card"), placement: .panel)
        guard case .success(let receipt) = result else {
            Issue.record("the page was refused")
            return
        }
        #expect(receipt.ready)
        #expect(windows.shown.count == 1)
        #expect(windows.shown.first?.placement == .panel)
        let snapshot = await service.snapshot()
        #expect(snapshot.holdsStage)
        #expect(snapshot.showing.map(\.title) == ["Card"])
        #expect(stage.currentOwner() == "canvas")

        await service.dismissAll()
        let after = await service.snapshot()
        #expect(!after.holdsStage)
        #expect(after.windows.isEmpty)
        #expect(stage.currentOwner() == nil)
    }

    /// A page that fails still comes up — the canvas reports, the caller decides.
    @Test func aFailedPageIsReportedNotHidden() async {
        let windows = FakeCanvasWindows()
        windows.failing["Broken"] = "ERROR: 0:3: syntax error"
        let service = CanvasFixtures.service(windows: windows)

        let result = await service.prepare(CanvasFixtures.page("Broken"))
        guard case .success(let receipt) = result else {
            Issue.record("a failed page is a receipt, not a refusal")
            return
        }
        #expect(!receipt.ready)
        #expect(receipt.log == "ERROR: 0:3: syntax error")
        #expect(!receipt.timedOut)
        await service.dismissAll()
    }

    @Test func aSilentPageSaysSo() async {
        let windows = FakeCanvasWindows()
        windows.silent = ["Quiet"]
        let service = CanvasFixtures.service(windows: windows)

        guard case .success(let receipt) = await service.prepare(CanvasFixtures.page("Quiet")) else {
            Issue.record("refused")
            return
        }
        #expect(!receipt.ready)
        #expect(receipt.timedOut)
        await service.dismissAll()
    }

    @Test func anOversizedPageIsRefusedBeforeAnyWindow() async {
        let windows = FakeCanvasWindows()
        let service = CanvasFixtures.service(windows: windows)
        let huge = CanvasPage(title: "Huge", html: String(repeating: "x", count: CanvasRefusal.pageByteLimit + 1))

        let result = await service.present(huge)
        guard case .failure(let refusal) = result else {
            Issue.record("an oversized page was accepted")
            return
        }
        #expect(refusal == .pageTooLarge(bytes: CanvasRefusal.pageByteLimit + 1))
        #expect(windows.prepared.isEmpty)
        let snapshot = await service.snapshot()
        #expect(!snapshot.holdsStage)
        #expect(snapshot.lastRefusal == refusal)
    }

    @Test func noScreenIsARefusal() async {
        let windows = FakeCanvasWindows()
        windows.screen = nil
        let service = CanvasFixtures.service(windows: windows)
        guard case .failure(let refusal) = await service.present(CanvasFixtures.page("Card")) else {
            Issue.record("shown with no screen")
            return
        }
        #expect(refusal == .noScreen)
    }

    @Test func aClickDismissesAndReleasesTheStage() async {
        let windows = FakeCanvasWindows()
        let service = CanvasFixtures.service(windows: windows)
        final class Seen: @unchecked Sendable { var dismissals: [CanvasDismissal] = [] }
        let seen = Seen()

        guard case .success(let receipt) = await service.present(
            CanvasFixtures.page("Card"), onDismiss: { _, by in seen.dismissals.append(by) })
        else {
            Issue.record("refused")
            return
        }
        windows.click(receipt.id)
        // The click hops onto the actor; give it the turn.
        for _ in 0..<50 where await service.snapshot().holdsStage {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = await service.snapshot()
        #expect(!snapshot.holdsStage)
        #expect(snapshot.windows.isEmpty)
        #expect(windows.closed.contains(receipt.id))
        #expect(seen.dismissals == [.click])
    }

    @Test func aPreemptClearsEverything() async {
        let windows = FakeCanvasWindows()
        let stage = StageArbiter()
        let service = CanvasFixtures.service(windows: windows, stage: stage)
        _ = await service.present(CanvasFixtures.page("One"))
        _ = await service.present(CanvasFixtures.page("Two"), placement: .panel)
        #expect(await service.showing().count == 2)

        // A later stage act asks the holder to step aside.
        await stage.preemptForNewClaim()
        for _ in 0..<50 where await service.snapshot().holdsStage {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = await service.snapshot()
        #expect(snapshot.windows.isEmpty)
        #expect(!snapshot.holdsStage)
        #expect(windows.closeAllCalls == 1)
        #expect(stage.currentOwner() == nil)
    }

    @Test func hideAndShowKeepThePage() async {
        let windows = FakeCanvasWindows()
        let service = CanvasFixtures.service(windows: windows)
        guard case .success(let receipt) = await service.prepare(CanvasFixtures.page("Beat")) else {
            Issue.record("refused")
            return
        }
        #expect(await service.showing().isEmpty)
        #expect(await service.show(receipt.id, placement: .rect(CGRect(x: 10, y: 10, width: 300, height: 200))))
        #expect(await service.showing() == [receipt.id])
        await service.hide(receipt.id)
        #expect(await service.showing().isEmpty)
        #expect(windows.hidden == [receipt.id])
        let snapshot = await service.snapshot()
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.holdsStage)
        await service.dismissAll()
    }

    @Test func dismissingNothingSaysSo() async {
        let service = CanvasFixtures.service()
        #expect(await service.dismissAll() == false)
        guard case .failure(let refusal) = await service.dismiss(CanvasWindowID()) else {
            Issue.record("dismissed a window that never was")
            return
        }
        #expect(refusal == .unknownWindow)
    }

    @Test func eventsTellTheStory() async {
        let windows = FakeCanvasWindows()
        let service = CanvasFixtures.service(windows: windows)
        let events = await service.events()
        _ = await service.present(CanvasFixtures.page("Card"))
        await service.dismissAll()
        var seen: [String] = []
        for await event in events {
            switch event {
            case .stage(let held): seen.append(held ? "held" : "released")
            case .prepared: seen.append("prepared")
            case .shown: seen.append("shown")
            case .dismissed(_, let by): seen.append("dismissed-\(by)")
            case .hidden: seen.append("hidden")
            case .refused: seen.append("refused")
            }
            if seen.last == "released" { break }
        }
        #expect(seen == ["held", "prepared", "shown", "dismissed-caller", "released"])
    }

    @Test func placementsMeanFrames() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 500)
        #expect(CanvasPlacement.fullScreen.frame(on: screen) == screen)
        #expect(CanvasPlacement.panel.frame(on: screen) == CGRect(x: 200, y: 100, width: 600, height: 300))
        #expect(CanvasPlacement(spoken: "full_screen") == .fullScreen)
        #expect(CanvasPlacement(spoken: "Panel") == .panel)
        #expect(CanvasPlacement(spoken: "sideways") == nil)
        #expect(CanvasPlacement.centered(0.5, on: screen) == .rect(CGRect(x: 250, y: 125, width: 500, height: 250)))
    }
}
