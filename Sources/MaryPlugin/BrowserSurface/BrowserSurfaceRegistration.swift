//
//  BrowserSurfaceRegistration.swift
//  MaryPlugin
//
//  ONE BROWSER'S DECLARED COORDINATES, resolved for use.
//
//  `ProseSurfaceRegistration` and `MediaSurfaceRegistration`'s third sibling,
//  and deliberately their twin in shape: a package writes a `browserSurface`
//  block, the compiler pairs it with the application's identity, and
//  everything the compiled lane needs to drive that browser is in this value
//  — while nothing in the lane names the browser.
//
//  WHY A SEPARATE TYPE FROM THE SCHEMA, unchanged from the two lanes before
//  it: the schema is what an author writes and a validator admits; this is
//  what the runtime uses, with identity attached. A schema change cannot
//  silently alter runtime behaviour, and the mapping is one place with a test.
//

import Foundation
import MaryFoundation

public struct BrowserSurfaceRegistration: Sendable, Equatable {

    /// The package's logical id for the application.
    public let applicationID: String

    /// The bundle identifiers this browser answers to. PREFIX-matched at use,
    /// like every other browser question in the codebase, so a Beta, Canary
    /// or Technology Preview build rides its release build's declaration
    /// rather than needing one of its own.
    public let bundleIdentifiers: [String]

    /// What the user calls it.
    public let displayName: String

    /// The declared block, verbatim.
    public let schema: PluginBrowserSurfaceSchema

    public init(
        applicationID: String,
        bundleIdentifiers: [String],
        displayName: String,
        schema: PluginBrowserSurfaceSchema
    ) {
        self.applicationID = applicationID
        self.bundleIdentifiers = bundleIdentifiers
        self.displayName = displayName
        self.schema = schema
    }

    /// BY PREFIX, and this is the one place the browser lane differs from its
    /// two siblings. A prose or media application is matched by exact bundle
    /// id because there is no family; browsers ship channel variants under
    /// extended ids (`com.google.Chrome.canary`,
    /// `com.apple.SafariTechnologyPreview`) whose tab strips are their
    /// release build's. Exact matching would leave a beta user with a browser
    /// Mary can see and cannot drive.
    public func owns(bundleID: String) -> Bool {
        bundleIdentifiers.contains { declared in
            bundleID.lowercased().hasPrefix(declared.lowercased())
        }
    }
}
