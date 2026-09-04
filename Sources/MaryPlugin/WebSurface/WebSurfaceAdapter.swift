//
//  WebSurfaceAdapter.swift
//  MaryPlugin
//
//  WHAT: The Skills a declared browser answers — where you are, where to go, and the
//        page's own player.
//  IN:   WebSurfaceSupport (which browser) + BrowserEngine (what to do)
//  OUT:  SkillOutcome
//  PIN:  NO BROWSER IS NAMED HERE. This adapter learns that one browser calls its back
//        button "Go back" and another says "Back" only because the packages said so.
//        A URL IS HELD, NEVER SPOKEN. Every summary says the SITE — "youtube" — because
//        an address read aloud is unusable as speech and puts query strings in a
//        transcript.
//        MEDIA VERBS ARE TWEAKS, NOT WRITES. Pausing is undone by pressing the same
//        button; being asked "are you sure?" first is the interaction nobody wants.
//        Closing a tab is not, and it is the one write here.
//

import Foundation
import MaryAmbient
import MaryComputerUse
import MaryFoundation

public struct WebSurfaceAdapter: MaryAdapter {

    public let name = "web-surface"
    public let summary =
        "reads which page a browser is on and drives it — navigation, tabs, and the page's own media player"

    private let support: WebSurfaceSupport
    private let engine: BrowserEngine

    public init(support: WebSurfaceSupport = .shared, engine: BrowserEngine = .live) {
        self.support = support
        self.engine = engine
    }

    public var abilities: Set<AbilityID> { [.browsing] }
    // NO ALIASES. "the browser" belongs to the packages that teach one; claiming it here
    // shadows their routing identity and the whole graph refuses to activate.
    public var applicationAliases: Set<String> { [] }

    public var promptFragment: String? {
        """
        The browser's own controls are read through Accessibility; what is INSIDE the \
        page is read from pixels. Say the site, never the address. Drive a video with \
        control_media — never a site's keyboard shortcut, and never the system media \
        keys, which reach whatever holds now-playing rather than this tab.
        """
    }

    public var targetedRead: (binding: String, parameter: String)? {
        (binding: "current_page", parameter: "app")
    }

    public var refusals: [String] {
        ["I can't press things inside a page by name yet — only the player's controls."]
    }

    public var skillBindings: [SkillBinding] {
        [currentPage, listTabs, describeMedia, controlMedia,
         openLocation, navigateBack, navigateForward, reloadPage, scrollPage]
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(
            _ name: String,
            capability: CapabilityID,
            input: ValueTypeID,
            output: ValueTypeID,
            observes: Bool = true
        ) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID,
                operation: name,
                capabilities: [capability],
                inputTypes: [input],
                outputTypes: [output],
                observesPerceptions: observes ? ["perception.page-context"] : [],
                targetClasses: ["web-page"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Web Surface",
            transport: .accessibility,
            operations: [
                operation("current_page", capability: "browser.page.read",
                          input: "browsing.browser-query", output: "browsing.page-report"),
                operation("list_tabs", capability: "browser.tabs.read",
                          input: "browsing.browser-query", output: "browsing.page-report"),
                operation("describe_media", capability: "browser.media.read",
                          input: "browsing.browser-query", output: "browsing.media-report"),
                operation("control_media", capability: "browser.media.control",
                          input: "browsing.media-request", output: "browsing.operation-result"),
                operation("open_location", capability: "browser.navigate",
                          input: "browsing.address", output: "browsing.page-report"),
                operation("navigate_back", capability: "browser.navigate",
                          input: "browsing.browser-query", output: "browsing.page-report"),
                operation("navigate_forward", capability: "browser.navigate",
                          input: "browsing.browser-query", output: "browsing.page-report"),
                operation("reload_page", capability: "browser.navigate",
                          input: "browsing.browser-query", output: "browsing.page-report"),
                operation("scroll_page", capability: "browser.page.act",
                          input: "browsing.media-request", output: "browsing.operation-result"),
            ],
            providesPerceptions: ["perception.page-context"],
            supportedValueTypes: [
                "browsing.browser-query",
                "browsing.page-report",
                "browsing.media-report",
                "browsing.media-request",
                "browsing.address",
                "browsing.operation-result",
            ],
            // The two boundaries these operations cross. Screen recording is named
            // because reading a page means reading its pixels.
            grantedPermissions: [.accessibility, .screenRecording])
    }

    // MARK: - Reading

    private var currentPage: SkillBinding {
        SkillBinding(
            name: "current_page",
            description: "Say which page the browser is on right now, and which site it belongs to.",
            parameters: [browserParameter],
            access: .read,
            backing: .native { arguments, _ in
                await self.run(arguments["app"]) { target in
                    await self.engine.readShell(target)
                }
            })
    }

    private var listTabs: SkillBinding {
        SkillBinding(
            name: "list_tabs",
            description: "List the browser's open tabs by name.",
            parameters: [browserParameter],
            access: .read,
            backing: .native { arguments, _ in
                await self.run(arguments["app"]) { target in
                    let outcome = await self.engine.readShell(target)
                    guard let shell = outcome.shell else { return outcome }
                    guard !shell.tabs.isEmpty else {
                        return BrowserOutcome(
                            ok: true,
                            spoken: "\(target.spokenName) isn't showing me its tabs.",
                            shell: shell)
                    }
                    return BrowserOutcome(
                        ok: true, spoken: shell.tabs.joined(separator: "\n"), shell: shell)
                }
            })
    }

    private var describeMedia: SkillBinding {
        SkillBinding(
            name: "describe_media",
            description: """
                Say what the video or player on the current page is doing — playing or \
                paused, and how far through. Use for "is it playing", "how far in are we".
                """,
            parameters: [browserParameter],
            access: .read,
            backing: .native { arguments, _ in
                await self.run(arguments["app"]) { target in
                    await self.engine.describeMedia(in: target)
                }
            },
            // SEEING THE PLAYER MEANS CLAIMING THE STAGE. A player only draws its
            // controls while the pointer is over an active window, so this read moves
            // the machine even though it changes nothing on the page.
            stage: true)
    }

    // MARK: - Driving

    private var controlMedia: SkillBinding {
        SkillBinding(
            name: "control_media",
            description: """
                Play, pause, mute, unmute, go full screen, or skip to a position in the \
                video on the page the browser is showing. Use for "pause the video", \
                "mute this", "skip to halfway".
                """,
            parameters: [
                .init(
                    name: "action", type: "string",
                    description: "What to do to the player.",
                    required: true,
                    enumValues: ["play", "pause", "toggle", "mute", "unmute", "fullscreen", "seek"]),
                .init(
                    name: "position", type: "string",
                    description: "For seek: how far through, 0 to 1 (0.5 is halfway).",
                    required: false),
                browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let raw = arguments["action"]?.lowercased() else {
                    return SkillOutcome(ok: false, summary: "Tell me what to do to the video.")
                }
                let action: MediaAction?
                switch raw {
                case "play": action = .play
                case "pause": action = .pause
                case "toggle": action = .toggle
                case "mute": action = .mute
                case "unmute": action = .unmute
                case "fullscreen": action = .fullscreen
                case "seek":
                    // A SEEK WITHOUT A POSITION IS NOT A SEEK. Picking one would move
                    // somebody's video to a place nobody asked for.
                    guard let fraction = arguments["position"].flatMap(Double.init),
                          (0 ... 1).contains(fraction)
                    else {
                        return SkillOutcome(
                            ok: false,
                            summary: "Tell me how far through to skip to — halfway, or a quarter in.")
                    }
                    action = .seek(fraction: fraction)
                default: action = nil
                }
                guard let action else {
                    return SkillOutcome(ok: false, summary: "I don't know how to \(raw) a video.")
                }
                return await self.run(arguments["app"]) { target in
                    await self.engine.controlMedia(action, in: target)
                }
            },
            stage: true)
    }

    private var openLocation: SkillBinding {
        SkillBinding(
            name: "open_location",
            description: """
                Go to a web address in the browser. Use when the user names a site or \
                gives an address to open.
                """,
            parameters: [
                .init(name: "address", type: "string",
                      description: "The address to open, including https://.", required: true),
                browserParameter,
            ],
            // A NAVIGATION IS A TWEAK THAT PREPARES A SURFACE, not a write: nothing of
            // the user's is changed, and declaring it a read made the continuation
            // judge the turn unfinished and navigate a second time — off the page it
            // had just opened.
            access: .tweak,
            backing: .native { arguments, _ in
                guard let address = arguments["address"], !address.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me where to go.")
                }
                return await self.run(arguments["app"]) { target in
                    await self.engine.navigate(.open(address), in: target)
                }
            },
            stage: true,
            preparesSurface: true)
    }

    private func navigation(
        _ name: String, _ description: String, _ request: NavigationRequest
    ) -> SkillBinding {
        SkillBinding(
            name: name,
            description: description,
            parameters: [browserParameter],
            access: .tweak,
            backing: .native { arguments, _ in
                await self.run(arguments["app"]) { target in
                    await self.engine.navigate(request, in: target)
                }
            },
            stage: true)
    }

    private var navigateBack: SkillBinding {
        navigation("navigate_back", "Go back to the previous page in the browser.", .back)
    }

    private var navigateForward: SkillBinding {
        navigation("navigate_forward", "Go forward again in the browser.", .forward)
    }

    private var reloadPage: SkillBinding {
        navigation("reload_page", "Reload the page the browser is showing.", .reload)
    }

    private var scrollPage: SkillBinding {
        SkillBinding(
            name: "scroll_page",
            description: "Scroll the page the browser is showing, up or down.",
            parameters: [
                .init(name: "direction", type: "string", description: "Which way.",
                      required: false, enumValues: ["down", "up"]),
                browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                let up = arguments["direction"]?.lowercased() == "up"
                return await self.run(arguments["app"]) { target in
                    await self.engine.navigate(.scroll(by: up ? 320 : -320), in: target)
                }
            },
            stage: true)
    }

    // MARK: - Shared

    private var browserParameter: ModelSkillSchema.Parameter {
        .init(
            name: "app", type: "string",
            description: "Which browser. Omit for the one they're using.",
            required: false)
    }

    /// Resolve the browser, run the operation, and answer in Mary's vocabulary.
    private func run(
        _ named: String?,
        _ body: (BrowserTarget) async -> BrowserOutcome
    ) async -> SkillOutcome {
        guard let (registration, pid) = support.resolve(named) else {
            let running = support.runningDisplayNames()
            if running.count > 1 {
                return SkillOutcome(
                    ok: true,
                    summary: BrowserRefusal.ambiguousBrowser(running).summary,
                    foundNothing: true)
            }
            if let named, !named.isEmpty { return ClosedWorld.read(app: named) }
            return SkillOutcome(
                ok: true, summary: BrowserRefusal.noBrowser.summary, foundNothing: true)
        }
        let target = BrowserTarget(registration: registration, processIdentifier: pid)
        let outcome = await body(target)
        return SkillOutcome(
            ok: outcome.ok,
            summary: outcome.spoken,
            archivePolicy: .stateSnapshot,
            // A REFUSAL THAT FOUND NOTHING IS A MISS, NOT A FAILURE — no player on the
            // page is an answer, and a turn that says so beats one reporting an error.
            foundNothing: outcome.refusal.map(Self.isMiss) ?? false,
            adapterTrail: ["web-surface"],
            // THE PROFILE ID, NEVER THE LOGICAL PLACE. Evidence of where the act landed
            // has to name the process that served it, or the habit ledger learns
            // "browser" and can never answer which one.
            applicationID: registration.applicationID)
    }

    /// Which refusals mean "there was nothing there" rather than "it went wrong".
    static func isMiss(_ refusal: BrowserRefusal) -> Bool {
        switch refusal {
        case .noBrowser, .ambiguousBrowser, .controlsNotFound, .controlNotFound,
             .elementNotFound:
            return true
        default:
            return false
        }
    }
}
