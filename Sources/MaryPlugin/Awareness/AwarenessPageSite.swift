//
//  AwarenessPageSite.swift
//  MaryPlugin
//
//  WHAT: The page in front of someone, as awareness sees it.
//  IN:   AwarenessSupport (who asked to be followed) + WebSurfaceAX + the last read
//  OUT:  AwarenessPageObserver
//  PIN:  NO PIXELS ON A POLL, AND NO INDEX ANYWHERE. The shell — title, site,
//        whether it moved — is Accessibility, cheap, and safe to read on a
//        cadence. What is ON the page is pixels, so this never asks for it: it
//        reports the roster a SKILL's own read already produced, and how old it
//        is. A page nobody has read yet says exactly that.
//        THE DOCUMENT SITE'S SIBLING, NOT ITS SUBCLASS. `AwarenessSite` resolves
//        a file, a project root and a caret; a page has none of the three, which
//        is why the document road bails on a browser rather than describing it.
//

import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

/// A page being followed, and whatever is known about its contents.
public struct AwarenessPageSite: Sendable {
    public let registration: AwarenessRegistration
    /// The browser's own chrome, read through Accessibility.
    public let shell: WebSurfaceAX.Reading
    /// What the last page read found — nil when nothing has read this page.
    public let roster: PageRoster?
    /// How long ago that read happened.
    public let rosterAge: TimeInterval?

    public init(
        registration: AwarenessRegistration,
        shell: WebSurfaceAX.Reading,
        roster: PageRoster? = nil,
        rosterAge: TimeInterval? = nil
    ) {
        self.registration = registration
        self.shell = shell
        self.roster = roster
        self.rosterAge = rosterAge
    }

    /// WHICH PAGE THIS IS, for telling one from the next.
    ///
    /// Title and site rather than the address: the address is more than was
    /// asked for and is never spoken (see `TurnPerceptionPublisher`), while a
    /// title alone changes under a single-page app that never navigates.
    public var identity: String {
        [shell.siteName, shell.title].compactMap { $0 }.joined(separator: " · ")
    }
}

public enum AwarenessPageResolver {

    /// The page in front, or nil when nothing followed is showing one.
    ///
    /// `named` lets a caller ask about one browser by name; without it this
    /// answers whichever followed browser the web surface is standing on —
    /// the same rule the document road follows, and for the same reason: a
    /// question is about the work Mary is watching, not about whichever window
    /// happens to be frontmost while somebody speaks.
    public static func resolve(
        named: String? = nil,
        support: AwarenessSupport = .shared,
        web: WebSurfaceSupport = .shared,
        roster: (roster: PageRoster, at: Date)? = nil,
        now: Date = Date()
    ) -> AwarenessPageSite? {
        let followed = support.all.filter(\.hasWebSurface)
        guard !followed.isEmpty else { return nil }
        guard let (web, pid) = web.resolve(named) else { return nil }
        // FOLLOWED MEANS DECLARED THE EDGE. A browser running without the
        // awareness dependency is not watched, and saying nothing is the right
        // answer rather than watching it anyway.
        guard let registration = followed.first(where: {
            $0.applicationID == web.applicationID
                || web.bundleIdentifiers.contains(where: $0.owns(bundleID:))
        }) else { return nil }
        guard let shell = WebSurfaceAX.read(pid: pid, registration: web) else { return nil }
        return AwarenessPageSite(
            registration: registration,
            shell: shell,
            roster: roster?.roster,
            rosterAge: roster.map { now.timeIntervalSince($0.at) })
    }
}
