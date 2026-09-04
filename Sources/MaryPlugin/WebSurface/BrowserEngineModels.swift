//
//  BrowserEngineModels.swift
//  MaryPlugin
//
//  WHAT: What the browser engine is asked, what it answers, and why it refuses.
//  IN:   BrowserEngine
//  OUT:  WebSurfaceAdapter, the web probe
//  PIN:  EVERY REFUSAL IS NAMED. "It didn't work" is the answer this type exists to
//        stop being given — a browsing turn has a dozen ways to not happen and the
//        person is owed which one.
//

import CoreGraphics
import Foundation
import MaryComputerUse

/// The browser a request is aimed at.
public struct BrowserTarget: Sendable, Equatable {
    public let registration: WebSurfaceRegistration
    public let processIdentifier: pid_t

    public init(registration: WebSurfaceRegistration, processIdentifier: pid_t) {
        self.registration = registration
        self.processIdentifier = processIdentifier
    }

    public var spokenName: String { registration.displayName }
    public var applicationID: String { registration.applicationID }
}

/// What to do to the page's transport.
public enum MediaAction: Sendable, Equatable {
    case play
    case pause
    /// Press whatever the transport offers — the honest verb when the caller does not
    /// know the current state and does not need to.
    case toggle
    case mute
    case unmute
    case fullscreen
    /// Jump to a proportion of the video.
    case seek(fraction: Double)

    public var spokenPast: String {
        switch self {
        case .play: return "Playing"
        case .pause: return "Paused"
        case .toggle: return "Pressed play"
        case .mute: return "Muted"
        case .unmute: return "Unmuted"
        case .fullscreen: return "Went full screen"
        case .seek(let fraction): return "Skipped to \(Int((fraction * 100).rounded()))%"
        }
    }
}

/// Where to go.
public enum NavigationRequest: Sendable, Equatable {
    case open(String)
    case back
    case forward
    case reload
    case newTab
    case tab(index: Int)
    case scroll(by: Double)
}

/// Why a browsing act did not happen.
public enum BrowserRefusal: Error, Sendable, Equatable {
    case noBrowser
    case ambiguousBrowser([String])
    case shellUnreadable(String)
    case pageNotVisible
    case visionUnavailable(String)
    /// No transport at all — usually hidden rather than absent.
    case controlsNotFound
    case controlNotFound(String)
    /// The act landed and nothing moved. The receipt that failed.
    case stateUnchanged(expected: String, observed: String)
    case navigationDidNotSettle
    case addressFieldNotFound
    case elementNotFound(String)
    case activationRefused(String)
    case notImplemented(String)
    /// The engine was asked to observe, not act.
    case dryRun(String)

    public var summary: String {
        switch self {
        case .noBrowser:
            return "There's no browser running that I can see."
        case .ambiguousBrowser(let names):
            return "I can see \(names.joined(separator: " and ")) — which one?"
        case .shellUnreadable(let name):
            return "I couldn't read \(name)'s window just now."
        case .pageNotVisible:
            return "I can't see the page — the window may be behind something."
        case .visionUnavailable(let detail):
            return "I couldn't look at the page: \(detail)"
        case .controlsNotFound:
            return "I can't find the player's controls on this page."
        case .controlNotFound(let what):
            return "I can see the player but not its \(what) control."
        case .stateUnchanged(let expected, let observed):
            return "I pressed it, but it's still \(observed) rather than \(expected)."
        case .navigationDidNotSettle:
            return "The page didn't finish loading."
        case .addressFieldNotFound:
            return "I couldn't find the address bar."
        case .elementNotFound(let phrase):
            return "I couldn't find \"\(phrase)\" on the page."
        case .activationRefused(let name):
            return "\(name) wouldn't come forward."
        case .notImplemented(let what):
            return "I can't \(what) yet."
        case .dryRun(let what):
            return "Dry run — I would have \(what)."
        }
    }
}

/// What one browsing operation produced.
public struct BrowserOutcome: Sendable {
    public var ok: Bool
    public var spoken: String
    public var refusal: BrowserRefusal?
    public var shell: WebSurfaceAX.Reading?
    public var media: MediaControlReading?
    /// Rows the page read published, when one ran.
    public var elements: [AXScreenElement]

    public init(
        ok: Bool, spoken: String, refusal: BrowserRefusal? = nil,
        shell: WebSurfaceAX.Reading? = nil, media: MediaControlReading? = nil,
        elements: [AXScreenElement] = []
    ) {
        self.ok = ok
        self.spoken = spoken
        self.refusal = refusal
        self.shell = shell
        self.media = media
        self.elements = elements
    }

    static func refused(_ refusal: BrowserRefusal) -> BrowserOutcome {
        BrowserOutcome(ok: false, spoken: refusal.summary, refusal: refusal)
    }
}

/// What a watcher sees.
public enum BrowserEngineEvent: Sendable {
    case resolved(browser: String, pid: pid_t)
    case shellRead(title: String?, site: String?, pageFrame: CGRect?)
    case perceived(controls: Int, playback: String, duration: Duration)
    case acted(String)
    case verified(String)
    case refused(BrowserRefusal)
}

/// Everything the engine knows about itself right now.
public struct BrowserEngineSnapshot: Sendable {
    public var startedAt: Date
    public var dryRun: Bool
    public var lastBrowser: String?
    public var lastChrome: WebSurfaceAX.Reading?
    public var lastMedia: MediaControlReading?
    public var lastRefusal: BrowserRefusal?
    public var acts: Int
    public var refusals: Int
    public var perceptions: Int
    /// The tail, newest last.
    public var recent: [String]

    public init(
        startedAt: Date, dryRun: Bool, lastBrowser: String? = nil,
        lastChrome: WebSurfaceAX.Reading? = nil, lastMedia: MediaControlReading? = nil,
        lastRefusal: BrowserRefusal? = nil, acts: Int = 0, refusals: Int = 0,
        perceptions: Int = 0, recent: [String] = []
    ) {
        self.startedAt = startedAt
        self.dryRun = dryRun
        self.lastBrowser = lastBrowser
        self.lastChrome = lastChrome
        self.lastMedia = lastMedia
        self.lastRefusal = lastRefusal
        self.acts = acts
        self.refusals = refusals
        self.perceptions = perceptions
        self.recent = recent
    }
}
