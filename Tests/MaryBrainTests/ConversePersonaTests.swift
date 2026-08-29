//
//  ConversePersonaTests.swift
//  MaryBrainTests
//
//  The fourth voice persona and its position in the ladder.
//
//  THE BUG IT PINS: `seerPersonaInTurn` was the catch-all for every turn that
//  was not a read and not a grounded result, which includes every greeting and
//  every joke — so a small conversational turn was handed ~150 words about
//  hands, Skill pipelines and intent acknowledgement, plus the only concrete
//  example reply in the whole voice prompt ("Got it — a new event on the
//  calendar"). Mary answered small talk with "I'm adding that now."
//
//  The ladder is what these tests are really about. `seerPersonaConverse`
//  carries ONE guard (`conversational`); the rest of its condition — no read,
//  no grounded result — is supplied by the two personas ahead of it claiming
//  the exclusive group first. That is only true if the plan order holds, so
//  the order is pinned here rather than trusted.
//

import Foundation
import Testing
@testable import MaryBrain

@Suite struct ConversePersonaTests {

    private let frozen = Date(timeIntervalSince1970: 1_755_000_000)

    private func render(
        conversational: Bool = false,
        readReport: Bool = false,
        readPassages: [String] = [],
        groundedResults: String? = nil
    ) -> PromptRender {
        MaryPrompts.seerRender(
            now: frozen,
            timeZone: TimeZone(identifier: "America/New_York")!,
            groundedResults: groundedResults,
            readPassages: readPassages,
            readReport: readReport,
            conversational: conversational)
    }

    private func outcome(
        _ render: PromptRender, _ id: PromptSectionID
    ) -> PromptSectionOutcome? {
        render.spend.first { $0.id == id }?.outcome
    }

    // MARK: - The persona renders, and displaces the action persona

    @Test("A conversational turn gets the converse persona, not the action one")
    func conversationalTurnSwapsPersona() {
        let render = render(conversational: true)
        #expect(outcome(render, .seerPersonaConverse) == .rendered)
        #expect(outcome(render, .seerPersonaInTurn) == .excluded)
        #expect(render.text.contains("This turn is CONVERSATION, not a request"))
        // The exemplar that was being copied must not be in this prompt at all.
        #expect(!render.text.contains("a new event on the calendar"))
    }

    @Test("The turn it is named for — the ack it must not produce")
    func namesTheAckItForbids() {
        let text = render(conversational: true).text
        #expect(text.contains("adding that now"))
        #expect(text.contains("Do not announce work"))
        // It must not buy the quiet by denying her hands — that is the
        // failure `seerPersonaInTurn` closes ("Never disclaim Mary's general
        // ability to act"), and the fix must not reopen it one persona over.
        #expect(text.contains("never disclaim what you can do"))
    }

    @Test("Without the flag nothing moves — the action persona still leads")
    func defaultTurnIsUnchanged() {
        let render = render()
        #expect(outcome(render, .seerPersonaConverse) == .gatedOut)
        #expect(outcome(render, .seerPersonaInTurn) == .rendered)
    }

    @Test("Byte-identical to the pre-change prompt on a non-conversational turn")
    func nonConversationalRenderIsUnchanged() {
        // The flag defaults false everywhere, so every existing caller — and
        // every pass with no route — must render exactly what it rendered
        // before this section existed.
        #expect(render(conversational: false).text == render().text)
    }

    // MARK: - Ladder precedence

    @Test("A read outranks conversation — the passage still gets recited")
    func readWinsOverConverse() {
        let render = render(
            conversational: true, readReport: true, readPassages: ["the passage"])
        #expect(outcome(render, .seerPersonaRead) == .rendered)
        #expect(outcome(render, .seerPersonaConverse) == .excluded)
        #expect(outcome(render, .seerPersonaInTurn) == .excluded)
    }

    @Test("A finished action outranks conversation — the outcome still gets reported")
    func groundedWinsOverConverse() {
        let render = render(conversational: true, groundedResults: "opened the file")
        #expect(outcome(render, .seerPersonaGrounded) == .rendered)
        #expect(outcome(render, .seerPersonaConverse) == .excluded)
        #expect(outcome(render, .seerPersonaInTurn) == .excluded)
    }

    @Test("Exactly one persona ever renders")
    func personasAreMutuallyExclusive() {
        let personas: [PromptSectionID] = [
            .seerPersonaRead, .seerPersonaGrounded,
            .seerPersonaConverse, .seerPersonaInTurn,
        ]
        for render in [
            render(),
            render(conversational: true),
            render(conversational: true, readReport: true, readPassages: ["p"]),
            render(conversational: true, groundedResults: "g"),
            render(readReport: true, readPassages: ["p"]),
            render(groundedResults: "g"),
        ] {
            let rendered = personas.filter { outcome(render, $0) == .rendered }
            #expect(rendered.count == 1)
        }
    }

    // MARK: - The plan

    @Test("Converse sits third, which is half its gate")
    func planOrderPutsConverseThird() {
        let order = PromptPlan.voice.order
        let read = order.firstIndex(of: .seerPersonaRead)
        let grounded = order.firstIndex(of: .seerPersonaGrounded)
        let converse = order.firstIndex(of: .seerPersonaConverse)
        let inTurn = order.firstIndex(of: .seerPersonaInTurn)
        #expect(read != nil && grounded != nil && converse != nil && inTurn != nil)
        #expect(read! < grounded!)
        #expect(grounded! < converse!)
        #expect(converse! < inTurn!)
    }

    @Test("The voice plan is still structurally sound")
    func voicePlanValidates() {
        #expect(PromptPlan.voice.validate().isEmpty)
    }

    @Test("The spend waterfall still accounts for every character")
    func spendStaysAccounted() {
        #expect(render(conversational: true).isAccounted)
    }
}
