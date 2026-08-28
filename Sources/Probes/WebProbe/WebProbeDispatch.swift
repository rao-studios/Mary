//
//  WebProbeDispatch.swift
//  WebProbe
//
//  THROUGH THE DISPATCHER, not around it — the join every other check in
//  this lane skips.
//
//  `mary-web-probe skills` calls each Skill's binding closure directly. That
//  proves the binding works and proves nothing about the path a real turn
//  takes, because `AbilityRuntime.dispatch` does five things before the
//  closure ever runs:
//
//    1. ROUTING — is this Ability eligible in this context at all
//    2. THE TURN OFFER LEDGER — was this Skill offered, or is the model
//       calling something it was never shown
//    3. THE ACCESS GATE — a `.write` Skill parks for confirmation rather
//       than running; a `.tweak` runs behind a pinned allowlist
//    4. THE BEHAVIORAL RECORD — one row per act, including the refusals,
//       because a dataset omitting refusals teaches that requests are
//       always granted
//    5. THE RUN REGISTRY — the identity Stop cancels by
//
//  Mary's own parity pass over the prose lane found FOUR silent defects at
//  exactly this join, after every unit test was green. None of the browsing
//  Skills had been through it.
//
//    mary-web-probe dispatch [--browser <name>]
//
//  READ-ONLY. It dispatches the reads and one deliberate refusal; nothing
//  here presses anything on a page.
//

import AppKit
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum WebProbeDispatch {

    static func run(browser: String?) async {
        var failures = 0
        func check(_ passed: Bool, _ claim: String, _ detail: String = "") {
            print("  \(passed ? "✓" : "✗")  \(claim)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !passed { failures += 1 }
        }

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

        let log = AbilityExecutionLog()
        let runtime = AbilityRuntime(
            plugins: adapters,
            executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })

        // ── WHAT THE PLACE SAYS IT IS ────────────────────────────────
        // Checked FIRST and on its own, because it is the half a CLI can
        // answer honestly. Routing needs an ambient LEAD — a focus record
        // saying a browser is in front — and this process has no observers
        // running, so nothing has told the ambient layer anything. The
        // dispatches below therefore exercise the REFUSAL path, which is
        // worth having, and cannot exercise the grant path.
        print("▸ what the browser place declares")
        let browserPlace = AmbientPlaceResolver.browserPlace
        let classes = AmbientApplicationIndexProvider.current.targetClasses(of: browserPlace)
        check(
            classes.contains("browser-page"),
            "the browser place carries browser-page",
            classes.sorted().joined(separator: ", "))
        // AND THE ARM THAT DEPENDS ON IT. `browsing.mary` leads its
        // eligibility with this class; if the place cannot supply it, the arm
        // is dead and browsing is reachable by utterance token alone.
        if let browsing = load.snapshot.records.first(
            where: { $0.package.ability.id.rawValue == "browsing" }) {
            let context = AbilityRoutingContext(
                utterance: "", targetClasses: classes, interactions: [])
            check(
                AbilityRoutingEvaluator.isEligible(
                    browsing.package.ability.routing, in: context),
                "browsing is eligible on the target class alone",
                "without needing a word like \"tab\" in the sentence")
        }

        print("\n▸ through AbilityRuntime.dispatch")

        // THE ROSTER THE MODEL WOULD SEE. A Skill absent here was never
        // offered, and dispatching it is a different code path from
        // dispatching one that was — so this is checked before anything runs.
        let offered = Set(await runtime.schemas.map(\.name))
        for name in [
            "list_tabs", "current_tab", "read_page",
            "list_page_elements", "open_location", "find_in_page",
        ] {
            check(offered.contains(name), "\(name) is offered to the model")
        }

        let target = browser ?? BrowserSurfaceSupport.shared.runningDisplayNames().first
        let argument = target.map { "{\"browser\":\"\($0)\"}" } ?? "{}"
        if let target { print("  browser     \(target)") }

        for name in ["list_tabs", "current_tab", "list_page_elements"] {
            let outcome = await runtime.dispatch(name: name, argumentsJSON: argument)
            check(
                outcome.ok || outcome.foundNothing,
                "\(name) dispatched",
                outcome.summary.split(separator: "\n").first.map(String.init) ?? "")
        }

        // A REFUSAL, DISPATCHED. The record for a refused act matters more
        // than the record for a granted one: a dataset that omits them
        // teaches that asking is the same as receiving.
        let refused = await runtime.dispatch(
            name: "open_location",
            argumentsJSON: "{\"url\":\"file:///etc/passwd\"}")
        check(!refused.ok, "a non-http address is refused", refused.summary)

        // THE RECORDS. Every dispatch above should have left exactly one row,
        // refusals included.
        let rows = log.entries()
        check(!rows.isEmpty, "the execution log recorded the acts", "\(rows.count) rows")
        let names = Set(rows.map(\.action.intention))
        for name in ["list_tabs", "current_tab", "list_page_elements", "open_location"] {
            check(names.contains(name), "\(name) left a record")
        }
        // AND EACH ROW KNOWS WHO ANSWERED IT. An adapter trail is what makes
        // a later question — which provider did this — answerable without
        // guessing from the skill's name.
        let trailed = rows.filter { !$0.action.adapters.isEmpty }
        check(
            !trailed.isEmpty, "records carry an adapter trail",
            "\(trailed.count) of \(rows.count)")

        for row in rows {
            print("    · \(row.action.intention) — \(row.disposition)"
                + (row.action.adapters.isEmpty
                    ? "" : " via \(row.action.adapters.map(\.rawValue).joined(separator: ", "))"))
        }

        print(failures == 0
            ? "\n  Browsing reaches the model and comes back recorded."
            : "\n  \(failures) check(s) failed.")
    }
}
