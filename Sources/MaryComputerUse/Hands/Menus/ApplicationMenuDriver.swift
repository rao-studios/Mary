//
//  ApplicationMenuDriver.swift
//  MaryComputerUse
//
//  WHAT: Walk an application's menu bar by AX. Name the missing level.
//  OUT:  ceremony recipes (Documents → Move To, …)
//  PIN:  Disabled ≠ missing. Localization is an honest miss, not a guess.

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient

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

    // MARK: - Choosing

    /// Walk a titled path from the menu bar and press its leaf.
    @discardableResult
    public static func choose(
        path: [String], pid: pid_t
    ) async -> Result<Void, Failure> {
        let spelling = path.joined(separator: " → ")
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else {
            note(refused: pid, reason: .notRunning("that application"))
            return .failure(.notRunning)
        }

        switch locate(path: path, pid: pid) {
        case .failure(let failure):
            note(refused: pid, reason: failure.monitorReason)
            return .failure(failure)
        case .success(let item):
            guard AX.number(item, kAXEnabledAttribute)?.boolValue != false else {
                note(refused: pid, reason: .itemDisabled(path[path.count - 1]))
                return .failure(.itemDisabled(path[path.count - 1]))
            }
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                note(refused: pid, reason: .pressRefused(path[path.count - 1]))
                return .failure(.pressRefused(path[path.count - 1]))
            }
            ComputerUseMonitor.shared.note(lane: .menus, act: "menuChoose", pid: pid, detail: spelling)
            // A menu command runs on the next pass of the application's own
            // run loop; returning before it has is how a caller's verify beat
            // races the change it is verifying.
            try? await Task.sleep(for: .milliseconds(250))
            return .success(())
        }
    }

    private static func note(refused pid: pid_t, reason: ComputerUseRefusalReason) {
        ComputerUseMonitor.shared.note(
            lane: .menus, refused: "menuChoose", pid: pid, reason: reason)
    }

    /// Find the element a path names, without pressing it. Public because "does this
    /// application offer this command" is a real question.
    public static func locate(
        path: [String], pid: pid_t
    ) -> Result<AXUIElement, Failure> {
        // An empty path names nothing; the nearest honest sentence is the
        // menu-bar one.
        guard !path.isEmpty else { return .failure(.noMenuBar) }
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = AX.element(application, kAXMenuBarAttribute) else {
            return .failure(.noMenuBar)
        }

        var container = menuBar
        var reached: [String] = []
        for (level, title) in path.enumerated() {
            guard let match = child(of: container, titled: title) else {
                return .failure(.missingItem(title, inPath: reached))
            }
            reached.append(title)
            // Last path step is the item. "Last" is a position — titles may repeat (View → View).
            if level == path.count - 1 {
                return .success(match)
            }
            // A menu bar item and a submenu item both hold their contents in
            // an AXMenu CHILD rather than directly — so descending means
            // stepping through that wrapper.
            guard let submenu = AX.children(match).first(where: {
                AX.string($0, kAXRoleAttribute) == kAXMenuRole as String
            }) else {
                return .failure(.missingItem(title, inPath: reached))
            }
            container = submenu
        }
        // Unreachable: the loop returns at the last level and the path is
        // non-empty.
        return .failure(.noMenuBar)
    }

    /// One level's match. CASE- AND WHITESPACE-INSENSITIVE, and ellipsis-tolerant: an
    /// application titles a command that opens a dialog "Move To…", and a package author
    /// writing the path down naturally omits the ellipsis.
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

    /// The titles one level of a path offers. THE RUNTIME HALF OF A DECLARED PATH.
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

extension ApplicationMenuDriver.Failure {
    /// The same miss, in the monitor's named vocabulary.
    var monitorReason: ComputerUseRefusalReason {
        switch self {
        case .notRunning: return .notRunning("that application")
        case .noMenuBar: return .menuLevelMissing("menu bar")
        case .missingItem(let title, _): return .menuLevelMissing(title)
        case .itemDisabled(let title): return .itemDisabled(title)
        case .pressRefused(let title): return .pressRefused(title)
        }
    }
}
