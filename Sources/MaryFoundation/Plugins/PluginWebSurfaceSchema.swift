//
//  PluginWebSurfaceSchema.swift
//  MaryFoundation
//
//  WHAT: One browser's chrome, in its own words — the controls around the page.
//  IN:   PluginSchema.webSurface.
//  OUT:  web-surface adapter; PluginValidator (eyes).
//  PIN:  THE CHROME IS DECLARED, THE PAGE IS NOT. Everything here names a control the
//        BROWSER draws — its address field, its back button, its tab strip — and every
//        one of those names differs per browser: Safari calls back "Go back" and its
//        address field "smart search field"; Chrome says "Back" and "Address and search
//        bar" (measured, 2026-09-04). The page inside is read from pixels and needs no
//        declaration at all, which is why nothing here describes page content.
//        WHERE THE PAGE IS is a per-browser fact too, and `pageFrameSource` is it:
//        Safari publishes an AXWebArea whose frame is the WHOLE SCROLLABLE DOCUMENT
//        (measured 3101pt tall in an 842pt window), so it must be clipped to the
//        window; Chromium publishes no web area at all until an assistive client wakes
//        it, so its page is the window below the lowest toolbar.
//

import Foundation

/// Where a browser's current address can be read.
public enum PluginWebURLSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// From `AXURL` on the page's own web area. Correct where one exists.
    case webArea
    /// From the address field's value. What a browser with no live web area leaves.
    case addressField
}

/// How to work out which part of the window is the page.
public enum PluginWebPageFrameSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// The published web area, CLIPPED TO THE WINDOW — its own frame is the document.
    case webArea
    /// Everything below the lowest toolbar. For a browser whose page has no AX node.
    case windowBelowToolbar
}

/// The declared coordinates of one browser's chrome.
public struct PluginWebSurfaceSchema: Codable, Hashable, Sendable {

    /// The address field's accessibility label.
    public var addressFieldLabel: String

    /// The chord that focuses the address field when the field itself will not take
    /// focus. A BROWSER chord, never a site's: this is the browser's own menu command.
    public var addressFocusKey: PluginKey
    public var addressFocusModifiers: [PluginKeyModifier]

    public var backLabel: String
    public var forwardLabel: String
    public var reloadLabel: String

    /// The tab strip's role, when this browser publishes its tabs. Nil means tabs are
    /// not reachable and `list_tabs` says so rather than answering "none".
    public var tabRole: String?

    /// Text a browser appends to every window title — Safari appends nothing, Chrome
    /// appends " - Google Chrome" and the profile name after it.
    public var windowTitleSuffix: String?

    /// Noise a browser bakes into its tab labels. Chrome appends live memory usage to
    /// every tab's accessibility label ("GitLab - Memory usage - 455 MB"), which is not
    /// part of the page's name and must not be spoken as if it were.
    public var tabLabelSuffixSeparator: String?

    public var urlSource: PluginWebURLSource
    public var pageFrameSource: PluginWebPageFrameSource

    /// How often to look while this browser is in use.
    public var watch: PluginProseWatchSchema

    public init(
        addressFieldLabel: String,
        addressFocusKey: PluginKey = .l,
        addressFocusModifiers: [PluginKeyModifier] = [.command],
        backLabel: String,
        forwardLabel: String,
        reloadLabel: String,
        tabRole: String? = nil,
        windowTitleSuffix: String? = nil,
        tabLabelSuffixSeparator: String? = nil,
        urlSource: PluginWebURLSource = .webArea,
        pageFrameSource: PluginWebPageFrameSource = .webArea,
        watch: PluginProseWatchSchema = .init()
    ) {
        self.addressFieldLabel = addressFieldLabel
        self.addressFocusKey = addressFocusKey
        self.addressFocusModifiers = addressFocusModifiers
        self.backLabel = backLabel
        self.forwardLabel = forwardLabel
        self.reloadLabel = reloadLabel
        self.tabRole = tabRole
        self.windowTitleSuffix = windowTitleSuffix
        self.tabLabelSuffixSeparator = tabLabelSuffixSeparator
        self.urlSource = urlSource
        self.pageFrameSource = pageFrameSource
        self.watch = watch
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case addressFieldLabel
        case addressFocusKey
        case addressFocusModifiers
        case backLabel
        case forwardLabel
        case reloadLabel
        case tabRole
        case windowTitleSuffix
        case tabLabelSuffixSeparator
        case urlSource
        case pageFrameSource
        case watch
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        addressFieldLabel = try values.decode(String.self, forKey: .addressFieldLabel)
        addressFocusKey = try values.decodeIfPresent(
            PluginKey.self, forKey: .addressFocusKey) ?? .l
        addressFocusModifiers = try values.decodeIfPresent(
            [PluginKeyModifier].self, forKey: .addressFocusModifiers) ?? [.command]
        backLabel = try values.decode(String.self, forKey: .backLabel)
        forwardLabel = try values.decode(String.self, forKey: .forwardLabel)
        reloadLabel = try values.decode(String.self, forKey: .reloadLabel)
        tabRole = try values.decodeIfPresent(String.self, forKey: .tabRole)
        windowTitleSuffix = try values.decodeIfPresent(String.self, forKey: .windowTitleSuffix)
        tabLabelSuffixSeparator = try values.decodeIfPresent(
            String.self, forKey: .tabLabelSuffixSeparator)
        urlSource = try values.decodeIfPresent(
            PluginWebURLSource.self, forKey: .urlSource) ?? .webArea
        pageFrameSource = try values.decodeIfPresent(
            PluginWebPageFrameSource.self, forKey: .pageFrameSource) ?? .webArea
        watch = try values.decodeIfPresent(
            PluginProseWatchSchema.self, forKey: .watch) ?? .init()
    }
}
