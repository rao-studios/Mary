//
//  PageInteractionPlanTests.swift
//  MaryFoundationTests
//
//  WHAT: What a model may write, and everything it may not.
//  PIN:  ADMISSION IS THE WHOLE VALUE OF THIS TYPE. A plan that fails halfway leaves a
//        page in a state nobody asked for and nobody named, so every bound here is
//        checked BEFORE a window comes forward — and each of these cases is one way a
//        plan could otherwise have got that far.
//

import Foundation
import Testing
@testable import MaryFoundation

@Suite struct PageInteractionPlanTests {

    private func valid(_ json: String) throws -> PageInteractionPlan {
        switch PageInteractionPlanValidator.validate(planJSON: json) {
        case .valid(let plan): return plan
        case .invalid(let issues):
            Issue.record("expected valid, got \(issues.map(\.message))")
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func issues(_ json: String) -> [PageInteractionPlanIssue] {
        switch PageInteractionPlanValidator.validate(planJSON: json) {
        case .valid: return []
        case .invalid(let issues): return issues
        }
    }

    /// EVERY KIND DECODES, and each keeps the position the author gave it.
    @Test func everyCommandDecodesInAuthoredOrder() throws {
        let plan = try valid("""
        [{"kind":"click","target":"the first result"},
         {"kind":"hover","target":"Menu"},
         {"kind":"typeText","target":"Search","text":"boots","submit":true},
         {"kind":"scroll","deltaY":-400},
         {"kind":"wait","seconds":0.4},
         {"kind":"adjust","target":"Volume","mode":"fraction","fraction":0.3},
         {"kind":"keyChord","key":"escape"},
         {"kind":"drag","target":"Volume","targetFraction":0.8}]
        """)
        #expect(plan.commands.map(\.kind) == [
            .click, .hover, .typeText, .scroll, .wait, .adjust, .keyChord, .drag])
        #expect(plan.commands.map(\.sourceIndex) == Array(0 ..< 8))
        #expect(plan.commands[0].action.target == "the first result")
    }

    /// THE THREE KEYS AND NOTHING ELSE. A modified chord inside a page is a browser
    /// command; an unmodified letter is a site shortcut. Both are what this lane exists
    /// not to use, and a model writing one gets told which keys exist.
    @Test func keyChordIsReturnEscapeTabOnly() {
        #expect(issues(#"[{"kind":"keyChord","key":"k"}]"#).contains { $0.code == .invalidValue })
        #expect(issues(#"[{"kind":"keyChord","key":"f"}]"#).contains { $0.code == .invalidValue })
        let modifiers = issues(#"[{"kind":"keyChord","key":"return","modifiers":["command"]}]"#)
        #expect(modifiers.contains { $0.code == .unknownField && $0.field == "modifiers" })
        let named = issues(#"[{"kind":"keyChord","key":"k"}]"#).first?.message ?? ""
        #expect(named.contains("escape") && named.contains("return") && named.contains("tab"))
    }

    /// A POINTER COMMAND NAMES ONE PLACE. Both is a contradiction; neither is a click
    /// somewhere nobody chose.
    @Test func pointerCommandsTakeExactlyOneLocation() {
        #expect(issues(#"[{"kind":"click","target":"A","point":{"x":0.5,"y":0.5}}]"#)
            .contains { $0.code == .mutuallyExclusiveFields })
        #expect(issues(#"[{"kind":"click"}]"#).contains { $0.code == .mutuallyExclusiveFields })
    }

    /// A MISSPELLED FIELD IS AN ERROR. Ignored, `targt` becomes a click with no target.
    @Test func unknownFieldsAreRefusedByName() {
        let found = issues(#"[{"kind":"click","targt":"A","target":"A"}]"#)
        #expect(found.contains { $0.code == .unknownField && $0.field == "targt" })
        #expect(issues(#"[{"kind":"click","point":{"x":0.1,"y":0.1,"z":1}}]"#)
            .contains { $0.field == "point.z" })
    }

    /// BOUNDS ON EVERY NUMBER, AND A BOOL IS NOT A NUMBER — `true` bridges to 1 and
    /// would otherwise be admitted as one click.
    @Test func scalarsAreBoundedAndTyped() {
        #expect(issues(#"[{"kind":"click","target":"A","count":9}]"#)
            .contains { $0.code == .invalidValue && $0.field == "count" })
        #expect(issues(#"[{"kind":"click","target":"A","count":true}]"#)
            .contains { $0.code == .invalidType })
        #expect(issues(#"[{"kind":"scroll","deltaY":9000}]"#)
            .contains { $0.code == .invalidValue })
        #expect(issues(#"[{"kind":"scroll","deltaY":0}]"#)
            .contains { $0.code == .invalidValue })
        #expect(issues(#"[{"kind":"wait","seconds":30}]"#)
            .contains { $0.code == .invalidValue })
        #expect(issues(#"[{"kind":"click","point":{"x":1.5,"y":0.2}}]"#)
            .contains { $0.field == "point.x" })
    }

    /// A HOVER MUST LEAD SOMEWHERE. The pointer is put back when the plan ends, so a
    /// plan whose last real act is a hover asks for something that cannot survive it.
    @Test func hoverMustPrecedeAnotherAction() {
        #expect(issues(#"[{"kind":"click","target":"A"},{"kind":"hover","target":"B"}]"#)
            .contains { $0.code == .terminalHover })
        #expect(issues("""
        [{"kind":"hover","target":"B"},{"kind":"wait","seconds":0.2}]
        """).contains { $0.code == .terminalHover })
        #expect(issues("""
        [{"kind":"hover","target":"B"},{"kind":"wait","seconds":0.2},{"kind":"click","target":"C"}]
        """).isEmpty)
    }

    /// A FRACTION BELONGS TO ONE MODE, and a mode that needs one must have it.
    @Test func adjustFractionIsRequiredExactlyWhenItApplies() {
        #expect(issues(#"[{"kind":"adjust","target":"V","mode":"fraction"}]"#)
            .contains { $0.code == .missingField })
        #expect(issues(#"[{"kind":"adjust","target":"V","mode":"maximum","fraction":0.5}]"#)
            .contains { $0.code == .invalidValue })
        #expect(issues(#"[{"kind":"adjust","target":"V","mode":"minimum"}]"#).isEmpty)
        // The modes an AX slider has and a drawn one does not.
        #expect(issues(#"[{"kind":"adjust","target":"V","mode":"increment"}]"#)
            .contains { $0.code == .invalidValue })
    }

    /// THE SHAPE IS CHECKED BEFORE ANY COMMAND IS PARSED.
    @Test func planShapeIsRefusedFirst() {
        #expect(issues("{}").first?.code == .planMustBeArray)
        #expect(issues("[]").first?.code == .emptyPlan)
        #expect(issues("not json").first?.code == .invalidJSON)
        let many = (0 ..< 20).map { _ in #"{"kind":"wait","seconds":0.1}"# }.joined(separator: ",")
        #expect(issues("[\(many)]").first?.code == .tooManyCommands)
        let huge = String(repeating: "x", count: 40_000)
        #expect(issues(#"[{"kind":"typeText","text":"\#(huge)"}]"#).first?.code == .planTooLarge)
    }

    /// A PLAN THAT WOULD FLOOD THE MACHINE REFUSES WHILE NOTHING HAS HAPPENED.
    @Test func theEventBudgetRefusesBeforeAnythingMoves() {
        let text = String(repeating: "a", count: 4_000)
        let commands = (0 ..< 3).map { _ in #"{"kind":"typeText","text":"\#(text)"}"# }
        #expect(issues("[\(commands.joined(separator: ","))]").first?.code == .eventBudgetExceeded)
    }

    /// TARGETS ARE PRINTABLE AND BOUNDED.
    @Test func targetsArePrintableText() {
        #expect(issues(#"[{"kind":"click","target":""}]"#)
            .contains { $0.code == .invalidValue })
        #expect(issues("[{\"kind\":\"click\",\"target\":\"a\\u0007b\"}]")
            .contains { $0.code == .invalidValue })
        let long = String(repeating: "n", count: 600)
        #expect(issues(#"[{"kind":"click","target":"\#(long)"}]"#)
            .contains { $0.code == .invalidValue })
    }

    /// ISSUES COME BACK IN A STABLE ORDER, so a refusal reads the same twice.
    @Test func issuesAreSortedByPosition() {
        let found = issues("""
        [{"kind":"click"},{"kind":"nope"},{"kind":"wait","seconds":99}]
        """)
        #expect(found.map(\.sourceIndex) == [0, 1, 2])
        #expect(found == PageInteractionPlanValidator.sorted(found))
    }

    /// A SINGLE VERB IS A ONE-COMMAND PLAN — the same executor, the same rules.
    @Test func aSingleActionIsAPlan() {
        let plan = PageInteractionPlan.single(.click(.init(location: .target("Accept"))))
        #expect(plan.commands.count == 1)
        #expect(plan.commands[0].sourceIndex == 0)
        #expect(plan.commands[0].action.target == "Accept")
    }
}

@Suite struct SpokenAddressTests {

    /// A HOST IS KNOWLEDGE. A model may hold a front door.
    @Test func frontDoorsAreAdmittedWithoutBeingSpoken() {
        #expect(SpokenAddress.admit("https://example.com") == "https://example.com")
        #expect(SpokenAddress.admit("https://example.com/") == "https://example.com/")
        #expect(SpokenAddress.admit("http://example.com") != nil)
    }

    /// A PATH IS A CLAIM ABOUT SOMEBODY ELSE'S DATABASE. Nothing the model can read
    /// tells it which record that identifier names.
    @Test func aDeepLinkNobodySaidIsRefused() {
        #expect(SpokenAddress.admit("https://example.com/watch?v=YrXZ5J5-f3k") == nil)
        #expect(SpokenAddress.admit("https://example.com/issues/4821") == nil)
        #expect(SpokenAddress.admit("https://example.com/#section") == nil)
        #expect(SpokenAddress.admit("https://example.com/a", spokenIn: "open example dot com") == nil)
    }

    /// AND THE SAME LINK IS FINE WHEN THEY SAID IT — including through dictation, which
    /// writes the separators as words.
    @Test func aSpokenDeepLinkIsAdmitted() {
        let address = "https://example.com/watch?v=YrXZ5J5-f3k"
        #expect(SpokenAddress.admit(address, spokenIn: "open \(address)") == address)
        #expect(SpokenAddress.admit(
            address,
            spokenIn: "open example dot com slash watch v YrXZ5J5 f3k") == address)
        // A common path word is vocabulary, not provenance.
        #expect(SpokenAddress.admit(address, spokenIn: "watch that for me") == nil)
    }

    @Test func onlyWebSchemesAreAdmitted() {
        #expect(SpokenAddress.admit("file:///etc/passwd", spokenIn: "file etc passwd") == nil)
        #expect(SpokenAddress.admit("javascript:alert(1)") == nil)
        #expect(SpokenAddress.admit("nonsense") == nil)
    }

    /// THE REFUSAL STATES THE CONDITION AND STOPS. No "shall I search instead" tail —
    /// read as an instruction it drives the loop straight into a search that navigates.
    @Test func theRefusalNamesTheSiteAndOffersNothing() {
        let refusal = SpokenAddress.refusal(for: "https://example.com/watch?v=abc123def")
        #expect(refusal.contains("example.com"))
        #expect(!refusal.lowercased().contains("search"))
        #expect(!refusal.contains("watch?v="))
    }

    /// AN ADDRESS BAR TAKES BOTH, and the difference matters: a dotted word navigates
    /// while a phrase searches.
    @Test func aDottedWordLooksLikeAnAddressAndAPhraseDoesNot() {
        #expect(SpokenAddress.looksLikeAnAddress("example.com"))
        #expect(SpokenAddress.looksLikeAnAddress("https://example.com/x"))
        #expect(!SpokenAddress.looksLikeAnAddress("alpine touring boots"))
        #expect(!SpokenAddress.looksLikeAnAddress("swift 6.2"))
        #expect(!SpokenAddress.looksLikeAnAddress("what is a mortgage"))
    }
}
