//
//  AmbientCaptureBuilderTests.swift
//  MaryAmbientTests
//
//  WHAT THE MODEL SAW, PINNED.
//
//  The capture is the input half of every behavioural episode, so the
//  properties worth testing are the ones a future training run would silently
//  depend on and never complain about.
//
//  INJECTED, NOT HELD. The store offers more than any turn uses; the capture
//  must contain exactly what the renderer admitted, in the order it admitted
//  it. A capture that quietly included un-rendered facts would teach a model
//  to act on context the live one never received — training input that does
//  not match inference input, which is the one thing behavioural cloning
//  cannot survive.
//
//  THE TOKENS ARE THE SCHEMA. Realms and slots cross into the dataset as
//  strings, and this file is where their spelling is agreed. Getting one
//  wrong does not fail anything today — it silently splits one place into two
//  populations in a dataset nobody reads for months.
//
//  NO FABRICATED GEOMETRY. An element without a frame is dropped and counted,
//  never given a zero rect. A lie shaped like evidence is worse than a gap,
//  because the gap is visible.
//

import Foundation
import MaryFoundation
import Testing
@testable import MaryAmbient

@Suite struct AmbientCaptureBuilderTests {

    // MARK: - Fixtures

    static let now = Date(timeIntervalSince1970: 1_787_821_200)
    static let textEdit = AmbientRealm.dynamic("textedit")

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
            world: .applications, application: "textedit", slot: slot,
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
    @Test func aRenderedKeyWithNoFactIsSkipped() {
        let held = Self.fact(content: "still here")
        let vanished = AmbientKey(place: .dynamic("pages"), slot: .file)
        let rendering = AmbientRendering(
            mode: .relevance, blocks: ["x", "y"], keys: [vanished, held.key])

        let capture = AmbientCaptureBuilder.capture(
            facts: [held], surfaces: [], rendering: rendering, at: Self.now)

        #expect(capture.facts.map(\.text) == ["still here"])
    }

    /// AGE IS LOAD-BEARING. A fact renders with its age and loses authority as
    /// it grows, so a future model reading the dataset needs the difference
    /// between "the document says X" and "it said X four minutes ago".
    @Test func factsCarryTheirAgeAndProvenance() {
        let fact = Self.fact(content: "Essay", ageSeconds: 42)
        let rendering = AmbientRendering(mode: .relevance, blocks: ["Essay"], keys: [fact.key])

        let capture = AmbientCaptureBuilder.capture(
            facts: [fact], surfaces: [], rendering: rendering, at: Self.now)

        #expect(capture.facts.first?.ageSeconds == 42)
        #expect(capture.facts.first?.provenance == "cachedBody")
    }

    // MARK: - Tokens

    /// The realm token is the collision-free spelling, shared with the pane
    /// and the trace so a capture and a trace naming one place say one word.
    @Test func realmTokensMatchTheRealmsOwnSpelling() {
        #expect(AmbientCaptureBuilder.token(for: Self.textEdit) == "applications:textedit")
        #expect(AmbientCaptureBuilder.token(for: .native(.typer)) == "typer")
    }

    /// A named read keeps its phrase in the token, so a read of one thing
    /// stays distinguishable from a read of another.
    @Test func slotTokensKeepTheirParameters() {
        #expect(AmbientCaptureBuilder.token(for: .file) == "file")
        let read = AmbientSlot.namedRead(document: "Essay", phrase: "the opening")
        #expect(AmbientCaptureBuilder.token(for: read).contains("the opening"))
    }

    /// EVERY LANE AND EVERY SLOT HAS A TOKEN, and no two collide. A silent
    /// collision merges two populations in the dataset.
    @Test func laneTokensAreDistinct() {
        let tokens = AmbientWorld.allCases.map { AmbientCaptureBuilder.token(for: .native($0)) }
        #expect(Set(tokens).count == tokens.count)
        #expect(tokens.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Surfaces

    @Test func aSurfaceBecomesRecordsCarryingIdentityAndFrame() throws {
        let surface = Self.surface(elements: [
            Self.element("axbutton|share", ordinal: 1, label: "Share", frame: Self.frame(10, 20))
        ])
        let capture = AmbientCaptureBuilder.capture(
            facts: [], surfaces: [surface],
            rendering: AmbientRendering(mode: .relevance), at: Self.now)

        let captured = try #require(capture.surfaces.first)
        #expect(captured.place == "applications:textedit")
        #expect(captured.application.bundleID == "com.apple.TextEdit")
        #expect(captured.windowTitle == "Essay")
        let record = try #require(captured.elements.first)
        #expect(record.identity == "axbutton|share")
        #expect(record.frame.rect.x == 10)
        #expect(record.appName == "TextEdit")
        #expect(record.windowTitle == "Essay", "the record names the window it was in")
    }

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
    @Test func aBusySurfaceIsCappedAndSaysSo() {
        let many = (1...(AmbientCaptureBuilder.elementCap + 5)).map { index in
            Self.element("axbutton|\(index)", ordinal: index,
                         label: "\(index)", frame: Self.frame(Double(index), 0))
        }
        let capture = AmbientCaptureBuilder.capture(
            facts: [], surfaces: [Self.surface(elements: many)],
            rendering: AmbientRendering(mode: .relevance), at: Self.now)

        let captured = capture.surfaces.first
        #expect(captured?.elements.count == AmbientCaptureBuilder.elementCap)
        #expect(captured?.truncated == true)
        #expect(captured?.elements.first?.ordinal == 1, "the cap keeps reading order")
    }

    @Test func anUncappedSurfaceIsNotMarkedTruncated() {
        let capture = AmbientCaptureBuilder.capture(
            facts: [], surfaces: [Self.surface(elements: [
                Self.element("axbutton|one", ordinal: 1, label: "One", frame: Self.frame(0, 0))
            ])],
            rendering: AmbientRendering(mode: .relevance), at: Self.now)
        #expect(capture.surfaces.first?.truncated == false)
    }

    // MARK: - The rendered lines

    /// Both halves travel: the structure a future model should learn from,
    /// and the strings this build's model actually read. A disagreement
    /// between them is then visible in the data rather than invisible.
    @Test func theRenderedLinesTravelBesideTheStructure() {
        let fact = Self.fact(content: "Essay — 1,840 characters.")
        let rendering = AmbientRendering(
            mode: .focusedWorld,
            surfaceLines: ["On screen: TextEdit — Essay"],
            blocks: [fact.content],
            mentions: ["a note I haven't read"],
            keys: [fact.key])

        let capture = AmbientCaptureBuilder.capture(
            facts: [fact], surfaces: [], rendering: rendering,
            lead: Self.textEdit, at: Self.now)

        #expect(capture.mode == "focusedWorld")
        #expect(capture.lead == "applications:textedit")
        #expect(capture.renderedSurfaceLines == ["On screen: TextEdit — Essay"])
        #expect(capture.renderedBlocks == [fact.content])
        #expect(capture.renderedMentions == ["a note I haven't read"])
    }

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

    // MARK: - It survives the codec

    /// The whole point of the tokens: a capture round-trips through the
    /// dataset's encoder unchanged.
    @Test func aCaptureRoundTripsThroughTheCodec() throws {
        let fact = Self.fact(content: "Essay — 1,840 characters.")
        let capture = AmbientCaptureBuilder.capture(
            facts: [fact],
            surfaces: [Self.surface(elements: [
                Self.element("axtextarea|", ordinal: 1, label: "", frame: Self.frame(0, 44))
            ])],
            rendering: AmbientRendering(
                mode: .focusedWorld, blocks: [fact.content], keys: [fact.key]),
            lead: Self.textEdit,
            at: Self.now)

        let data = try BehavioralCodec.encoder().encode(capture)
        let decoded = try BehavioralCodec.decoder().decode(AmbientCapture.self, from: data)
        #expect(decoded == capture)
    }
}
