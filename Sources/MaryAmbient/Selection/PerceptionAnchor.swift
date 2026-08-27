//
//  PerceptionAnchor.swift
//  MaryBrain
//
//  WHAT anchored a watcher's excerpt — shared vocabulary, not a Pages
//  detail. The bug that forced this into existence: Pages anchored every
//  excerpt on the CARET, so a user who scrolled away and asked about the
//  paragraph in front of them got an honest-sounding denial built from a
//  stale cursor position. The cure is not a better heuristic, it is saying
//  out loud which of four very different things the text came from — and
//  saying it identically in the prompt and in the debugger.
//
//  Every co-writing/co-coding watcher that grows an excerpt reports one of
//  these; more of them are coming (the writing and coding plugin families
//  both expand), so the words live here once instead of drifting per app.
//
//  DOCTRINE: none of these anchors is a screen READ. Mary's AMBIENT
//  perception (watchers, anchors, selection) is Accessibility + AppleScript
//  only and never reads pixels. Screen Recording has exactly three
//  sanctioned uses — the debugger's pixel minimap, take_screenshot
//  (user-requested, persists to the Desktop), and the ephemeral look
//  (`looking`: user-requested, in-memory only, never persisted or
//  archived; see ScreenRegionCapture). `.viewport` means "the app told us
//  which characters are on screen", never "we looked at the pixels".
//
//  `.viewport` IS AN XCODE ANCHOR NOW, AND ONLY XCODE'S. Pages deleted the
//  concept outright: a window claim is a statement about an epistemic LIMIT,
//  and with `body text` in hand there is no limit for that watcher to report,
//  so the claim cannot be earned. Xcode's window is honestly a window — its
//  watcher reads the lines the editor is showing — so the anchor stays here
//  rather than moving into `XcodeContext`. See `PagesContextWatcher`'s header
//  for what replaced it.
//

import Foundation

public enum PerceptionAnchor: String, Sendable, Equatable, CaseIterable {
    /// The user's own highlight — the strongest statement of intent there is.
    case selection
    /// What the app reports as on-screen right now, WITH the app's own words
    /// for it (AXStringForRange). Beats the caret: a reader scrolls away from
    /// their cursor constantly, and the thing in front of their eyes is what
    /// they mean by "this paragraph".
    case viewport
    /// The insertion point, with no highlight and no viewport read — where
    /// they last typed, which is only sometimes where they are looking.
    case caret
    /// Nothing located the user at all; the head of the document is a
    /// fallback, and must never be dressed up as attention.
    case documentStart
    /// No readable text of any kind.
    case none

    /// The debugger's phrasing — the field the user reads on the tile to
    /// see WHY Mary is looking where she is looking.
    public var displayName: String {
        switch self {
        case .selection:      return "their highlight"
        case .viewport:       return "what they're looking at"
        case .caret:          return "their cursor"
        case .documentStart:  return "document start"
        case .none:           return "nothing readable"
        }
    }

    /// The prompt's lead-in for the excerpt this anchor produced. Nil when
    /// there is nothing to introduce. Deliberately unmistakable for
    /// `.viewport`: the model must read that line as "this is what the user
    /// is looking at right now", superseding any cursor-shaped context.
    public var promptLead: String? {
        switch self {
        case .selection:     return "Around their highlight"
        case .viewport:      return "On their screen right now (this is what they are looking at)"
        case .caret:         return "Around their cursor"
        case .documentStart: return "The document starts"
        case .none:          return nil
        }
    }

    /// True when the anchor's TEXT came from a live Accessibility read this
    /// tick rather than a throttled document cache — the freshness claim a
    /// contribution is allowed to make (see the watchers' liveness lines).
    ///
    /// ONLY XCODE CAN STILL ANSWER TRUE THROUGH `.viewport`. Pages produces
    /// `.selection` (whose TEXT really is the live highlight), `.caret`,
    /// `.documentStart` or `.none`, and its excerpt is always cut out of the
    /// AppleScript body — see `AmbientBridge.facts(from: PagesContext)`, which
    /// no longer consults this for the excerpt fact at all.
    public var isLiveRead: Bool {
        self == .selection || self == .viewport
    }
}

// `ViewportProvenance` USED TO LIVE HERE, and deleting it is the point rather
// than a tidy-up. It named six ways a viewport read could be worthless —
// `wholeDocument` and `diverged` were both real detectors, and both fired on
// real bugs — but every one of them interrogates THE RANGE. The thing that lied
// was THE ELEMENT: `PagesAX.textElement` early-returned a focused TITLE FIELD
// (it answers `kAXNumberOfCharacters`, which is all `isTextual` asks for), and
// everything downstream then read that element perfectly correctly —
// `totalCharacters = 120`, `visibleRange = 0..<120`, `visibleText` = the title.
// A range checked against a length that is itself the lie cannot come out
// false; `wholeDocument` was even disarmed by its own escape hatch, which asked
// `totalCharacters > excerptCap` on that same untrusted element and waved every
// element under 800 characters through as "a short document entirely on
// screen". The right instinct, aimed one layer too high. `PagesElementTrust`
// (in `PagesContextWatcher`) asks the question one layer down — is this element
// even long enough to BE the document — and the answer is checked against the
// AppleScript body rather than against itself.

/// WHICH branch found the element a watcher read from. A capability fallback
/// can land on a title field, a comment, a text box or a single page's
/// element — and a per-page element's "visible range" is page 1 no matter
/// where the user scrolled. Nothing recorded which branch fired, so that
/// hypothesis could not be checked at all.
public enum PerceptionElementResolution: String, Sendable, Equatable, CaseIterable {
    /// The app's focused UI element answered — fast and exact.
    case focusedElement
    /// A bounded descent of the main window found a real text area.
    case mainWindowDescent
    /// No text area anywhere; the first node that merely ANSWERED a text
    /// attribute was accepted. The weakest branch, and the one worth
    /// suspecting first when the excerpt looks wrong.
    case capabilityFallback

    public var displayName: String {
        switch self {
        case .focusedElement:     return "focused element"
        case .mainWindowDescent:  return "main-window descent"
        case .capabilityFallback: return "capability fallback"
        }
    }
}
