//
//  WindowManagementModels.swift
//  MaryBrain
//
//  WHAT: Value types and seams for window management.
//  IN:   WindowManagement.swift (sibling split)
//  OUT:  WindowManagementService / WindowManagementPlugin / adapters
//

import AppKit
import Foundation

/// Running application as values safe across an async boundary. NSRunningApplication is not kept.
public struct ManagedApplication: Sendable, Equatable {
    public var bundleIdentifier: String
    public var displayName: String
    public var processIdentifier: pid_t

    public init(bundleIdentifier: String, displayName: String, processIdentifier: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.processIdentifier = processIdentifier
    }
}

/// Adapter-neutral window identity. `id` is stable for the window's life; pass it back.
public struct ManagedWindow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Front-to-back order at observation time. One is frontmost in the app.
    public var index: Int
    /// Nil when the adapter cannot observe minimisation. Unknown is not false.
    public var isMinimized: Bool?

    public init(id: String, title: String, index: Int, isMinimized: Bool? = nil) {
        self.id = id
        self.title = title
        self.index = index
        self.isMinimized = isMinimized
    }
}

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

/// Machine result before projection into SkillOutcome.
public struct WindowManagementResult: Sendable, Equatable {
    public var ok: Bool
    public var summary: String
    public var foundNothing: Bool
    public var windows: [ManagedWindow]

    public init(
        ok: Bool,
        summary: String,
        foundNothing: Bool = false,
        windows: [ManagedWindow] = []
    ) {
        self.ok = ok
        self.summary = summary
        self.foundNothing = foundNothing
        self.windows = windows
    }

    static func failure(_ error: WindowManagementError) -> Self {
        let foundNothing: Bool
        switch error {
        case .applicationNotRunning, .applicationNotFound, .noWindows, .windowNotFound:
            foundNothing = true
        default:
            foundNothing = false
        }
        return Self(ok: false, summary: error.summary, foundNothing: foundNothing)
    }

    var activityOutcome: SkillOutcome {
        // Window titles are live coordination, not durable memory. Archive none.
        SkillOutcome(
            ok: ok,
            summary: summary,
            archivePolicy: .none,
            foundNothing: foundNothing)
    }
}

/// Injectable high-level surface for the ability binding and its tests.
public protocol WindowManagementServing: Sendable {
    func activateApplication(named application: String) async -> WindowManagementResult
    func listWindows(application: String) async -> WindowManagementResult
    func restoreWindow(application: String, window: String) async -> WindowManagementResult
    func raiseWindow(application: String, window: String) async -> WindowManagementResult
    func raiseAllWindows(application: String) async -> WindowManagementResult
    /// Enter or leave full screen. Empty `window` = the one in front.
    func setFullScreen(
        application: String, window: String, enabled: Bool
    ) async -> WindowManagementResult
}

public extension WindowManagementServing {
    /// Default decline. Live service overrides; test doubles stay honest.
    func setFullScreen(
        application: String, window: String, enabled: Bool
    ) async -> WindowManagementResult {
        .failure(.operationFailed("I can't switch full screen here."))
    }
}

/// Primitive window capabilities. Specialists lead; Accessibility is the fallback.
public protocol WindowManagementAdapter: Sendable {
    var id: String { get }
    func supports(application: ManagedApplication) -> Bool
    func windows(in application: ManagedApplication) async throws -> [ManagedWindow]
    func resolve(
        _ reference: String,
        in application: ManagedApplication,
        windows: [ManagedWindow]
    ) async throws -> ManagedWindow
    func restore(_ window: ManagedWindow, in application: ManagedApplication) async throws
    func raise(_ window: ManagedWindow, in application: ManagedApplication) async throws
    func raiseAll(_ windows: [ManagedWindow], in application: ManagedApplication) async throws -> Int
    func setFullScreen(
        _ window: ManagedWindow, in application: ManagedApplication, enabled: Bool
    ) async throws
}

public extension WindowManagementAdapter {
    /// Decline rather than silent no-op. Service then falls through to Accessibility.
    func setFullScreen(
        _ window: ManagedWindow, in application: ManagedApplication, enabled: Bool
    ) async throws {
        throw WindowManagementError.operationFailed(
            "I can't switch full screen for \(application.displayName) windows.")
    }

    /// Shared resolution: stable id, unique exact title, then unique contained title.
    /// PIN: a tie never silently chooses the front window.
    func resolve(
        _ reference: String,
        in application: ManagedApplication,
        windows: [ManagedWindow]
    ) async throws -> ManagedWindow {
        try WindowReferenceResolver.resolve(reference, in: windows)
    }
}

enum WindowReferenceResolver {
    static func resolve(_ reference: String, in windows: [ManagedWindow]) throws -> ManagedWindow {
        let query = normalize(reference)
        guard !query.isEmpty else { throw WindowManagementError.windowNotFound(reference) }

        if let identified = windows.first(where: { normalize($0.id) == query }) {
            return identified
        }
        let exact = windows.filter { normalize($0.title) == query }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw WindowManagementError.ambiguousWindow(reference) }

        let contained = windows.filter {
            let title = normalize($0.title)
            return title.contains(query) || query.contains(title)
        }
        if contained.count == 1 { return contained[0] }
        if contained.count > 1 { throw WindowManagementError.ambiguousWindow(reference) }
        throw WindowManagementError.windowNotFound(reference)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")
            .union(.whitespacesAndNewlines)).lowercased()
    }
}
protocol WindowApplicationResolving: Sendable {
    func runningApplication(named application: String) -> Result<ManagedApplication, WindowManagementError>
    func activateApplication(named application: String) async -> Result<ManagedApplication, WindowManagementError>
}

/// A window an application resolved for itself — opaque identity plus owner.
public struct ManagedWindowReference: Sendable, Equatable {
    /// Bundle identifier of the owning application.
    public let applicationID: String
    /// Owner's own stable spelling for this window.
    public let identity: String

    public init(applicationID: String, identity: String) {
        self.applicationID = applicationID
        self.identity = identity
    }
}

/// Whether a spoken reference belongs to an application, and if so where.
/// PIN: owned-but-unresolved stops the ladder — do not fall through.
public enum WindowReferenceDecision: Sendable, Equatable {
    case none
    case ownedButUnresolved(WindowManagementError)
    case resolved(ManagedWindowReference)
}
