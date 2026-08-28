//
//  WebLoadSettle.swift
//  MaryPlugin
//
//  HAS THE PAGE FINISHED? — asked without asking the browser.
//
//  The predecessor asked over the browser's scripting dictionary and got a
//  real answer. Mary sends no Apple Events, so a load has to be INFERRED, and
//  an inference about somebody else's renderer needs measuring before it can
//  be believed. It was (`mary-web-probe settle`, 2026-08-28, macOS 26):
//
//    • QUIESCENCE WORKS, and is not marginal on ordinary pages. Safari
//      settled at 1.2 s and Chrome at 1.1 s, then held perfectly still —
//      identical title, identical child count, every poll — for the remaining
//      nineteen seconds.
//    • `AXURL` IS NOT READABLE on the web area in EITHER browser. So this
//      cannot confirm WHICH page arrived. It says a page arrived and stopped
//      moving; the caller that needs the address reads the toolbar's address
//      field, which is chrome rather than page and is readable before the
//      page is.
//
//  WHY THE VERDICT HAS THREE CASES AND NOT TWO. A page that never stops
//  moving is not a failed load — a live feed, a carousel, a chat view will
//  churn forever and be perfectly readable throughout. Returning "false" for
//  those would make the honest lane refuse the pages people most want read.
//  `.presentButChurning` is a success a caller may proceed on, with the
//  knowledge that what it reads is a moment rather than a settled state.
//  Only `.neverAppeared` is an absence, and it is the one worth speaking.
//
//  IT DECIDES NOTHING ABOUT WAKING. A Chromium page that was never woken
//  never appears, and reporting that as "this page is slow" would send the
//  caller to the wrong remedy — so callers run `BrowserAXReadiness` first and
//  this assumes they did.
//

import ApplicationServices
import Foundation

public enum WebLoadSettle {

    /// One look at the page. Deliberately three cheap reads and not a walk:
    /// this runs on a poll loop, and a settle check that costs a full tree
    /// read per beat would be the most expensive thing in the turn.
    public struct Sample: Sendable, Equatable {
        /// Whether a web area answered at all.
        public var hasPage: Bool
        /// The front window's title. Moves while a page loads and stops when
        /// it lands — the single most reliable signal either browser gives.
        public var title: String?
        /// The web area's direct child count. Catches the case where a title
        /// is set early and the body fills in afterwards, which is the common
        /// shape for a server-rendered page.
        public var childCount: Int

        public init(hasPage: Bool, title: String?, childCount: Int) {
            self.hasPage = hasPage
            self.title = title
            self.childCount = childCount
        }

        /// Two looks that agree. Both must see a page: a sample pair taken
        /// across the moment a page is torn down and rebuilt would otherwise
        /// read as "nothing changed" precisely because nothing was there.
        func agrees(with other: Sample) -> Bool {
            hasPage && other.hasPage
                && title == other.title
                && childCount == other.childCount
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// A page is there and stopped moving. The ordinary answer.
        case settled(afterSeconds: TimeInterval)
        /// A page is there and never stopped within the budget. A success —
        /// see the header — but the caller is reading a moving target.
        case presentButChurning
        /// No web area within the budget. The only absence, and the only case
        /// worth a sentence to the user.
        case neverAppeared
    }

    /// Sized against the measurement: both browsers settled inside 1.3 s, so
    /// eight seconds is generous for an ordinary page and short enough that a
    /// churning one does not hold a turn open.
    public static let defaultBudget: TimeInterval = 8
    /// Half a second, matching the interval the settle rule was measured at.
    /// A faster poll costs IPC to learn the same thing.
    public static let pollInterval: Duration = .milliseconds(500)

    /// Watch one application's focused-or-main window until its page stops
    /// moving. Callers run `BrowserAXReadiness.ensureWebContentAX` first.
    public static func await(
        pid: pid_t,
        budget: TimeInterval = defaultBudget
    ) async -> Verdict {
        let application = AXUIElementCreateApplication(pid)
        return await settle(budget: budget) { sample(of: application) }
    }

    /// One live look, in the three cheap reads `Sample` documents.
    static func sample(of application: AXUIElement) -> Sample {
        let area = WebAreaLocator.firstWebArea(inApp: application)
        let window = AX.element(application, kAXFocusedWindowAttribute)
            ?? AX.element(application, kAXMainWindowAttribute)
        return Sample(
            hasPage: area != nil,
            title: window.flatMap { AX.string($0, kAXTitleAttribute) },
            childCount: area.map { AX.children($0).count } ?? 0)
    }

    /// THE ENTIRE DECISION, over an injected sampler and an injected clock.
    ///
    /// Pure for the same reason `ProseWriteLocator` is: everything that could
    /// be wrong here is a rule about a SEQUENCE of observations, and a live
    /// test of it would be a test of whatever the machine's browser happened
    /// to be doing. Injected, the churning page, the page that appears late,
    /// and the page that never appears are three fixtures.
    static func settle(
        budget: TimeInterval,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        sleep: @escaping () async -> Bool = {
            do { try await Task.sleep(for: pollInterval); return true } catch { return false }
        },
        sample: () -> Sample
    ) async -> Verdict {
        let started = now()
        var previous: Sample?
        var everSawPage = false

        while now() - started < budget {
            let current = sample()
            everSawPage = everSawPage || current.hasPage

            if let previous, previous.agrees(with: current) {
                return .settled(afterSeconds: now() - started)
            }
            previous = current

            // A CANCELLED SLEEP IS NOT A SETTLED PAGE. Reporting `.settled`
            // when the turn was torn down would hand the caller a page it
            // never confirmed; the honest answer is what was actually seen.
            guard await sleep() else {
                return everSawPage ? .presentButChurning : .neverAppeared
            }
        }
        return everSawPage ? .presentButChurning : .neverAppeared
    }
}
