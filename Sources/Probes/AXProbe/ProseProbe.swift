//
//  ProseProbe.swift
//  AXProbe
//
//  WHAT: Prose lane read/write against a real editor (incl. background window).
//  OUT:  CLI: mary-ax-probe --prose [--write]
//  PIN:  --write only touches a scratch note this run created.
//

import AppKit
import ApplicationServices
import Foundation
import MaryPlugin
import MaryAmbient
import MaryComputerUse
import MaryFoundation

enum ProseProbe {

    static func shouldRun(_ arguments: [String]) -> Bool { arguments.contains("--prose") }

    /// TextEdit-shaped registration built in-probe (fields a package will declare).
    static func textEditRegistration() -> ProseSurfaceRegistration {
        ProseSurfaceRegistration(
            applicationID: "textedit",
            bundleIdentifiers: ["com.apple.TextEdit"],
            displayName: "TextEdit",
            schema: PluginProseSurfaceSchema(
                handlePrefix: "W",
                editorRoles: [.textArea],
                grammar: .prose,
                documentKey: .documentPathThenWindow,
                documentNoun: .init(singular: "note", plural: "notes"),
                chords: [.newDocument: .init(key: .n, modifiers: [.command])],
                watch: .init(activeSeconds: 2.5, idleSeconds: 10),
                budgets: .init()))
    }

    static func run(_ arguments: [String]) async {
        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted — see the note in main.swift.")
            exit(1)
        }
        let registration = textEditRegistration()
        guard let pid = ProseSurfaceSupport.pid(of: registration) else {
            print("TextEdit isn't running. Open it and try again.")
            exit(1)
        }
        print("▸ \(registration.displayName) (pid \(pid))")

        // MARK: Reading

        let started = Date()
        let surfaces = ProseSurfaceAX.surfaces(pid: pid, registration: registration)
        let walked = Date().timeIntervalSince(started)
        print("""

          roster      \(surfaces.count) \(registration.noun.plural) · \
        \(String(format: "%.0f", walked * 1000)) ms
        """)
        for surface in surfaces.prefix(8) {
            let text = ProseSurfaceAX.fullString(of: surface.editor) ?? ""
            let firstLine = text.split(
                separator: "\n", omittingEmptySubsequences: false).first ?? ""
            print("""
                [\(registration.handlePrefix)\(surface.ordinal)] \(surface.title) \
            — \(text.count) characters
                     key: \(surface.documentKey)
                     first line: \(firstLine.prefix(60))
            """)
        }
        guard !surfaces.isEmpty else {
            print("\nNo \(registration.noun.plural) open — nothing to read.")
            exit(0)
        }

        guard arguments.contains("--write") else {
            print("""

            Read-only. Add --write to measure the write ladder, including the
            question this probe exists for: does a write reach a BACKGROUND
            window, or must it be raised first?
            """)
            exit(0)
        }

        // MARK: Writing — on a note this probe makes

        print("\n▸ making a scratch note (⌘N)")
        let before = Set(surfaces.map { $0.documentKey })
        let activation = await VerifiedActivation.bringForward(pid: pid)
        guard activation.succeeded else {
            print("  couldn't bring TextEdit forward: "
                + (activation.reason(app: "TextEdit") ?? "refused"))
            exit(1)
        }
        guard KeyChordPress.press(key: .n, modifiers: [.command]) else {
            print("  ⌘N could not be posted")
            exit(1)
        }

        var scratch: ProseSurfaceAX.Surface?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, scratch == nil {
            scratch = ProseSurfaceAX.surfaces(pid: pid, registration: registration)
                .first { !before.contains($0.documentKey) }
            if scratch == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard let scratch else {
            print("  no new note appeared — the chord did not take")
            exit(1)
        }
        print("  made \"\(scratch.title)\"  key: \(scratch.documentKey)")

        // Seed it, so there is something to locate and replace.
        let seed = "Alpha one.\n\nBravo two.\n\nCharlie three."
        _ = ProseSurfaceAX.select(0..<0, in: scratch.editor)
        let seeded = ProseSurfaceAX.setSelectedText(seed, in: scratch.editor)
        print("  seed via setSelectedText: \(seeded == .success ? "✓" : "✗ (\(seeded.rawValue))")")
        if seeded != .success {
            _ = await KeyboardTyper.typeIntoSelection(seed, targetPrefix: "com.apple.TextEdit")
            print("  seeded by keystrokes instead")
        }

        // MARK: The foreground write

        print("\n▸ foreground write")
        report(await write("Bravo two.", to: "BRAVO REPLACED.", in: scratch, pid: pid,
                           registration: registration))

        // MARK: THE QUESTION — a write to a window that is not in front

        print("\n▸ background write (the decision gate)")
        guard surfaces.count >= 1 else {
            print("  need another note open to push the scratch one behind — skipped")
            exit(0)
        }
        // Bring a DIFFERENT note forward, leaving the scratch note behind it.
        if let other = surfaces.first {
            ProseSurfaceAX.raise(other.window)
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("  raised \"\(other.title)\" — the scratch note is now behind it")
        }
        let background = await write(
            "Charlie three.", to: "CHARLIE REPLACED.", in: scratch, pid: pid,
            registration: registration)
        report(background)

        print("""

        ── THE VERDICT ──────────────────────────────────────────────
        \(background.landed
            ? """
              A background write LANDED. `ProseSurfaceWriter` keeps
              `raisesBackgroundWindows: false` — edits to notes the user is
              not looking at happen silently, which is what they should do.
              """
            : """
              A background write did NOT land. Ship `ProseSurfaceWriter` with
              `raisesBackgroundWindows: true`: raise, write, restore. The user
              sees a window come forward for each such edit, which is worse
              than silence and much better than an edit that goes nowhere —
              or worse, into whatever was in front.
              """)
        ─────────────────────────────────────────────────────────────
        """)
        exit(0)
    }

    // MARK: - One write, measured

    struct Attempt {
        var landed: Bool
        var method: String
        var detail: String
    }

    static func write(
        _ passage: String, to replacement: String,
        in surface: ProseSurfaceAX.Surface, pid: pid_t,
        registration: ProseSurfaceRegistration
    ) async -> Attempt {
        guard let live = ProseSurfaceAX.fullString(of: surface.editor) else {
            return Attempt(landed: false, method: "—", detail: "could not read the note")
        }
        let candidate = ProseTextCandidate(resolution: .mainWindowDescent, text: live)
        guard case .chosen(let target) = ProseWriteLocator.choose(
            among: [candidate], passageText: passage, hint: 0..<0)
        else {
            return Attempt(landed: false, method: "—", detail: "locator refused")
        }

        let selected = ProseSurfaceAX.select(target.range, in: surface.editor)
        guard selected == .success else {
            return Attempt(
                landed: false, method: "select",
                detail: "kAXSelectedTextRange refused (\(selected.rawValue))")
        }
        var method = "setSelectedText"
        let set = ProseSurfaceAX.setSelectedText(replacement, in: surface.editor)
        if set != .success {
            method = "keystrokes"
            _ = await KeyboardTyper.typeIntoSelection(replacement, targetPrefix: "com.apple.TextEdit")
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let after = ProseSurfaceAX.fullString(of: surface.editor) ?? ""
        return Attempt(
            landed: after.contains(replacement),
            method: method,
            detail: after.contains(replacement)
                ? "read back the new text"
                : "the note does not contain the replacement")
    }

    static func report(_ attempt: Attempt) {
        print("  \(attempt.landed ? "✓" : "✗")  via \(attempt.method) — \(attempt.detail)")
    }
}
