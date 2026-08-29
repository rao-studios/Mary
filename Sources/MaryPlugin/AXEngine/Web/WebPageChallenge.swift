//
//  WebPageChallenge.swift
//  MaryPlugin
//
//  IS THIS PAGE A BOT CHECK RATHER THAN THE PAGE — and answering it.
//
//  A site behind an anti-bot service serves an interstitial that looks, to
//  every mechanism this lane has, like a page that simply does not contain
//  what was asked for. It has a title, a web area, and text; it just is not
//  the site. Without this check the failure that reaches the user is "I
//  couldn't find the editor on the page" — which blames the site's layout for
//  something the site never did, and sends them to debug the wrong thing.
//
//  MEASURED, TWICE. The predecessor recorded exactly this: a run went looking
//  for an editor that was never going to appear and reported no editor. This
//  port reproduced it on its first live attempt against a shader editor that
//  now sits behind such a service — "Performing security verification… Verify
//  you are human".
//
//  IT DOES NOT CLEAR ITSELF. Waiting produces a timeout, not a page, so this
//  is a distinct outcome rather than a slow load.
//
//  ── WHAT MARY DOES ABOUT IT, and the boundary that holds ──
//
//  An earlier revision of this file DECLINED to touch the control, on the
//  argument that the check asks "is a person here" and Mary answering it
//  asserts something untrue. That argument was wrong in its premise, and the
//  decision is reversed here rather than quietly edited around.
//
//  A PERSON IS HERE. They asked for this, on their own machine, in their own
//  browser session, one keystroke ago; they are looking at the tab. The check
//  is not asking Mary to claim to be a human — it is a control on a page,
//  guarding a door the user is entitled to walk through, and Mary presses
//  controls on pages. That is the whole of what `satisfy` does:
//
//    ONE PRESS of the control that is on screen, through the same
//    `PageElementActions.press` ladder every other control gets — AXPress
//    first, a real click at the measured frame second.
//
//  WHAT IT IS NOT, and what it must never become. No clearance token is
//  forged. No user agent, fingerprint or header is spoofed. Nothing is routed
//  through a solving service. There is NO RETRY LOOP: exactly one attempt,
//  because a site that declines a synthetic press has decided it wants a
//  person, and asking it again in a louder voice is precisely the behaviour
//  the check exists to stop. If the press does not clear it, Mary stops
//  pressing and HANDS OVER — the browser is already in front, clearing it is
//  one click, and she waits a bounded moment for the person who was there all
//  along. Then she carries on, or says so and stops.
//
//  Everything above is a decision about honesty rather than capability, and
//  it is written here at length because the next reader will otherwise
//  rediscover the argument from scratch and land wherever their week put them.
//
//  THE WORDS ARE COMPILED, NOT DECLARED, unlike almost everything else in
//  this lane. A challenge is not a fact about the site — the site did not
//  choose it, a service in front of it did, and the same handful of services
//  guard millions of unrelated sites. A per-canvas list would have every
//  package restating the same six phrases and going stale independently.
//

import ApplicationServices
import Foundation

public enum WebPageChallenge {

    /// Phrases an interstitial shows while it decides whether a person is
    /// present. Matched against the page's own text, lowercased.
    ///
    /// Deliberately the SERVICE's words rather than any site's: these are
    /// what the major providers put on the page, and a site's own content
    /// does not read like this.
    static let phrases = [
        "verify you are human",
        "performing security verification",
        "checking your browser",
        "just a moment",
        "attention required",
        "please wait while we verify",
        "i'm not a robot",
        "confirm you are human",
    ]

    /// Whether this page text is a challenge rather than the page.
    ///
    /// SHORT PAGES ONLY. The phrases are distinctive but not unique — an
    /// article ABOUT bot detection could contain any of them — and an
    /// interstitial is always a nearly empty page. Requiring both makes a
    /// false positive need a page that is both tiny and about CAPTCHAs.
    public static func isChallenge(pageText: String) -> Bool {
        guard !pageText.isEmpty, pageText.utf8.count <= maximumChallengePageBytes
        else { return false }
        let lowered = pageText.lowercased()
        return phrases.contains { lowered.contains($0) }
    }

    /// An interstitial is a handful of lines. A real page that merely
    /// mentions these phrases is far bigger.
    static let maximumChallengePageBytes = 1500

    // MARK: - Answering it

    /// How it went, so a caller can tell "carry on" from "say so and stop"
    /// without re-reading the page a third time.
    public enum Resolution: Sendable, Equatable {
        /// The page is through — by the press, or by the person.
        case cleared
        /// It is still standing after the press and the wait.
        case standing
        /// The turn was cancelled while waiting.
        case cancelled
    }

    /// Press the check once, then wait for the person.
    ///
    /// THE CONTROL IS FOUND THE WAY EVERY CONTROL IS FOUND — through
    /// `PageControlsReader`, rooted at the web area rather than the window.
    /// There is no bespoke tree walk here and there must not be one: a second
    /// definition of "the pressable things on this page" is how two call sites
    /// start disagreeing about what is on screen.
    ///
    /// - Parameters:
    ///   - application: the browser's AX handle.
    ///   - pid: the browser process, for the click that backs up `AXPress`.
    ///   - handoff: how long to wait for the person after the press did not
    ///     take. Zero skips the wait entirely, for a caller acting on a page
    ///     the user did not ask it to open.
    public static func satisfy(
        in application: AXUIElement,
        pid: pid_t,
        handoff: TimeInterval = defaultHandoff
    ) async -> Resolution {
        // ONE PRESS. Not a loop, not a ladder of candidates — the first
        // control whose own label says what it is.
        if let control = self.control(in: application) {
            _ = await PageElementActions.press(control, pid: pid)
            switch await waitForClearance(in: application, timeout: pressSettle) {
            case .cleared: return .cleared
            case .cancelled: return .cancelled
            case .standing: break
            }
        }

        // IT DECLINED, OR THERE WAS NOTHING TO PRESS. Either way Mary is done
        // pressing. The browser is in front and the person is looking at it.
        guard handoff > 0 else { return .standing }
        return await waitForClearance(in: application, timeout: handoff)
    }

    /// The control the interstitial is asking about.
    ///
    /// An anti-bot widget renders as a checkbox or a button whose label is the
    /// question itself — which is why the compiled phrases above serve for
    /// both the page text and the control, and why no separate list of
    /// control labels exists to drift out of step with them.
    ///
    /// `AXCheckBox` arrives here as `.button`; see `PageElementKindDerivation`.
    static func control(in application: AXUIElement) -> PageElement? {
        PageControlsReader.read(inApp: application).first { element in
            guard element.kind == .button, element.isEnabled else { return false }
            let label = element.label.lowercased()
            guard !label.isEmpty else { return false }
            return phrases.contains { label.contains($0) }
        }
    }

    /// Poll until the page stops being a challenge.
    ///
    /// A READ, NOT A SLEEP: the person may clear it in the first second, and
    /// making them wait out a fixed interval after they already did the thing
    /// is the difference between a hand-off and a hang.
    static func waitForClearance(
        in application: AXUIElement, timeout: TimeInterval
    ) async -> Resolution {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard !Task.isCancelled else { return .cancelled }
            if let reading = WebPageText.read(inApp: application),
               !isChallenge(pageText: reading.text) {
                return .cleared
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return .cancelled }
        } while Date() < deadline
        return .standing
    }

    /// How long to watch after the press before concluding it did not take.
    /// The services that use these widgets resolve in about a second when
    /// they resolve at all.
    static let pressSettle: TimeInterval = 6

    /// How long to leave the door open for the person. Long enough for
    /// someone who looked away to look back; short enough that a turn nobody
    /// is watching ends rather than parks.
    public static let defaultHandoff: TimeInterval = 45
}
