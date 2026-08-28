//
//  WebPageChallenge.swift
//  MaryPlugin
//
//  IS THIS PAGE A BOT CHECK RATHER THAN THE PAGE?
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
//  port reproduced it on its first live attempt against Shadertoy, which now
//  sits behind Cloudflare — "Performing security verification… Verify you are
//  human".
//
//  IT DOES NOT CLEAR ITSELF. Waiting produces a timeout, not a page, so this
//  is a distinct outcome rather than a slow load.
//
//  ⚠️ MARY DOES NOT ANSWER IT, and that is a decision rather than a gap. The
//  predecessor pressed the checkbox, with a careful argument: the user's own
//  machine, their own session, a control they can see. The argument holds,
//  and this build still declines — because the question the control asks is
//  literally "is a person here", and at that moment the honest answer is no.
//  Nothing is forged, spoofed, or routed around either way; the difference is
//  only whether Mary asserts something about herself that isn't true. The
//  refusal is also genuinely useful: clearing it once by hand fixes it for
//  the session, and the sentence says so.
//
//  THE WORDS ARE COMPILED, NOT DECLARED, unlike almost everything else in
//  this lane. A challenge is not a fact about the site — the site did not
//  choose it, a service in front of it did, and the same handful of services
//  guard millions of unrelated sites. A per-canvas list would have every
//  package restating the same six phrases and going stale independently.
//

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
}
