//
//  ProseSurfaceWriter.swift
//  MaryPlugin
//
//  PUTTING NEW TEXT WHERE OLD TEXT WAS — the one write path the prose lane
//  has, for every application that declares a prose surface.
//
//  THE CONTRACT IT IMPLEMENTS is `PassageWriter`, and its three clauses were
//  each a bug before they were a rule: re-locate the passage in the string
//  THIS element just returned (never convert an offset that arrived from
//  somewhere else); refuse rather than guess when the passage is ambiguous;
//  and read back what actually landed rather than reporting what was sent.
//
//  THE LADDER, in order, and every rung is evidence-driven:
//
//    1. SELECT the located range, then SET the selected text. Two calls, and
//       the second is allowed to fail — a great many applications implement
//       the range setter and not the text setter, and for those the selection
//       is still the whole of the locating work.
//    2. KEYSTROKES into the selection the first rung landed. This inherits all
//       of the locating, and it lands in the application's OWN undo stack,
//       which is the thing a user reaches for when Mary gets it wrong.
//    3. Read back and compare. A write that cannot be verified is reported as
//       unverified, never as success.
//
//  THE BACKGROUND-WINDOW QUESTION, MEASURED AND ANSWERED — 2026-08-27,
//  TextEdit on macOS 26, via `mary-ax-probe --prose --write`.
//
//  Bonnie reached background windows through an application's scripting
//  layer, which addresses a window by id and needs no focus change. This lane
//  has none, so whether `kAXSelectedTextRange` and `kAXSelectedText` land in a
//  window that is NOT frontmost was an open question with a designed fallback
//  (raise, write, restore) waiting behind it.
//
//  THEY LAND. The probe seeded a scratch note, raised a different note over
//  it, wrote into the one behind, and read the new text back — `✓ via
//  setSelectedText`. So `raisesBackgroundWindows` stays FALSE: an edit to a
//  note the user is not looking at happens silently, which is what it should
//  do, and no window flashes forward for it.
//
//  THE FALLBACK STAYS, unexercised, because the measurement is about ONE
//  application. A prose surface is a family, and the next member may refuse
//  a background write; the flag is how that member ships without this file
//  changing. Do not delete it on the strength of one green probe.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

public struct ProseSurfaceWriter: PassageWriter {

    public let registration: ProseSurfaceRegistration

    /// Whether a write to a background window must raise it first.
    ///
    /// Nil means "not yet decided" and behaves as false — attempt the write
    /// where the document is, and let the read-back catch a silent no-op.
    /// The probe sets this deliberately once measured; nothing infers it.
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

        // THE DOCUMENT THIS SNAPSHOT IS ABOUT, not whatever is in front now.
        // A snapshot carries the key it was read from; between reading and
        // writing the user may have switched windows, and writing into the
        // new front one would be an edit to a document nobody named.
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
            // The selection above already landed; typing replaces it
            // wherever it is, which is why the fallback needs no locating of
            // its own — and why it lands in the application's own undo stack.
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
            // HONEST ABOUT VERIFICATION. `readBack` is false when the element
            // would not hand its text back afterwards — the write may well
            // have landed, and a receipt claiming it was verified when
            // nothing was read is the one lie the runner cannot catch.
            readBack: after != nil,
            method: method)
    }

    private func runningPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first { application in
            application.bundleIdentifier.map(registration.owns) ?? false
        }?.processIdentifier
    }
}

/// Why a prose write could not happen. Every case is a sentence the user
/// hears, so each names the condition and stops — no case suggests a Skill,
/// because a refusal that reads as an errand sends the model back around the
/// loop it was refused in.
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
