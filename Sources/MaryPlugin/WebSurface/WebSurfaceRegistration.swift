//
//  WebSurfaceRegistration.swift
//  MaryPlugin
//
//  WHAT: One browser's declared shell, identity attached.
//  IN:   PluginWebSurfaceSchema  OUT: WebSurfaceSupport
//  PIN:  Twin of MediaSurfaceRegistration. The adapter learns that Safari calls its
//        back button "Go back" and Chrome calls it "Back" only because the packages
//        said so — no Swift file here names a browser.
//

import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

public struct WebSurfaceRegistration: Sendable, Equatable, SurfaceClaim {

    /// The package's logical id for the browser — `safari`, `shell`.
    public let applicationID: String
    public let bundleIdentifiers: [String]
    /// The process FAMILY, so Chrome Beta/Canary and Safari Technology Preview register.
    public let bundleIdentifierPrefix: String?
    public let displayName: String
    public let schema: PluginWebSurfaceSchema

    public init(
        applicationID: String,
        bundleIdentifiers: [String],
        bundleIdentifierPrefix: String? = nil,
        displayName: String,
        schema: PluginWebSurfaceSchema
    ) {
        self.applicationID = applicationID
        self.bundleIdentifiers = bundleIdentifiers
        self.bundleIdentifierPrefix = bundleIdentifierPrefix
        self.displayName = displayName
        self.schema = schema
    }

    /// Exact first, then the family — `MediaSurfaceRegistration`'s own two-tier rule.
    public func owns(bundleID: String) -> Bool {
        SurfaceClaimOwnership.exactThenFamily(
            bundleID: bundleID,
            identifiers: bundleIdentifiers,
            prefix: bundleIdentifierPrefix)
    }

    /// Which lane this browser's page content arrives on, if any AX lane does.
    /// Read from the machine layer's classifier, not declared: it is a fact about the
    /// binary on disk, and a package claiming otherwise would not change it.
    public func host(pid: pid_t) -> WebContentHost.Kind {
        WebContentHost.classify(pid: pid, bundleID: bundleIdentifiers.first)
    }

    // MARK: - Label matching

    static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func matches(_ label: String?, _ declared: String) -> Bool {
        guard let label else { return false }
        return Self.folded(label) == Self.folded(declared)
    }

    public func isBackLabel(_ label: String?) -> Bool { matches(label, schema.backLabel) }
    public func isForwardLabel(_ label: String?) -> Bool { matches(label, schema.forwardLabel) }
    public func isReloadLabel(_ label: String?) -> Bool { matches(label, schema.reloadLabel) }
    public func isAddressLabel(_ label: String?) -> Bool {
        matches(label, schema.addressFieldLabel)
    }

    /// A window title with the browser's own name trimmed off the end.
    ///
    /// Chrome appends " - Google Chrome" AND the profile name after it, so the suffix is
    /// matched as a prefix of the tail rather than as an exact ending.
    public func pageTitle(fromWindowTitle title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        guard let suffix = schema.windowTitleSuffix, !suffix.isEmpty,
              let range = title.range(of: suffix, options: [.backwards, .caseInsensitive])
        else { return title }
        let trimmed = String(title[title.startIndex..<range.lowerBound])
        return trimmed.isEmpty ? title : trimmed
    }

    /// A tab's own name, with whatever the browser bakes into the label removed.
    ///
    /// Chrome writes live memory usage into every tab's accessibility label
    /// ("GitLab - Memory usage - 455 MB"). That is the browser talking about itself, not
    /// the page's name, and speaking it back would be nonsense.
    public func tabTitle(fromLabel label: String) -> String {
        guard let separator = schema.tabLabelSuffixSeparator, !separator.isEmpty,
              let range = label.range(of: separator, options: [.backwards])
        else { return label }
        let trimmed = String(label[label.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? label : trimmed
    }
}
