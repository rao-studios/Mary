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

        // AND NAMED, which is the ladder's top rung and the one a refusal
        // above sends the user to.
        for browser in BrowserSurfaceSupport.shared.runningDisplayNames() {
            await call("list_tabs", ["browser": browser])
        }

        guard act else {
            print("\n  Read-only. Pass --act to switch a tab and switch back.")
            return
        }

        guard let (registration, target) = BrowserSurfaceSupport.shared.resolve() else {
            print("\n  No single browser to act on.")
            return
        }
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
        await call("activate_tab", ["tab": other.name])
        await call("activate_tab", ["tab": current.name])
    }
}
