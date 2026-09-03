//
//  ProseSurfaceWriter.swift
//  MaryPlugin
//
//  WHAT: PassageWriter for declared prose — relocate, set selection, read back.
//  OUT:  PassageEditRunner APPLY
//  PIN:  Background windows: setSelectedText lands; raisesBackgroundWindows stays false.

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

public struct ProseSurfaceWriter: PassageWriter {

    public let registration: ProseSurfaceRegistration

    /// Whether a write to a background window must raise it first. Nil means "not yet
    /// decided" and behaves as false.
    public let raisesBackgroundWindows: Bool

    public init(
        registration: ProseSurfaceRegistration,
        raisesBackgroundWindows: Bool = false
    ) {
        self.registration = registration
        self.raisesBackgroundWindows = raisesBackgroundWindows
    }

    public func replace(
        _ passageText: String,
        with replacement: String,
        hint: Range<Int>,
        in snapshot: BodySnapshot
    ) async throws -> WriteReceipt {
        guard let pid = runningPID() else {
            throw PassageWriteFailure.applicationUnavailable(registration.displayName)
        }

        // The document this snapshot is about, not whatever is in front now.
        let surfaces = ProseSurfaceAX.surfaces(pid: pid, registration: registration)
        guard let surface = surfaces.first(where: { $0.documentKey == snapshot.documentKey })
        else {
            throw PassageWriteFailure.documentMoved(snapshot.documentTitle)
        }

        // RE-READ, ALWAYS. The snapshot may be seconds old and the user types
        // faster than that; every offset below is into THIS string.
        guard let live = ProseSurfaceAX.fullString(of: surface.editor) else {
            throw PassageWriteFailure.unreadable(registration.displayName)
        }

        let candidate = ProseTextCandidate(resolution: .mainWindowDescent, text: live)
        switch ProseWriteLocator.choose(
            among: [candidate], passageText: passageText, hint: hint
        ) {
        case .refused(let refusal):
            // EXHAUSTIVE, so a refusal added to the locator cannot reach the
            // user as a generic failure. Each arm names the condition and
            // stops.
            switch refusal {
            case .accessibilityBlocked:
                throw PassageWriteFailure.unreadable(registration.displayName)
            case .noTextElement, .notFound:
                throw PassageWriteFailure.notFound(snapshot.documentTitle)
            case .ambiguous:
                throw PassageWriteFailure.ambiguous(snapshot.documentTitle)
            case .selectionRefused, .timedOut:
                throw PassageWriteFailure.selectionRefused(snapshot.documentTitle)
            }
        case .chosen(let target):
            return try await write(
                replacement, into: surface, at: target.range, wasFrontmost: surface.ordinal == 1)
        }
    }

    // MARK: - The write

    private func write(
        _ replacement: String,
        into surface: ProseSurfaceAX.Surface,
        at range: Range<Int>,
        wasFrontmost: Bool
    ) async throws -> WriteReceipt {
        if raisesBackgroundWindows, !wasFrontmost {
            ProseSurfaceAX.raise(surface.window)
            // A raise is asynchronous in the window server; a write issued in
            // the same runloop turn can beat the focus change.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        guard ProseSurfaceAX.select(range, in: surface.editor) == .success else {
            throw PassageWriteFailure.selectionRefused(surface.title)
        }

        var method: PassageWriteMethod = .accessibility
        if ProseSurfaceAX.setSelectedText(replacement, in: surface.editor) != .success {
            // RUNG 2. Not an error — see the ladder in the file header.
                        let typed = await KeyboardTyper.typeIntoSelection(
                replacement, targetPrefix: registration.bundleIdentifiers.first ?? "")
            guard typed else {
                throw PassageWriteFailure.writeRefused(surface.title)
            }
            method = .keystrokes
        }

        // RUNG 3. What actually landed, from the same element.
        let after = ProseSurfaceAX.fullString(of: surface.editor)
        return WriteReceipt(
            appliedRange: after == nil
                ? nil
                : range.lowerBound..<(range.lowerBound + replacement.utf16.count),
            newBodyHash: after.map(ContentUndoStore.hash),
            newBody: after,
            // HONEST ABOUT VERIFICATION. `readBack` is false when the element would not
            // hand its text back afterwards.
            readBack: after != nil,
            method: method)
    }

    private func runningPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first { application in
            application.bundleIdentifier.map(registration.owns) ?? false
        }?.processIdentifier
    }
}

/// Why a prose write could not happen. Every case is a sentence the user hears, so each
/// names the condition and stops.
public enum PassageWriteFailure: Error, Sendable, Equatable {
    case applicationUnavailable(String)
    case documentMoved(String)
    case unreadable(String)
    case notFound(String)
    case ambiguous(String)
    case selectionRefused(String)
    case writeRefused(String)

    public var spoken: String {
        switch self {
        case .applicationUnavailable(let app):
            return "\(app) isn't running, so there's nothing to write into."
        case .documentMoved(let title):
            return "\"\(title)\" isn't open any more — it closed or moved since I read it."
        case .unreadable(let app):
            return "I couldn't read \(app)'s text just now."
        case .notFound(let title):
            return "I couldn't find that passage in \"\(title)\" any more."
        case .ambiguous(let title):
            return "That passage appears more than once in \"\(title)\" and I can't tell which you mean."
        case .selectionRefused(let title):
            return "\"\(title)\" wouldn't let me select the passage, so I left it alone."
        case .writeRefused(let title):
            return "\"\(title)\" wouldn't take the change, so nothing was altered."
        }
    }
}
