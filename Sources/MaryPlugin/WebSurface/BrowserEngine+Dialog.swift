//
//  BrowserEngine+Dialog.swift
//  MaryPlugin
//
//  WHAT: The browser's own question — a modal sheet the page cannot be read or
//        pressed through — described, or answered by the words that name a choice.
//  IN:   WebSurfaceAX.Dialog
//  OUT:  asked / answer / choices
//  PIN:  NOTHING ANSWERS IT ON MARY'S OWN ACCOUNT. Every verb refuses with the
//        question unless it is the verb that reads it or the one whose words
//        name one of its choices — see `DialogStance` on `staged`.
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

extension BrowserEngine {
    // MARK: - The browser's own question

    /// The refusal every blocked verb gives: the browser's question, with the
    /// shell attached so a caller can see what stood in the way.
    func asked(_ dialog: WebSurfaceAX.Dialog, shell: WebSurfaceAX.Reading) -> BrowserOutcome {
        let refusal = BrowserRefusal.browserIsAsking(
            question: dialog.question, choices: dialog.choices)
        emit(.refused(refusal))
        return BrowserOutcome(ok: false, spoken: refusal.summary, refusal: refusal, shell: shell)
    }

    /// How long a pressed choice gets to take the dialog away.
    static let dialogAnswerBudget: Double = 3

    /// Answer the browser's question with the person's words — and only when
    /// those words name one of its choices.
    ///
    /// PIN: NEVER A GUESS, NEVER A DEFAULT. "Continue" on a resubmission is a
    /// write the person did once already; pressing it because it is the
    /// rightmost button, or because the person said "yes", would be Mary
    /// deciding what they meant. The words either carry a choice or the
    /// question is put back to them.
    func answer(
        _ dialog: WebSurfaceAX.Dialog, with phrase: String,
        in target: BrowserTarget, shell: WebSurfaceAX.Reading
    ) async -> BrowserOutcome {
        let matching = Self.choices(named: phrase, among: dialog.choices)
        guard matching.count == 1, let choice = matching.first else {
            return asked(dialog, shell: shell)
        }
        if dryRun { return refuse(.dryRun("answered \(choice)")) }
        guard await seams.shell.press(
            label: choice, pid: target.processIdentifier, registration: target.registration,
            within: workingWindow)
        else { return refuse(.elementNotFound(choice)) }
        emit(.acted("answered \(choice)"))

        // GONE IS THE RECEIPT. The dialog was a shell fact; the shell says
        // whether it still stands.
        let waited = await waitForShell(target, budget: Self.dialogAnswerBudget) { $0.dialog == nil }
        if let reading = waited.settled {
            lastChrome = reading
            let receipt = PageCommandReceipt(
                sourceIndex: 0, kind: .click, target: choice,
                delivery: .delivered, effect: .verified(.dialogAnswered(choice)))
            emit(.receipt(receipt))
            return BrowserOutcome(
                ok: true, spoken: "Answered \(choice).", shell: reading,
                receipts: [receipt], landed: true)
        }
        return BrowserOutcome(
            ok: false,
            spoken: BrowserRefusal.stateUnchanged(
                expected: "the question answered", observed: "it is still asking").summary,
            refusal: .stateUnchanged(expected: "the question answered", observed: "it is still asking"),
            shell: waited.latest ?? shell)
    }

    /// The choices the person's words name. A choice is named when its whole
    /// label appears in the words, as words — "press continue" names
    /// "Continue"; "continue the video" does too, and that is the person's to
    /// say while the browser is asking.
    static func choices(named phrase: String, among choices: [String]) -> [String] {
        let said = words(phrase)
        guard !said.isEmpty else { return [] }
        return choices.filter { choice in
            let wanted = words(choice)
            guard !wanted.isEmpty, wanted.count <= said.count else { return false }
            return (0...(said.count - wanted.count)).contains { start in
                Array(said[start..<(start + wanted.count)]) == wanted
            }
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
