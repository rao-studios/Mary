//
//  AmbientCaptureBuilderTests.swift
//  MaryAmbientTests
//
//  WHAT: Capture admits exactly the rendered facts, in order; no fabricated geometry.
//  OUT:  AmbientCaptureBuilder
//

import Foundation
import MaryFoundation
import Testing
@testable import MaryAmbient

@Suite struct AmbientCaptureBuilderTests {

    // MARK: - Fixtures

    static let now = Date(timeIntervalSince1970: 1_787_821_200)
    static let textEdit = AmbientPlace.application("textedit")

    static func frame(_ x: Double, _ y: Double) -> AXFrame {
        AXFrame(
            space: .axGlobalTopLeft,
            rect: .init(x: x, y: y, width: 100, height: 20),
            center: .init(x: x + 50, y: y + 10),
            capturedAt: now)
    }

    static func element(
        _ identity: String, ordinal: Int, label: String, frame: AXFrame?
    ) -> AmbientSurface.Element {
        AmbientSurface.Element(
            identity: identity, ordinal: ordinal, role: "AXButton",
            kind: "button", label: label, frame: frame)
    }

    static func surface(
        elements: [AmbientSurface.Element], windowTitle: String = "Essay"
    ) -> AmbientSurface {
        AmbientSurface(
            place: textEdit,
            application: .init(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 4321),
            activeWindow: .init(title: windowTitle, frame: frame(0, 0)),
            windowCount: 1,
            elements: elements,
            capturedAt: now.addingTimeInterval(-2))
    }

    static func fact(
        slot: AmbientSlot = .file, content: String, ageSeconds: Double = 3
    ) -> AmbientFact {
        AmbientFact(
            attention: .applications, application: "textedit", slot: slot,
            content: content, provenance: .cachedBody,
            capturedAt: now.addingTimeInterval(-ageSeconds))
    }

    // MARK: - Injected, not held

    /// THE CENTRAL PROPERTY. Two facts are held; the rendering admitted one.
    /// The capture carries that one.
    @Test func onlyRenderedFactsAreCaptured() {
        let shown = Self.fact(content: "Essay — 1,840 characters.")
        let hidden = Self.fact(slot: .viewport, content: "Something nobody asked about.")
        let rendering = AmbientRendering(
            mode: .focusedWorld,
            blocks: [shown.content],
            keys: [shown.key])

        let capture = AmbientCaptureBuilder.capture(
            facts: [shown, hidden], surfaces: [], rendering: rendering, at: Self.now)

        #expect(capture.facts.count == 1)
        #expect(capture.facts.first?.text == shown.content)
    }

    /// ORDER IS INFORMATION. The rendering's key order is the model's reading
    /// order — which fact led — and a capture that re-sorted would erase what
    /// the ranking decided.
    @Test func capturedFactsFollowTheRenderedOrder() {
        let first = Self.fact(slot: .file, content: "the document")
        let second = Self.fact(slot: .viewport, content: "the viewport")
        let rendering = AmbientRendering(
            mode: .relevance,
            blocks: [second.content, first.content],
            keys: [second.key, first.key])

        let capture = AmbientCaptureBuilder.capture(
            facts: [first, second], surfaces: [], rendering: rendering, at: Self.now)

        #expect(capture.facts.map(\.text) == ["the viewport", "the document"])
    }

    /// A key the renderer named but the store no longer holds is skipped
    /// rather than crashing or emitting a placeholder.

    /// AGE IS LOAD-BEARING. A fact renders with its age and loses authority as
    /// it grows, so a future model reading the dataset needs the difference
    /// between "the document says X" and "it said X four minutes ago".

    // MARK: - Tokens

    /// The place token is the collision-free spelling, shared with the pane
    /// and the trace so a capture and a trace naming one place say one word.

    /// A named read keeps its phrase in the token, so a read of one thing
    /// stays distinguishable from a read of another.

    /// EVERY LANE AND EVERY SLOT HAS A TOKEN, and no two collide. A silent
    /// collision merges two populations in the dataset.

    // MARK: - Surfaces

    /// A frameless element is DROPPED AND COUNTED. Inventing a zero rect would
    /// put a lie in the dataset shaped exactly like evidence.
    @Test func aFramelessElementIsDroppedAndCounted() {
        let surface = Self.surface(elements: [
            Self.element("axbutton|share", ordinal: 1, label: "Share", frame: Self.frame(10, 20)),
            Self.element("axbutton|ghost", ordinal: 2, label: "Ghost", frame: nil),
        ])
        let capture = AmbientCaptureBuilder.capture(
            facts: [], surfaces: [surface],
            rendering: AmbientRendering(mode: .relevance), at: Self.now)

        #expect(capture.surfaces.first?.elements.count == 1)
        #expect(capture.surfaces.first?.framelessDropped == 1)
        #expect(capture.surfaces.first?.elements.first?.identity == "axbutton|share")
    }

    /// The cap keeps the top of the window — reading order — and says so.

    // MARK: - The rendered lines

    /// Both halves travel: the structure a future model should learn from,
    /// and the strings this build's model actually read. A disagreement
    /// between them is then visible in the data rather than invisible.

    // MARK: - Absent is not empty

    /// A capture built from nothing is EMPTY — a real observation, meaning
    /// context was assembled and there was none. The episode records "no
    /// context was assembled at all" by holding no capture, which is a
    /// different fact and is the caller's decision, not this builder's.
    @Test func aCaptureFromNothingIsEmptyRatherThanAbsent() {
        let capture = AmbientCaptureBuilder.capture(
            facts: [], surfaces: [], rendering: AmbientRendering(mode: .relevance),
            at: Self.now)
        #expect(capture.isEmpty)
        #expect(capture.mode == "relevance")
    }
}
