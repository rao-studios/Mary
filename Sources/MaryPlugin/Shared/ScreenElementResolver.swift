//
//  ScreenElementResolver.swift
//  MaryAdapter
//
//  WHAT: Phrase → AXScreenElement via SpokenReference.
//  IN:   AXElementRoster  OUT: ambient / affordance

import Foundation

extension AXScreenElement: SpokenReferable {
    public var spokenLabel: String { label }

    public var spokenKind: PageElementKind? {
        switch category {
        case .interactive:
            return PageElementKindDerivation.kind(
                role: role, subrole: subrole, url: nil, label: label, frame: frame)
        case .scripted:
            // A scripting-sub-engine graft (a slide, a row in a list the
            // app never exposed AX for) — countable, but never a link: it
            // never had a destination to begin with.
            return .row
        case .image:
            return .image
        case .text:
            return role == "AXHeading" ? .heading : nil
        case .container:
            return role == "AXRow" || role == "AXCell" ? .row : nil
        default:
            return nil
        }
    }
}

public enum ScreenElementResolution: Sendable, Equatable {
    case one(AXScreenElement)
    case ambiguous([AXScreenElement])
    case none
}

public enum ScreenElementResolver {

    public static let spokenRivalLimit = SpokenReference.spokenRivalLimit

    public static func resolve(
        phrase rawPhrase: String,
        in elements: [AXScreenElement],
        preferShortestOnTie: Bool = true
    ) -> ScreenElementResolution {
        switch SpokenReference.resolve(
            phrase: rawPhrase, among: elements, preferShortestOnTie: preferShortestOnTie
        ) {
        case .one(let index): return .one(elements[index])
        case .ambiguous(let indices): return .ambiguous(indices.map { elements[$0] })
        case .none: return .none
        }
    }

    // MARK: - Spoken outcomes

    /// Named for the app the rivals actually came from, read off the rivals themselves
    /// rather than threaded through as a parameter.
    public static func ambiguityRefusal(
        _ rivals: [AXScreenElement], phrase: String
    ) -> String {
        let named = rivals.prefix(spokenRivalLimit)
            .map { "\"\(shortened($0.label))\"" }
        let list = SpokenReference.spokenList(Array(named))
        let where_ = rivals.first.map { "in \($0.appName)" } ?? "on the screen"
        return "There are \(rivals.count) things \(where_) matching \(phrase) — \(list). Which one?"
    }

    /// Unlike the page lane's miss, this makes no promise of a
    /// read-the-screen tool — none exists yet on this lane, and a refusal
    /// should never advertise a capability that isn't there.
    public static func missRefusal(phrase: String, appName: String?) -> String {
        let where_ = appName.map { " in \($0)" } ?? ""
        return "I can't find \(phrase)\(where_)."
    }

    public static func shortened(_ label: String, limit: Int = 60) -> String {
        SpokenReference.shortened(label, limit: limit)
    }

    // MARK: - Offerings

    /// What this snapshot's published elements are FOR, in the same shape
    /// `PageElementKindDerivation.offerings(in:)` reports for a page.
    public static func offerings(
        in elements: [AXScreenElement]
    ) -> [(kind: PageElementKind, count: Int)] {
        PageElementKindDerivation.offerings(of: elements.compactMap(\.spokenKind))
    }
}
