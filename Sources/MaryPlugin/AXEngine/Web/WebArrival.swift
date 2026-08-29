//
//  WebArrival.swift
//  MaryPlugin
//
//  WHAT IS ACTUALLY IN FRONT OF MARY, having arrived somewhere on the web.
//
//  A page load that settles is not the same as the page you asked for. Two
//  things routinely stand in the way, both of them shaped exactly like an
//  ordinary page to every mechanism this lane has — a title, a web area,
//  text, controls — and both of them produce the SAME wrong sentence when
//  nobody looks: "there's nothing on that page I can press".
//
//  WHY THIS IS ONE READING AND NOT TWO CHECKS AT TWO CALL SITES. The bot
//  check already existed and was wired into the web-canvas lane alone, so
//  `open_location` reported an interstitial as a successful load and
//  `list_page_elements` then blamed the site's layout for it. The consent
//  wall was not detected anywhere outside a canvas's declared labels. Both
//  are facts about ARRIVING, not about composing, so they belong to arrival —
//  and arrival happens in exactly two places:
//
//    1. after a navigation Mary performed  (`WebSurface.openLocation`)
//    2. before acting on a page she did not navigate to  (`pageTarget`)
//
//  THE WORDS ARE COMPILED, NOT DECLARED, for both families, and it is the
//  same argument `WebPageChallenge` already makes for its phrases: neither an
//  interstitial nor a cookie banner is a fact about the SITE. A handful of
//  services put both in front of millions of sites that have never heard of
//  each other, and the words belong to those services. A per-package list
//  would have every declaration restating the same six strings and going
//  stale independently.
//
//  ⚠️ THE ASYMMETRY IN HOW THE TWO ARE ANSWERED IS DELIBERATE, and will read
//  as an inconsistency to anyone who does not find this paragraph:
//
//    • A BOT CHECK IS ANSWERED (once) by the caller that navigated. It asks
//      whether a person is present, the person IS present, and the control is
//      one Mary can see and press like any other. See `WebPageChallenge`.
//
//    • A CONSENT WALL IS NAMED AND NEVER PRESSED, here in the general lane.
//      It is not asking whether someone is there; it is asking them to AGREE
//      to something, and agreeing on someone's behalf is not a thing Mary
//      does because it would be convenient. So the wall becomes a sentence
//      that names the choice, and the user settles it in one word through the
//      ordinary `click_on_page` path.
//
//    • THE ONE EXCEPTION is a declared web canvas, which auto-dismisses its
//      own `consentLabels`. A canvas is a destination the user asked Mary to
//      open, and its labels are a package author's considered declaration
//      rather than this file's guess about a page nobody chose.
//

import ApplicationServices
import Foundation

public enum WebArrival: Sendable, Equatable {

    /// The page. Whatever it is, nothing is standing in front of it.
    case page

    /// An anti-bot interstitial. Answerable — see `WebPageChallenge.satisfy`.
    case challenge

    /// A consent dialog, carrying the labels it offered so a caller can name
    /// them back to the user rather than saying "a cookie notice" and leaving
    /// them to go and look.
    case consentWall(labels: [String])

    /// Read one settled page and say what it is.
    ///
    /// CHALLENGE FIRST. An interstitial can carry a consent banner of its own,
    /// and reporting the cookie notice on a page the user cannot reach yet
    /// sends them to answer the wrong question.
    ///
    /// Assumes the caller has already run `BrowserAXReadiness` — a Chromium
    /// page nobody woke reads as no page at all, and calling that "an ordinary
    /// page" is the one mistake this whole lane exists to avoid.
    public static func read(inApp application: AXUIElement) -> WebArrival {
        guard let reading = WebPageText.read(inApp: application) else { return .page }
        if WebPageChallenge.isChallenge(pageText: reading.text) { return .challenge }
        let controls = PageControlsReader.read(inApp: application)
        if let labels = consentWallLabels(among: controls) {
            return .consentWall(labels: labels)
        }
        return .page
    }

    // MARK: - Consent

    /// What a consent platform puts on the button that agrees.
    /// MATCHED BY EQUALITY OR PREFIX, so a label needs its own entry whenever
    /// the platform puts a word IN FRONT of the verb. "I Accept" is not
    /// prefixed by "accept" and was missed until a test asked for it — which
    /// is the whole failure mode of a list like this: every gap looks like an
    /// ordinary page rather than like a bug.
    static let acceptLabels = [
        "accept all", "accept cookies", "accept and continue", "accept & continue",
        "accept", "i accept", "agree", "i agree", "yes, i agree",
        "allow all", "allow cookies", "got it", "ok, got it", "consent",
    ]

    /// What it puts on the button that does not — or that opens the settings
    /// instead. A dialog offering only the first family is a notice; one
    /// offering both is a CHOICE, and a choice is what a person has to make.
    static let declineLabels = [
        "reject all", "reject", "decline", "disagree", "no thanks",
        "manage options", "manage preferences", "manage settings",
        "cookie settings", "privacy settings", "customise", "customize",
        "more options", "only necessary", "necessary only", "essential only",
    ]

    /// THE GATE IS STRUCTURAL, NOT A THRESHOLD, and that is the point.
    ///
    /// The obvious implementation counts controls and calls a small page a
    /// banner, which needs a magic number nobody can defend and gets a sparse
    /// landing page wrong. The signature that actually holds is GRAMMATICAL:
    /// a consent platform must offer a way to refuse, so an accept-shaped
    /// control and a refuse-or-manage-shaped control appear TOGETHER. That
    /// pair is close to nonexistent on an ordinary page — a checkout has
    /// "Accept" and no "Reject all"; an article about privacy has neither as a
    /// control, only as prose, and this reads controls rather than text.
    ///
    /// Returns the labels as the page actually spelled them, so the sentence
    /// the user hears quotes the buttons they are about to be shown rather
    /// than this file's lowercased approximation of them.
    static func consentWallLabels(among controls: [PageElement]) -> [String]? {
        let pressable = controls.filter { $0.kind == .button || $0.kind == .link }
        guard !pressable.isEmpty else { return nil }

        func matches(_ family: [String]) -> [String] {
            pressable.compactMap { element in
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, label.count <= maximumConsentLabelLength else { return nil }
                let lowered = label.lowercased()
                return family.contains(where: { lowered == $0 || lowered.hasPrefix($0) })
                    ? label : nil
            }
        }

        let accepts = matches(acceptLabels)
        let declines = matches(declineLabels)
        guard !accepts.isEmpty, !declines.isEmpty else { return nil }

        // In page order, deduplicated: a banner commonly renders its buttons
        // twice (once in the dialog, once in a sticky footer), and naming the
        // same choice twice reads as four options.
        var seen: Set<String> = []
        return (accepts + declines).filter { seen.insert($0.lowercased()).inserted }
    }

    /// A consent button is a phrase, not a paragraph. Anything longer is body
    /// copy that happens to begin "accept" — a link into the cookie policy,
    /// which is not the control.
    static let maximumConsentLabelLength = 40

    /// The sentence for a wall the general lane will not press.
    ///
    /// It NAMES THE CHOICE rather than reporting an obstacle, because the
    /// useful next thing the user says is one of these words, and
    /// `click_on_page` presses whichever they pick.
    public static func consentSentence(labels: [String]) -> String {
        let named = labels.prefix(4)
        let list: String
        switch named.count {
        case 0: return "That page is behind a cookie notice I shouldn't answer for you."
        case 1: list = named[0]
        default:
            list = named.dropLast().joined(separator: ", ") + " or " + named[named.count - 1]
        }
        return """
        That page is behind a cookie notice — it's offering \(list). \
        That's your call, so say which and I'll press it.
        """
    }
}
