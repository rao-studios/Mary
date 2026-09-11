//
//  WindowManagementPlugin.swift
//  MaryPlugin
//
//  WHAT: Runtime Skill bindings for window management.
//  IN:   WindowManagementService
//  OUT:  list / raise / raise-all / restore / full-screen
//  PIN:  Invocation names snake_case; adapter identity hyphenated.
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
        [bringApplicationForward, openNewWindow, listAppWindows, bringWindowForward,
         bringAllWindowsForward, restoreWindow, makeWindowFullScreen, exitFullScreen]
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
            // PIN: one generic class. A place mints `<id>-window` when it leads.
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
                // THE SKILL THAT COULD NOT ACTIVATE ANYTHING. `bring_application_forward`
                // was bound to an operation no adapter published, so "bring Chrome
                // forward" had a summary and no hands. It is the same faculty every
                // act stages through — `VerifiedActivation` — offered by name.
                operation(
                    "bring_application_forward",
                    capabilities: ["application.activate"],
                    input: "window-management.application-target",
                    output: "window-management.operation-result",
                    targets: ["macos-application"]),
                // NEW WINDOW, NOT A RAISED ONE. `application.activate` alone,
                // like the skill above: what this is POINTED AT is an
                // application, and the capability model scopes by target class
                // — `window.enumerate` allows only window classes, so requiring
                // both describes a dispatch that targets an application and a
                // window at once, which is why the graph validator refuses it.
                // Counting windows to prove the new one appeared is internal to
                // the adapter and runs under the manifest's own accessibility
                // grant, not a capability this Skill points at anything with.
                operation(
                    "open_new_window",
                    capabilities: ["application.activate"],
                    input: "window-management.application-target",
                    output: "window-management.operation-result",
                    targets: ["macos-application"]),
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

    private var openNewWindow: SkillBinding {
        SkillBinding(
            name: "open_new_window",
            description: "Make a named application produce a new window, opening the application first when it is not running. Uses the application's own New command.",
            parameters: [appParameter],
            access: .tweak,
            backing: .native { [service] arguments, _ in
                await service.openNewWindow(
                    application: arguments["app"] ?? "").activityOutcome
            },
            stage: true,
            preparesSurface: true)
    }

    private var bringApplicationForward: SkillBinding {
        SkillBinding(
            name: "bring_application_forward",
            description: "Bring a running application forward as a whole — its front window restored and raised, and proved by looking again. Opens it first when it is not running.",
            parameters: [appParameter],
            access: .tweak,
            backing: .native { [service] arguments, _ in
                await service.activateApplication(named: arguments["app"] ?? "")
                    .activityOutcome
            },
            stage: true,
            preparesSurface: true)
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
            description: "Restore and bring one window of a running application forward. Identify it by stable id or an unambiguous exact title; omit the window to bring the application's front window forward.",
            parameters: [appParameter, optionalWindowParameter],
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

    /// Full screen for the window — not a video's on-page control (`act_on_screen`).
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

    /// Same reference, optional. Omitted = frontmost — the honest meaning of "it".
    private var optionalWindowParameter: ModelSkillSchema.Parameter {
        .init(
            name: "window", type: "string",
            description: "Stable id or exact title; omit for the window in front.",
            required: false,
            aliases: Self.windowAliases)
    }

    /// Names a model writes instead of `window`. Shared by required and optional forms.
    private static let windowAliases = [
        "title", "window_title", "windowtitle", "window_name", "name", "document",
    ]

    /// AppKit spellings either side of NSRunningApplication.
    private static let applicationAliases = [
        "application", "app_name", "application_name", "bundle_id", "bundle_identifier",
    ]
}
