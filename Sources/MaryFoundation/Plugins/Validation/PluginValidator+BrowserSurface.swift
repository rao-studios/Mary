//
//  PluginValidator+BrowserSurface.swift
//  MaryFoundation
//
//  THE BROWSER-SURFACE DECLARATION'S BOUNDS.
//
//  Nothing here reads a screen — the declaration is coordinates, so what can
//  be checked is whether they are WELL FORMED and whether they are INTERNALLY
//  CONSISTENT. Whether they match the browser is a live question, and the
//  probe is where it is asked.
//
//  CONSISTENCY IS THE WHOLE JOB HERE, and it is worth more than it sounds.
//  Three of these fields only mean something in combination — a close
//  affordance that needs a label, a selection signal that promises an
//  attribute, an ordinal fallback that contradicts a pressable strip. Each
//  inconsistent pair produces a browser that is READ correctly and ACTED ON
//  wrongly, which is the failure shape this lane is least able to notice at
//  runtime: the roster looks right, and the press goes nowhere.
//

import Foundation

public extension PluginValidator {

    /// An Accessibility role is an identifier, not a sentence. Bounding the
    /// length is not about memory; it is that a role longer than this is
    /// something other than a role, and failing here says so while failing at
    /// read time says only "no strip found".
    static let maximumBrowserRoleCharacters = 64

    static func validateBrowserSurface(
        _ surface: PluginBrowserSurfaceSchema,
        root: String,
        error: (String, String, String) -> Void
    ) {
        func checkRole(_ value: String, _ field: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                error(
                    "empty-browser-role",
                    "\(root).browserSurface.\(field)",
                    "An Accessibility role cannot be blank: the strip search would match every element it walked.")
            } else if trimmed.count > maximumBrowserRoleCharacters {
                error(
                    "oversized-browser-role",
                    "\(root).browserSurface.\(field)",
                    "An Accessibility role may be at most \(maximumBrowserRoleCharacters) characters.")
            } else if trimmed != value {
                // Surrounding whitespace never matches, and the failure it
                // produces is "no tab strip" — which reads as the browser's
                // fault rather than the declaration's.
                error(
                    "padded-browser-role",
                    "\(root).browserSurface.\(field)",
                    "An Accessibility role must carry no surrounding whitespace: it is compared exactly.")
            }
        }

        checkRole(surface.tabStripRole, "tabStripRole")
        checkRole(surface.tabRole, "tabRole")
        if let subrole = surface.tabStripSubrole { checkRole(subrole, "tabStripSubrole") }

        // A STRIP THAT IS ITS OWN TAB cannot be walked: the search looks for a
        // container holding children of `tabRole`, and a container whose role
        // IS `tabRole` would match itself and publish nothing.
        if surface.tabStripRole == surface.tabRole {
            error(
                "browser-strip-is-its-own-tab",
                "\(root).browserSurface.tabRole",
                "The tab strip and a tab cannot share a role: the strip is found by holding children of the tab role.")
        }

        switch surface.closeAffordance {
        case .childButton, .elementAction:
            // BOTH OF THESE ARE FOUND BY NAME, so neither works without one.
            // The measured browsers name them differently ("Close" as a child
            // button, "close tab" as an action), which is exactly why the
            // label is declared rather than assumed — and why omitting it has
            // to be an error rather than a default.
            if surface.closeControlLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty != false {
                error(
                    "missing-browser-close-label",
                    "\(root).browserSurface.closeControlLabel",
                    "A \(surface.closeAffordance.rawValue) close affordance is located by its label, so the label must be declared.")
            }
        case .chordOnly:
            // Harmless but meaningless, and a package saying two things about
            // how it closes a tab is a package whose author believed one of
            // them was doing something.
            if surface.closeControlLabel != nil {
                error(
                    "unused-browser-close-label",
                    "\(root).browserSurface.closeControlLabel",
                    "A chordOnly close affordance presses no control, so a close label would never be read.")
            }
        }
    }
}
