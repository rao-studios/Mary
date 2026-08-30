//
//  WindowManagementModels.swift
//  MaryBrain
//
//  Split out of WindowManagement.swift (docs/DECOMPOSITION.md Wave 2) —
//  pure relocation, no declaration changed.
//

import AppKit
import Foundation

/// A running application reduced to values that are safe to carry across an
/// async boundary. `NSRunningApplication` itself is deliberately not retained.
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

/// An adapter-neutral window identity. `id` is stable for the life of the
/// source window; callers should pass it back instead of relying on z-order.
public struct ManagedWindow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Front-to-back order at observation time. One is frontmost in the app.
    public var index: Int
    /// Nil when the preferred adapter cannot observe minimisation without an
    /// extra permission or round-trip. Unknown is not treated as false.
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

/// Result of a machine operation before it is projected into the conversation
/// runtime's `SkillOutcome` type.
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
        // Window names are useful live coordination data, but they can expose
        // private document titles and have no durable-memory value. The
        // schema/receipt layer can project a deliberately redacted record;
        // the legacy activity archive must not retain this transient summary.
        SkillOutcome(
            ok: ok,
            summary: summary,
            archivePolicy: .none,
            foundNothing: foundNothing)
    }
}

/// Injectable high-level surface used by the ability binding and its tests.
public protocol WindowManagementServing: Sendable {
    func activateApplication(named application: String) async -> WindowManagementResult
    func listWindows(application: String) async -> WindowManagementResult
    func restoreWindow(application: String, window: String) async -> WindowManagementResult
    func raiseWindow(application: String, window: String) async -> WindowManagementResult
    func raiseAllWindows(application: String) async -> WindowManagementResult
    /// Enter or leave full screen. `window` may be empty: "make it full
    /// screen" names no window, and the frontmost one is the only honest
    /// reading of "it".
    func setFullScreen(
        application: String, window: String, enabled: Bool
    ) async -> WindowManagementResult
}

public extension WindowManagementServing {
    /// DEFAULTED so the many test doubles conforming to this protocol did not
    /// all have to grow a method they have nothing to say about. The live
    /// service overrides it; anything that does not is honest about not
    /// implementing it rather than quietly reporting success.
    func setFullScreen(
        application: String, window: String, enabled: Bool
    ) async -> WindowManagementResult {
        .failure(.operationFailed("I can't switch full screen here."))
    }
}

/// One local implementation of primitive window capabilities. Specialist
/// adapters lead the ordered registry; Accessibility is the generic fallback.
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
    /// A SPECIALIST THAT CANNOT DO IT SAYS SO, rather than inheriting a
    /// silent no-op. The generic Accessibility adapter implements this; an
    /// application adapter whose own dictionary has no full-screen verb
    /// declines here and the service falls through to Accessibility, which is
    /// the same shape `supports(application:)` already gives the registry.
    func setFullScreen(
        _ window: ManagedWindow, in application: ManagedApplication, enabled: Bool
    ) async throws {
        throw WindowManagementError.operationFailed(
            "I can't switch full screen for \(application.displayName) windows.")
    }

    /// Total, ambiguity-preserving resolution shared by generic adapters.
    /// Stable id, unique exact title, then unique contained title. A tie never
    /// silently chooses the front window.
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

/// A WINDOW AN APPLICATION HAS RESOLVED FOR ITSELF — its own id spelling and
/// the application it belongs to.
///
/// The identity is opaque to window management on purpose: only the owning
/// application knows whether its windows are addressed by a scripting id, an
/// accessibility handle or something else, and a service that parsed the
/// spelling would be a second answer to a question its owner already answered.
public struct ManagedWindowReference: Sendable, Equatable {
    /// The bundle identifier of the application that owns the window.
    public let applicationID: String
    /// The owner's own stable spelling for this window.
    public let identity: String

    public init(applicationID: String, identity: String) {
        self.applicationID = applicationID
        self.identity = identity
    }
}

/// WHETHER A SPOKEN REFERENCE BELONGS TO AN APPLICATION, and if so where it
/// points.
///
/// The middle case is the one that matters and the one a boolean would lose:
/// "this reference IS mine and I could not resolve it" must stop the ladder,
/// because falling through to a looser resolver after a confident owner has
/// failed is how a raise lands on the wrong window.
public enum WindowReferenceDecision: Sendable, Equatable {
    case none
    case ownedButUnresolved(WindowManagementError)
    case resolved(ManagedWindowReference)
}
