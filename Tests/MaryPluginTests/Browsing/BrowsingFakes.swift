//
//  BrowsingFakes.swift
//  MaryPluginTests
//
//  WHAT: The browsing engine's seams and fixtures, faked — shared by every suite
//        that drives a BrowserEngine without a browser.
//  OUT:  FakeShell, FakePage, FakeHands, FakeKeys, FakeStage, BrowsingFixtures
//  PIN:  ONE SET OF FAKES. Eight suites drive the engine; a second FakeStage
//        would be a second opinion about what the stage does. The clock is a
//        fake too — see `BrowsingFixtures.engine`.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryAmbient
import MaryComputerUse
@testable import MaryFoundation
@testable import MaryPlugin

// MARK: - Fakes

final class FakeShell: BrowserShellReading, @unchecked Sendable {
    var readings: [WebSurfaceAX.Reading?]
    var opened: [String] = []
    var pressed: [String] = []
    var openSucceeds = true
    var pressSucceeds = true

    /// Every window the engine asked for, in order (nil: none named yet).
    var preferred: [CGWindowID?] = []
    var pressedWithin: [CGWindowID?] = []

    init(_ readings: [WebSurfaceAX.Reading?]) { self.readings = readings }

    func read(
        pid: pid_t, registration: WebSurfaceRegistration, preferring window: CGWindowID?
    ) async -> WebSurfaceAX.Reading? {
        preferred.append(window)
        return readings.count > 1 ? readings.removeFirst() : readings.first ?? nil
    }

    func openLocation(
        _ address: String, pid: pid_t, registration: WebSurfaceRegistration,
        within window: CGWindowID?
    ) async -> Bool {
        opened.append(address)
        return openSucceeds
    }

    func press(
        label: String, pid: pid_t, registration: WebSurfaceRegistration, within window: CGWindowID?
    ) async -> Bool {
        pressedWithin.append(window)
        pressed.append(label)
        return pressSucceeds
    }
}

final class FakePage: PagePerceiving, @unchecked Sendable {
    var readings: [MediaControlReading?]
    var failure: VisionPageReader.Failure?
    var reads = 0
    /// Rosters served to `.elements`, one per read; the last one repeats.
    var pages: [(elements: [AXScreenElement], map: PageMapSummary)] = []
    /// Rows served to `.elements` instead, when a test needs what only a row
    /// carries — a slider's value and range. One per read; the last repeats.
    var rowPages: [[PageRow]] = []
    var elementReads = 0

    init(_ readings: [MediaControlReading?], failure: VisionPageReader.Failure? = nil) {
        self.readings = readings
        self.failure = failure
    }

    convenience init(pages: [(elements: [AXScreenElement], map: PageMapSummary)]) {
        self.init([nil])
        self.pages = pages
    }

    func read(
        pid: pid_t, windowID: CGWindowID?, pageFrame: CGRect,
        intent: VisionPageReader.Intent, appName: String, windowTitle: String,
        previousFraction: Double?, previousElapsed: TimeInterval?
    ) async throws -> VisionPageReader.Reading {
        if let failure { throw failure }
        reads += 1
        if intent == .elements, !rowPages.isEmpty {
            let index = min(elementReads, rowPages.count - 1)
            elementReads += 1
            return Self.reading(rows: rowPages[index], pid: pid, appName: appName,
                                windowTitle: windowTitle, pageFrame: pageFrame)
        }
        if intent == .elements {
            let index = min(elementReads, max(0, pages.count - 1))
            elementReads += 1
            let page: (elements: [AXScreenElement], map: PageMapSummary) =
                pages.isEmpty ? (elements: [], map: PageMapSummary()) : pages[index]
            return VisionPageReader.Reading(
                elements: page.elements, pageFrame: pageFrame, pixelsPerPoint: 1,
                classified: true, map: page.map)
        }
        let media = readings.count > 1 ? readings.removeFirst() : readings.first ?? nil
        return VisionPageReader.Reading(
            media: media, pageFrame: pageFrame, pixelsPerPoint: 1)
    }

    /// THE AX SHIM RIDES WITH THE ROWS. `PageActor.route` still looks up an
    /// element by the winner's ordinal, so a fake that published only `PageRow`s
    /// could never be pressed.
    static func reading(
        rows: [PageRow], pid: pid_t, appName: String, windowTitle: String, pageFrame: CGRect
    ) -> VisionPageReader.Reading {
        let groupRefs = Dictionary(
            rows.compactMap { row -> (Int, PageGroupRef)? in row.group.map { ($0.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let groups = groupRefs.values.sorted { $0.id < $1.id }.map { ref in
            PageGroup(
                id: ref.id, kind: ref.kind, title: ref.title,
                memberOrdinals: rows.filter { $0.group?.id == ref.id }.map(\.ordinal).sorted())
        }
        var annotations: [Int: SeenElementAnnotation] = [:]
        let elements: [AXScreenElement] = rows.map { row in
            let role = row.role ?? (row.affordance == .press ? "AXLink" : "AXStaticText")
            annotations[row.ordinal] = SeenElementAnnotation(
                affordance: row.affordance, affordanceSource: row.affordanceSource,
                labelSource: row.labelSource, hints: row.hints,
                groupID: row.group?.id, confidence: row.confidence)
            return AXScreenElement(
                ordinal: row.ordinal, id: AXNodeID(raw: UInt(row.ordinal)),
                pid: pid, appName: appName, windowID: AXNodeID(raw: 1),
                windowTitle: windowTitle, role: role,
                category: AXNodeCategory.category(role: role),
                label: row.label, frame: row.frame,
                containerTrail: [row.group?.title, row.group?.kind.rawValue]
                    .compactMap { $0 }.filter { !$0.isEmpty },
                provenance: row.provenance)
        }
        return VisionPageReader.Reading(
            rows: rows, groups: groups, elements: elements,
            pageFrame: pageFrame, pixelsPerPoint: 1, classified: true,
            map: PageMapSummary(
                groups: groups.map {
                    SeenGroup(id: $0.id, kind: $0.kind.rawValue, title: $0.title,
                              memberOrdinals: $0.memberOrdinals)
                },
                annotations: annotations, labeledFraction: 1))
    }
}

final class FakeHands: BrowserHands, @unchecked Sendable {
    var clicks: [CGPoint] = []
    var hovers: [CGPoint] = []
    var glides: [CGPoint] = []
    var drags: [(CGPoint, CGPoint)] = []
    var scrolls: [Double] = []
    var restored: [CGPoint?] = []

    var onClick: (() -> Void)?
    func click(
        at point: CGPoint, button: PluginPointerButton, count: Int, pid: pid_t
    ) async {
        clicks.append(point)
        onClick?()
    }
    func scroll(at point: CGPoint, by delta: Double, pid: pid_t) async {
        scrolls.append(delta)
    }
    func hover(at point: CGPoint, pid: pid_t) async { hovers.append(point) }
    func glide(to point: CGPoint, pid: pid_t) async { glides.append(point) }
    func drag(from: CGPoint, to: CGPoint, duration: Double, pid: pid_t) async {
        drags.append((from, to))
    }
    func cursorLocation() async -> CGPoint? { CGPoint(x: 5, y: 5) }
    func restoreCursor(to point: CGPoint?) async { restored.append(point) }
}

final class FakeKeys: BrowserKeys, @unchecked Sendable {
    var typed: [String] = []
    var pressed: [PageInteractionKey] = []
    var typeSucceeds = true

    func type(_ text: String, targetPrefix: String) async -> Bool {
        typed.append(text)
        return typeSucceeds
    }

    func press(_ key: PageInteractionKey) async -> Bool {
        pressed.append(key)
        return true
    }

    var chords: [String] = []
    func chord(
        _ key: PluginKey, modifiers: [PluginKeyModifier], targetPrefix: String
    ) async -> Bool {
        chords.append((modifiers.map(\.rawValue) + [key.rawValue]).joined(separator: "+"))
        return true
    }
}

final class FakeStage: BrowserStaging, @unchecked Sendable {
    var succeeds = true
    var keepsFocus = true
    /// Who is in front before the act — the process the stage may be owed to.
    var front: pid_t?
    /// Every pid the stage was taken for, in order.
    var taken: [pid_t] = []
    /// Every stand-down, with the pid the stage was given back to (nil: kept).
    var stoodDown: [pid_t?] = []
    /// Queued outcomes, consumed in order. Empty falls back to `succeeds`.
    var outcomes: [Activation] = []

    init(
        succeeds: Bool = true, keepsFocus: Bool = true, front: pid_t? = nil,
        outcomes: [Activation] = []
    ) {
        self.succeeds = succeeds
        self.keepsFocus = keepsFocus
        self.front = front
        self.outcomes = outcomes
    }

    func frontmost() async -> pid_t? { front }
    var raised: [CGWindowID?] = []
    func bringForward(pid: pid_t, raising window: CGWindowID?) async -> Activation {
        raised.append(window)
        var outcome = take(pid)
        // A minimized window is "nothing on screen"; the raise road tries again.
        if outcome.failure == .noVisibleWindow, !outcomes.isEmpty {
            outcome = take(pid)
        }
        return outcome
    }
    private func take(_ pid: pid_t) -> Activation {
        taken.append(pid)
        if !outcomes.isEmpty { return outcomes.removeFirst() }
        return succeeds ? Activation(road: .cooperative, failure: nil) : .lost(.refused)
    }
    func standDown(givingBackTo previous: pid_t?) async { stoodDown.append(previous) }
    func holdsFocus(pid: pid_t) async -> Bool { keepsFocus }
    /// Another act asked for the stage; flipped by a test mid-act.
    var preempt = false
    func preemptRequested() async -> Bool { preempt }
}

// MARK: - Support

enum BrowsingFixtures {

    static let pageFrame = CGRect(x: 100, y: 200, width: 800, height: 600)

    static func target() -> BrowserTarget {
        BrowserTarget(
            registration: WebSurfaceRegistration(
                applicationID: "a-browser",
                bundleIdentifiers: ["test.browser"],
                displayName: "A Browser",
                schema: PluginWebSurfaceSchema(
                    addressFieldLabel: "address",
                    backLabel: "Back", forwardLabel: "Forward", reloadLabel: "Reload")),
            processIdentifier: 1234)
    }

    static func shell(
        title: String = "A Page", url: String? = "https://example.com/x",
        canGoBack: Bool? = true
    ) -> WebSurfaceAX.Reading {
        WebSurfaceAX.Reading(
            title: title, url: url, pageFrame: pageFrame, pageFrameSource: "test",
            canGoBack: canGoBack, canGoForward: false, tabs: ["A Page"],
            windowFrame: pageFrame)
    }

    static func media(
        playing: MediaControlReading.Playback = .paused,
        fraction: Double = 0.2,
        muted: Bool? = nil,
        controlsVisible: Bool = true
    ) -> MediaControlReading {
        let volume: MediaControlReading.Control? = muted.map {
            .init(frame: CGRect(x: 180, y: 700, width: 20, height: 20),
                  glyph: $0 ? .muted : .volume, confidence: 0.6)
        }
        return MediaControlReading(
            pageFrame: pageFrame,
            controlsVisible: controlsVisible,
            playback: playing,
            playPause: .init(
                frame: CGRect(x: 120, y: 700, width: 20, height: 20),
                glyph: playing == .playing ? .pause : .play, confidence: 0.7),
            volume: volume,
            progress: .init(
                frame: CGRect(x: 110, y: 680, width: 780, height: 4), fraction: fraction))
    }

    /// One page's worth of rows, with the map that describes them.
    static func page(
        _ rows: [(role: String, label: String, affordance: SeenAffordance)],
        group: (kind: String, title: String?)? = nil,
        source: SeenAffordanceSource = .classifier,
        labelSource: SeenLabelSource = .textInside,
        hints: [Int: [String]] = [:],
        confidence: Double = 0
    ) -> (elements: [AXScreenElement], map: PageMapSummary) {
        var elements: [AXScreenElement] = []
        var annotations: [Int: SeenElementAnnotation] = [:]
        for (index, row) in rows.enumerated() {
            let ordinal = index + 1
            elements.append(AXScreenElement(
                ordinal: ordinal,
                id: AXNodeID(raw: UInt(ordinal)),
                pid: 1234,
                appName: "A Browser",
                windowID: AXNodeID(raw: 1),
                windowTitle: "A Page",
                role: row.role,
                category: AXNodeCategory.category(role: row.role),
                label: row.label,
                frame: CGRect(
                    x: 140, y: 240 + CGFloat(index) * 60, width: 400, height: 40),
                containerTrail: group.map { [$0.title, $0.kind].compactMap { $0 } } ?? [],
                provenance: .seen))
            annotations[ordinal] = SeenElementAnnotation(
                affordance: row.affordance,
                affordanceSource: source,
                labelSource: labelSource,
                hints: hints[ordinal] ?? [],
                groupID: group == nil ? nil : 0,
                confidence: confidence)
        }
        let groups = group.map { described in
            [SeenGroup(
                id: 0, kind: described.kind, title: described.title,
                memberOrdinals: Array(1 ... max(1, rows.count)))]
        } ?? []
        return (elements, PageMapSummary(
            groups: groups, annotations: annotations, labeledFraction: 1))
    }

    /// PIN: THE CLOCK IS A FAKE TOO. The settle loop polls until a deadline, so a real
    /// `Date()` makes the stalled-navigation test wait the whole budget — ten seconds of
    /// a suite spent proving something arithmetic. This advances a second per reading.
    static func engine(
        shell: FakeShell, page: FakePage, hands: FakeHands = FakeHands(),
        keys: FakeKeys = FakeKeys(), stage: FakeStage = FakeStage(), dryRun: Bool = false
    ) -> BrowserEngine {
        let clock = Clock()
        return BrowserEngine(
            seams: .init(
                shell: shell, page: page, hands: hands, keys: keys, stage: stage,
                // ITS OWN SLATE. The suite runs in parallel and the shared one is
                // process-wide, so two engines publishing into it answered each other's
                // questions — a failure that appeared and vanished with test order.
                slate: AmbientElementIndexStore(),
                sleep: { _ in clock.advance(1) }, now: { clock.now }),
            dryRun: dryRun)
    }

    final class Clock: @unchecked Sendable {
        private let start = Date(timeIntervalSince1970: 1_000_000)
        private var elapsed: TimeInterval = 0
        var now: Date { start.addingTimeInterval(elapsed) }
        func advance(_ seconds: TimeInterval) { elapsed += seconds }
    }
}
