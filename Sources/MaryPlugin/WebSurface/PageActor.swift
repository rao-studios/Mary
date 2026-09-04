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
        let shellOutcome = await readShell(target)
        guard let shell = shellOutcome.shell else { return shellOutcome }
        guard await seams.stage.bringForward(pid: target.processIdentifier) else {
            return refuse(.activationRefused(target.spokenName))
        }
        // Restored in order, never in a deferred Task — see `describeMedia`.
        let cursor = await seams.hands.cursorLocation()
        let outcome = await perform(
            plan, in: target, shell: shell, deadline: deadline, restingAt: cursor)
        await seams.hands.restoreCursor(to: cursor)
        return outcome
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
                    AffordanceSlatePublisher.retract(store: seams.slate)
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
            let placed = place(click.location, in: roster, requiring: nil)
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
            let placed = place(hover.location, in: roster, requiring: nil)
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
            let placed = place(drag.source, in: roster, requiring: nil)
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
                switch resolveGoal(phrase, in: roster, requiring: .fill) {
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
            switch resolveGoal(adjust.target, in: roster, requiring: .adjust) {
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
            let roster = PageRoster(
                elements: reading.elements, map: reading.map,
                pageFrame: reading.pageFrame)
            emit(.read(
                rows: roster.elements.count,
                named: roster.elements.count - roster.elements.filter {
                    roster.annotation(for: $0)?.labelSource == .synthesized
                }.count,
                groups: roster.map.groups.count))
            AffordanceSlatePublisher.publish(roster, store: seams.slate)
            return .success(roster)
        }
    }

    // MARK: - Resolving

    /// THE ONE LADDER. A phrase becomes a row here, for every verb and for the
    /// deterministic affordance press alike: the naming ladder first, strictly, then
    /// meaning over the slate this read just published.
    func resolveGoal(
        _ phrase: String, in roster: PageRoster, requiring affordance: SeenAffordance?
    ) -> Result<AXScreenElement, BrowserRefusal> {
        let pool: [AXScreenElement]
        switch affordance {
        case .fill: pool = roster.fillable.isEmpty ? roster.actionable : roster.fillable
        case .adjust: pool = roster.adjustable.isEmpty ? roster.actionable : roster.adjustable
        default: pool = roster.actionable
        }
        guard !pool.isEmpty else { return .failure(.elementNotFound(phrase)) }

        // NAMING A REAL THING OF THE WRONG SORT IS A DIFFERENT MISTAKE FROM NAMING
        // NOTHING, and it deserves the sentence that says so. The narrowed pool answers
        // first — "the search box" must find the field even when a link says "search" —
        // and only when it finds nothing does the whole page get asked, so that a hit
        // there can be refused for what it is rather than reported as missing.
        if let affordance, pool.count != roster.actionable.count,
           case .none = ScreenElementResolver.resolve(
               phrase: phrase, in: pool, preferShortestOnTie: false),
           case .one = ScreenElementResolver.resolve(
               phrase: phrase, in: roster.actionable, preferShortestOnTie: false) {
            return .failure(mismatch(phrase, affordance))
        }

        switch ScreenElementResolver.resolve(
            phrase: phrase, in: pool, preferShortestOnTie: false) {
        case .one(let element):
            guard let checked = checked(
                element, phrase: phrase, requiring: affordance, in: roster)
            else { return .failure(mismatch(phrase, affordance)) }
            return .success(checked)
        case .ambiguous(let rivals):
            // MEANING BREAKS A NAMING TIE, but only when it picks ONE. Two things that
            // both answer to the phrase stay two things.
            if let best = bySense(phrase, among: rivals, in: roster) {
                return .success(best)
            }
            return .failure(.ambiguousElement(
                phrase: phrase,
                rivals: rivals.prefix(3).map { ScreenElementResolver.shortened($0.label, limit: 40) }))
        case .none:
            if let best = bySense(phrase, among: pool, in: roster) {
                return .success(best)
            }
            // A PERSON NAMING SOMETHING IS EVIDENCE THE MAP DOES NOT HAVE.
            //
            // PIN: The map offers what it is confident about; a phrase reaches further,
            // because whoever said it can see the screen. Measured: a retrained
            // classifier stopped calling body text `AXLink` — the fix that mattered —
            // and in the same pass stopped calling a real "9 languages" control anything
            // at all, so a click that had worked live began refusing. Widening to every
            // row the map holds, but ONLY on an exact naming match and only when nothing
            // offered fits, restores the act without weakening what is offered. The
            // receipt still decides whether it did anything.
            if case .one(let element) = ScreenElementResolver.resolve(
                phrase: phrase, in: roster.elements, preferShortestOnTie: false),
               element.isEnabled {
                emit(.matched(phrase: phrase, to: "\(element.label) (not offered)"))
                return .success(element)
            }
            return .failure(.elementNotFound(phrase))
        }
    }

    private func checked(
        _ element: AXScreenElement, phrase: String, requiring affordance: SeenAffordance?,
        in roster: PageRoster
    ) -> AXScreenElement? {
        guard let affordance else { return element }
        guard let found = roster.annotation(for: element)?.affordance else { return element }
        return found == affordance ? element : nil
    }

    private func mismatch(_ phrase: String, _ affordance: SeenAffordance?) -> BrowserRefusal {
        switch affordance {
        case .fill: return .notFillable(phrase)
        case .adjust: return .notAdjustable(phrase)
        default: return .elementNotFound(phrase)
        }
    }

    /// The embedding rung, over the slate this read published — the same gate a native
    /// window's affordances go through.
    private func bySense(
        _ phrase: String, among pool: [AXScreenElement], in roster: PageRoster
    ) -> AXScreenElement? {
        let ranked = AmbientReferenceGate.rank(
            phrase: phrase, scope: AffordanceSlatePublisher.browserScope,
            requires: .pressable, store: seams.slate)
            .filter { AffordanceDistinctiveness.survives($0, phrase: phrase) }
        guard let best = ranked.first else { return nil }
        // A GENUINE TIE IS STILL A TIE. The band is the gate's own, so two rivals that
        // matched on the same basis stay rivals rather than being separated by noise.
        let tied = ranked.filter { $0.score >= best.score - AffordanceResolver.tieBand }
        guard tied.count == 1 else { return nil }
        let byIdentity = Dictionary(
            pool.map { (AffordanceSlatePublisher.identity(of: $0), $0) },
            uniquingKeysWith: { first, _ in first })
        guard let element = byIdentity[best.record.elementID], element.isEnabled else {
            return nil
        }
        emit(.matched(phrase: phrase, to: element.label))
        return element
    }

    // MARK: - Places

    /// Where a pointer command goes, and the row it belongs to.
    ///
    /// PIN: THE REFUSAL COMES BACK WITH IT, rather than being re-derived by asking
    /// again. Resolving twice can answer differently — the slate moves between the two
    /// calls — and the second answer would then describe a miss that never happened.
    func place(
        _ location: PageInteractionPointerLocation, in roster: PageRoster,
        requiring affordance: SeenAffordance?
    ) -> Result<(CGPoint, AXScreenElement?), BrowserRefusal> {
        switch location {
        case .point(let normalized):
            return .success((point(normalized, in: roster.pageFrame), nil))
        case .target(let phrase):
            switch resolveGoal(phrase, in: roster, requiring: affordance) {
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
