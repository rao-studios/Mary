//
//  WindowManagementError.swift
//  MaryComputerUse
//
//  WHAT: Why a window act could not happen, in the words Mary speaks.
//  IN:   AccessibilityWindowCore | WindowManagement (MaryPlugin)
//  OUT:  WindowManagementResult.summary
//  PIN:  Lives beside the acts that throw it. `WindowManagement` catches this
//        exact type and falls back to a generic sentence otherwise, so the
//        cases and their wording are load-bearing.
//

import Foundation

public enum WindowManagementError: Error, Sendable, Equatable {
    case invalidApplication
    case applicationNotRunning(String)
    case applicationNotFound(String)
    case ambiguousApplication(String)
    case accessibilityRequired
    case noWindows(String)
    case windowNotFound(String)
    case ambiguousWindow(String)
    case operationFailed(String)

    public var summary: String {
        switch self {
        case .invalidApplication:
            return "No application was given."
        case .applicationNotRunning(let name):
            return "\(name) isn't open, so it has no windows to manage."
        case .applicationNotFound(let name):
            return "I couldn't find an application called \(name)."
        case .ambiguousApplication(let name):
            return "More than one running application matches \(name); use its full name or bundle identifier."
        case .accessibilityRequired:
            return "Managing windows needs Accessibility access — grant it to Mary in System Settings, Privacy & Security, Accessibility."
        case .noWindows(let name):
            return "\(name) is open but has no manageable windows."
        case .windowNotFound(let name):
            return "I couldn't find one open window matching \"\(name)\"."
        case .ambiguousWindow(let name):
            return "More than one open window matches \"\(name)\"; use its exact title or stable window id."
        case .operationFailed(let detail):
            return detail
        }
    }
}
