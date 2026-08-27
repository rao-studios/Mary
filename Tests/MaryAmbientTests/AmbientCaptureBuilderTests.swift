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
//  THE TOKENS ARE THE SCHEMA. Places and slots cross into the dataset as
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
        let vanished = AmbientKey(place: .application("pages"), slot: .file)
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

    /// The place token is the collision-free spelling, shared with the pane
    /// and the trace so a capture and a trace naming one place say one word.
    @Test func realmTokensMatchTheRealmsOwnSpelling() {
        #expect(AmbientCaptureBuilder.token(for: Self.textEdit) == "applications:textedit")
        #expect(AmbientCaptureBuilder.token(for: .lane(.typer)) == "typer")
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
        let tokens = AmbientWorld.allCases.map { AmbientCaptureBuilder.token(for: .lane($0)) }
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

// MARK: - The realm: what could have served, and where it landed

/// THE JUDGEMENT HALF OF THE INPUT. The surfaces record what Mary could SEE;
/// the realm records what she could USE and which of those won. A dataset row
/// with only the first teaches an association ("she typed into TextEdit"); a
/// row with both teaches the choice ("three conformed; this one led on a
/// four-second-old activation").
@Suite struct RealmCaptureTests {

    static let textEdit = AmbientPlace.application("textedit")
    static let pages = AmbientPlace.application("pages")

    /// AN APPLICATION CONFORMING TO TWO NEEDS APPEARS ONCE, CARRYING BOTH.
    /// Splitting it would let the same place compete with itself, and the
    /// dataset would show two candidates where the user had one choice.
    static var realm: AmbientRealm {
        AmbientRealm(
            need: AmbientNeed(abilities: ["writing", "typing"], discipline: .writing),
            candidates: [
                AmbientCandidate(
                    place: textEdit,
                    conformsByAbilities: ["writing", "typing"],
                    conformsByDiscipline: true,
                    targetClasses: ["editable-prose-surface"],
                    hasEyes: true,
                    evidence: .activation,
                    evidenceAgeSeconds: 4),
                AmbientCandidate(
                    place: pages,
                    conformsByAbilities: ["writing"],
                    conformsByDiscipline: true,
                    hasEyes: true),
            ],
            place: textEdit,
            decidedBy: .ambientSource)
    }

    private func capture(_ realm: AmbientRealm?) -> AmbientCapture {
        AmbientCaptureBuilder.capture(
            facts: [], surfaces: [],
            rendering: AmbientRendering(mode: .focusedWorld),
            lead: realm?.place, realm: realm,
            at: Date(timeIntervalSince1970: 1_787_821_200))
    }

    @Test func aRealmReachesTheDatasetAsTokens() throws {
        let captured = try #require(capture(Self.realm).realm)
        #expect(captured.need.abilities == ["typing", "writing"], "sorted, so rows are stable")
        #expect(captured.need.discipline == "writing")
        #expect(captured.place == "applications:textedit")
        #expect(captured.decidedBy == "ambientSource")
        #expect(captured.candidates.map(\.place)
            == ["applications:textedit", "applications:pages"])
    }

    @Test func aCandidateCarriesBothConformancesAndItsEvidence() throws {
        let captured = try #require(capture(Self.realm).realm)
        let chosen = try #require(captured.candidates.first)
        #expect(chosen.conformsByAbilities == ["typing", "writing"])
        #expect(chosen.conformsByDiscipline)
        #expect(chosen.targetClasses == ["editable-prose-surface"])
        #expect(chosen.evidence == "activation")
        #expect(chosen.evidenceAgeSeconds == 4)

        // The loser conformed too, and the row says so — that is the whole
        // point of keeping the set after the decision.
        let rival = try #require(captured.candidates.last)
        #expect(rival.conformsByAbilities == ["writing"])
        #expect(rival.evidence == nil, "cold: nothing recent happened there")
    }

    /// EVIDENCE IS A NAME, NOT A RANK. `FocusEvidenceKind`'s raw value is an
    /// Int used for comparison; writing `2` into the dataset would record a
    /// comparison rather than a fact.
    @Test(arguments: [
        (FocusEvidenceKind.activity, "activity"),
        (.activation, "activation"),
        (.glance, "glance"),
    ])
    func evidenceTokensAreNames(_ kind: FocusEvidenceKind, _ expected: String) {
        #expect(AmbientCaptureBuilder.token(for: kind) == expected)
    }

    /// ABSENT IS NOT EMPTY, one level deeper than the capture itself. No realm
    /// means nobody worked out the candidates; a realm with none means she
    /// understood the need and knows nowhere that serves it.
    @Test func noRealmAndAnEmptyRealmAreDifferentRows() throws {
        let unresolved = capture(nil)
        let nowhere = capture(AmbientRealm(need: AmbientNeed(discipline: .writing)))
        #expect(unresolved.realm == nil)
        #expect(nowhere.realm?.candidates.isEmpty == true)
        #expect(nowhere.realm?.place == nil, "conformance found nobody, so nothing was chosen")

        let a = try BehavioralCodec.encoder().encode(unresolved)
        let b = try BehavioralCodec.encoder().encode(nowhere)
        #expect(a != b)
    }

    /// THE DATASET AND THE PROMPT MUST AGREE ABOUT THE WHERE. `lead` is what
    /// the prompt used; `realm.place` is what the resolver chose. A row where
    /// they disagreed would teach the wrong lesson confidently.
    @Test func theResolvedPlaceMatchesTheLead() {
        let captured = capture(Self.realm)
        #expect(captured.realm?.place == captured.lead)
    }

    @Test func aRealmBearingCaptureRoundTrips() throws {
        let original = capture(Self.realm)
        let data = try BehavioralCodec.encoder().encode(original)
        let decoded = try BehavioralCodec.decoder().decode(AmbientCapture.self, from: data)
        #expect(decoded == original)
        #expect(try BehavioralCodec.encoder().encode(decoded) == data)
    }

    /// An omitted realm stays omitted in the canonical bytes — the digest
    /// rule the whole codec keeps.
    @Test func anAbsentRealmDoesNotAppearInTheEncoding() throws {
        let data = try BehavioralCodec.encoder().encode(capture(nil))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("realm"))
    }
}
