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
import MaryFoundation

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
    /// Jump to a time from the start. Resolved against the video's length into
    /// a `seek(fraction:)` before anything is pressed — see `BrowserEngine.drove`.
    case seekTo(seconds: TimeInterval)
    /// Move by a length of time from wherever it is; negative is backwards.
    case seekBy(seconds: TimeInterval)
    /// Set the sound to a proportion of the volume track.
    case volume(fraction: Double)

    public var spokenPast: String {
        switch self {
        case .play: return "Playing"
        case .pause: return "Paused"
        case .toggle: return "Pressed play"
        case .mute: return "Muted"
        case .unmute: return "Unmuted"
        case .fullscreen: return "Went full screen"
        case .seek(let fraction): return "Skipped to \(Int((fraction * 100).rounded()))%"
        case .seekTo(let seconds): return "Went to \(SpokenDuration.clock(seconds))"
        case .seekBy(let seconds):
            return seconds < 0
                ? "Went back \(SpokenDuration.clock(seconds))"
                : "Skipped ahead \(SpokenDuration.clock(seconds))"
        case .volume(let fraction):
            return "Set the volume to \(Int((fraction * 100).rounded()))%"
        }
    }

    /// A time seek, before it is resolved into a place on the track.
    public var isTimeSeek: Bool {
        switch self {
        case .seekTo, .seekBy: return true
        default: return false
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
    /// A human-verification interstitial stands between the person and the page
    /// they asked for, and pressing its visible control did not clear it. NOT a
    /// failure to try — see PageChallenge — but the point at which the honest
    /// answer is to hand it back.
    case humanCheck
    case addressFieldNotFound
    case elementNotFound(String)
    /// Several things answer to that phrase. Carries the rivals so the refusal names them.
    case ambiguousElement(phrase: String, rivals: [String])
    /// A plan the model wrote that the grammar would not take.
    case planInvalid([String])
    /// Somebody touched the machine while a plan was running.
    case interrupted(atCommand: Int)
    /// A search was typed and the browser went somewhere that is not results for it.
    case searchCompletedElsewhere
    /// A named thing that is not the kind the command needs.
    case notFillable(String)
    case notAdjustable(String)
    case outOfTime
    /// The browser could not be staged, and why — the stage faculty's own
    /// reason, so five different conditions are not one sentence.
    case activationRefused(String, Activation.Failure?)
    /// THE WINDOW THIS SESSION WAS TOLD TO WORK IN IS GONE. A runner named it;
    /// falling back to whichever window the browser calls main would put the
    /// act in the person's own window — measured in round 10, when the round's
    /// window closed and every trip after it ran in theirs.
    case workingWindowGone
    /// THE BROWSER ITSELF IS ASKING SOMETHING, and until it is answered the
    /// page cannot be read or acted on. Carries what it asks and the choices it
    /// offers, so the person can answer in one word.
    case browserIsAsking(question: String, choices: [String])
    /// A time was asked for and no lane could read how long the video is.
    case videoLengthUnknown
    /// A time past the end of the video, as the reading measures it.
    case beyondTheEnd(TimeInterval)
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
        case .humanCheck:
            return "There's a \"verify you are human\" step on this page — could you click it? I'd rather not get that one wrong."
        case .addressFieldNotFound:
            return "I couldn't find the address bar."
        case .elementNotFound(let phrase):
            return "I couldn't find \"\(phrase)\" on the page."
        case .ambiguousElement(let phrase, let rivals):
            let named = rivals.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
            return "There's more than one \"\(phrase)\" on this page — \(named). Which one?"
        case .planInvalid(let problems):
            return "I can't run that: \(problems.prefix(3).joined(separator: "; "))."
        case .interrupted(let index):
            return "Something else took over at step \(index + 1), so I stopped there."
        case .searchCompletedElsewhere:
            return "The browser went somewhere else instead of showing results for that."
        case .notFillable(let phrase):
            return "\"\(phrase)\" isn't something I can type into."
        case .notAdjustable(let phrase):
            return "\"\(phrase)\" isn't a slider, so there's nothing to set."
        case .outOfTime:
            return "That was taking too long, so I stopped partway."
        case .activationRefused(let name, let failure):
            return failure.flatMap { Activation.lost($0).reason(app: name) }
                ?? "\(name) wouldn't come forward."
        case .workingWindowGone:
            return "The browser window I was working in is gone."
        case .browserIsAsking(let question, let choices):
            let offered = choices.isEmpty
                ? ""
                : " — " + choices.map { "\"\($0)\"" }.joined(separator: " or ")
            return "The browser is asking: \(question)\(offered). Which?"
        case .videoLengthUnknown:
            return "I can't tell how long the video is, so I can't go to a time in it."
        case .beyondTheEnd(let duration):
            return "The video is only \(SpokenDuration.clock(duration)) long."
        case .notImplemented(let what):
            return "I can't \(what) yet."
        case .dryRun(let what):
            return "Dry run — I would have \(what)."
        }
    }
}

/// The evidence that an act did something.
///
/// PIN: RANKED, AND THE RANK IS THE HONESTY. A page repaints on its own — adverts
/// rotate, lazy images arrive — so "something changed" is the weakest thing that can be
/// said and it is not proof. Only the top three carry `landed`; the rest are reported as
/// delivered with the effect unverified, which is a different sentence and a different
/// decision for whatever reads it.
public enum PageEffectEvidence: Sendable, Equatable {
    /// The strongest: the browser went somewhere and stayed there.
    case navigation(title: String)
    /// The thing itself changed — its words, or it is gone.
    case targetChanged(before: String, after: String)
    /// The typed text is now in the field.
    case textAppeared(in: String)
    /// The page's rows differ. Weak on its own.
    case rosterChanged(added: Int, removed: Int)
    /// The player moved. The media lane's own witness.
    case mediaState(String)
    /// The browser's own question was answered with this choice, and it is gone.
    case dialogAnswered(String)

    public var spoken: String {
        switch self {
        case .navigation(let title): return "the page became \(title)"
        case .dialogAnswered(let choice): return "the browser's question was answered with \(choice)"
        case .targetChanged(_, let after):
            return after.isEmpty ? "it is gone from the page" : "it now says \(after)"
        case .textAppeared(let field): return "the text is in \(field)"
        case .rosterChanged(let added, let removed):
            return "the page changed (\(added) new, \(removed) gone)"
        case .mediaState(let what): return what
        }
    }

    /// Whether this is proof, or only a sign.
    public var isProof: Bool {
        switch self {
        case .navigation, .targetChanged, .textAppeared, .mediaState, .dialogAnswered: return true
        case .rosterChanged: return false
        }
    }
}

/// Whether a command reached the machine.
public enum PageDeliveryState: Sendable, Equatable {
    case delivered
    case refused(BrowserRefusal)
    /// An earlier command stopped the plan before this one ran.
    case notAttempted
    case interrupted
}

/// Whether it did anything.
public enum PageEffectState: Sendable, Equatable {
    case verified(PageEffectEvidence)
    case weak(PageEffectEvidence)
    case unverified
}

/// One command's whole story.
public struct PageCommandReceipt: Sendable, Equatable {
    public var sourceIndex: Int
    public var kind: PageInteractionCommandKind
    public var target: String?
    public var delivery: PageDeliveryState
    public var effect: PageEffectState

    public init(
        sourceIndex: Int, kind: PageInteractionCommandKind, target: String? = nil,
        delivery: PageDeliveryState, effect: PageEffectState = .unverified
    ) {
        self.sourceIndex = sourceIndex
        self.kind = kind
        self.target = target
        self.delivery = delivery
        self.effect = effect
    }

    /// Proof, not a sign — what `SkillOutcome.landed` is allowed to rest on.
    public var landed: Bool {
        guard case .delivered = delivery else { return false }
        if case .verified = effect { return true }
        return false
    }

    public var spoken: String {
        let named = target.map { " \"\($0)\"" } ?? ""
        switch delivery {
        case .refused(let refusal): return refusal.summary
        case .notAttempted: return "didn't get to \(kind.rawValue)\(named)"
        case .interrupted: return "stopped during \(kind.rawValue)\(named)"
        case .delivered:
            switch effect {
            case .verified(let evidence), .weak(let evidence):
                return "\(kind.rawValue)\(named) — \(evidence.spoken)"
            case .unverified:
                return "\(kind.rawValue)\(named) — no sign it did anything"
            }
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
    /// What the map said about those rows.
    public var map: PageMapSummary?
    /// One per command, in authored order.
    public var receipts: [PageCommandReceipt]
    /// PROVEN, not merely attempted. The continuation nudge reads this to decide whether
    /// the asked-for change actually happened, so a hopeful `true` here is how a turn
    /// closes on work it did not do.
    public var landed: Bool

    public init(
        ok: Bool, spoken: String, refusal: BrowserRefusal? = nil,
        shell: WebSurfaceAX.Reading? = nil, media: MediaControlReading? = nil,
        elements: [AXScreenElement] = [], map: PageMapSummary? = nil,
        receipts: [PageCommandReceipt] = [], landed: Bool = false
    ) {
        self.ok = ok
        self.spoken = spoken
        self.refusal = refusal
        self.shell = shell
        self.media = media
        self.elements = elements
        self.map = map
        self.receipts = receipts
        self.landed = landed
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
    case read(rows: Int, named: Int, groups: Int)
    /// A goal was weighed against every row the read produced. The whole verdict, not
    /// only its winner — see `PageRouteTrace`.
    case routed(PageRouteTrace)
    /// A phrase became one row. Named `matched` because `resolved` already means
    /// "which browser" on this stream.
    case matched(phrase: String, to: String)
    case receipt(PageCommandReceipt)
    case acted(String)
    case verified(String)
    case refused(BrowserRefusal)
}

public extension BrowserEngineEvent {

    /// ONE VOCABULARY FOR EVERY WATCHER. The probe timing a roundtrip and the bench
    /// drawing a timeline are looking at the same stream and must not describe it in two
    /// dialects — a lane whose events read differently in two places cannot be compared
    /// across them, which is the entire use of watching it.
    ///
    /// PIN: PAST TENSE, AND NO ADDRESSES. Every one of these already happened, and the
    /// browsing lane speaks site names rather than URLs everywhere else — a debug line
    /// that printed one would be the only place a URL leaked back into view.
    var line: String {
        switch self {
        case .resolved(let browser, _):
            return "resolved \(browser)"
        case .shellRead(let title, let site, _):
            return "read the shell — \(title ?? "untitled")\(site.map { " · \($0)" } ?? "")"
        case .perceived(let controls, let playback, _):
            return "perceived \(controls) controls · \(playback)"
        case .read(let rows, let named, let groups):
            return "looked — \(rows) rows, \(named) named, \(groups) groups"
        case .routed(let trace):
            let picked = trace.selected.first.map { "\"\($0.label)\"" }
                ?? (trace.rivals.isEmpty ? "nothing" : "a question")
            return "routed \"\(trace.goal)\" → \(picked)"
                + " (\(trace.eligibleCount) of \(trace.decisions.count) eligible)"
        case .matched(let phrase, let label):
            return "matched \"\(phrase)\" → \"\(label)\""
        case .receipt(let receipt):
            return "receipt — \(receipt.spoken)"
        case .acted(let what):
            return what
        case .verified(let what):
            return "verified \(what)"
        case .refused(let refusal):
            return "refused — \(refusal.summary)"
        }
    }

    /// Whether this line is the lane saying it did NOT do something. The one thing a
    /// timeline must never colour like an ordinary step.
    var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }
}

/// Everything the engine knows about itself right now.
public struct BrowserEngineSnapshot: Sendable {
    public var startedAt: Date
    public var dryRun: Bool
    public var lastBrowser: String?
    public var lastChrome: WebSurfaceAX.Reading?
    /// Which road the last journey took — see `WatchRecipe.Road`.
    public var lastWatchRoad: String?
    public var lastMedia: MediaControlReading?
    /// The last page read, whole — the same roster the slate was published from.
    ///
    /// PIN: EVIDENCE OF A READ THAT HAPPENED, never a licence to act on it. It is here
    /// so a debugger can DRAW what the engine saw; resolution re-reads, always, because
    /// a roster is a photograph and the page has moved on. Nil is the honest answer
    /// whenever the slate is retracted — a navigation makes both wrong at once.
    public var lastRoster: PageRoster?
    /// The window the engine works in, once one has been read.
    public var workingWindow: CGWindowID?
    /// The last goal routed against that roster. Cleared with it, for its reason.
    public var lastRoute: PageRouteTrace?
    public var lastRefusal: BrowserRefusal?
    public var acts: Int
    public var refusals: Int
    public var perceptions: Int
    /// The tail, newest last.
    public var recent: [String]

    public init(
        startedAt: Date, dryRun: Bool, lastBrowser: String? = nil,
        lastChrome: WebSurfaceAX.Reading? = nil, lastWatchRoad: String? = nil,
        lastMedia: MediaControlReading? = nil,
        lastRoster: PageRoster? = nil, lastRoute: PageRouteTrace? = nil,
        workingWindow: CGWindowID? = nil,
        lastRefusal: BrowserRefusal? = nil, acts: Int = 0, refusals: Int = 0,
        perceptions: Int = 0, recent: [String] = []
    ) {
        self.startedAt = startedAt
        self.dryRun = dryRun
        self.lastBrowser = lastBrowser
        self.lastChrome = lastChrome
        self.lastWatchRoad = lastWatchRoad
        self.lastMedia = lastMedia
        self.lastRoster = lastRoster
        self.workingWindow = workingWindow
        self.lastRoute = lastRoute
        self.lastRefusal = lastRefusal
        self.acts = acts
        self.refusals = refusals
        self.perceptions = perceptions
        self.recent = recent
    }
}
