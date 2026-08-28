//
//  WebProbeCanvas.swift
//  WebProbe
//
//  A DECLARED WEB CANVAS, DRIVEN — the whole shaderfeel choreography against
//  the real site, through the shipped Skill.
//
//  The verdict RULES are pinned against fixtures in `WebCanvasVerdictTests`,
//  and they are correct in the abstract. What no fixture can say is whether
//  the declaration matches the site: whether that address still loads, the
//  consent labels are still those words, the editor is findable, the run
//  chord still runs, and the failure phrases are still the ones printed. All
//  five are facts about somebody else's website, and all five can change
//  without anything here failing to compile.
//
//  IT WRITES A REAL SHADER TO A REAL SITE and leaves the tab open, which is
//  why it is its own subcommand and not part of `skills`.
//

import AppKit
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum WebProbeCanvas {

    /// A DELIBERATELY VALID shader, so a failure verdict means the lane is
    /// wrong rather than the shader. Its companion below is deliberately
    /// broken, which is the only way to see the failure path at all.
    static let good = """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        vec2 uv = fragCoord / iResolution.xy;
        vec3 col = 0.5 + 0.5 * cos(iTime + uv.xyx + vec3(0.0, 2.0, 4.0));
        fragColor = vec4(col, 1.0);
    }
    """

    static let broken = """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        this is not glsl at all;
    }
    """

    static func run(browser: String?) async {
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
        WebCanvasSupport.shared.reconcile(
            MaryRuntime.webCanvasRegistrations(from: load.snapshot))
        AmbientApplicationBridge.install(
            profiles: adapters.map(\.applicationProfile)
                + load.snapshot.plugins.applicationProfiles)

        guard let canvas = WebCanvasSupport.shared.all().first else {
            print("  ✗  no web canvas is declared.")
            return
        }
        print("""
        ▸ \(canvas.displayName) — \(canvas.schema.address)
          content     \(canvas.schema.contentNoun), \
        ≤ \(canvas.schema.contentLimitBytes / 1000)k\
        \(canvas.schema.requiredContentMarker.map { ", must contain \($0)" } ?? "")
          run chord   \(canvas.schema.runChord.modifiers.map(\.rawValue).joined(separator: "+"))\
        \(canvas.schema.runChord.modifiers.isEmpty ? "" : "+")\(canvas.schema.runChord.key.rawValue)
          failure     \(canvas.schema.diagnosticPhrases.joined(separator: ", "))
          disbelieved \(canvas.schema.statusMarker ?? "—")
        """)

        guard let adapter = adapters.first(where: { $0.name == "browser-surface" }),
              let binding = adapter.skillBindings.first(
                where: { $0.name == "compose_in_web_canvas" }),
              case .native(let run) = binding.backing
        else {
            print("  ✗  compose_in_web_canvas is not published.")
            return
        }

        // A browser must be NAMED: this is a CLI, so the Terminal is
        // frontmost and the ladder correctly refuses to guess between two.
        let target = browser ?? BrowserSurfaceSupport.shared.runningDisplayNames().first
        guard let target else {
            print("  ✗  no declared browser is running.")
            return
        }
        print("  browser     \(target)\n")

        // BOTH PATHS, because a lane that can only be seen succeeding has an
        // untested half — and the failure half is the one carrying the
        // "disbelieve the status marker" rule.
        for (label, shader) in [("a valid shader", good), ("a broken one", broken)] {
            print("▸ \(label)")
            let started = Date()
            do {
                let outcome = try await run(
                    ["content": shader, "opening": "Here's how it looks.",
                     "browser": target],
                    AbilityExecutionContext(projects: [:]))
                print(String(
                    format: "  %@  %.1f s\n    %@",
                    outcome.ok ? "ok" : "REPORTED A PROBLEM",
                    Date().timeIntervalSince(started),
                    outcome.summary))
            } catch {
                print("  THREW  \(error.localizedDescription)")
            }
            print("")
        }
        print("  Both tabs are left open — closing one raises a confirmation.")
    }
}
