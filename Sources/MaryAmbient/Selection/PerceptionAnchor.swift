//
//  PerceptionAnchor.swift
//  MaryBrain
//
//  WHAT: What anchored a watcher's excerpt — shared vocabulary, not a Pages detail.
//  OUT:  prompt and debugger (identical phrasing)
//  PIN:  Ambient perception is AX + AppleScript, never pixels. `.viewport` is Xcode-only now.
//
import Foundation

public enum PerceptionAnchor: String, Sendable, Equatable, CaseIterable {
    /// The user's own highlight — the strongest statement of intent there is.
    case selection
    /// What the app reports as on-screen right now, WITH the app's own words for it
    /// (AXStringForRange). Beats the caret: a reader scrolls away from their cursor constantly,
    /// and the thing in front of their eyes is what they mean by "this paragraph".
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

    /// The prompt's lead-in for the excerpt this anchor produced. Nil when there is nothing to
    /// introduce.
    public var promptLead: String? {
        switch self {
        case .selection:     return "Around their highlight"
        case .viewport:      return "On their screen right now (this is what they are looking at)"
        case .caret:         return "Around their cursor"
        case .documentStart: return "The document starts"
        case .none:          return nil
        }
    }

    /// True when the anchor's TEXT came from a live Accessibility read this tick rather than a
    /// throttled document cache — the freshness claim a contribution is allowed to make (see
    /// the watchers' liveness lines). ONLY XCODE CAN STILL ANSWER TRUE THROUGH `.viewport`.
    public var isLiveRead: Bool {
        self == .selection || self == .viewport
    }
}

// `ViewportProvenance` USED TO LIVE HERE, and deleting it is the point rather than a
// tidy-up.

/// WHICH branch found the element a watcher read from. A capability fallback can land on a
/// title field, a comment, a text box or a single page's element — and a per-page element's
/// "visible range" is page 1 no matter where the user scrolled.
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
