//
//  ApplicationMenuDriver.swift
//  MaryPlugin
//
//  WALKING AN APPLICATION'S MENU BAR — the verbs no chord can reach.
//
//  A RE-FOUNDING, NOT A PORT. The predecessor drove menus by asking System
//  Events to click them, which is an Apple Event, which Mary does not send.
//  What survives is the DOCTRINE — check every level, name the level that was
//  missing, never guess past a gap — and the mechanism is the menu bar's own
//  accessibility tree.
//
//  WHY THIS EXISTS AT ALL, when the recipe grammar already presses chords. A
//  chord is one keystroke to one command, and it works only for commands the
//  application gave a shortcut. The interesting structural verbs mostly have
//  none: "Move To" opens onto a submenu built from the user's own project at
//  runtime, and no keystroke can name a folder created this morning. Menus
//  are how an application exposes what it can do; a chord is a shortcut past
//  the exposure, and where there is no shortcut there is still a menu.
//
//  EVERY LEVEL IS CHECKED, and the failure names the level that was missing.
//  A path is a claim about another program's menus, and that program is free
//  to rename, reorder or localize them between releases — so "Documents →
//  Move To → Drafts" failing must say WHICH of the three was not there. The
//  difference matters: a missing leaf is usually the user's project not
//  having that folder, a missing middle is usually a version change, and a
//  missing top is usually the wrong application.
//
//  LOCALIZATION IS AN HONEST FAILURE, not a silent one. Menu titles come from
//  a package, so they are in whatever language the author wrote them, and a
//  Mary running in French will find no "Documents" menu. That reports as
//  `missingItem("Documents")` — which is exactly what happened, said plainly,
//  and it is repairable by editing a declaration rather than a binary.
//
//  MEASURED 2026-08-28 against Scrivener 3 with a real project open
//  (`mary-corpus-probe menus`), and the first run settled a question the
//  predecessor recorded as open and could not answer:
//
//    • `Documents → Status` and `Documents → Label` DO NOT EXIST. The
//      predecessor searched for both, found neither, and could not tell
//      absence from unavailability because its probe ran with no project
//      open. With one open the answer is the same: the Documents menu holds
//      eighteen items and neither is among them. Status and Label are set in
//      the Inspector panel, which is not a menu at all — so a ceremony
//      declared through those paths could never have worked, and the honest
//      response is not to declare one.
//    • `Documents → Move To`, `Documents → Move to Trash`,
//      `Project → New Text` and `Project → New Folder` all exist.
//    • DISABLED IS COMMON AND IS NOT MISSING. "Move to Trash" and "Split → at
//      Selection" are both present and both greyed out with nothing selected,
//      which is why `itemDisabled` is its own case: "your version doesn't
//      have that" and "select something first" are different sentences.
//

import AppKit
import ApplicationServices
import Foundation

public enum ApplicationMenuDriver {

    public enum Failure: Error, Equatable, Sendable {
        case notRunning
        /// No menu bar at all — the process is up but has published nothing.
        case noMenuBar
        /// A level of the path was not there. Carries the TITLE that was
        /// looked for and the path that reached it.
        case missingItem(String, inPath: [String])
        /// The item is there and the application says it cannot be used right
        /// now — greyed out. A real and common answer: "Move To" is disabled
        /// with nothing selected.
        case itemDisabled(String)
        /// The item was found, enabled, and did not respond to being pressed.
        case pressRefused(String)

        public func spoken(app: String) -> String {
            switch self {
            case .notRunning:
                return "\(app) isn't running."
            case .noMenuBar:
                return "\(app) isn't showing its menus, so I couldn't reach that command."
            case .missingItem(let title, let path):
                return path.isEmpty
                    ? "\(app) has no \(title) menu."
                    : "I couldn't find \(title) under \(path.joined(separator: " → ")) in \(app)."
            case .itemDisabled(let title):
                return "\(app)'s \(title) command is greyed out just now."
            case .pressRefused(let title):
                return "\(app) didn't respond when I chose \(title)."
            }
        }
    }

    /// Menu bars are shallow and wide; this bounds a pathological one without
    /// coming near a real menu's size.
    static let budget = AXTreeWalker.Budget(maxDepth: 4, maxNodes: 400)

    // MARK: - Choosing

    /// Walk a titled path from the menu bar and press its leaf.
    ///
    /// THE CALLER OWNS THE FOREGROUND. A menu bar belongs to the frontmost
    /// application, so choosing a command in a background app reaches the
    /// wrong menus — `VerifiedActivation` first, always.
    @discardableResult
    public static func choose(
        path: [String], pid: pid_t
    ) async -> Result<Void, Failure> {
        guard !path.isEmpty else { return .failure(.noMenuBar) }
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false
        else { return .failure(.notRunning) }

        switch locate(path: path, pid: pid) {
        case .failure(let failure): return .failure(failure)
        case .success(let item):
            guard AX.number(item, kAXEnabledAttribute)?.boolValue != false else {
                return .failure(.itemDisabled(path[path.count - 1]))
            }
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            else { return .failure(.pressRefused(path[path.count - 1])) }
            // A menu command runs on the next pass of the application's own
            // run loop; returning before it has is how a caller's verify beat
            // races the change it is verifying.
            try? await Task.sleep(for: .milliseconds(250))
            return .success(())
        }
    }

    /// Find the element a path names, without pressing it. Public because
    /// "does this application offer this command" is a real question — a
    /// package can declare a path the installed version does not have, and
    /// finding out before acting is better than finding out after.
    public static func locate(
        path: [String], pid: pid_t
    ) -> Result<AXUIElement, Failure> {
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = AX.element(application, kAXMenuBarAttribute) else {
            return .failure(.noMenuBar)
        }

        var container = menuBar
        var reached: [String] = []
        for title in path {
            guard let match = child(of: container, titled: title) else {
                return .failure(.missingItem(title, inPath: reached))
            }
            reached.append(title)
            // A menu bar item and a submenu item both hold their contents in
            // an AXMenu CHILD rather than directly — so descending means
            // stepping through that wrapper. The last level has no wrapper to
            // step into and is the item itself.
            if title == path[path.count - 1] {
                return .success(match)
            }
            guard let submenu = AX.children(match).first(where: {
                AX.string($0, kAXRoleAttribute) == kAXMenuRole as String
            }) else {
                return .failure(.missingItem(title, inPath: reached))
            }
            container = submenu
        }
        return .failure(.noMenuBar)
    }

    /// One level's match.
    ///
    /// CASE- AND WHITESPACE-INSENSITIVE, and ellipsis-tolerant: an
    /// application titles a command that opens a dialog "Move To…", and a
    /// package author writing the path down naturally omits the ellipsis.
    /// Neither spelling is wrong, so neither is required.
    static func child(of container: AXUIElement, titled title: String) -> AXUIElement? {
        let wanted = normalized(title)
        return AX.children(container).first { element in
            guard let found = AX.string(element, kAXTitleAttribute) else { return false }
            return normalized(found) == wanted
        }
    }

    static func normalized(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\u{2026}", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - Reading what is offered

    /// The titles one level of a path offers.
    ///
    /// THE RUNTIME HALF OF A DECLARED PATH. "Move To" opens onto the user's
    /// own folders, which no package can enumerate — so a ceremony declares
    /// the path AS FAR AS THE MENU IS FIXED and reads the last level here.
    /// This is also how a refusal names what WAS there, which is the
    /// difference between "no such folder" and "no such folder; you have
    /// Drafts, Research and Trash".
    public static func titles(under path: [String], pid: pid_t) -> [String] {
        guard case .success(let item) = locate(path: path, pid: pid) else { return [] }
        guard let submenu = AX.children(item).first(where: {
            AX.string($0, kAXRoleAttribute) == kAXMenuRole as String
        }) else { return [] }
        return AX.children(submenu).compactMap { element in
            guard let title = AX.string(element, kAXTitleAttribute),
                  !title.isEmpty else { return nil }
            return title
        }
    }

    /// Every top-level menu, for diagnosis.
    public static func topLevelTitles(pid: pid_t) -> [String] {
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = AX.element(application, kAXMenuBarAttribute) else { return [] }
        return AX.children(menuBar).compactMap { AX.string($0, kAXTitleAttribute) }
    }
}
