//
//  WindowManagementPlugin.swift
//  MaryBrain
//
//  Runtime bindings for the window-management ability. Public invocation
//  names stay snake_case; the portable adapter identity stays hyphenated.
//

import Foundation

public struct WindowManagementPlugin: MaryAdapter {
    public static let adapterID = "window-management"

    public let name = Self.adapterID
    public let summary = "Inspect, restore, or bring application windows forward."
    public let abilities: Set<AbilityID> = [.windowManagement]
    public let applicationAliases: Set<String> = ["window", "windows", "window management"]

    private let service: any WindowManagementServing

    public init(service: any WindowManagementServing = WindowManagementService.live) {
        self.service = service
    }

    public var skillBindings: [SkillBinding] {
        [listAppWindows, bringWindowForward, bringAllWindowsForward, restoreWindow,
         makeWindowFullScreen, exitFullScreen]
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID(Self.adapterID)
        func guarantee(
            _ kind: CapabilityConstraint.Kind,
            _ value: String
        ) -> CapabilityConstraint {
            CapabilityConstraint(kind: kind, value: value)
        }
        let guarantees: [CapabilityID: [CapabilityConstraint]] = [
            "window.resolve": [guarantee(.sourceMustMatchTarget, "application-and-process-epoch")],
            "window.raise": [guarantee(.sourceMustMatchTarget, "resolved-window")],
            "window.raise-all": [guarantee(.sourceMustMatchTarget, "resolved-application")],
            "window.restore": [guarantee(.sourceMustMatchTarget, "resolved-window")],
            "window.full-screen": [guarantee(.sourceMustMatchTarget, "resolved-window")],
        ]
        func operation(
            _ name: String,
            capabilities: [CapabilityID],
            input: ValueTypeID,
            output: ValueTypeID,
            // ONE CLASS, GENERIC. A second entry named one application's windows,
        // so that application's window Skills were eligible by default and
        // every other application's were not. A place mints its own
        // `<id>-window` class through the turn classifier when it leads.
        targets: [String] = ["macos-application-window"]
        ) -> InstalledAdapterBinding {
            let enforced = Set(capabilities.flatMap { guarantees[$0] ?? [] })
            return InstalledAdapterBinding(
                adapterID: adapterID,
                operation: name,
                capabilities: capabilities,
                inputTypes: [input],
                outputTypes: [output],
                targetClasses: targets,
                enforcedConstraints: enforced.sorted {
                    ($0.kind.rawValue, $0.value) < ($1.kind.rawValue, $1.value)
                })
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Window Management",
            transport: .accessibility,
            claimCoverage: .complete,
            operations: [
                operation(
                    "list_app_windows",
                    capabilities: ["window.enumerate"],
                    input: "window-management.application-target",
                    output: "window-management.window-list"),
                operation(
                    "bring_window_forward",
                    capabilities: ["window.resolve", "window.restore", "window.raise"],
                    input: "window-management.window-reference",
                    output: "window-management.operation-result"),
                operation(
                    "bring_all_windows_forward",
                    capabilities: ["window.raise-all"],
                    input: "window-management.application-target",
                    output: "window-management.operation-result"),
                operation(
                    "restore_window",
                    capabilities: ["window.resolve", "window.restore"],
                    input: "window-management.window-reference",
                    output: "window-management.operation-result"),
                operation(
                    "make_window_full_screen",
                    capabilities: ["window.resolve", "window.raise", "window.full-screen"],
                    input: "window-management.window-reference",
                    output: "window-management.operation-result"),
                operation(
                    "exit_full_screen",
                    capabilities: ["window.resolve", "window.full-screen"],
                    input: "window-management.window-reference",
                    output: "window-management.operation-result"),
            ],
            supportedValueTypes: [
                "window-management.application-target",
                "window-management.window-reference",
                "window-management.window-list",
                "window-management.operation-result",
            ],
            grantedPermissions: [.accessibility, .automation])
    }

    private var listAppWindows: SkillBinding {
        SkillBinding(
            name: "list_app_windows",
            description: "List a running application's manageable windows with stable ids, titles, order, and known minimized state. This does not activate the app.",
            parameters: [appParameter],
            access: .read,
            backing: .native { [service] arguments, _ in
                await service.listWindows(application: arguments["app"] ?? "")
                    .activityOutcome
            })
    }

    private var bringWindowForward: SkillBinding {
        SkillBinding(
            name: "bring_window_forward",
            description: "Restore and bring one window of a running application forward. Identify it by stable id or an unambiguous exact title.",
            parameters: [appParameter, windowParameter],
            access: .tweak,
            backing: .native { [service] arguments, _ in
                await service.raiseWindow(
                    application: arguments["app"] ?? "",
                    window: arguments["window"] ?? "").activityOutcome
            },
            stage: true,
            preparesSurface: true)
    }

    private var bringAllWindowsForward: SkillBinding {
        SkillBinding(
            name: "bring_all_windows_forward",
            description: "Restore and bring every window of a running application forward while preserving its existing front-to-back stacking order.",
            parameters: [appParameter],
            access: .tweak,
            backing: .native { [service] arguments, _ in
                await service.raiseAllWindows(application: arguments["app"] ?? "")
                    .activityOutcome
            },
            stage: true,
            preparesSurface: true)
    }

    private var restoreWindow: SkillBinding {
        SkillBinding(
            name: "restore_window",
            description: "Unminimize one window of a running application without activating or raising the application. Identify it by stable id or exact title.",
            parameters: [appParameter, windowParameter],
            access: .tweak,
            backing: .native { [service] arguments, _ in
                await service.restoreWindow(
                    application: arguments["app"] ?? "",
                    window: arguments["window"] ?? "").activityOutcome
            },
            stage: true,
            preparesSurface: true)
    }

    /// FULL SCREEN FOR THE WINDOW, which is not the same request as full
    /// screen for a VIDEO.
    ///
    /// "Make it full screen" over a playing video means the player's own
    /// control, and that is `act_on_screen`'s job — it presses what the page
    /// offers. This is the other half of the same phrase: the window itself,
    /// in any application, for the many times nothing on screen offers it.
    /// Neither is a fallback for the other; they answer different "it"s, and
    /// the descriptions say which.
    private var makeWindowFullScreen: SkillBinding {
        SkillBinding(
            name: "make_window_full_screen",
            description: "Put an application WINDOW into macOS full screen. For a video or a player with its own full-screen control on the page, use act_on_screen instead — this moves the whole window to its own Space.",
            parameters: [appParameter, optionalWindowParameter],
            access: .tweak,
            backing: .native { [service] arguments, _ in
                await service.setFullScreen(
                    application: arguments["app"] ?? "",
                    window: arguments["window"] ?? "",
                    enabled: true).activityOutcome
            },
            stage: true,
            preparesSurface: true)
    }

    private var exitFullScreen: SkillBinding {
        SkillBinding(
            name: "exit_full_screen",
            description: "Take an application window back out of macOS full screen.",
            parameters: [appParameter, optionalWindowParameter],
            access: .tweak,
            backing: .native { [service] arguments, _ in
                await service.setFullScreen(
                    application: arguments["app"] ?? "",
                    window: arguments["window"] ?? "",
                    enabled: false).activityOutcome
            },
            stage: true,
            preparesSurface: true)
    }

    private var appParameter: ModelSkillSchema.Parameter {
        .init(
            name: "app", type: "string",
            description: "Application name or bundle identifier; omit for the frontmost application.",
            required: false,
            aliases: Self.applicationAliases)
    }

    private var windowParameter: ModelSkillSchema.Parameter {
        .init(
            name: "window", type: "string",
            description: "Stable id from list_app_windows, or one unambiguous exact window title.",
            required: true,
            aliases: Self.windowAliases)
    }

    /// The same reference, optional. "Make it full screen" names no window,
    /// and the service reads an omitted one as the frontmost — the only
    /// honest meaning of "it".
    private var optionalWindowParameter: ModelSkillSchema.Parameter {
        .init(
            name: "window", type: "string",
            description: "Stable id or exact title; omit for the window in front.",
            required: false,
            aliases: Self.windowAliases)
    }

    /// WHAT A MODEL CALLS A WINDOW WHEN IT DOES NOT SAY "WINDOW".
    ///
    /// `title` is the live one: asked to raise "Untitled 47", the model sent
    /// `{"app":"TextEdit","title":"Untitled 47"}` — the natural word for the
    /// only thing that distinguishes one untitled document from another. The
    /// rest are the same substitution in the other directions this Skill's own
    /// description invites ("exact window title", "document").
    ///
    /// Shared by both spellings of the parameter so the required and optional
    /// forms can never drift apart on what they will accept.
    private static let windowAliases = [
        "title", "window_title", "windowtitle", "window_name", "name", "document",
    ]

    /// The same, for the application half — the two spellings AppKit itself
    /// uses either side of `NSRunningApplication`.
    private static let applicationAliases = [
        "application", "app_name", "application_name", "bundle_id", "bundle_identifier",
    ]
}
