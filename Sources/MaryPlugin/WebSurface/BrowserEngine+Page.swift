//
//  BrowserEngine+Page.swift
//  MaryPlugin
//
//  WHAT: The verbs — read a page, press something on it, type into it, scroll to it.
//  IN:   WebSurfaceAdapter
//  OUT:  BrowserOutcome, with the listing the model reads next
//  PIN:  EVERY VERB IS A PLAN. Each of these builds one or two commands and hands them
//        to the same executor, so resolution, receipts, restoration and interruption are
//        written once. A verb with its own pressing code would be a second set of rules
//        about all four.
//        EVERY ACT ENDS BY SAYING WHAT IS THERE NOW. "Opened X. Now offering 4 videos,
//        2 fields…" is what lets the next round name something without reading again,
//        and it is why a chain of verbs needs no state between them.
//

import CoreGraphics
import Foundation
import MaryComputerUse
import MaryFoundation

public extension BrowserEngine {

    /// Look at the page and say what is on it.
    ///
    /// PIN: THIS CLAIMS THE STAGE. A page is read from pixels, and pixels of a window
    /// that is behind another window are the other window's — the same reason the media
    /// read stages. Nothing about the page is changed.
    func readPage(
        in target: BrowserTarget, query: String? = nil
    ) async -> BrowserOutcome {
        let shellOutcome = await readShell(target)
        guard let shell = shellOutcome.shell else { return shellOutcome }
        guard await seams.stage.bringForward(pid: target.processIdentifier) else {
            return refuse(.activationRefused(target.spokenName))
        }
        let cursor = await seams.hands.cursorLocation()
        // The slate belongs to the page that is there NOW.
        retractSlate()
        let outcome = await read(target, shell: shell)
        await seams.hands.restoreCursor(to: cursor)
        switch outcome {
        case .failure(let refusal):
            return refuse(refusal)
        case .success(let roster):
            return BrowserOutcome(
                ok: true,
                spoken: PageListing.spoken(
                    roster, pageName: shell.title ?? shell.siteName, query: query),
                shell: shell,
                elements: roster.elements,
                map: roster.map)
        }
    }

    /// Press something on the page, named in the person's own words.
    func pressOnPage(
        _ phrase: String, in target: BrowserTarget, deadline: Date? = nil
    ) async -> BrowserOutcome {
        await act(
            .single(.click(.init(location: .target(phrase)))),
            in: target, deadline: deadline)
    }

    /// Type into a field on the page, and optionally commit it.
    func fillOnPage(
        _ phrase: String?, text: String, submit: Bool,
        in target: BrowserTarget, deadline: Date? = nil
    ) async -> BrowserOutcome {
        await act(
            .single(.typeText(.init(target: phrase, text: text, submit: submit))),
            in: target, deadline: deadline)
    }

    /// Set a slider on the page to a position.
    func adjustOnPage(
        _ phrase: String, fraction: Double, in target: BrowserTarget, deadline: Date? = nil
    ) async -> BrowserOutcome {
        await act(
            .single(.adjust(.init(target: phrase, mode: .fraction, fraction: fraction))),
            in: target, deadline: deadline)
    }

    /// Bring something into view, scrolling until it is there.
    ///
    /// PIN: A LOOP, NOT ONE SCROLL. "The seventh result" is usually below the fold, and
    /// a verb that reads once and refuses is refusing something that is plainly on the
    /// page — just not yet drawn. Bounded, because a page with infinite scroll would
    /// otherwise never stop being asked.
    func scrollToOnPage(
        _ phrase: String, in target: BrowserTarget, deadline: Date? = nil
    ) async -> BrowserOutcome {
        let shellOutcome = await readShell(target)
        guard let shell = shellOutcome.shell else { return shellOutcome }
        guard await seams.stage.bringForward(pid: target.processIdentifier) else {
            return refuse(.activationRefused(target.spokenName))
        }
        let cursor = await seams.hands.cursorLocation()
        defer { Task { await seams.hands.restoreCursor(to: cursor) } }

        for attempt in 0 ... Self.scrollAttempts {
            if let deadline, seams.now() >= deadline { return refuse(.outOfTime) }
            switch await read(target, shell: shell) {
            case .failure(let refusal):
                await seams.hands.restoreCursor(to: cursor)
                return refuse(refusal)
            case .success(let roster):
                if case .success(let element) = route(
                    phrase, verb: .reveal, in: roster) {
                    await seams.hands.restoreCursor(to: cursor)
                    let visible = roster.pageFrame.intersects(element.frame)
                    return BrowserOutcome(
                        ok: true,
                        spoken: visible
                            ? "\(ScreenElementResolver.shortened(element.label, limit: 60)) is on screen."
                            : "I found \(ScreenElementResolver.shortened(element.label, limit: 60)).",
                        shell: shell,
                        elements: roster.elements,
                        map: roster.map,
                        landed: true)
                }
                guard attempt < Self.scrollAttempts else {
                    await seams.hands.restoreCursor(to: cursor)
                    return refuse(.elementNotFound(phrase))
                }
                await seams.hands.scroll(
                    at: CGPoint(
                        x: roster.pageFrame.midX.rounded(),
                        y: roster.pageFrame.midY.rounded()),
                    by: -roster.pageFrame.height * Self.scrollShare,
                    pid: target.processIdentifier)
                emit(.acted("scrolled looking for \"\(phrase)\""))
                await seams.sleep(Self.scrollSettle)
            }
        }
        await seams.hands.restoreCursor(to: cursor)
        return refuse(.elementNotFound(phrase))
    }

    /// Search the web and open what was asked for.
    ///
    /// PIN: NO UTTERANCE PARAMETER, DELIBERATELY. `open_location` needs one — an address
    /// the model wrote is only admitted when the person said it — but a QUERY carries no
    /// such claim. It is words typed into a field, and asking where the words came from
    /// would be asking a question with no wrong answer.
    func searchWeb(
        _ query: String, in target: BrowserTarget,
        open pick: String? = nil, deadline: Date? = nil
    ) async -> BrowserOutcome {
        await WebSearchRecipe.searchAndOpen(
            query, pick: pick, in: target, engine: self, deadline: deadline)
    }
}

public extension BrowserEngine {
    /// How many times `scroll_to_on_page` looks again before it says it cannot find it.
    static var scrollAttempts: Int { 4 }
    /// How far one look scrolls, as a share of the page.
    static var scrollShare: CGFloat { 0.8 }
    static var scrollSettle: Duration { .milliseconds(350) }
}
