//
//  SelectionSurfacePolicy.swift
//  MaryBrain
//
//  WHAT: Referencing a highlight vs mutating a text surface — separate abilities.
//  OUT:  ambient routing / keyboard typer
//  PIN:  Browser/article selection can inform an answer without becoming a write target.
//        Known canvas editors retain their explicit upgrade via registration.
//
import Foundation

public enum SelectionSurfacePolicy {

    /// Applications where synthesizing prose would be unsafe even if an AX element happens to
    /// report a selected range. TERMINALS ONLY, NOW.
    private static let blockedProseApplications: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    public static func permitsProseApplication(_ applicationID: String) -> Bool {
        applicationID != Bundle.main.bundleIdentifier
            && !blockedProseApplications.contains(applicationID)
            // BROWSERS ARE NOT CGEVENT TYPING SURFACES.
            && !AmbientPlaceResolver.isBrowser(bundleID: applicationID)
    }

    /// Pages and a manuscript application can render a canvas while omitting AXEditable.
    public static func isKnownProseEditor(_ applicationID: String) -> Bool {
        // NO COMPILED EDITORS. Two bundle ids used to be admitted before the roster was consulted
        // at all, which meant those two worked with no package installed and every other editor
        // had to earn it.
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
