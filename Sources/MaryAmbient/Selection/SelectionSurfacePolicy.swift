//
//  SelectionSurfacePolicy.swift
//  MaryBrain
//
//  Referencing a highlight and mutating a text surface are separate abilities.
//  This small policy is shared by ambient routing and the keyboard typer so a
//  browser/article selection can inform an answer without ever becoming a
//  write target, while known canvas editors retain their explicit upgrade.
//

import Foundation

public enum SelectionSurfacePolicy {

    /// Applications where synthesizing prose would be unsafe even if an AX
    /// element happens to report a selected range.
    private static let blockedProseApplications: Set<String> = [
        WorkspaceApplicationIdentity.xcode,
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    public static func permitsProseApplication(_ applicationID: String) -> Bool {
        applicationID != Bundle.main.bundleIdentifier
            && !blockedProseApplications.contains(applicationID)
            // BROWSERS ARE NOT CGEVENT TYPING SURFACES. The web writers own
            // browser prose: they scope to the page's web area (the URL bar
            // is unreachable), verify focus by reading it back, paste rather
            // than type (canvas editors auto-format synthetic keystrokes),
            // and produce honest receipts. Letting type_at_cursor resolve a
            // browser would spray keystrokes past every one of those guards.
            // Browser selections stay REFERABLE — referencing is a separate
            // ability, exactly this file's header.
            && !AmbientRealmResolver.isBrowser(bundleID: applicationID)
    }

    /// Pages and a manuscript application can render a canvas while omitting
    /// AXEditable; their representations are the explicit evidence that this
    /// unknown AX surface is still an ordinary prose editor. Unknown
    /// third-party surfaces remain referable but not keyboard-writable until
    /// AX declares them editable or a representation supplies an equivalent
    /// verifier.
    ///
    /// THE REGISTRATION IS THAT EQUIVALENT VERIFIER, which this function's own
    /// comment has sanctioned since it was written. The rung is deliberately
    /// narrow: a registration qualifies only when it earned EYES and realizes
    /// WRITING — a package that merely declares aliases cannot talk its way
    /// into having keystrokes sprayed at an unknown surface.
    public static func isKnownProseEditor(_ applicationID: String) -> Bool {
        if applicationID == WorkspaceApplicationIdentity.pages { return true }
        if applicationID == WorkspaceApplicationIdentity.textEdit { return true }
        guard let registration = AmbientApplicationIndexProvider.current
            .registration(bundleID: applicationID)
        else { return false }
        return registration.hasEyes && registration.place.focus == .writing
    }

    public static func isWritableProseSurface(
        applicationID: String,
        editability: AmbientSelectionEditability
    ) -> Bool {
        guard permitsProseApplication(applicationID) else { return false }
        switch editability {
        case .editable:
            return true
        case .readOnly:
            return false
        case .unknown:
            return isKnownProseEditor(applicationID)
        }
    }
}
