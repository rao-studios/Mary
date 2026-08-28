//
//  WebCanvasSupport.swift
//  MaryPlugin
//
//  THE ROSTER OF DECLARED WEB CANVASES.
//
//  The same frozen-swap registry the three application surfaces use, for the
//  fourth kind of declared place — one that lives on the web rather than on
//  the machine. Reconciled wholesale on every package activation: a package
//  that stops declaring a canvas must stop having one.
//
//  RESOLUTION IS BY NAME OR BY BEING THE ONLY ONE, which is the media lane's
//  rule rather than the browser lane's. A browser is resolved by what the
//  user is looking at; a web canvas is not a place anyone is looking at until
//  Mary opens it, so focus has nothing to say. With one canvas installed the
//  distinction is invisible; with two it is the difference between opening
//  the one the user meant and opening whichever sorted first.
//

import Foundation
import MaryFoundation
import os

public struct WebCanvasRegistration: Sendable, Equatable {
    /// The package that declared it — its ability id, which is what a user
    /// would name ("shaderfeel").
    public let canvasID: String
    /// What the user calls it out loud.
    public let displayName: String
    public let schema: WebCanvasSchema

    public init(canvasID: String, displayName: String, schema: WebCanvasSchema) {
        self.canvasID = canvasID
        self.displayName = displayName
        self.schema = schema
    }
}

public final class WebCanvasSupport: @unchecked Sendable {

    public static let shared = WebCanvasSupport()

    private let box = OSAllocatedUnfairLock<[String: WebCanvasRegistration]>(
        initialState: [:])

    public init() {}

    public func reconcile(_ registrations: [WebCanvasRegistration]) {
        let map = Dictionary(
            registrations.map { ($0.canvasID, $0) },
            uniquingKeysWith: { first, _ in first })
        box.withLock { $0 = map }
    }

    public func all() -> [WebCanvasRegistration] {
        box.withLock { Array($0.values) }.sorted { $0.canvasID < $1.canvasID }
    }

    /// The canvas a request addresses.
    ///
    /// NAMED FIRST, THEN THE SOLE ONE, and NIL when two are installed and
    /// nothing said which — the same refusal-over-guess rule the browser
    /// ladder uses, for the same reason: picking is right half the time and
    /// is never questioned.
    public func resolve(_ named: String?) -> WebCanvasRegistration? {
        let installed = all()
        if let named, !named.isEmpty {
            return installed.first {
                $0.canvasID.caseInsensitiveCompare(named) == .orderedSame
                    || $0.displayName.caseInsensitiveCompare(named) == .orderedSame
            }
        }
        return installed.count == 1 ? installed[0] : nil
    }
}
