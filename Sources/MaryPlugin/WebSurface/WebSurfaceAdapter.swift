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
        page is read from pixels. Say the site, never the address. READ THE PAGE BEFORE \
        NAMING SOMETHING ON IT — read_page lists what is there, numbered, and \
        click_on_page, fill_in_page and scroll_to_on_page take those words back. To \
        search the web use search_web, which types the query into the browser's own \
        address bar; to search WITHIN a site, open it and fill_in_page its search box \
        with submit. Drive a video INSIDE THIS PAGE with control_media — never a site's \
        keyboard shortcut. For the music app, or for whatever is playing \
        system-wide, control_playback is the one that reaches it.
        """
    }

    public var targetedRead: (binding: String, parameter: String)? {
        (binding: "current_page", parameter: "app")
    }

    /// THE PLACE A BROWSER LEADS AS, which is not this adapter's name.
    ///
    /// PIN: EVERY BROWSER COLLAPSES TO ONE WORKSPACE — `AmbientPlaceResolver`
    /// resolves Safari, Chrome and every Chromium variant to the single logical
    /// application `"browser"`, deliberately. Fetch-first looks a read up by the
    /// LEAD PLACE'S token, so without this the browsing reads were addressed by
    /// a name no place is ever spelled with, and `fetchAwareness` fell through
    /// to catalog order — pre-reading the code buffer for a question about a
    /// page. See `AbilityRuntime.readOwnerKeys`.
    public var readOwnerAliases: [String] {
        [AmbientPlaceResolver.browserApplicationID]
    }

    /// MARY'S OWN READ OF A PAGE, before either lane speaks.
    ///
    /// PIN: THE BROWSING HALF OF THE FETCH-FIRST LANE, which existed only for
    /// code and prose. "What do you think about this code" reads the buffer
    /// first; "what do you think of this article" read nothing at all, so the
    /// answer was about a title. The unit is what the page SAYS; the
    /// surroundings are which page it is. `fetchAwareness`'s own gates decide
    /// when — a question or a deictic remark, never an action turn, so
    /// "click that link" still does its own reading inside the skill.
    public var awarenessRead: AwarenessRead? {
        AwarenessRead(unit: "read_page_text", surroundings: "current_page")
    }

    /// WHICH PAGE THE BROWSER IS ON, every turn.
    ///
    /// PIN: THE SHELL, NEVER THE PAGE. Title and site come from Accessibility;
    /// what is INSIDE the page is pixels, and pixels are read when a Skill asks
    /// and at no other time. THE SITE, NOT THE ADDRESS — a URL in a transcript
    /// is both unreadable and more than was asked for.
    /// The same sentence `current_page` answers with, so the prompt line and
    /// the spoken answer never drift.
    public func turnPerceptions() async -> [DeclaredPerception] {
        guard let (registration, pid) = support.resolve(nil),
              let reading = WebSurfaceAX.read(pid: pid, registration: registration)
        else { return [] }
        return [DeclaredPerception(
            schemaID: "perception.page-context",
            value: ValueEnvelope(
                typeID: "browsing.page-report",
                value: .string(
                    BrowserEngine.spoken(reading, browser: registration.displayName)),
                // Scope = process read. Two browsers hold two readings.
                scope: SourceScope(
                    applicationID: registration.applicationID, processID: pid),
                provenance: .init(operation: "current_page"),
                privacy: .private))]
    }

    public var refusals: [String] {
        ["I can't fill in a page that shows me no field to type into."]
    }

    public var skillBindings: [SkillBinding] {
        [currentPage, listTabs, describeMedia, controlMedia,
         openLocation, navigateBack, navigateForward, reloadPage, scrollPage,
         readPage, readPageText, clickOnPage, fillInPage, scrollToOnPage,
         adjustOnPage, searchWeb, interactWithPage]
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
                operation("read_page", capability: "browser.page.read",
                          input: "browsing.page-query", output: "browsing.page-listing"),
                operation("read_page_text", capability: "browser.page.read",
                          input: "browsing.page-query", output: "browsing.page-listing"),
                operation("click_on_page", capability: "browser.page.press",
                          input: "browsing.page-target", output: "browsing.operation-result"),
                operation("fill_in_page", capability: "browser.page.fill",
                          input: "browsing.page-fill", output: "browsing.operation-result"),
                operation("scroll_to_on_page", capability: "browser.page.act",
                          input: "browsing.page-target", output: "browsing.operation-result"),
                operation("adjust_on_page", capability: "browser.page.act",
                          input: "browsing.page-fill", output: "browsing.operation-result"),
                operation("search_web", capability: "browser.page.search",
                          input: "browsing.search-query", output: "browsing.page-listing"),
                operation("interact_with_page", capability: "browser.page.act",
                          input: "browsing.page-plan", output: "browsing.operation-result"),
            ],
            providesPerceptions: ["perception.page-context"],
            supportedValueTypes: [
                "browsing.browser-query",
                "browsing.page-query",
                "browsing.page-listing",
                "browsing.page-target",
                "browsing.page-fill",
                "browsing.page-plan",
                "browsing.search-query",
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
                Play, pause, mute, unmute, go full screen, set the volume, or skip to a \
                position in the video on the page the browser is showing. Use for \
                "pause the video", "mute this", "skip to halfway", "turn it down".
                """,
            parameters: [
                .init(
                    name: "action", type: "string",
                    description: "What to do to the player.",
                    required: true,
                    enumValues: [
                        "play", "pause", "toggle", "mute", "unmute", "fullscreen",
                        "seek", "volume",
                    ]),
                .init(
                    name: "position", type: "string",
                    description: "For seek, how far through; for volume, how loud. 0 to 1.",
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
                case "volume":
                    // A VOLUME WITHOUT A LEVEL IS NOT A SETTING. Choosing one would put
                    // somebody's sound where nobody asked for it.
                    guard let fraction = arguments["position"].flatMap(Double.init),
                          (0 ... 1).contains(fraction)
                    else {
                        return SkillOutcome(
                            ok: false,
                            summary: "Tell me how loud — halfway, or a quarter.")
                    }
                    action = .volume(fraction: fraction)
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
            backing: .native { arguments, context in
                guard let address = arguments["address"], !address.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me where to go.")
                }
                // A DEEP LINK THE MODEL WROTE IS A CLAIM ABOUT SOMEBODY ELSE'S DATABASE.
                // A host it may hold; an identifier it can only have invented, unless
                // the person said it. See SpokenAddress.
                guard let admitted = SpokenAddress.admit(
                    address, spokenIn: context.utterance)
                else {
                    return SkillOutcome(
                        ok: false, summary: SpokenAddress.refusal(for: address))
                }
                return await self.run(arguments["app"]) { target in
                    await self.engine.navigate(.open(admitted), in: target)
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

    // MARK: - The page

    private var readPage: SkillBinding {
        SkillBinding(
            name: "read_page",
            description: """
                Look at the page the browser is showing and list what can be acted on — \
                results, links, videos, fields and buttons, numbered. Do this before \
                naming something on a page you have not read this turn.
                """,
            parameters: [
                .init(name: "query", type: "string",
                      description: "Narrow the listing to things matching these words.",
                      required: false),
                browserParameter,
            ],
            access: .read,
            backing: .native { arguments, _ in
                await self.run(arguments["app"]) { target in
                    await self.engine.readPage(in: target, query: arguments["query"])
                }
            },
            // READING A PAGE MEANS READING ITS PIXELS, and pixels of a window behind
            // another window are the other window's.
            stage: true)
    }

    private var readPageText: SkillBinding {
        SkillBinding(
            name: "read_page_text",
            description: """
                Read what the page SAYS — its headings and prose, top to bottom — \
                so you can answer a question about it, summarise it, or give a view \
                on it. read_page is the other one: what can be pressed.
                """,
            parameters: [browserParameter],
            access: .read,
            backing: .native { arguments, _ in
                await self.run(arguments["app"]) { target in
                    await self.engine.readPageText(in: target)
                }
            },
            stage: true)
    }

    private var clickOnPage: SkillBinding {
        SkillBinding(
            name: "click_on_page",
            description: """
                Press something inside the page by name — a result, a link, a video, a \
                button. Use the words from read_page, or the person's own words.
                """,
            parameters: [
                .init(name: "target", type: "string",
                      description: "What to press, in words — \"the first result\", \"Accept all\".",
                      required: true),
                browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, context in
                guard let phrase = arguments["target"], !phrase.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me what to press.")
                }
                return await self.run(arguments["app"]) { target in
                    await self.engine.pressOnPage(
                        phrase, in: target, deadline: context.deadline)
                }
            },
            stage: true)
    }

    private var fillInPage: SkillBinding {
        SkillBinding(
            name: "fill_in_page",
            description: """
                Type into a field inside the page — a search box, a form. Set submit to \
                press Return afterwards, which is how you search within a site.
                """,
            parameters: [
                .init(name: "target", type: "string",
                      description: "Which field. Omit to type where the cursor already is.",
                      required: false),
                .init(name: "text", type: "string",
                      description: "What to type.", required: true),
                .init(name: "submit", type: "string",
                      description: "\"true\" to press Return after typing.",
                      required: false, enumValues: ["true", "false"]),
                browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, context in
                guard let text = arguments["text"], !text.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me what to type.")
                }
                let submit = arguments["submit"]?.lowercased() == "true"
                return await self.run(arguments["app"]) { target in
                    await self.engine.fillOnPage(
                        arguments["target"], text: text, submit: submit,
                        in: target, deadline: context.deadline)
                }
            },
            stage: true)
    }

    private var scrollToOnPage: SkillBinding {
        SkillBinding(
            name: "scroll_to_on_page",
            description: """
                Scroll the page until something is on screen. Use when what was asked \
                for is further down than the page currently shows.
                """,
            parameters: [
                .init(name: "target", type: "string",
                      description: "What to bring into view.", required: true),
                browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, context in
                guard let phrase = arguments["target"], !phrase.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me what to look for.")
                }
                return await self.run(arguments["app"]) { target in
                    await self.engine.scrollToOnPage(
                        phrase, in: target, deadline: context.deadline)
                }
            },
            stage: true)
    }

    private var adjustOnPage: SkillBinding {
        SkillBinding(
            name: "adjust_on_page",
            description: """
                Set a slider on the page to a position — a volume control, a progress \
                bar, a range. Position is 0 to 1.
                """,
            parameters: [
                .init(name: "target", type: "string",
                      description: "Which slider.", required: true),
                .init(name: "position", type: "string",
                      description: "How far along, 0 to 1.", required: true),
                browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, context in
                guard let phrase = arguments["target"], !phrase.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me which slider.")
                }
                guard let fraction = arguments["position"].flatMap(Double.init),
                      (0 ... 1).contains(fraction)
                else {
                    return SkillOutcome(
                        ok: false, summary: "Tell me how far along to set it — halfway, or a third.")
                }
                return await self.run(arguments["app"]) { target in
                    await self.engine.adjustOnPage(
                        phrase, fraction: fraction, in: target, deadline: context.deadline)
                }
            },
            stage: true)
    }

    private var searchWeb: SkillBinding {
        SkillBinding(
            name: "search_web",
            description: """
                Search the web for something and show the results, opening one when the \
                person named which. The query goes into the browser's own address bar, \
                so it uses whichever search they have set up.
                """,
            parameters: [
                .init(name: "query", type: "string",
                      description: "What to search for.", required: true),
                .init(name: "open", type: "string",
                      description: "Which result to open — \"the first one\", or words from its title.",
                      required: false),
                browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, context in
                guard let query = arguments["query"], !query.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me what to search for.")
                }
                return await self.run(arguments["app"]) { target in
                    await self.engine.searchWeb(
                        query, in: target, open: arguments["open"],
                        deadline: context.deadline)
                }
            },
            stage: true,
            preparesSurface: true)
    }

    private var interactWithPage: SkillBinding {
        SkillBinding(
            name: "interact_with_page",
            description: """
                Carry out a short sequence of page gestures in one go, as a JSON array \
                of commands: click, hover, drag, keyChord, typeText, adjust, scroll, \
                wait. Name targets with words from a read_page you have already done. \
                Prefer the single verbs unless the steps genuinely belong together.
                """,
            parameters: [
                .init(name: "plan", type: "string",
                      description: "The commands, as one JSON array.", required: true),
                browserParameter,
            ],
            access: .tweak,
            backing: .native { arguments, context in
                guard let json = arguments["plan"], !json.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Tell me what the steps are.")
                }
                switch PageInteractionPlanValidator.validate(planJSON: json) {
                case .invalid(let issues):
                    // REFUSED BEFORE ANYTHING MOVES, and named so it can be fixed.
                    return SkillOutcome(
                        ok: false,
                        summary: BrowserRefusal.planInvalid(issues.map(\.spoken)).summary)
                case .valid(let plan):
                    return await self.run(arguments["app"]) { target in
                        await self.engine.act(plan, in: target, deadline: context.deadline)
                    }
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
        // A BROWSING ACT IS REAL WORK IN A PLACE.
        //
        // PIN: THE LEDGER IS WHAT KEEPS A PAGE IN THE CONVERSATION. `stickyLead`
        // and `admittedPlaceMentions` both key on `.activity` evidence, and only
        // the code, prose and corpus observers ever stamped it — so the moment
        // any other window came forward, the browser stopped leading and every
        // browsing skill fell out of the roster mid-conversation. Reading a page
        // or acting on one is exactly the "user was just here" this evidence
        // means. Stamped on a real outcome only: a refusal reached nothing.
        if outcome.ok {
            WorkspaceFocusTracker.shared.noteWork(
                place: AmbientPlaceResolver.browserPlace,
                processBundleID: registration.bundleIdentifiers.first)
        }
        return SkillOutcome(
            ok: outcome.ok,
            summary: outcome.spoken,
            archivePolicy: .stateSnapshot,
            // A REFUSAL THAT FOUND NOTHING IS A MISS, NOT A FAILURE — no player on the
            // page is an answer, and a turn that says so beats one reporting an error.
            foundNothing: outcome.refusal.map(Self.isMiss) ?? false,
            // PROVEN, NEVER MERELY ATTEMPTED. The continuation nudge reads this to
            // decide whether the asked-for change happened; a hopeful `true` is how a
            // turn closes on work it did not do.
            landed: outcome.landed,
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
             .elementNotFound, .ambiguousElement, .notFillable, .notAdjustable:
            return true
        default:
            return false
        }
    }
}
