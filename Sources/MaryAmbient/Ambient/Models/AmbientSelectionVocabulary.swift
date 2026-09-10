//
//  AmbientSelectionVocabulary.swift
//  MaryAmbient
//
//  WHAT: How a selection was captured, identified, recovered, and whether it
//        can be written back to.
//  OUT:  fields of AmbientSelectionHandoff (and AmbientWorld.Snapshot)
//  PIN:  ONE VOCABULARY, one file. Diagnostic provenance, never a routing
//        switch — evidence can license DISCUSSING words, not replacing them.
//

import Foundation

/// How the source-selection ability reached the source application. The channel is
/// diagnostic provenance. It never selects a workspace or changes routing.
public enum AmbientSelectionCaptureChannel: String, Sendable, Equatable, Codable {
    /// The source application's AX selection-change notification named the
    /// element that changed.
    case accessibilityNotification
    /// The source application was yielding focus, so its registered selection
    /// ability captured the still-owned selection immediately.
    case applicationHandoff
    /// A source-owned watcher sampled an app whose AX implementation does not
    /// publish selection notifications.
    case sourcePoll
    /// An application adapter read the selection together with its document
    /// identity through one application-owned transaction (for example,
    /// Xcode's path + range + buffer AppleScript read).
    case applicationScripting

}

/// How directly Accessibility identified the element that supplied selected
/// text. This is evidence arbitration only; it never changes application scope
/// or decides what a request means.
public enum AmbientSelectionSourceEvidence: String, Sendable, Equatable, Codable {
    /// The application itself returned the value, document, and range in one
    /// read. This is stronger than an AX element identity because it proves
    /// the workspace/document scope as well as the selected value.
    case documentAtomic
    /// The source application itself materialized its current selection for a command targeted
    /// to its verified process.
    case targetedApplication
    /// The application's focused element, or an AX observer callback naming
    /// the element, supplied the text.
    case exactElement
    /// A bounded, positive-evidence search found one unambiguous descendant
    /// because the app focused a canvas/container instead of its text leaf.
    case discoveredDescendant

    public var rank: Int {
        switch self {
        case .discoveredDescendant: return 0
        case .targetedApplication, .exactElement: return 1
        case .documentAtomic: return 2
        }
    }

    public var isExact: Bool { rank >= Self.exactElement.rank }
}

/// Where the selected payload's characters came from when the source element proved a range
/// but could not return its value.
public enum AmbientSelectionPayloadRecovery: String, Sendable, Equatable, Codable {
    /// Pages returned document identity and body at the request boundary; the
    /// adapter sliced the unchanged AX range from that live body.
    case applicationBodyRange
    /// An opted-in source adapter issued Copy directly to its lifecycle- verified process,
    /// observed a newly-written nonempty plain-text value, and restored the user's pasteboard.
    case applicationCopy
}

/// Whether Accessibility says the source text surface can be changed. Highlighting is
/// always useful as a reference.
public enum AmbientSelectionEditability: String, Sendable, Equatable, Codable {
    case editable
    case readOnly
    case unknown
}

