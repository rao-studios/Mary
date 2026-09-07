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
        // A question about the page gives the stage back — see `staged`; and a
        // read is the verb that DESCRIBES the browser's own question.
        await staged(target, after: .givenBack, asking: .described) { shell, _ in
            // The slate belongs to the page that is there NOW.
            retractSlate()
            switch await read(target, shell: shell) {
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
    }

    /// Read what the page SAYS, rather than what can be pressed on it.
    ///
    /// PIN: THE HALF OF A PAGE MARY COULD NOT REACH. `read_page` lists rows to
    /// act on and drops the prose; `current_page` answers with a title. So
    /// "what do you think of this article" had nothing to think about — the
    /// exact gap the code and prose worlds fixed years earlier by declaring a
    /// read. The text is already in the reading (the vision `.text` lane runs
    /// for both intents); it was being discarded at this door.
    /// SAME READ, SAME STAGE, SAME SLATE. This is `readPage` with a different
    /// rendering, not a second way to look at a page.
    func readPageText(
        in target: BrowserTarget, budget: Int = PageListing.textBudget
    ) async -> BrowserOutcome {
        await staged(target, after: .givenBack, asking: .described) { shell, _ in
            retractSlate()
            switch await read(target, shell: shell) {
            case .failure(let refusal):
                return refuse(refusal)
            case .success(let roster):
                let passage = PageListing.text(
                    roster, pageName: shell.title ?? shell.siteName, budget: budget)
                return BrowserOutcome(
                    ok: true,
                    spoken: passage,
                    // NOTHING READABLE IS A MISS, NOT A FAILURE — an image-only page
                    // is an answer, and a turn that says so beats one reporting an
                    // error against a page that loaded perfectly.
                    shell: shell,
                    elements: roster.elements,
                    map: roster.map)
            }
        }
    }

    /// Press something on the page, named in the person's own words.
    func pressOnPage(
        _ phrase: String, in target: BrowserTarget, deadline: Date? = nil
    ) async -> BrowserOutcome {
        await lookingFurther(for: phrase, in: target, deadline: deadline) {
            await self.act(
                .single(.click(.init(location: .target(phrase)))),
                in: target, deadline: deadline)
        }
    }

    /// Type into a field on the page, and optionally commit it.
    func fillOnPage(
        _ phrase: String?, text: String, submit: Bool,
        in target: BrowserTarget, deadline: Date? = nil
    ) async -> BrowserOutcome {
        await lookingFurther(for: phrase, in: target, deadline: deadline) {
            await self.act(
                .single(.typeText(.init(target: phrase, text: text, submit: submit))),
                in: target, deadline: deadline)
        }
    }

    /// Set a slider on the page to a position.
    func adjustOnPage(
        _ phrase: String, fraction: Double, in target: BrowserTarget, deadline: Date? = nil
    ) async -> BrowserOutcome {
        await lookingFurther(for: phrase, in: target, deadline: deadline) {
            await self.act(
                .single(.adjust(.init(target: phrase, mode: .fraction, fraction: fraction))),
                in: target, deadline: deadline)
        }
    }

    /// A NAMED THING THE PAGE IS NOT SHOWING YET IS NOT A THING THE PAGE HAS NOT
    /// GOT — so an act that cannot find it goes and looks, and tries once more.
    ///
    /// PIN: THE TREE ENDS AT THE FOLD, AND THAT IS NOT A BUDGET. Measured on a
    /// whole encyclopedia article, walked at eighty deep and sixty thousand
    /// nodes: eight hundred and eleven nodes exist, none of them off screen, and
    /// everything below the fold is published as a ONE-PIXEL sliver at the
    /// viewport's edge carrying no name at all. There is nothing further to read
    /// — the only way to a row below the fold is to move the page. So "read more"
    /// was never the answer to "click the link to X six screens down"; walking
    /// is, and `scrollToOnPage` is already the walk.
    ///
    /// ONLY A NAME SEARCHES. "The third link" means the third of the ones the
    /// person can see; scrolling to count things they never saw would answer a
    /// different question. Same rule as `countsForAPosition`, and it is why this
    /// asks `namesOnlyAPosition` rather than trying always.
    ///
    /// AND THE PAGE GOES BACK IF IT WAS NOT THERE. Leaving somebody six screens
    /// down having found nothing is worse than the refusal they were owed.
    func lookingFurther(
        for phrase: String?,
        in target: BrowserTarget,
        deadline: Date?,
        act: @Sendable () async -> BrowserOutcome
    ) async -> BrowserOutcome {
        let outcome = await act()
        guard let phrase, !phrase.isEmpty,
              !PageElementKindDerivation.namesOnlyAPosition(phrase),
              weakReach(outcome)
        else { return outcome }

        emit(.acted("looking further down the page for \"\(phrase)\""))
        let travelled = await searchByScrolling(phrase, in: target, deadline: deadline)
        guard travelled.found else {
            await scrollBack(travelled.screens, in: target)
            // THE FIRST ANSWER, NOT A SECOND ONE. Nothing better was down there,
            // so what this page had is what the person gets — including, when it
            // was a refusal, the refusal they were already owed.
            return outcome
        }
        let again = await act()
        if again.refusal != nil { await scrollBack(travelled.screens, in: target) }
        return again
    }

    /// Was that answer worth looking past?
    ///
    /// PIN: TWO CASES, AND THE SECOND IS THE ONE THAT MATTERS. A refusal is the
    /// obvious one. The other is a match reached on MEANING ALONE — nothing in
    /// any row's NAME answered, and the router settled for the closest thing on
    /// this screen, which on a rich page is almost always something. Measured
    /// live: "Ski mountaineering" reached "Ski touring" on 0 naming and 809
    /// meaning. That is a plausible guess, and a NAMED row one screen down beats
    /// it.
    ///
    /// CONTAINMENT IS NOT WEAK, and the distinction cost a test to find. On the
    /// same page "Randonnee racing equipment" reaches "Equipment" — which LOOKS
    /// like the same kind of guess and is not: the row's name is inside what the
    /// person said, which is real naming evidence and the rung "the Boiler Room
    /// link" → "Boiler Room" is pinned on. Only `.none` searches. A rule that
    /// also searched on containment would spend four page reads on most acts to
    /// improve a few.
    ///
    /// WHY NOT MAKE THE ROUTER REFUSE INSTEAD. Tried, measured, reverted — see
    /// `PageRouter.clearsFloor`. Meaning alone is genuinely how a named thing is
    /// reached when the page spells it differently, and forbidding it broke a
    /// pinned case. The router is right to answer; the ACT is what should not
    /// settle for the answer without looking.
    /// Test seam: the judgement over a stated trace, so the rule can be pinned
    /// without a live element index to reach a row by meaning with.
    func judgeReachForTests(trace: PageRouteTrace, outcome: BrowserOutcome) -> Bool {
        lastRoute = trace
        return weakReach(outcome)
    }

    func weakReach(_ outcome: BrowserOutcome) -> Bool {
        if case .elementNotFound = outcome.refusal { return true }
        guard outcome.refusal == nil, let route = lastRoute else { return false }
        guard let selected = route.decisions.first(where: { $0.disposition == .selected })
        else { return false }
        return selected.evidence.lexicalBasis == .none
    }

    /// Scroll a screen at a time until the phrase reaches a row, bounded, and
    /// say how far it went so the page can be put back.
    private func searchByScrolling(
        _ phrase: String, in target: BrowserTarget, deadline: Date?
    ) async -> (found: Bool, screens: Int) {
        let shellOutcome = await readShell(target)
        guard let shell = shellOutcome.shell else { return (false, 0) }
        var screens = 0
        for attempt in 0 ... Self.scrollAttempts {
            if let deadline, seams.now() >= deadline { return (false, screens) }
            guard case .success(let roster) = await read(target, shell: shell)
            else { return (false, screens) }
            if case .success = route(phrase, verb: .reveal, in: roster) {
                return (true, screens)
            }
            guard attempt < Self.scrollAttempts else { return (false, screens) }
            await seams.hands.scroll(
                at: CGPoint(
                    x: roster.pageFrame.midX.rounded(),
                    y: roster.pageFrame.midY.rounded()),
                by: -roster.pageFrame.height * Self.scrollShare,
                pid: target.processIdentifier)
            screens += 1
            await seams.sleep(Self.scrollSettle)
        }
        return (false, screens)
    }

    /// Put the page back where the person left it.
    private func scrollBack(_ screens: Int, in target: BrowserTarget) async {
        guard screens > 0, let frame = (await readShell(target)).shell?.pageFrame
        else { return }
        for _ in 0..<screens {
            await seams.hands.scroll(
                at: CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded()),
                by: frame.height * Self.scrollShare,
                pid: target.processIdentifier)
            await seams.sleep(Self.scrollSettle)
        }
        emit(.acted("put the page back where it was"))
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
        // Bringing something into view keeps the stage: it is there to be seen.
        await staged(target, after: .kept) { shell, cursor in
            await scrolledTo(phrase, in: target, shell: shell, deadline: deadline, restingAt: cursor)
        }
    }

    private func scrolledTo(
        _ phrase: String, in target: BrowserTarget, shell: WebSurfaceAX.Reading,
        deadline: Date?, restingAt cursor: CGPoint?
    ) async -> BrowserOutcome {
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
                        // A REVEAL CHANGES NOTHING, SO IT PROVES NOTHING.
                        //
                        // PIN: `landed` IS THE TOP THREE RECEIPTS AND NOTHING ELSE.
                        // This returned true with an EMPTY receipt list — measured on
                        // `scroll-to` in round 0 — which is `landed` from nothing at
                        // all. Bringing something into view is delivered work and the
                        // sentence says so; it is not proof that anything moved.
                        landed: false)
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

    // MARK: - Tabs

    /// How long a tab switch is given to show in the shell.
    static let tabSwitchBudget: TimeInterval = 3

    /// Bring a tab forward, named by its title, its position, or "the other one".
    ///
    /// PIN: THE SHELL'S OWN CONTROL, PRESSED. A tab is a button the browser
    /// publishes with the page's title on it — the same walk that finds Back
    /// finds it — and pressing it is what a person does. No chord, because a
    /// chord counts tabs the way the browser does and a person counts them the
    /// way they see them. Proved by the shell: the active tab is the one whose
    /// name the window wears.
    func switchTab(_ phrase: String, in target: BrowserTarget) async -> BrowserOutcome {
        await staged(target, after: .kept) { shell, _ in
            guard shell.tabs.count > 1 else {
                return refuse(.elementNotFound(phrase))
            }
            guard let index = Self.tabIndex(for: phrase, in: shell) else {
                return refuse(.elementNotFound(phrase))
            }
            if shell.activeTabIndex == index {
                return BrowserOutcome(
                    ok: true, spoken: "You're already on \(shell.tabs[index]).", shell: shell)
            }
            let label = index < shell.tabLabels.count ? shell.tabLabels[index] : shell.tabs[index]
            if dryRun { return refuse(.dryRun("switched to \(shell.tabs[index])")) }
            guard await seams.shell.press(
                label: label, pid: target.processIdentifier, registration: target.registration)
            else { return refuse(.elementNotFound(shell.tabs[index])) }
            emit(.acted("pressed the tab \(shell.tabs[index])"))
            // THE PROOF: the window wears the tab's name.
            let deadline = seams.now().addingTimeInterval(Self.tabSwitchBudget)
            var now: WebSurfaceAX.Reading?
            while seams.now() < deadline {
                await seams.sleep(.milliseconds(150))
                now = await seams.shell.read(
                    pid: target.processIdentifier, registration: target.registration)
                if let now, now.activeTabIndex == index
                    || now.title?.caseInsensitiveCompare(shell.tabs[index]) == .orderedSame {
                    break
                }
            }
            guard let after = now,
                  after.activeTabIndex == index
                    || after.title?.caseInsensitiveCompare(shell.tabs[index]) == .orderedSame
            else {
                return refuse(.stateUnchanged(
                    expected: shell.tabs[index], observed: now?.title ?? "the same tab"))
            }
            lastChrome = after
            retractSlate()
            let receipt = PageCommandReceipt(
                sourceIndex: 0, kind: .navigate, target: shell.tabs[index],
                delivery: .delivered, effect: .verified(.navigation(title: after.title ?? "")))
            emit(.receipt(receipt))
            return BrowserOutcome(
                ok: true, spoken: "Switched to \(shell.tabs[index]).", shell: after,
                receipts: [receipt], landed: true)
        }
    }

    /// Which tab a phrase means: a position ("the second tab"), "the other one"
    /// when there are two, or a title. Nil when nothing answers.
    static func tabIndex(for phrase: String, in shell: WebSurfaceAX.Reading) -> Int? {
        let tabs = shell.tabs
        if let ordinal = SpokenOrdinal.value(in: phrase) {
            if ordinal == -1 { return tabs.isEmpty ? nil : tabs.count - 1 }
            return (1...tabs.count).contains(ordinal) ? ordinal - 1 : nil
        }
        let words = RowFactsDerivation.folded(phrase).split(separator: " ").map(String.init)
        if words.contains("other"), tabs.count == 2, let active = shell.activeTabIndex {
            return 1 - active
        }
        // THE ASKING, REMOVED. "Switch to the blank tab" names a tab called
        // something like "blank"; the verb and the word "tab" are how it was
        // asked, and would drown a one-word title in a token match.
        let named = words.filter { !tabAskingWords.contains($0) }.joined(separator: " ")
        guard !named.isEmpty else { return nil }
        // A PAGE TITLE IS PUNCTUATED AND A PERSON IS NOT. The title matcher
        // folds punctuation AWAY rather than to a space — right for a song
        // called "Rock & Roll", wrong for a tab called "about:blank", which
        // becomes one token nobody can say. Every tab is spoken as its words
        // before it is matched, and the answer comes back by position.
        let spokenTabs: [String] = tabs.map { title in
            String(String(title.map { $0.isLetter || $0.isNumber ? $0 : " " })
                .split(separator: " ").joined(separator: " "))
        }
        switch SpokenTitleMatcher.resolve(named, in: spokenTabs) {
        case .match(let title), .guessed(let title):
            return spokenTabs.firstIndex(of: title)
        case .ambiguous, .none:
            return nil
        }
    }

    /// The words a person asks to switch tabs with — never a tab's own name.
    static let tabAskingWords: Set<String> = [
        "switch", "go", "to", "the", "a", "tab", "tabs", "open", "show", "me", "bring",
        "up", "back", "over", "one", "please", "can", "you", "on", "with",
    ]

    // MARK: - Find in page

    /// Open the browser's own find bar and type the words into it.
    ///
    /// PIN: THE SHELL'S FIND, NOT A READ. Reading the page for a word answers
    /// "is it there"; the person asked to be TAKEN to it, highlighted, with the
    /// browser's own count beside it — which is what the find bar does and no
    /// page read can. The chord is the browser's own menu command, declared by
    /// its package, aimed at the browser. Delivered, not landed: what the find
    /// bar found is drawn in the shell, and this lane does not read it back yet.
    func findInPage(_ text: String, in target: BrowserTarget) async -> BrowserOutcome {
        await staged(target, after: .kept) { shell, _ in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return refuse(.notFillable("nothing to find")) }
            if dryRun { return refuse(.dryRun("found \"\(trimmed)\" on the page")) }
            guard let prefix = target.registration.bundleIdentifiers.first,
                  await seams.keys.chord(
                      target.registration.schema.findKey,
                      modifiers: target.registration.schema.findModifiers,
                      targetPrefix: prefix)
            else { return refuse(.notImplemented("open the find bar")) }
            await seams.sleep(.milliseconds(250))
            guard await seams.keys.type(trimmed, targetPrefix: prefix) else {
                return refuse(.interrupted(atCommand: 0))
            }
            _ = await seams.keys.press(.return)
            emit(.acted("found \"\(trimmed)\" on the page"))
            let receipt = PageCommandReceipt(
                sourceIndex: 0, kind: .typeText, target: trimmed, delivery: .delivered)
            emit(.receipt(receipt))
            return BrowserOutcome(
                ok: true, spoken: "Looking for \"\(trimmed)\" on the page.", shell: shell,
                receipts: [receipt], landed: false)
        }
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
        // ONE STAGE FOR THE WHOLE JOURNEY. The recipe navigates, reads and
        // presses through the same verbs a person would say one at a time; held
        // through the outer act, the stage is taken once and the person's editor
        // is not handed forward between the read and the press.
        await journey(target, after: .kept) {
            await WebSearchRecipe.searchAndOpen(
                query, pick: pick, in: target, engine: self, deadline: deadline)
        }
    }

    /// Watch something: search, choose a result that answers what AND where,
    /// and failing that, go to the site they named and search it. One stage for
    /// the whole journey — see `WatchRecipe`.
    func watch(
        _ query: String, in target: BrowserTarget, deadline: Date? = nil
    ) async -> BrowserOutcome {
        await journey(target, after: .kept) {
            await WatchRecipe.watch(query, in: target, engine: self, deadline: deadline)
        }
    }
}

public extension BrowserEngine {
    /// How many times `scroll_to_on_page` looks again before it says it cannot find it.
    static var scrollAttempts: Int { 4 }
    /// How far one look scrolls, as a share of the page.
    static var scrollShare: CGFloat { 0.8 }
    static var scrollSettle: Duration { .milliseconds(350) }
}
