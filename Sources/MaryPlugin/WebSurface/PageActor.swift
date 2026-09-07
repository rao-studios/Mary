//
//  PageActor.swift
//  MaryPlugin
//
//  WHAT: A page plan, carried out one command at a time, each proved by looking again.
//  IN:   BrowserEngine.act
//  OUT:  PageCommandReceipt per command
//  PIN:  ONE EXECUTOR, AND EVERY VERB GOES THROUGH IT. "Click the first result" is a
//        one-command plan; a model-authored sequence is a sixteen-command plan; the
//        deterministic affordance press is a one-command plan. A second path would be a
//        second set of rules about resolution, receipts and restoration, and the two
//        would drift the first time either was fixed.
//        THE PAGE IS READ AGAIN BEFORE EVERY COMMAND. A plan carries words, not
//        coordinates, so a page that moved under the plan is simply re-read; a
//        coordinate captured at authoring time would land on whatever moved into it.
//        THE POINTER GOES BACK BEFORE THE SECOND LOOK. Something appears under the
//        cursor after almost every click, and a reading taken with the pointer still
//        parked reports that tooltip as the effect. The player is the exception: its
//        transport only exists while the pointer is over it.
//        VALIDATED BEFORE ANYTHING MOVES. A plan that would break halfway must refuse
//        while the page is still untouched.
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

extension BrowserEngine {

    /// How long after a command before the page is believed to have reacted.
    static let commandSettle = Duration.milliseconds(220)
    /// A click gets longer, because a press that navigates needs the shell to catch up.
    static let clickSettle = Duration.milliseconds(450)
    /// How many times a shell that has NOT moved is asked again before it is believed.
    /// Two, because a navigation commits its address within a few hundred milliseconds
    /// and the settle before this has already spent that.
    static let quietPolls = 2

    /// Run a plan against a page.
    public func act(
        _ plan: PageInteractionPlan,
        in target: BrowserTarget,
        deadline: Date? = nil
    ) async -> BrowserOutcome {
        // Acting on the page keeps the stage: what the press did is there to see.
        await staged(target, after: .kept, asking: .answered) { shell, cursor in
            // THE BROWSER IS ASKING. A single press whose words name one of the
            // choices answers it; anything else is put back as the question.
            if let dialog = shell.dialog {
                guard plan.commands.count == 1, let command = plan.commands.first,
                      command.kind == .click, let phrase = command.action.target
                else { return asked(dialog, shell: shell) }
                return await answer(dialog, with: phrase, in: target, shell: shell)
            }
            return await perform(
                plan, in: target, shell: shell, deadline: deadline, restingAt: cursor)
        }
    }

    /// `restingAt` is where the pointer was before any of this — where it goes back to
    /// between commands, so the second look is not taken through a tooltip.
    func perform(
        _ plan: PageInteractionPlan,
        in target: BrowserTarget,
        shell: WebSurfaceAX.Reading,
        deadline: Date?,
        restingAt cursor: CGPoint? = nil
    ) async -> BrowserOutcome {
        var receipts: [PageCommandReceipt] = []
        var shellNow: WebSurfaceAX.Reading? = shell
        var roster: PageRoster
        switch await read(target, shell: shell) {
        case .failure(let refusal): return refuse(refusal)
        case .success(let read): roster = read
        }
        var stopped = false

        for command in plan.commands {
            guard !stopped else {
                receipts.append(PageCommandReceipt(
                    sourceIndex: command.sourceIndex, kind: command.kind,
                    target: command.action.target, delivery: .notAttempted))
                continue
            }
            if let deadline, seams.now() >= deadline {
                receipts.append(PageCommandReceipt(
                    sourceIndex: command.sourceIndex, kind: command.kind,
                    target: command.action.target, delivery: .refused(.outOfTime)))
                stopped = true
                continue
            }
            // SOMEBODY ELSE MAY HAVE TAKEN THE MACHINE. A plan that keeps pressing into
            // whatever came forward is worse than one that stops and says where it got to.
            guard await seams.stage.holdsFocus(pid: target.processIdentifier) else {
                receipts.append(PageCommandReceipt(
                    sourceIndex: command.sourceIndex, kind: command.kind,
                    target: command.action.target, delivery: .interrupted))
                stopped = true
                continue
            }

            let before = PageReceipts.Look(shell: shellNow, roster: roster)
            let outcome = await run(
                command, in: target, roster: roster, shell: shellNow)
            switch outcome {
            case .refused(let refusal):
                receipts.append(PageCommandReceipt(
                    sourceIndex: command.sourceIndex, kind: command.kind,
                    target: command.action.target, delivery: .refused(refusal)))
                emit(.refused(refusal))
                stopped = true
                continue
            case .ran(let resolved, let point, let typed, let holdPointer):
                await seams.sleep(command.kind == .click ? Self.clickSettle : Self.commandSettle)
                // THE POINTER GOES BACK BEFORE THE SECOND LOOK. Something appears under
                // the cursor after almost every click, and a reading taken with it still
                // parked reports that tooltip as the effect. The player is the exception,
                // and says so: its transport exists only while the pointer is on it.
                if !holdPointer, cursor != nil { await seams.hands.restoreCursor(to: cursor) }
                shellNow = await settledShell(
                    after: command, target: target, from: before.shell)
                // A NAVIGATION MAKES THE WHOLE SLATE WRONG. Retract before the new page
                // is published, so nothing can be offered from the page that just left.
                if PageReceipts.navigation(before.shell, shellNow) != nil {
                    retractSlate()
                    // A SUBMIT THAT MADE A RESULTS PAGE IS A LIST OF ANSWERS TOO.
                    //
                    // PIN: ONLY `search_web` USED TO REMEMBER. Searching a site
                    // through its OWN box — fill the field, press return — lands
                    // on results exactly as the address bar does, and the next
                    // "open the first one" then routed as a bare press over the
                    // whole page, counting the site's chrome among the answers.
                    // The evidence is the same the search recipe already trusts:
                    // the typed words, folded, showing up in the page that
                    // arrived. No site name, no address kept.
                    if case .typeText(let typing) = command.action, typing.submit,
                       let arrived = shellNow,
                       WebSearchRecipe.searched(for: typing.text, shell: arrived) {
                        lastResultQuery = typing.text
                    }
                }
                switch await read(target, shell: shellNow ?? shell) {
                case .failure(let refusal):
                    receipts.append(PageCommandReceipt(
                        sourceIndex: command.sourceIndex, kind: command.kind,
                        target: command.action.target, delivery: .refused(refusal)))
                    stopped = true
                    continue
                case .success(let read):
                    roster = read
                }
                let effect = PageReceipts.judge(
                    command: command,
                    before: before,
                    after: PageReceipts.Look(shell: shellNow, roster: roster),
                    target: resolved, clickPoint: point, typedText: typed)
                let receipt = PageCommandReceipt(
                    sourceIndex: command.sourceIndex, kind: command.kind,
                    target: command.action.target, delivery: .delivered, effect: effect)
                receipts.append(receipt)
                emit(.receipt(receipt))
            }
        }

        let landed = receipts.contains { $0.landed }
            && !receipts.contains { if case .refused = $0.delivery { return true } else { return false } }
        let refusal = receipts.compactMap { receipt -> BrowserRefusal? in
            if case .refused(let refusal) = receipt.delivery { return refusal }
            return nil
        }.first
        return BrowserOutcome(
            ok: refusal == nil,
            spoken: spoken(receipts, roster: roster, shell: shellNow),
            refusal: refusal,
            shell: shellNow,
            elements: roster.elements,
            map: roster.map,
            receipts: receipts,
            landed: landed)
    }

    /// The shell once it has stopped moving — or once it is clear it is not going to.
    ///
    /// PIN: A NAVIGATING PRESS NEEDS TO BE WAITED FOR, and a fixed pause cannot know how
    /// long. Reading once after a settle reported "the page changed" for a press that had
    /// actually navigated, and the navigation turned up on the NEXT command's receipt.
    /// PIN: BUT ONLY A PRESS THAT MOVED SOMETHING IS WAITED FOR. The first version polled
    /// the full budget whichever way it went, which measured 4.2 SECONDS on a click that
    /// opened a menu — eight shell reads at a quarter-second each, waiting for a
    /// navigation that was never coming. A shell that has not moved after the settle is
    /// given two more chances and then believed; a shell that HAS moved is followed until
    /// it holds still, because a title flickers to the bare host before it becomes the
    /// page's real name.
    func settledShell(
        after command: PageInteractionPlanCommand,
        target: BrowserTarget,
        from before: WebSurfaceAX.Reading?
    ) async -> WebSurfaceAX.Reading? {
        func read() async -> WebSurfaceAX.Reading? {
            await seams.shell.read(
                pid: target.processIdentifier, registration: target.registration)
        }
        let mayNavigate: Bool
        switch command.action {
        case .click, .keyChord: mayNavigate = true
        case .typeText(let typing): mayNavigate = typing.submit
        default: mayNavigate = false
        }
        guard mayNavigate, let before else { return await read() }

        func moved(_ reading: WebSurfaceAX.Reading?) -> Bool {
            guard let reading else { return false }
            return reading.url != before.url || reading.title != before.title
        }

        var latest = await read()
        var quiet = 0
        var stable = 0
        while quiet < Self.quietPolls, stable < 2 {
            if moved(latest) {
                stable += 1
                quiet = 0
                if stable >= 2 { break }
            } else {
                quiet += 1
            }
            await seams.sleep(Self.navigationPoll)
            if let next = await read() {
                if moved(next), moved(latest), next.url == latest?.url,
                   next.title == latest?.title {
                    latest = next
                    stable += 1
                    break
                }
                latest = next
            }
        }
        return latest
    }

    /// What one command did, before its receipt is judged.
    enum CommandRun {
        case refused(BrowserRefusal)
        /// The row it acted on, where it clicked, what it typed, and whether the pointer
        /// must stay where it is for the second look.
        case ran(
            resolved: AXScreenElement?, point: CGPoint?, typed: String?, holdPointer: Bool)
    }

    func run(
        _ command: PageInteractionPlanCommand,
        in target: BrowserTarget,
        roster: PageRoster,
        shell: WebSurfaceAX.Reading?
    ) async -> CommandRun {
        let pid = target.processIdentifier
        switch command.action {
        case .click(let click):
            let placed = place(click.location, in: roster, verb: pressVerb(for: click.location))
            guard case .success(let (point, element)) = placed else {
                if case .failure(let refusal) = placed { return .refused(refusal) }
                return .refused(.pageNotVisible)
            }
            if dryRun { return .refused(.dryRun("clicked \(name(element, click.location))")) }
            await seams.hands.glide(to: point, pid: pid)
            await seams.sleep(Self.pressSettle)
            await seams.hands.click(
                at: point, button: Self.pointerButton(click.button), count: click.count,
                pid: pid)
            emit(.acted("clicked \(name(element, click.location))"))
            return .ran(resolved: element, point: point, typed: nil, holdPointer: false)

        case .hover(let hover):
            let placed = place(hover.location, in: roster, verb: .press)
            guard case .success(let (point, element)) = placed else {
                if case .failure(let refusal) = placed { return .refused(refusal) }
                return .refused(.pageNotVisible)
            }
            if dryRun { return .refused(.dryRun("hovered \(name(element, hover.location))")) }
            await seams.hands.glide(to: point, pid: pid)
            emit(.acted("hovered \(name(element, hover.location))"))
            // THE POINTER STAYS. A hover whose effect is undone before the next command
            // is not a hover; the grammar already refuses a plan that ends on one.
            return .ran(resolved: element, point: point, typed: nil, holdPointer: true)

        case .drag(let drag):
            let placed = place(drag.source, in: roster, verb: .press)
            guard case .success(let (from, element)) = placed else {
                if case .failure(let refusal) = placed { return .refused(refusal) }
                return .refused(.pageNotVisible)
            }
            let to: CGPoint
            switch drag.destination {
            case .point(let normalized):
                to = point(normalized, in: roster.pageFrame)
            case .targetFraction(let fraction):
                guard let element, let along = self.point(alongTrack: element, fraction: fraction)
                else { return .refused(.notAdjustable(name(element, drag.source))) }
                to = along
            }
            if dryRun { return .refused(.dryRun("dragged \(name(element, drag.source))")) }
            await seams.hands.glide(to: from, pid: pid)
            await seams.hands.drag(
                from: from, to: to, duration: drag.durationSeconds, pid: pid)
            emit(.acted("dragged \(name(element, drag.source))"))
            return .ran(resolved: element, point: to, typed: nil, holdPointer: false)

        case .keyChord(let chord):
            if dryRun { return .refused(.dryRun("pressed \(chord.key.rawValue)")) }
            guard await seams.keys.press(chord.key) else {
                return .refused(.notImplemented("press \(chord.key.rawValue)"))
            }
            emit(.acted("pressed \(chord.key.rawValue)"))
            return .ran(resolved: nil, point: nil, typed: nil, holdPointer: false)

        case .typeText(let typing):
            var element: AXScreenElement?
            if let phrase = typing.target {
                switch route(phrase, verb: .fill, in: roster) {
                case .failure(let refusal): return .refused(refusal)
                case .success(let found): element = found
                }
            }
            if dryRun {
                return .refused(.dryRun("typed into \(element?.label ?? "the focused field")"))
            }
            if let element {
                let point = CGPoint(x: element.frame.midX.rounded(), y: element.frame.midY.rounded())
                await seams.hands.glide(to: point, pid: pid)
                await seams.sleep(Self.pressSettle)
                await seams.hands.click(at: point, button: .left, count: 1, pid: pid)
                await seams.sleep(Self.commandSettle)
            }
            guard await seams.keys.type(
                typing.text, targetPrefix: target.registration.bundleIdentifiers.first ?? "")
            else { return .refused(.interrupted(atCommand: command.sourceIndex)) }
            if typing.submit {
                guard await seams.keys.press(.return) else {
                    return .refused(.notImplemented("submit that"))
                }
            }
            emit(.acted("typed \(typing.text.count) characters"))
            return .ran(
                resolved: element, point: nil, typed: typing.text, holdPointer: false)

        case .adjust(let adjust):
            switch route(adjust.target, verb: .adjust, in: roster) {
            case .failure(let refusal): return .refused(refusal)
            case .success(let element):
                guard let to = point(alongTrack: element, fraction: adjust.resolvedFraction)
                else { return .refused(.notAdjustable(adjust.target)) }
                if dryRun { return .refused(.dryRun("set \(element.label)")) }
                await seams.hands.glide(to: to, pid: pid)
                await seams.sleep(Self.pressSettle)
                await seams.hands.click(at: to, button: .left, count: 1, pid: pid)
                emit(.acted("set \(element.label)"))
                return .ran(resolved: element, point: to, typed: nil, holdPointer: false)
            }

        case .scroll(let scroll):
            let centre = CGPoint(
                x: roster.pageFrame.midX.rounded(), y: roster.pageFrame.midY.rounded())
            if dryRun { return .refused(.dryRun("scrolled the page")) }
            await seams.hands.scroll(at: centre, by: scroll.deltaY, pid: pid)
            if scroll.settleSeconds > 0 {
                await seams.sleep(.milliseconds(Int(scroll.settleSeconds * 1_000)))
            }
            emit(.acted("scrolled"))
            return .ran(resolved: nil, point: nil, typed: nil, holdPointer: false)

        case .wait(let wait):
            await seams.sleep(.milliseconds(Int(wait.seconds * 1_000)))
            return .ran(resolved: nil, point: nil, typed: nil, holdPointer: false)
        }
    }

    // MARK: - Reading

    /// One look at the page, published as what the screen is offering.
    func read(
        _ target: BrowserTarget, shell: WebSurfaceAX.Reading
    ) async -> Result<PageRoster, BrowserRefusal> {
        switch await perceive(target, shell: shell, intent: .elements, reveal: false) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let reading):
            // THE READING'S OWN ROWS, whose facts were decided once at the seal.
            // The AX-shaped pair rides along for the parts of this lane that
            // still read it, and goes with them.
            let roster = PageRoster(
                rows: reading.rows,
                groups: reading.groups,
                elements: reading.elements,
                map: reading.map,
                pageFrame: reading.pageFrame,
                // WHAT THE READ WAS, carried so a bench can tell a hard page from
                // a machine with no classifier installed.
                classified: reading.classified,
                readDuration: reading.duration)
            emit(.read(
                rows: roster.elements.count,
                named: roster.elements.count - roster.elements.filter {
                    roster.annotation(for: $0)?.labelSource == .synthesized
                }.count,
                groups: roster.map.groups.count))
            publishSlate(roster)
            return .success(roster)
        }
    }

    // MARK: - Routing

    /// A phrase becomes a row — the one arbitration, for every verb.
    ///
    /// PIN: THE LADDER MOVED OUT, WHOLE. This used to be three rungs and two helpers here
    /// (a naming pass, a meaning pass over the slate, and an exact-name widening), with a
    /// second copy of the same idea in the search recipe and a third for native windows.
    /// They could not be compared and they drifted. `PageRouter` is that arbitration for
    /// all of them, and it explains itself: what is left here is asking, publishing the
    /// record, and handing back the row.
    func route(
        _ phrase: String, verb: PageRouteVerb, in roster: PageRoster
    ) -> Result<AXScreenElement, BrowserRefusal> {
        let arbitration = arbitrate(phrase, verb: verb, in: roster)
        if let winner = arbitration.winner {
            emit(.matched(phrase: phrase, to: winner.label))
            // THE ROUTER ANSWERS IN ROWS; the executor and its receipts still
            // speak the AX-shaped element. Looked up by ordinal, which is the one
            // identity both views share. Both halves go with the shim.
            if let element = roster.elements.first(where: { $0.ordinal == winner.ordinal }) {
                return .success(element)
            }
        }
        return .failure(arbitration.refusal ?? .elementNotFound(phrase))
    }

    /// The whole verdict, for a caller that needs more than the row — the search recipe
    /// reads `goalUnmatched` to say when it fell back to the page's own first answer.
    func arbitrate(
        _ phrase: String, verb: PageRouteVerb, in roster: PageRoster
    ) -> PageRouteArbitration {
        let arbitration = PageRouter.arbitrate(
            goal: phrase, verb: verb, roster: roster, store: seams.slate)
        lastRoute = arbitration.trace
        // THIS PAGE IS A LIST OF ANSWERS TO SOMETHING. Remembered for the next
        // bare "open the second one" — see `lastResultQuery`.
        if case .openResult(let query) = verb, !query.isEmpty {
            lastResultQuery = query
        }
        emit(.routed(arbitration.trace))
        return arbitration
    }

    // MARK: - Places

    /// Where a pointer command goes, and the row it belongs to.
    ///
    /// PIN: THE REFUSAL COMES BACK WITH IT, rather than being re-derived by asking
    /// again. Resolving twice can answer differently — the slate moves between the two
    /// calls — and the second answer would then describe a miss that never happened.
    /// Which verb a click routes with: an ordinary press, or opening one of the
    /// answers this page is already a list of.
    ///
    /// PIN: ONLY WHEN THE PHRASE SAYS NOTHING BUT WHICH ONE. "Open the second
    /// one" and "the first video" name a position within a category and nothing
    /// else — they can only mean the answers. A phrase that NAMES something
    /// ("click the Boiler Room link") is a name, and `.press` reaches a row by
    /// name anywhere on the page, which is the wider and correct pool for it.
    /// The scoping is `.openResult`'s own; this only decides when to ask for it.
    func pressVerb(for location: PageInteractionPointerLocation) -> PageRouteVerb {
        guard case .target(let phrase) = location,
              let query = lastResultQuery, !query.isEmpty,
              PageElementKindDerivation.namesOnlyAPosition(phrase)
        else { return .press }
        return .openResult(query: query)
    }

    func place(
        _ location: PageInteractionPointerLocation, in roster: PageRoster,
        verb: PageRouteVerb
    ) -> Result<(CGPoint, AXScreenElement?), BrowserRefusal> {
        switch location {
        case .point(let normalized):
            return .success((point(normalized, in: roster.pageFrame), nil))
        case .target(let phrase):
            switch route(phrase, verb: verb, in: roster) {
            case .success(let element):
                return .success((
                    CGPoint(x: element.frame.midX.rounded(), y: element.frame.midY.rounded()),
                    element))
            case .failure(let refusal):
                return .failure(refusal)
            }
        }
    }

    func point(_ normalized: PageInteractionNormalizedPoint, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: (frame.minX + frame.width * CGFloat(normalized.x)).rounded(),
            y: (frame.minY + frame.height * CGFloat(normalized.y)).rounded())
    }

    /// Where along a track a fraction lands.
    ///
    /// PIN: ORIENTATION FROM SHAPE, and it is a guess this says out loud. A track read
    /// from pixels has no axis attribute — only a rectangle — so a long thin one runs
    /// leading to trailing and a tall thin one runs bottom to top, which is how every
    /// slider anybody draws behaves and is still an inference rather than a fact.
    func point(alongTrack element: AXScreenElement?, fraction: Double) -> CGPoint? {
        guard let frame = element?.frame, frame.width > 0, frame.height > 0 else { return nil }
        let clamped = CGFloat(min(max(fraction, 0), 1))
        if frame.width >= frame.height {
            return CGPoint(
                x: (frame.minX + frame.width * clamped).rounded(),
                y: frame.midY.rounded())
        }
        return CGPoint(
            x: frame.midX.rounded(),
            y: (frame.maxY - frame.height * clamped).rounded())
    }

    /// The grammar's button, as the machine layer's. Spelled out rather than bridged by
    /// rawValue: both are string-backed, so a hop would compile and answer wrongly the
    /// day either gains a case.
    static func pointerButton(_ button: PageInteractionPointerButton) -> PluginPointerButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .center: return .left
        }
    }

    func name(_ element: AXScreenElement?, _ location: PageInteractionPointerLocation) -> String {
        if let element { return ScreenElementResolver.shortened(element.label, limit: 40) }
        if case .target(let phrase) = location { return phrase }
        return "a point on the page"
    }

    // MARK: - Saying it

    func spoken(
        _ receipts: [PageCommandReceipt], roster: PageRoster, shell: WebSurfaceAX.Reading?
    ) -> String {
        guard !receipts.isEmpty else { return "Nothing to do." }
        if let refusal = receipts.compactMap({ receipt -> BrowserRefusal? in
            if case .refused(let refusal) = receipt.delivery { return refusal }
            return nil
        }).first {
            return refusal.summary
        }
        let done = receipts.map(\.spoken).joined(separator: "; ")
        let tail = PageListing.tail(roster)
        return tail.isEmpty ? "\(done)." : "\(done). \(tail)"
    }
}
