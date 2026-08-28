//
//  WebProbeLane.swift
//  WebProbe
//
//  DOES THE BROWSING LANE ACTUALLY LOAD — the join no test can make.
//
//  Every other check in this repo asks a narrower question and gets a true
//  answer: the roster tests pin the assembly rules, `mary-package-probe`
//  says the packages are well formed, the manifest test says the adapter
//  declares its operations. All three passed while the predecessor's
//  equivalent lane was, at various times, entirely unreachable.
//
//  THE FAILURE THIS EXISTS TO CATCH IS THE ONE THAT LOOKS LIKE NOTHING. A
//  package can be individually valid and still be rejected by the GRAPH this
//  build assembles — that is exactly what happened in the parity pass that
//  found `writing.mary` declaring five skills whose lane was deferred: the
//  package probe called it valid because it IS, and the whole graph was
//  refused, and the symptom was an empty snapshot with no skills in it.
//  Nothing failed. There was simply nothing there.
//
//  So this runs `installBrainConfiguration`'s steps 1-3 VERBATIM — the same
//  seams, the same load, the same reconcile — and then asks the four
//  questions that can each be false while everything above is green:
//
//    1. did the package graph activate at all
//    2. did a browserSurface registration reach the runtime
//    3. is the browser place a place with EYES, and is its ability `browsing`
//    4. are the browsing Skills OFFERED, or installed and blocked
//
//  Hand-building a registration here would prove the lane works while saying
//  nothing about whether the packages declare it, which is the only question
//  a live pass is for.
//

import AppKit
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum WebProbeLane {

    static func run() async {
        var failures = 0
        func check(_ passed: Bool, _ claim: String, _ detail: String = "") {
            print("  \(passed ? "✓" : "✗")  \(claim)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !passed { failures += 1 }
        }

        // Steps 1-3 of the real install, minus the brain.
        ProseSurfaceSupport.shared.installBackingResolver()
        AmbientCapabilityBridge.install()

        let adapters = MaryAdapterCatalog.adapters()
        let observers = MaryAdapterCatalog.observers()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: observers),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])

        print("▸ the shipped configuration")
        check(
            load.activated, "the package graph activated",
            load.snapshot.records.map(\.package.ability.id.rawValue).sorted()
                .joined(separator: ", "))
        for issue in load.issues where issue.severity == .error {
            print("      ! \(issue.code): \(issue.message)")
        }

        // The reconcile the composition root performs.
        let registrations = MaryRuntime.browserSurfaceRegistrations(from: load.snapshot)
        BrowserSurfaceSupport.shared.reconcile(registrations)
        AmbientApplicationBridge.install(
            profiles: adapters.map(\.applicationProfile)
                + load.snapshot.plugins.applicationProfiles)

        check(
            !registrations.isEmpty, "a browser surface is declared",
            registrations.map(\.applicationID).sorted().joined(separator: ", "))

        for registration in registrations {
            let place = AmbientPlace.application(registration.applicationID)
            // A DISCIPLINE IS EARNED BY REALIZING A SKILL, never declared —
            // so this is really asking whether the package's realization of a
            // `browsing` skill reached the compiled profile. It came back
            // wrong for every application once already, when the world shrink
            // left the tie-breaker permanently empty and every taught app got
            // an alphabetical fallback over its own id.
            check(
                place.ability?.rawValue == "browsing",
                "\(registration.applicationID)'s place reads as browsing",
                place.ability?.rawValue ?? "no ability")
            check(place.hasEyes, "\(registration.applicationID)'s place has eyes")
        }

        // THE BROWSER IS ONE PLACE. Two packages, one workspace — the
        // carve-out that keeps a browser's facts from splitting in half.
        for registration in registrations {
            for bundleID in registration.bundleIdentifiers {
                check(
                    AmbientPlaceResolver.isBrowser(bundleID: bundleID),
                    "\(bundleID) is recognised as a browser",
                    AmbientPlaceResolver.browserName(bundleID: bundleID) ?? "unnamed")
            }
        }

        // THE QUESTION THE OTHER CHECKS CANNOT ANSWER: are the Skills
        // actually offered? A Skill can be installed, valid, and BLOCKED —
        // which is what an under-declared adapter manifest produces, and it
        // reports itself one Skill at a time rather than as a failure here.
        let browsingSkills = load.snapshot.skills
            .filter { $0.id.rawValue.hasPrefix("browsing.") }
        check(
            !browsingSkills.isEmpty, "browsing skills reached the roster",
            "\(browsingSkills.count)")

        // NOT VACUOUSLY. With no skills loaded at all, "none is blocked" is
        // true and reassuring and means nothing — which is exactly what it
        // printed the first time the packages failed to seal, right beside
        // the three checks that had already said so.
        let blocked = browsingSkills.filter { $0.availability.readiness == .blocked }
        check(
            blocked.isEmpty && !browsingSkills.isEmpty, "no browsing skill is blocked",
            blocked.isEmpty
                ? "\(browsingSkills.count) offered"
                : blocked.map { skill in
                    "\(skill.id.rawValue): "
                        + (skill.availability.reasons.first ?? "no reason given")
                }.sorted().joined(separator: "; "))

        // THE CANVAS LANE, which is a different question: a web canvas is
        // declared on the PACKAGE rather than on a plugin, so it reconciles
        // through its own path and can be absent while browsing is perfect.
        let canvases = MaryRuntime.webCanvasRegistrations(from: load.snapshot)
        WebCanvasSupport.shared.reconcile(canvases)
        if !canvases.isEmpty {
            check(
                true, "a web canvas is declared",
                canvases.map(\.canvasID).sorted().joined(separator: ", "))
            let canvasSkills = load.snapshot.skills.filter { skill in
                canvases.contains { skill.id.rawValue.hasPrefix("\($0.canvasID).") }
            }
            let canvasBlocked = canvasSkills.filter { $0.availability.readiness == .blocked }
            check(
                canvasBlocked.isEmpty && !canvasSkills.isEmpty,
                "no canvas skill is blocked",
                canvasBlocked.isEmpty
                    ? "\(canvasSkills.count) offered"
                    : canvasBlocked.map { skill in
                        "\(skill.id.rawValue): "
                            + (skill.availability.reasons.first ?? "no reason given")
                    }.sorted().joined(separator: "; "))
        }

        let partial = browsingSkills.filter { $0.availability.readiness == .partial }
        if !partial.isEmpty {
            print("      partial: " + partial.map(\.id.rawValue).sorted()
                .joined(separator: ", "))
        }

        // THE FIRST SHIPPED RECIPE WITH A MODEL-SUPPLIED INPUT. Its steps
        // are chords and a typeText that carries the model's own word, so
        // this is also the first time the text-expression path is exercised
        // by anything but a unit test.
        if let find = load.snapshot.skills.first(
            where: { $0.id.rawValue == "browsing.find-in-page" }) {
            check(
                find.availability.readiness != .blocked,
                "find_in_page is realized by a browser package",
                find.availability.selectedBinding?.operation ?? "no binding")
        }

        print(failures == 0
            ? "\n  The browsing lane is loaded and offered."
            : "\n  \(failures) check(s) failed.")
    }
}
