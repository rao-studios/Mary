//
//  WebCanvasComposition.swift
//  MaryPlugin
//
//  PUTTING A BODY OF TEXT INTO A WEB TOOL AND READING BACK WHAT IT SAID.
//
//  The choreography every web canvas shares — go there, get past the consent
//  banner, find the editor, replace what is in it, press run, read the
//  verdict — with every word that differs between tools arriving from a
//  `WebCanvasSchema`. Nothing here names a site.
//
//  THE VERDICT IS THE PART WORTH READING TWICE, because it is where the
//  obvious implementation is confidently wrong. A page that has just run
//  something says several things at once, and they do not carry equal weight:
//
//    • A DIAGNOSTIC IS DECISIVE. If the page prints one of the phrases the
//      package listed as meaning failure, it failed. Positive evidence.
//    • A STATUS MARKER IS NOT EVIDENCE OF ANYTHING. Shadertoy prints
//      "Compiled in 0.0 secs" whether or not the compile worked, so a reader
//      that treated it as success would report every run as fine — including
//      the ones that printed an error beside it. The package declares it so
//      it can be DISBELIEVED.
//    • THE ABSENCE OF A DIAGNOSTIC PROVES NOTHING. A tool can fail silently,
//      or in words nobody listed. So "no diagnostic" is `.unconfirmed`, not
//      success — and the sentence says so.
//
//  Failure-first ordering, in other words, and a third case for the honest
//  middle. The predecessor's equivalent could not read a page in Chrome at
//  all and returned `.unknown` for every Chrome run; here the page read is
//  engine-neutral, so the middle case means what it says instead of meaning
//  "wrong browser".
//
//  A PASTE, NEVER TYPING, and this is a decision rather than a shortcut. A
//  code editor auto-indents and auto-closes brackets, so feeding source
//  through the typer a chunk at a time grows a phantom `}` per `{` and
//  re-indents what came before. A paste is one atomic insert the editor
//  leaves alone.
//

import AppKit
import ApplicationServices
import Foundation
import MaryFoundation

public enum WebCanvasComposition {

    /// What the page said afterwards.
    public enum Verdict: Equatable, Sendable {
        /// The page printed one of the declared failure phrases. Carries the
        /// line, so the user hears what the tool actually said.
        case failed(String)
        /// The page was read and said nothing that means failure. NOT
        /// success — see the header.
        case unconfirmed
        /// The tool declared a marker it prints whenever it runs, and the
        /// page does not have it. See the header: the marker is worthless as
        /// evidence of SUCCESS and is the only evidence there is that the run
        /// happened at all.
        case didNotRun
        /// The page could not be read at all after the run.
        case unreadable
    }

    public enum Failure: Error, Equatable, Sendable {
        case contentTooLarge(limit: Int)
        case missingRequiredMarker(String)
        case noBrowser
        case surface(WebSurface.Failure)

        public func spoken(browser: String, noun: String) -> String {
            switch self {
            case .contentTooLarge(let limit):
                return "That \(noun) is longer than the \(limit / 1000)k the editor takes."
            case .missingRequiredMarker(let marker):
                return "That \(noun) has no \(marker), so there is nothing for the tool to run."
            case .noBrowser:
                return "No browser I know is running, so I couldn't open the editor."
            case .surface(let failure):
                return failure.spoken(browser: browser)
            }
        }
    }

    public struct Outcome: Sendable {
        public var verdict: Verdict
        /// The page's own words, for a caller that wants to quote them.
        public var pageText: String
    }

    /// Run one composition against a declared canvas.
    ///
    /// The caller has already resolved and staged the browser: this places
    /// text and reads a page, and taking the foreground is not its business.
    public static func compose(
        _ content: String,
        canvas: WebCanvasSchema,
        pid: pid_t,
        bundleID: String? = nil
    ) async -> Result<Outcome, Failure> {
        // ADMITTED BEFORE ANYTHING IS OPENED. Discovering that a shader has
        // no entry point costs a navigation, a wait and a paste if it is
        // checked on the page instead of here.
        guard content.utf8.count <= canvas.contentLimitBytes else {
            return .failure(.contentTooLarge(limit: canvas.contentLimitBytes))
        }
        if let marker = canvas.requiredContentMarker, !marker.isEmpty,
           !content.contains(marker) {
            return .failure(.missingRequiredMarker(marker))
        }

        // A NEW TAB, always. The canvas is a destination, and navigating the
        // tab the user was reading away from what they were reading is a
        // cost they did not ask for.
        if let failure = await WebSurface.openLocation(canvas.address, pid: pid) {
            return .failure(.surface(failure))
        }
        guard !Task.isCancelled else { return .failure(.surface(.cancelled)) }

        // THE WAKE, AND ITS VERDICT. Chromium builds no page tree until an
        // assistive client asks, and a page nobody woke reads as no page at
        // all — which every step below would report as "I couldn't find the
        // editor", blaming the site for the browser.
        //
        // THE VERDICT WAS BEING DISCARDED HERE. `pageTarget` refuses on
        // `.axTreeAbsent` and this lane no longer goes through it (the canvas
        // is a destination, so its tab does not exist until the line above),
        // so the check has to be honoured here or it is not made anywhere.
        if await BrowserAXReadiness.ensureWebContentAX(
            pid: pid, bundleID: bundleID) == .axTreeAbsent {
            return .failure(.surface(.pageNotExposed))
        }
        let application = WebSurface.application(pid: pid)

        // IS THIS THE SITE, OR A BOT CHECK STANDING IN FRONT OF IT? Asked
        // BEFORE the editor hunt, because an interstitial has a web area and
        // text and no editor — so hunting first spends twelve seconds and
        // then blames the site's layout for something the site never did.
        // This port made exactly that mistake on its first live run.
        //
        // ANSWERED, ONCE, rather than refused: a canvas is somewhere the user
        // ASKED Mary to open, they are looking at the tab, and the control is
        // one she can see. If the press does not take, she hands over and
        // waits a moment for the person rather than making them start the
        // whole errand again. See `WebPageChallenge`.
        if let reading = WebPageText.read(inApp: application),
           WebPageChallenge.isChallenge(pageText: reading.text) {
            switch await WebPageChallenge.satisfy(in: application, pid: pid) {
            case .cleared: break
            case .cancelled: return .failure(.surface(.cancelled))
            case .standing: return .failure(.surface(.humanCheck))
            }
        }

        // THE EDITOR, PREFERRING WHAT THE PACKAGE NAMED. `editorHints` is the
        // declaration's answer to a page holding several text areas; without
        // it this takes the first, which on a single-editor tool is right and
        // on anything else is a coin toss between the editor and the site's
        // own search box.
        guard let editor = await WebSurface.awaitEditableSurface(
            in: application,
            consentLabels: Set(canvas.consentLabels),
            hints: canvas.editorHints)
        else { return .failure(.surface(.noEditableSurface)) }

        guard await WebSurface.takeFocus(editor, in: application, pid: pid) else {
            return .failure(.surface(.couldNotFocus))
        }
        guard await WebSurface.replaceAll(with: content) else {
            return .failure(.surface(.placingTextFailed))
        }

        _ = KeyChordPress.press(
            key: canvas.runChord.key, modifiers: canvas.runChord.modifiers)
        // The tool needs a beat to compile and to print whatever it prints.
        // Measured against the predecessor's shader lane; a shorter wait read
        // the page before the diagnostic appeared and called every failure
        // unconfirmed.
        try? await Task.sleep(for: .milliseconds(2500))

        guard let reading = WebPageText.read(inApp: application) else {
            return .success(Outcome(verdict: .unreadable, pageText: ""))
        }
        return .success(Outcome(
            verdict: verdict(pageText: reading.text, canvas: canvas),
            pageText: reading.text))
    }

    /// THE WHOLE DECISION, pure — over the page's text and the declaration.
    ///
    /// Separated from the choreography above because everything that can be
    /// wrong here is a rule about words, and testing it through a live
    /// browser would test the browser.
    static func verdict(pageText: String, canvas: WebCanvasSchema) -> Verdict {
        guard !pageText.isEmpty else { return .unreadable }
        let lowered = pageText.lowercased()

        // FAILURE FIRST. A diagnostic outranks everything else on the page,
        // including a status marker sitting right beside it saying the run
        // took 0.0 seconds.
        for phrase in canvas.diagnosticPhrases {
            let needle = phrase.lowercased()
            guard !needle.isEmpty, lowered.contains(needle) else { continue }
            // The LINE it appeared on, so the user hears the tool's own
            // words rather than "it failed".
            let line = pageText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first { $0.lowercased().contains(needle) }
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            return .failed(line ?? phrase)
        }

        // NO DIAGNOSTIC. Now the status marker earns its keep — in the ONE
        // direction it can be trusted.
        //
        // Its presence still proves nothing and must never be read as success:
        // the marker a shader editor prints reads "Compiled in 0.0 secs"
        // whether or not the compile worked, which is why the package declares
        // it to be DISBELIEVED. But a package that names such a marker is
        // telling us the tool prints it WHENEVER IT RUNS — so its ABSENCE is
        // positive evidence the run never happened: the chord missed, the
        // paste landed somewhere inert, the page was still loading. Reporting
        // that as "it's on screen and nothing complained" is the one lie this
        // lane could still tell after the diagnostic check.
        if let marker = canvas.statusMarker, !marker.isEmpty,
           !lowered.contains(marker.lowercased()) {
            return .didNotRun
        }
        return .unconfirmed
    }

    /// The sentence for a verdict. Kept beside the rule so the two cannot
    /// drift into disagreeing about what `unconfirmed` means.
    public static func spoken(
        _ verdict: Verdict, noun: String, opening: String
    ) -> (summary: String, ok: Bool) {
        switch verdict {
        case .failed(let line):
            return ("\(opening) — but the editor didn't like it: \(line)", false)
        case .unconfirmed:
            // SAID PLAINLY. The run was delivered and the page did not
            // complain, which is not the same as knowing it worked.
            return ("\(opening) It's on screen; the editor didn't report a problem.", true)
        case .didNotRun:
            // NOT ok. Nothing is on screen, and saying otherwise would be the
            // most convincing wrong answer this lane can give.
            return (
                "\(opening) I placed the \(noun), but the editor never reported "
                    + "running it.",
                false)
        case .unreadable:
            return (
                "\(opening) I placed the \(noun) but couldn't read the page back "
                    + "to see what it made of it.",
                true)
        }
    }
}
