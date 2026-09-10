//
//  LaneACompanyHeadingTests.swift
//  MaryBrainTests
//
//  WHAT: Lane A is company + heading, not present-tense work from ambient facts.
//  OUT:  MaryPrompts.sewnInstructions, SewnWire.Persona.mary, capabilityLine
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain

@Suite struct LaneACompanyHeadingTests {

    @Test func personaVoiceIsCompanyAndHeadingNotPresentProgress() {
        let voice = SewnWire.Persona.mary.voice
        #expect(voice.contains("You are Mary"))
        #expect(voice.contains("good company first"))
        #expect(voice.contains("name the heading"))
        #expect(voice.contains("talk back"))
        #expect(voice.contains("never \"opening that\", \"adding that now\""))
        #expect(!voice.contains("who ACTS — not a"))
    }

    @Test func defaultInstructionsPrefillCompanyAndHeadingBeforeFacts() {
        let live = "THE_LIVE_WORK_BLOCK"
        let text = MaryPrompts.sewnInstructions(liveWork: [live])
        let company = "a question back is company"
        let heading = "Your hands are running in parallel this turn"
        let scenery = "never evidence a Skill ran"
        #expect(text.contains(company))
        #expect(text.contains(heading))
        #expect(text.contains(scenery))
        #expect(text.contains("I'll get that on the calendar"))
        #expect(!text.contains("Got it — a new event on the calendar"))
        #expect(!text.contains("as you speak"))
        let companyAt = text.range(of: company)!.lowerBound
        let liveAt = text.range(of: live)!.lowerBound
        #expect(companyAt < liveAt)
        let headingAt = text.range(of: heading)!.lowerBound
        #expect(headingAt < liveAt)
    }

    @Test func conversationalPassDropsThisTurnHeading() {
        let text = MaryPrompts.sewnInstructions(conversational: true)
        #expect(text.contains("a question back is company"))
        #expect(!text.contains("Your hands are running in parallel this turn"))
        #expect(text.contains("This turn is CONVERSATION"))
    }

    @Test func groundedCloserDropsThisTurnHeadingAndKeepsCompany() {
        let text = MaryPrompts.sewnInstructions(groundedResults: "the event is on Tuesday")
        #expect(text.contains("a question back is company"))
        #expect(!text.contains("Your hands are running in parallel this turn"))
        #expect(text.contains("You just FINISHED actions"))
        #expect(text.contains("the event is on Tuesday"))
        #expect(!text.contains("I'll get that on the calendar"))
    }

    @Test func readReportDropsThisTurnHeading() {
        let text = MaryPrompts.sewnInstructions(readReport: true)
        #expect(!text.contains("Your hands are running in parallel this turn"))
        #expect(text.contains("You just READ exactly what the user asked about"))
    }

    @Test func capabilityLineDoesNotWriteAsYouSpeak() {
        let world = PinnedWorld(applicationID: "pages", focus: .writing)
        let line = MaryPrompts.capabilityLine(for: world)
        #expect(line.contains("this voice pass is not writing as it speaks"))
        #expect(!line.contains("directly, as you speak"))
    }
}
