//
//  FrontmostGuard.swift
//  MaryComputerUse
//
//  WHAT: Is the application a keystroke is FOR the one in front? One answer for
//        the typer and the chord.
//  IN:   a target bundle-id prefix, and a frontmost read
//  OUT:  KeyboardTyper / KeyChordPress
//  PIN:  ONE GUARD, NOT FOUR. The same test — frontmost bundle id has the
//        target's prefix — was written in the typer's run, its delete, and the
//        chord, and had already drifted once: the chord checked nothing until a
//        corpus run sent ⌘L to whatever had the stage. A guard that lives in one
//        place cannot drift.
//        A PREFIX, BECAUSE A FAMILY IS ONE APPLICATION TO THE PERSON. A beta and
//        a stable build share a prefix; a helper process does too, but a helper
//        is never frontmost, so the prefix test is exact in practice.
//        NIL MEANS ANYWHERE, ON PURPOSE. A caller with no application in mind —
//        a system chord, a media key — is not made to invent one.
//

import AppKit
import Foundation

public enum FrontmostGuard {

    public enum Verdict: Equatable {
        /// The target is in front, or nothing was asked.
        case clear
        /// Somebody else is, and this is who.
        case lost(frontmost: String?)
    }

    /// The live frontmost bundle id — the default `frontmost` every caller shares.
    @Sendable public static func liveFrontmost() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    public static func check(
        targetPrefix: String?,
        frontmost: () -> String?
    ) -> Verdict {
        guard let targetPrefix, !targetPrefix.isEmpty else { return .clear }
        let front = frontmost()
        guard front?.hasPrefix(targetPrefix) == true else { return .lost(frontmost: front) }
        return .clear
    }
}
