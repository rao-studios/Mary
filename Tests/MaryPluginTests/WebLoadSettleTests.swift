//
//  WebLoadSettleTests.swift
//  MaryPluginTests
//
//  Pins `WebLoadSettle.settle` — the rule that decides a page has stopped
//  moving — over injected sample sequences and an injected clock.
//
//  This is a state machine over a SEQUENCE of observations, and every one of
//  its interesting inputs is a sequence a live browser produces only by
//  accident: a page that appears on the fourth poll, one that never stops
//  churning, one that is torn down and rebuilt between two looks. A live test
//  would exercise whichever of those the machine happened to be doing.
//

import XCTest
@testable import MaryPlugin

final class WebLoadSettleTests: XCTestCase {

    /// Feeds a fixed script of samples and advances a fake clock half a
    /// second per poll — the real interval, so the budget arithmetic under
    /// test is the shipped arithmetic.
    private func verdict(
        _ script: [WebLoadSettle.Sample],
        budget: TimeInterval = WebLoadSettle.defaultBudget,
        sleepSucceeds: Bool = true
    ) async -> WebLoadSettle.Verdict {
        var clock: TimeInterval = 0
        var index = 0
        return await WebLoadSettle.settle(
            budget: budget,
            now: { clock },
            sleep: { clock += 0.5; return sleepSucceeds },
            sample: {
                defer { index += 1 }
                // A script that runs out keeps answering with its last frame:
                // a settled page goes on being settled, which is what a real
                // one does.
                return script[min(index, script.count - 1)]
            })
    }

    private func page(_ title: String, children: Int = 4) -> WebLoadSettle.Sample {
        .init(hasPage: true, title: title, childCount: children)
    }
    private var nothing: WebLoadSettle.Sample {
        .init(hasPage: false, title: nil, childCount: 0)
    }

    // MARK: - Settling

    func testTwoAgreeingLooksSettle() async {
        let result = await verdict([page("Example"), page("Example")])
        guard case .settled = result else { return XCTFail("expected settled, got \(result)") }
    }

    /// The title moves while a page loads. Two looks that disagree are not a
    /// settle, however still the page looks otherwise.
    func testAMovingTitleIsNotSettled() async {
        let result = await verdict([
            page("loading…"), page("Example — loa"), page("Example"), page("Example"),
        ])
        guard case .settled(let after) = result else {
            return XCTFail("expected settled, got \(result)")
        }
        XCTAssertEqual(after, 1.5, accuracy: 0.01)
    }

    /// The case the child count exists for: a server-rendered page sets its
    /// title early and fills its body in afterwards. Title alone would call
    /// this settled while the page was still arriving.
    func testAStableTitleWithAGrowingBodyIsNotSettled() async {
        let result = await verdict([
            page("Example", children: 1), page("Example", children: 6),
            page("Example", children: 9), page("Example", children: 9),
        ])
        guard case .settled(let after) = result else {
            return XCTFail("expected settled, got \(result)")
        }
        XCTAssertEqual(after, 1.5, accuracy: 0.01)
    }

    // MARK: - Churning

    /// A live feed never stops moving and is perfectly readable throughout.
    /// Calling this a failure would refuse the pages people most want read.
    func testAPageThatNeverStopsIsPresentButChurning() async {
        var beat = 0
        var clock: TimeInterval = 0
        let result = await WebLoadSettle.settle(
            budget: 3,
            now: { clock },
            sleep: { clock += 0.5; return true },
            sample: {
                defer { beat += 1 }
                return .init(hasPage: true, title: "Feed", childCount: beat)
            })
        XCTAssertEqual(result, .presentButChurning)
    }

    // MARK: - Absence

    func testAPageThatNeverAppearsIsNeverAppeared() async {
        let result = await verdict([nothing], budget: 2)
        XCTAssertEqual(result, .neverAppeared)
    }

    /// A page that arrives late still settles. The budget is the only limit
    /// that decides, and a slow load is not a missing one.
    func testAPageThatArrivesLateStillSettles() async {
        let result = await verdict([
            nothing, nothing, nothing, page("Late"), page("Late"),
        ])
        guard case .settled = result else { return XCTFail("expected settled, got \(result)") }
    }

    /// TWO LOOKS AT NOTHING ARE NOT AGREEMENT. Without the `hasPage` guard in
    /// `agrees`, a page that has not appeared reads as perfectly stable —
    /// same nil title, same zero children — and the lane would report a
    /// settled page it never saw.
    func testNothingTwiceIsNotASettledPage() async {
        let result = await verdict([nothing, nothing, nothing], budget: 2)
        XCTAssertEqual(result, .neverAppeared)
    }

    /// A page torn down and rebuilt between two looks would otherwise read as
    /// "nothing changed" precisely because nothing was there for one of them.
    func testAPageThatBlinksOutBetweenLooksDoesNotSettleOnTheGap() async {
        let result = await verdict([
            page("A"), nothing, page("A"), page("A"),
        ])
        guard case .settled(let after) = result else {
            return XCTFail("expected settled, got \(result)")
        }
        // Not at 0.5s (the A/nothing pair), and not at 1.0s (nothing/A):
        // only the two real looks at the same page agree.
        XCTAssertEqual(after, 1.5, accuracy: 0.01)
    }

    // MARK: - Interruption

    /// A CANCELLED TURN IS NOT A SETTLED PAGE. Reporting `.settled` on the
    /// way down would hand a caller a page nothing ever confirmed.
    func testACancelledSleepReportsWhatWasActuallySeen() async {
        let sawPage = await verdict([page("A"), page("B")], sleepSucceeds: false)
        XCTAssertEqual(sawPage, .presentButChurning)

        let sawNothing = await verdict([nothing, nothing], sleepSucceeds: false)
        XCTAssertEqual(sawNothing, .neverAppeared)
    }

    /// A zero budget takes no look at all, and must not claim one.
    func testAZeroBudgetClaimsNothing() async {
        let result = await verdict([page("Example")], budget: 0)
        XCTAssertEqual(result, .neverAppeared)
    }
}
