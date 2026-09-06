//
//  RecordingSeams.swift
//  MaryPlugin
//
//  WHAT: The engine's own boundary, wired to write down everything that crosses it.
//  IN:   BrowserEngine.Seams (any of them — live, or a replay's fakes)
//  OUT:  TripRecording, one leg at a time
//  PIN:  ONE CAPTURE POINT, AND IT IS THE SEAM THAT ALREADY EXISTS. The engine
//        was given seams so every refusal path could be reached without driving
//        a browser by hand; the same boundary is where a live run can be written
//        down without the engine learning that anybody is watching. A recorder
//        threaded through the engine's own body would be a second set of rules
//        about what a browsing turn does, kept in step by hand.
//        IT DECORATES, IT DOES NOT DECIDE. Every call forwards to the real seam
//        and returns the real answer. If this file could change what the engine
//        does, a recording would be evidence about a machine nobody runs.
//        THE PAGE FRAME IS THE FRAME OF REFERENCE. Points are recorded as
//        fractions of it, so a recording made on one display describes the same
//        place on the page as one made on another.
//

import CoreGraphics
import Foundation
import MaryComputerUse
import MaryFoundation

/// Everything one leg's seams saw, gathered in order.
public actor TripRecorder {

    private var started: Date
    private let clock: @Sendable () -> Date

    private var shells: [RecordedShell] = []
    private var pageReads: [RecordedPageRead] = []
    private var media: [RecordedMedia] = []
    private var acts: [RecordedAct] = []
    /// The page frame the current leg is aiming at, so a point can be said as a
    /// fraction of it. Set by every shell read that carries one.
    private var pageFrame: CGRect?

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        clock = now
        started = now()
    }

    /// A new leg. Everything before it belonged to the leg before.
    public func begin() {
        started = clock()
        shells = []
        pageReads = []
        media = []
        acts = []
    }

    var elapsed: Int { Int(clock().timeIntervalSince(started) * 1000) }

    // MARK: - What the seams report

    func noteShell(_ reading: WebSurfaceAX.Reading?) {
        guard let reading else { return }
        if let frame = reading.pageFrame { pageFrame = frame }
        shells.append(RecordedShell(reading, atMilliseconds: elapsed))
    }

    func notePage(_ roster: PageRoster) {
        pageReads.append(RecordedPageRead(
            page: PageRosterFixture(roster: roster), atMilliseconds: elapsed))
    }

    func noteMedia(_ reading: MediaControlReading?) {
        guard let reading else { return }
        media.append(RecordedMedia(reading, atMilliseconds: elapsed))
    }

    func noteAct(_ act: RecordedAct) {
        var act = act
        act.atMilliseconds = elapsed
        acts.append(act)
    }

    /// A point, as a fraction of the page frame this leg is aiming at.
    func place(_ point: CGPoint) -> (x: Double, y: Double)? {
        guard let pageFrame else { return nil }
        return RecordedAct.fraction(of: point, in: pageFrame)
    }

    // MARK: - What it hands back

    public func gathered() -> (
        shells: [RecordedShell], pageReads: [RecordedPageRead],
        media: [RecordedMedia], acts: [RecordedAct], elapsed: Int
    ) {
        (shells, pageReads, media, acts, elapsed)
    }

    /// The frame the leg aimed at, for a caller turning a fraction back into a
    /// point.
    public func frame() -> CGRect? { pageFrame }
}

// MARK: - The decorators

/// PIN: FIVE THIN WRAPPERS AND NOTHING ELSE. Each forwards, records, returns.
/// A decorator that computed anything would be a place for the recording and
/// the run to disagree.
struct RecordingShell: BrowserShellReading {
    let inner: any BrowserShellReading
    let recorder: TripRecorder

    func read(pid: pid_t, registration: WebSurfaceRegistration) async -> WebSurfaceAX.Reading? {
        let reading = await inner.read(pid: pid, registration: registration)
        await recorder.noteShell(reading)
        return reading
    }

    func openLocation(
        _ address: String, pid: pid_t, registration: WebSurfaceRegistration
    ) async -> Bool {
        // THE ADDRESS IS NOT WRITTEN DOWN — only that one was typed, and how
        // long it was. A recording holds no query strings.
        await recorder.noteAct(RecordedAct(
            kind: .openLocation, typedLength: address.count))
        return await inner.openLocation(address, pid: pid, registration: registration)
    }

    func press(label: String, pid: pid_t, registration: WebSurfaceRegistration) async -> Bool {
        // A SHELL LABEL IS PACKAGE DATA, not a page's words — safe to keep, and
        // the only way to tell which chord was pressed.
        await recorder.noteAct(RecordedAct(kind: .pressShell, shellLabel: label))
        return await inner.press(label: label, pid: pid, registration: registration)
    }
}

struct RecordingPage: PagePerceiving {
    let inner: any PagePerceiving
    let recorder: TripRecorder

    func read(
        pid: pid_t, windowID: CGWindowID?, pageFrame: CGRect,
        intent: VisionPageReader.Intent, appName: String, windowTitle: String,
        previousFraction: Double?, previousElapsed: TimeInterval?
    ) async throws -> VisionPageReader.Reading {
        let reading = try await inner.read(
            pid: pid, windowID: windowID, pageFrame: pageFrame, intent: intent,
            appName: appName, windowTitle: windowTitle,
            previousFraction: previousFraction, previousElapsed: previousElapsed)
        await recorder.noteMedia(reading.media)
        // A MEDIA READ HAS NO ROWS AND IS NOT A PAGE READ. Recording an empty
        // roster for it would put a page with nothing on it into the evidence.
        if intent == .elements || !reading.rows.isEmpty || !reading.elements.isEmpty {
            await recorder.notePage(PageRoster(
                rows: reading.rows,
                groups: reading.groups,
                elements: reading.elements,
                map: reading.map,
                pageFrame: reading.pageFrame,
                classified: reading.classified,
                readDuration: reading.duration))
        }
        return reading
    }
}

struct RecordingHands: BrowserHands {
    let inner: any BrowserHands
    let recorder: TripRecorder

    private func place(_ point: CGPoint) async -> (x: Double, y: Double)? {
        await recorder.place(point)
    }

    func move(to point: CGPoint, pid: pid_t) async {
        let at = await place(point)
        await recorder.noteAct(RecordedAct(kind: .move, atX: at?.x, atY: at?.y))
        await inner.move(to: point, pid: pid)
    }

    func click(
        at point: CGPoint, button: PluginPointerButton, count: Int, pid: pid_t
    ) async {
        let at = await place(point)
        await recorder.noteAct(RecordedAct(kind: .click, atX: at?.x, atY: at?.y))
        await inner.click(at: point, button: button, count: count, pid: pid)
    }

    func scroll(at point: CGPoint, by delta: Double, pid: pid_t) async {
        let at = await place(point)
        await recorder.noteAct(RecordedAct(
            kind: .scroll, atX: at?.x, atY: at?.y, delta: delta))
        await inner.scroll(at: point, by: delta, pid: pid)
    }

    func hover(at point: CGPoint, pid: pid_t) async {
        let at = await place(point)
        await recorder.noteAct(RecordedAct(kind: .hover, atX: at?.x, atY: at?.y))
        await inner.hover(at: point, pid: pid)
    }

    func glide(to point: CGPoint, pid: pid_t) async {
        let at = await place(point)
        await recorder.noteAct(RecordedAct(kind: .glide, atX: at?.x, atY: at?.y))
        await inner.glide(to: point, pid: pid)
    }

    func drag(from: CGPoint, to: CGPoint, duration: Double, pid: pid_t) async {
        let start = await place(from)
        let end = await place(to)
        await recorder.noteAct(RecordedAct(
            kind: .drag, atX: start?.x, atY: start?.y, toX: end?.x, toY: end?.y))
        await inner.drag(from: from, to: to, duration: duration, pid: pid)
    }

    func cursorLocation() async -> CGPoint? { await inner.cursorLocation() }

    func restoreCursor(to point: CGPoint?) async {
        await recorder.noteAct(RecordedAct(kind: .restoreCursor))
        await inner.restoreCursor(to: point)
    }
}

struct RecordingKeys: BrowserKeys {
    let inner: any BrowserKeys
    let recorder: TripRecorder

    func type(_ text: String, targetPrefix: String) async -> Bool {
        // HOW MUCH WAS TYPED, NEVER WHAT. The chunk-boundary race is about
        // LENGTH, which is the whole of what a recording needs to show it.
        await recorder.noteAct(RecordedAct(kind: .type, typedLength: text.count))
        return await inner.type(text, targetPrefix: targetPrefix)
    }

    func press(_ key: PageInteractionKey) async -> Bool {
        await recorder.noteAct(RecordedAct(kind: .key, key: key.rawValue))
        return await inner.press(key)
    }
}

struct RecordingStaging: BrowserStaging {
    let inner: any BrowserStaging
    let recorder: TripRecorder

    func bringForward(pid: pid_t) async -> Bool {
        await recorder.noteAct(RecordedAct(kind: .bringForward))
        return await inner.bringForward(pid: pid)
    }

    func holdsFocus(pid: pid_t) async -> Bool { await inner.holdsFocus(pid: pid) }
}

// MARK: - Wiring

public extension BrowserEngine.Seams {

    /// The same seams, writing down everything that crosses them.
    ///
    /// PIN: A RECORDING RUN AND AN ORDINARY RUN MUST BE THE SAME RUN. Every
    /// timing, every settle and every retry is the inner seam's; this adds an
    /// append to an actor per call and decides nothing.
    func recording(into recorder: TripRecorder) -> BrowserEngine.Seams {
        BrowserEngine.Seams(
            shell: RecordingShell(inner: shell, recorder: recorder),
            page: RecordingPage(inner: page, recorder: recorder),
            hands: RecordingHands(inner: hands, recorder: recorder),
            keys: RecordingKeys(inner: keys, recorder: recorder),
            stage: RecordingStaging(inner: stage, recorder: recorder),
            slate: slate,
            sleep: sleep,
            now: now)
    }
}

// MARK: - Turning the engine's own answers into a recording

public extension RecordedRoute {

    /// One arbitration, as the trace made it.
    init(_ trace: PageRouteTrace, facts: [Int: RowFacts], atMilliseconds: Int) {
        self.init(
            goal: trace.goal,
            verb: trace.verb,
            eligibleCount: trace.eligibleCount,
            goalUnmatched: trace.goalUnmatched,
            selectedOrdinal: trace.selected.first?.id,
            rivalOrdinals: trace.rivals.map(\.id),
            decisions: trace.decisions.map { decision in
                RecordedRouteDecision(
                    ordinal: decision.id,
                    disposition: decision.disposition.rawValue,
                    label: decision.label,
                    reason: decision.reason,
                    lexical: decision.evidence.lexical,
                    lexicalBasis: decision.evidence.lexicalBasis.rawValue,
                    semantic: decision.evidence.semantic,
                    affordance: decision.evidence.affordance,
                    provenance: decision.evidence.provenance,
                    structure: decision.evidence.structure,
                    facts: facts[decision.id]?.rawValue ?? 0)
            },
            atMilliseconds: atMilliseconds)
    }
}

public extension RecordedReceipt {

    init(_ receipt: PageCommandReceipt) {
        let delivery: String
        switch receipt.delivery {
        case .delivered: delivery = "delivered"
        case .refused(let refusal): delivery = "refused: \(RecordedReceipt.name(of: refusal))"
        case .notAttempted: delivery = "notAttempted"
        case .interrupted: delivery = "interrupted"
        }
        let evidence: PageEffectEvidence?
        switch receipt.effect {
        case .verified(let found), .weak(let found): evidence = found
        case .unverified: evidence = nil
        }
        self.init(
            kind: receipt.kind.rawValue,
            target: receipt.target,
            delivery: delivery,
            receipt: RecordedReceipt.name(of: evidence),
            landed: receipt.landed,
            spoken: receipt.spoken)
    }

    /// The receipt RANK, which is what a trip states — never its sentence.
    static func name(of evidence: PageEffectEvidence?) -> String {
        switch evidence {
        case .navigation: return "navigation"
        case .targetChanged: return "targetChanged"
        case .textAppeared: return "textAppeared"
        case .rosterChanged: return "rosterChanged"
        case .mediaState: return "mediaState"
        case nil: return "none"
        }
    }

    /// A refusal's CLASS. The summaries carry a page's own words and a trip
    /// asserts which refusal, so only the case name is recorded.
    static func name(of refusal: BrowserRefusal) -> String {
        switch refusal {
        case .noBrowser: return "noBrowser"
        case .ambiguousBrowser: return "ambiguousBrowser"
        case .shellUnreadable: return "shellUnreadable"
        case .pageNotVisible: return "pageNotVisible"
        case .visionUnavailable: return "visionUnavailable"
        case .controlsNotFound: return "controlsNotFound"
        case .controlNotFound: return "controlNotFound"
        case .stateUnchanged: return "stateUnchanged"
        case .navigationDidNotSettle: return "navigationDidNotSettle"
        case .humanCheck: return "humanCheck"
        case .addressFieldNotFound: return "addressFieldNotFound"
        case .elementNotFound: return "elementNotFound"
        case .ambiguousElement: return "ambiguousElement"
        case .planInvalid: return "planInvalid"
        case .interrupted: return "interrupted"
        case .searchCompletedElsewhere: return "searchCompletedElsewhere"
        case .notFillable: return "notFillable"
        case .notAdjustable: return "notAdjustable"
        case .outOfTime: return "outOfTime"
        case .activationRefused: return "activationRefused"
        case .notImplemented: return "notImplemented"
        case .dryRun: return "dryRun"
        }
    }
}
