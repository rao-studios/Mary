//
//  PluginBrowserSurfaceSchema.swift
//  MaryFoundation
//
//  WHERE A BROWSER KEEPS ITS TABS — declared, not coded.
//
//  The third sibling of `PluginProseSurfaceSchema` and
//  `PluginMediaSurfaceSchema`, for the thing a browser hands Mary that is
//  neither a document nor a player: a set of pages, one of which is current.
//  Mary compiles in ONE generic browser adapter that knows how to find a tab
//  strip, read it, press a tab and confirm the press. What it does not know
//  is what THIS browser calls that strip or where it keeps a tab's name.
//
//  WHY THIS IS A DECLARATION, and the measurement that settles it. The port
//  this descends from read tabs over each browser's scripting dictionary,
//  where `tabs` is a collection with a `name` — one shape for everyone. Mary
//  sends no Apple Events, so the tab strip has to be found in the tree, and
//  the two browsers measured on 2026-08-28 (macOS 26) agree on exactly one
//  axis out of six:
//
//                    Chrome 151                 Safari
//    strip container AXTabGroup                 AXOpaqueProviderGroup
//    strip depth     7-8, deep in the chrome    1, a child of the window
//    a tab           AXRadioButton/AXTabButton  ← the one agreement
//    its NAME in     AXDescription              AXTitle
//    AXPress         advertised                 advertised
//    which is on     AXSelected                 NOT PUBLISHED AT ALL
//    closing         a child AXButton "Close"   a custom "close tab" action
//
//  A LANE THAT SEARCHED FOR A TAB GROUP BY ROLE WOULD, IN SAFARI, FIND THE
//  PAGE — Safari's own `AXTabGroup` is the content container. That is not a
//  near miss that returns nothing; it returns the page and calls it the tab
//  strip. Six differences of that kind are what a package is for.
//
//  THE FAMILY, NOT THE APPLICATION. Every field below describes a class of
//  software — "a browser that publishes its tab strip through Accessibility"
//  — and none of them names a product. A third browser joins by shipping one
//  of these.
//
//  DEFAULTS ARE THE MEASURED MAJORITY, NOT A GUESS. `tabRole` defaults to
//  what both browsers agreed on; the container and the name attribute have no
//  majority, so they have no defaults worth trusting and a package that omits
//  them is asking the adapter to search. That is slower and less certain than
//  declaring, and it is honest about which of the two it is doing.
//

import Foundation

/// How this browser says which tab is current.
///
/// A CLOSED ENUM AND NOT A BOOLEAN, because Safari forced the question. It
/// publishes no `AXSelected` on its tabs at all — so a lane that read the
/// flag would report "no tab is current" for a browser that plainly has one,
/// and a lane that assumed the first tab would be wrong four times in five.
/// The answer Safari does give is its window title, which matches the current
/// tab's name; that is a real mechanism, weaker than a flag (two tabs showing
/// the same page are indistinguishable) and worth naming as such.
public enum PluginTabSelectionSignal: String, Codable, Hashable, Sendable, CaseIterable {
    /// The tab carries `AXSelected`. Exact.
    case selectedAttribute
    /// Nothing on the tab says so; the window title names the current one.
    /// Ambiguous when two tabs show identically-titled pages, and the adapter
    /// reports that ambiguity rather than choosing.
    case windowTitle
}

/// How a tab is closed.
public enum PluginTabCloseAffordance: String, Codable, Hashable, Sendable, CaseIterable {
    /// A child button inside the tab — Chrome's shape.
    case childButton
    /// A named action on the tab itself — Safari's shape.
    case elementAction
    /// Neither; the close chord is the only road.
    case chordOnly
}

public struct PluginBrowserSurfaceSchema: Codable, Hashable, Sendable {

    /// The Accessibility role of the element holding one child per tab.
    /// No default: the two measured browsers disagree, and a wrong guess
    /// here finds the page (see the header).
    public var tabStripRole: String

    /// A subrole to disambiguate when the role alone is not enough. Safari's
    /// strip is an `AXOpaqueProviderGroup` with subrole `AXOpaqueProviderList`
    /// and other opaque groups exist in the same window.
    public var tabStripSubrole: String?

    /// The role each tab carries. Defaults to the one thing both measured
    /// browsers agreed on.
    public var tabRole: String

    /// Which attribute holds a tab's name. Chrome uses description, Safari
    /// title — and a reader that climbs a fixed ladder instead of being told
    /// finds an unnamed strip in one of them, silently.
    public var tabNameAttribute: PluginElementTextAttribute

    /// Words that mark the start of DIAGNOSTIC text a browser appends to a
    /// tab's published name, rather than part of the page's title.
    ///
    /// MEASURED, and not a nicety: Chrome publishes a tab's accessibility
    /// name as "<title> - Memory usage - 772 MB", so the name Mary reads back
    /// to the user ends in a number that changes every few seconds. It also
    /// makes a name a poor thing to match on — the same tab is a different
    /// string one minute later.
    ///
    /// A DECLARED LIST RATHER THAN A PATTERN IN THE READER, because which
    /// diagnostics a browser volunteers is a fact about that browser, and the
    /// next one will volunteer different ones. The reader knows only the
    /// SHAPE: a trailing dash-separated segment, from the marker onward.
    public var tabNameNoiseMarkers: [String]

    /// How to tell which tab is current.
    public var selectionSignal: PluginTabSelectionSignal

    /// How a tab is closed, when it is not by chord.
    public var closeAffordance: PluginTabCloseAffordance

    /// The label on the per-tab close control, for `childButton` /
    /// `elementAction`. A word, so it is a package's to say.
    public var closeControlLabel: String?

    /// The chord that opens a new tab. Every browser measured uses ⌘T, but a
    /// browser that did not could still be taught.
    public var newTabChord: PluginChord?

    /// The chord that closes the current tab.
    public var closeTabChord: PluginChord?

    /// The chord that focuses the address bar.
    public var addressChord: PluginChord?

    /// Whether ⌘1…⌘9 select tabs by position.
    ///
    /// A FALLBACK THAT IS OFF BY DEFAULT, deliberately. Both measured
    /// browsers advertise `AXPress` on their tabs, so a tab is addressable by
    /// IDENTITY — and an ordinal is a POSITION, which is wrong the moment a
    /// tab moves or a neighbour closes. Turning this on says "this browser's
    /// tabs cannot be pressed", which is a claim a package should have to
    /// make out loud.
    public var ordinalChordFallback: Bool

    public init(
        tabStripRole: String,
        tabStripSubrole: String? = nil,
        tabRole: String = "AXRadioButton",
        tabNameAttribute: PluginElementTextAttribute,
        tabNameNoiseMarkers: [String] = [],
        selectionSignal: PluginTabSelectionSignal,
        closeAffordance: PluginTabCloseAffordance = .chordOnly,
        closeControlLabel: String? = nil,
        newTabChord: PluginChord? = nil,
        closeTabChord: PluginChord? = nil,
        addressChord: PluginChord? = nil,
        ordinalChordFallback: Bool = false
    ) {
        self.tabStripRole = tabStripRole
        self.tabStripSubrole = tabStripSubrole
        self.tabRole = tabRole
        self.tabNameAttribute = tabNameAttribute
        self.tabNameNoiseMarkers = tabNameNoiseMarkers
        self.selectionSignal = selectionSignal
        self.closeAffordance = closeAffordance
        self.closeControlLabel = closeControlLabel
        self.newTabChord = newTabChord
        self.closeTabChord = closeTabChord
        self.addressChord = addressChord
        self.ordinalChordFallback = ordinalChordFallback
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tabStripRole, tabStripSubrole, tabRole, tabNameAttribute
        case tabNameNoiseMarkers
        case selectionSignal, closeAffordance, closeControlLabel
        case newTabChord, closeTabChord, addressChord, ordinalChordFallback
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tabStripRole = try values.decode(String.self, forKey: .tabStripRole)
        tabStripSubrole = try values.decodeIfPresent(String.self, forKey: .tabStripSubrole)
        tabRole = try values.decodeIfPresent(String.self, forKey: .tabRole) ?? "AXRadioButton"
        tabNameAttribute = try values.decode(
            PluginElementTextAttribute.self, forKey: .tabNameAttribute)
        tabNameNoiseMarkers = try values.decodeIfPresent(
            [String].self, forKey: .tabNameNoiseMarkers) ?? []
        selectionSignal = try values.decode(
            PluginTabSelectionSignal.self, forKey: .selectionSignal)
        closeAffordance = try values.decodeIfPresent(
            PluginTabCloseAffordance.self, forKey: .closeAffordance) ?? .chordOnly
        closeControlLabel = try values.decodeIfPresent(String.self, forKey: .closeControlLabel)
        newTabChord = try values.decodeIfPresent(PluginChord.self, forKey: .newTabChord)
        closeTabChord = try values.decodeIfPresent(PluginChord.self, forKey: .closeTabChord)
        addressChord = try values.decodeIfPresent(PluginChord.self, forKey: .addressChord)
        ordinalChordFallback = try values.decodeIfPresent(
            Bool.self, forKey: .ordinalChordFallback) ?? false
    }

    /// HAND-WRITTEN, and every optional and defaulted field omitted when it
    /// carries its default. The package digest is taken over these exact
    /// bytes, so a synthesized encoder writing `"tabStripSubrole": null` — or
    /// writing out a default nobody declared — changes the digest of every
    /// package that did not say it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabStripRole, forKey: .tabStripRole)
        if let tabStripSubrole {
            try container.encode(tabStripSubrole, forKey: .tabStripSubrole)
        }
        if tabRole != "AXRadioButton" { try container.encode(tabRole, forKey: .tabRole) }
        try container.encode(tabNameAttribute, forKey: .tabNameAttribute)
        if !tabNameNoiseMarkers.isEmpty {
            try container.encode(tabNameNoiseMarkers, forKey: .tabNameNoiseMarkers)
        }
        try container.encode(selectionSignal, forKey: .selectionSignal)
        if closeAffordance != .chordOnly {
            try container.encode(closeAffordance, forKey: .closeAffordance)
        }
        if let closeControlLabel {
            try container.encode(closeControlLabel, forKey: .closeControlLabel)
        }
        if let newTabChord { try container.encode(newTabChord, forKey: .newTabChord) }
        if let closeTabChord { try container.encode(closeTabChord, forKey: .closeTabChord) }
        if let addressChord { try container.encode(addressChord, forKey: .addressChord) }
        if ordinalChordFallback {
            try container.encode(ordinalChordFallback, forKey: .ordinalChordFallback)
        }
    }
}
