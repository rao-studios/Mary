//
//  WebProbeSkills.swift
//  WebProbe
//
//  THE SKILLS THEMSELVES, CALLED — against a real browser, through the
//  shipped adapter, with the shipped registrations behind them.
//
//  `lane` proves the packages load and the Skills are offered. `roster`
//  proves the AX reads work. Neither proves the thing in between: that
//  calling a Skill by the name the model would use, with the arguments the
//  model would send, produces the sentence the user would hear. That join is
//  where a wrong parameter name, a refusal that fires on the happy path, or a
//  summary composed from the wrong browser lives — and none of it shows up in
//  a unit test, because the adapter's bindings are closures over live state.
//
//    mary-web-probe skills                 read-only: list, current, page
//    mary-web-probe skills --act           also switches a tab and back
//
//  READ-ONLY BY DEFAULT, deliberately. This drives the user's real browser,
//  and a probe that rearranged their tabs merely by being run would be a
//  probe nobody runs.
//

import AppKit
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum WebProbeSkills {

    static func run(act: Bool) async {
        // The same install `lane` performs — the shipped configuration, not a
        // hand-built fixture.
        ProseSurfaceSupport.shared.installBackingResolver()
        AmbientCapabilityBridge.install()
        let adapters = MaryAdapterCatalog.adapters()
        let observers = MaryAdapterCatalog.observers()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: observers),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])
        BrowserSurfaceSupport.shared.reconcile(
            MaryRuntime.browserSurfaceRegistrations(from: load.snapshot))
        AmbientApplicationBridge.install(
            profiles: adapters.map(\.applicationProfile)
                + load.snapshot.plugins.applicationProfiles)

        guard let adapter = adapters.first(where: { $0.name == "browser-surface" }) else {
            print("  ✗  no browser-surface adapter in the catalog.")
            return
        }
        let bindings = Dictionary(
            adapter.skillBindings.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        /// Call one Skill the way the dispatcher does.
        func call(_ name: String, _ arguments: [String: String] = [:]) async {
            guard let binding = bindings[name] else {
                print("  ✗  \(name) — no such binding")
                return
            }
            let shown = arguments.isEmpty
                ? ""
                : "(" + arguments.map { "\($0.key): \($0.value)" }.sorted()
                    .joined(separator: ", ") + ")"
            print("\n▸ \(name)\(shown)")
            guard case .native(let run) = binding.backing else {
                print("  (not a native binding)")
                return
            }
            let started = Date()
            let outcome: SkillOutcome
            do {
                outcome = try await run(
                    arguments, AbilityExecutionContext(projects: [:]))
            } catch {
                print("  THREW  \(error.localizedDescription)")
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            print(String(
                format: "  %@  %.0f ms%@",
                outcome.ok ? "ok" : "REFUSED", elapsed * 1000,
                outcome.foundNothing ? "  (found nothing)" : ""))
            for line in outcome.summary.split(separator: "\n").prefix(12) {
                print("    \(line)")
            }
            if outcome.summary.split(separator: "\n").count > 12 { print("    …") }
        }

        // WITH NO ARGUMENT AT ALL, which is how the model will call these
        // most of the time — and the path where "two browsers are open, which
        // one?" fires. That refusal is a correct outcome here, not a failure.
        await call("list_tabs")
        await call("current_tab")
        await call("read_page")
        await call("list_page_elements")
        await call("list_page_elements", ["kind": "link"])

        // AND NAMED, which is the ladder's top rung and the one a refusal
        // above sends the user to.
        for browser in BrowserSurfaceSupport.shared.runningDisplayNames() {
            await call("list_tabs", ["browser": browser])
        }

        guard act else {
            print("\n  Read-only. Pass --act to switch a tab and switch back.")
            return
        }

        // NAMED, not resolved by focus. This probe is a CLI, so the Terminal
        // is frontmost while it runs and the ladder falls through to "two
        // browsers are visible, which one?" — which is the ladder being
        // RIGHT, and makes the unnamed form useless from here. `--browser`
        // picks; otherwise the first declared running one.
        let wanted = value("--browser")
            ?? BrowserSurfaceSupport.shared.runningDisplayNames().first
        guard let (registration, target) = BrowserSurfaceSupport.shared.resolve(wanted) else {
            print("\n  No browser to act on\(wanted.map { " named \($0)" } ?? "").")
            return
        }
        print("\n  acting on \(registration.displayName)")
        let tabs = BrowserTabRoster.read(
            pid: target.processIdentifier, surface: registration.schema)
        guard let current = tabs.first(where: { $0.isCurrent == true }),
              let other = tabs.first(where: { $0.isCurrent != true })
        else {
            print("\n  Need two tabs and a readable current one to act safely.")
            return
        }

        // SWITCH AWAY AND BACK. The probe leaves the browser as it found it,
        // which is what makes running it a safe thing to do twice.
        print("\n  (currently on \"\(current.name)\")")
        await call("activate_tab", ["tab": other.name, "browser": registration.displayName])
        await call("activate_tab", ["tab": current.name, "browser": registration.displayName])

        // THE PAGE VERBS, and only the ones that leave the page where it is.
        // `click_on_page` is deliberately NOT driven here: pressing a real
        // link navigates the user's own tab away from whatever they were
        // reading, and a probe that costs the user their place is a probe
        // they stop running. Its ladder is exercised by the two refusals
        // below, which reach the same resolver and touch nothing.
        let page = PageControlsReader.read(
            inApp: WebSurface.application(pid: target.processIdentifier))
        if let first = page.first {
            await call("scroll_to_on_page", ["target": first.label, "browser": registration.displayName])
        }
        // A MISS and an AMBIGUITY, both of which must be sentences rather
        // than errors — and neither of which presses anything.
        await call("click_on_page", ["target": "a control no page has ever had", "browser": registration.displayName])
        if let repeated = Self.repeatedLabel(in: page) {
            await call("click_on_page", ["target": repeated, "browser": registration.displayName])
        }
        // FILLING A FIELD — the same focus-then-replace path the web-canvas
        // lane uses to put a shader in an editor, which is the half of that
        // choreography a fixture cannot reach.
        if let field = page.first(where: { $0.kind == .field }) {
            await call(
                "fill_in_page",
                ["target": field.label, "text": "mary was here",
                 "browser": registration.displayName])
        }
        // AND THE ROAD THAT REFUSAL PROMISES. It tells the user to name the
        // thing by number, so this proves that form actually resolves — a
        // refusal offering an answer that does not work is worse than one
        // that offers none.
        await call(
            "scroll_to_on_page",
            ["target": "the third link", "browser": registration.displayName])
    }

    /// A label two or more elements share, for exercising the ambiguity
    /// refusal against whatever page happens to be open.
    static func repeatedLabel(in elements: [PageElement]) -> String? {
        var counts: [String: Int] = [:]
        for element in elements where !element.label.isEmpty {
            counts[element.label, default: 0] += 1
        }
        return counts.first { $0.value > 1 }?.key
    }
}
