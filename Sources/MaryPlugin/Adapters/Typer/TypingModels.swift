//
//  TypingModels.swift
//  MaryPlugin
//
//  WHAT: TypingSurface and the resolve ladder for type_at_cursor.
//  IN:   TyperPlugin.swift (sibling split)
//  OUT:  TyperPlugin+Typing / StagedWritingSurface / AmbientApplicationIndex
//  PIN:  No compiled TypingTarget enum — taughtSurface(named:) asks the roster.
//

import AppKit
import Foundation
import MaryComputerUse
import os

// PIN: no compiled TypingTarget. taughtSurface(named:) is the ladder rung.

/// Concrete text surface a typing run owns. Chosen from taught / staged / frontmost / selection.
struct TypingSurface: Sendable, Equatable {
    /// Value-typed running-app slice for selection-source resolution. Testable without AppKit.
    struct RunningApplication: Sendable, Equatable {
        let bundleID: String
        let spokenName: String?

        init(bundleID: String, spokenName: String? = nil) {
            self.bundleID = bundleID
            self.spokenName = spokenName
        }

        init?(_ app: NSRunningApplication) {
            guard let bundleID = app.bundleIdentifier else { return nil }
            self.init(bundleID: bundleID, spokenName: app.localizedName)
        }
    }

    let bundleID: String
    let matchPrefix: String
    let spokenName: String

    init(bundleID: String, matchPrefix: String? = nil, spokenName: String?) {
        self.bundleID = bundleID
        self.matchPrefix = matchPrefix ?? bundleID
        self.spokenName = spokenName.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID
    }

    /// Exact bundle id, then family prefix (ApplicationRegistration.isInFamily).
    var isRunning: Bool {
        Self.isRunning(
            bundleID: bundleID,
            matchPrefix: matchPrefix,
            runningBundleIdentifiers: NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier))
    }

    /// Exact-then-family, without a live process.
    static func isRunning(
        bundleID: String,
        matchPrefix: String,
        runningBundleIdentifiers: [String]
    ) -> Bool {
        let bundleID = bundleID.lowercased()
        let matchPrefix = matchPrefix.lowercased()
        if runningBundleIdentifiers.contains(where: { $0.lowercased() == bundleID }) {
            return true
        }
        return runningBundleIdentifiers.contains {
            ApplicationRegistration.isInFamily($0.lowercased(), prefix: matchPrefix)
        }
    }

    /// Ordinary writing only. Code path owns Xcode; terminals stay out.
    static func canReceiveProse(bundleID: String) -> Bool {
        SelectionSurfacePolicy.permitsProseApplication(bundleID)
    }

    /// Resolve in safety order: named taught (may activate) → unique running
    /// name → staged → selection owner → frontmost. Else refuse.
    /// PIN: staged outranks turn-start attention (preferredApplicationID is stale).
    static func resolve(
        requested: String?,
        preferredApplicationID: String?,
        frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        runningApplications suppliedApplications: [RunningApplication]? = nil,
        staged: StagedWritingSurface.Staged? = StagedWritingSurface.shared.fresh()
    ) -> TypingSurface? {
        let applications = suppliedApplications ?? NSWorkspace.shared.runningApplications
            .compactMap(RunningApplication.init)
        let frontmostApplication = frontmost.flatMap(RunningApplication.init)
        let stagedSurface: TypingSurface? = staged.flatMap { staged in
            guard canReceiveProse(bundleID: staged.bundleID),
                  let app = applications.first(where: { $0.bundleID == staged.bundleID })
            else { return nil }
            return TypingSurface(
                bundleID: staged.bundleID, spokenName: staged.spokenName ?? app.spokenName)
        }
        // Only rung that may activate. Eyes + writing discipline (SelectionSurfacePolicy).
        if let requested, let taught = taughtSurface(named: requested) {
            return taught
        }

        if let requested {
            let matches = applications.filter { app in
                canReceiveProse(bundleID: app.bundleID) && names(app, requested: requested)
            }
            if matches.count == 1, let app = matches.first {
                return TypingSurface(bundleID: app.bundleID, spokenName: app.spokenName)
            }
            // Zero matches + staged: the "app" was a document title. Two matches refuse.
            if matches.isEmpty, let stagedSurface { return stagedSurface }
            return nil
        }

        if let stagedSurface { return stagedSurface }

        if let preferredApplicationID,
           canReceiveProse(bundleID: preferredApplicationID),
           let app = applications.first(where: { $0.bundleID == preferredApplicationID }) {
            return TypingSurface(bundleID: preferredApplicationID, spokenName: app.spokenName)
        }

        if let frontmostApplication,
           canReceiveProse(bundleID: frontmostApplication.bundleID) {
            return TypingSurface(
                bundleID: frontmostApplication.bundleID, spokenName: frontmostApplication.spokenName)
        }

        // PIN: no one-known-app fallback over an open roster.
        return nil
    }

    /// Taught writing app the user named — may bring forward. Nil unless
    /// roster + eyes + writing + exact bundle id (a family prefix cannot activate).
    static func taughtSurface(named requested: String) -> TypingSurface? {
        let asked = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return nil }
        let roster = AmbientApplicationIndexProvider.current
        let registration = roster.registration(id: asked)
            ?? roster.all.first { $0.profile.isMentioned(in: asked) }
        guard let registration,
              registration.hasEyes,
              registration.place.focus == .writing,
              let bundleID = registration.bundleIdentifiers.sorted().first
        else { return nil }
        // Carry the family prefix, not just the declared id. See isRunning.
        return TypingSurface(
            bundleID: bundleID,
            matchPrefix: registration.bundleIdentifierPrefix ?? bundleID,
            spokenName: registration.displayName)
    }

    private static func names(_ app: RunningApplication, requested: String) -> Bool {
        let requested = normalized(requested)
        guard !requested.isEmpty else { return false }
        return [app.spokenName, app.bundleID]
            .compactMap { $0 }
            .map(normalized)
            .contains(requested)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
