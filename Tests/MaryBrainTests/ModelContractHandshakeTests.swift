//
//  ModelContractHandshakeTests.swift
//  MaryBrainTests
//
//  DOES THE MODEL ACTUALLY LEARN WHAT A SKILL TAKES?
//
//  THE FAILURE THIS IS THE REGRESSION FOR, because nothing about it looks like
//  a failure from any single vantage point. `shaderfeel.mary` declared its
//  content parameter as "a complete GLSL fragment shader with a mainImage
//  entry point". The model was shown "The text to place in the tool's editor."
//  It invented a parameter called `text`, put the user's own sentence in it,
//  and the adapter correctly reported that there was nothing to put in the
//  editor.
//
//  Every check in this repository passed. The package was valid, the graph
//  activated, the handshake was ready, the schema was well formed. The
//  DECLARED CONTRACT simply never reached the model, because
//  `AbilityRuntime.projectedSchema` takes the declared parameter NAME and the
//  ADAPTER's description — deliberately, since package prose may never reach
//  the prompt.
//
//  So there are two properties worth pinning, and they pull in opposite
//  directions:
//
//    1. THE NAMES MUST JOIN. A declared parameter with no counterpart on the
//       adapter projects as "Typed input <name>." and its value is dropped on
//       the floor at the guard — the exact symptom above, from a different
//       cause. That join is checked here rather than in the package validator
//       because an adapter's manifest does not carry parameter names, and
//       teaching it to would mean every adapter declaring its parameters
//       TWICE — the second declaration to disagree with the first eventually.
//
//    2. THE DESCRIPTION MUST SAY SOMETHING. A required parameter whose only
//       guidance is the adapter's generic sentence is how a contract empties
//       out silently. This cannot be a rule about wording, so it is pinned
//       where the wording is derived instead — see `WebCanvasContractTests`.
//

import Foundation
import Testing
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct ModelContractHandshakeTests {

    @Test func everyDeclaredParameterJoinsOneOnItsAdapter() throws {
        guard let abilities = InstalledPackages.installed() else { return }

        let adapters = MaryAdapterCatalog.adapters()
        let manifests = MaryAdapterCatalog.adapterManifests(
            adapters: adapters,
            observers: MaryAdapterCatalog.observers())

        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        let report = library.configureAndLoad(
            adapterManifests: manifests,
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            locations: [.init(directory: abilities, source: .sourceTree, priority: 20)],
            installedDirectory: nil)
        #expect(report.activated, "the shipped packages did not activate")

        // Every compiled adapter's bindings, by operation name.
        var bindings: [String: SkillBinding] = [:]
        for adapter in adapters {
            for binding in adapter.skillBindings { bindings[binding.name] = binding }
        }

        var checked = 0
        for skill in report.snapshot.skills {
            guard let operation = skill.reference.bindingOperation,
                  let binding = bindings[operation]
            else { continue }
            let declared = skill.skill.modelExposure.parameters
            guard !declared.isEmpty else { continue }
            checked += 1

            let offered = Set(binding.parameters.map(\.name))
            for parameter in declared where !offered.contains(parameter.name) {
                Issue.record(
                    """
                    \(skill.skill.id.rawValue) exposes "\(parameter.name)" but \
                    \(operation) has no such parameter — the model would be shown it, \
                    send it, and have the value dropped. Offered: \
                    \(offered.sorted().joined(separator: ", ")).
                    """)
            }
        }
        #expect(checked > 0, "no shipped Skill declares its own model parameters")
    }

    /// ⚠️ THE ONE THAT WOULD HAVE CAUGHT IT. Not a general rule — a specific
    /// claim about the Skill that failed: by the time the model sees
    /// `show_feeling_shader`, the words "shader" and "mainImage" are in front
    /// of it. Both come from the package's own declaration, shaped into Mary's
    /// sentence by `WebCanvasContract`; neither is hardcoded anywhere.
    @Test func theCanvasSkillTellsTheModelWhatItIsWriting() throws {
        let adapters = MaryAdapterCatalog.adapters()
        guard let browser = adapters.first(where: { $0.name == "browser-surface" }) else {
            Issue.record("the browser surface adapter is not installed")
            return
        }
        WebCanvasSupport.shared.reconcile([
            WebCanvasRegistration(
                canvasID: "shaderfeel",
                displayName: "ShaderFeel",
                schema: .init(
                    address: "https://example.com/new",
                    contentNoun: "shader",
                    contentLimitBytes: 32000,
                    requiredContentMarker: "mainImage",
                    runChord: .init(key: .return, modifiers: [.option]))),
        ])
        defer { WebCanvasSupport.shared.reconcile([]) }

        let binding = browser.skillBindings.first { $0.name == "compose_in_web_canvas" }
        let content = binding?.parameters.first { $0.name == "content" }
        #expect(content?.description.contains("shader") == true)
        #expect(content?.description.contains("mainImage") == true)

        // And the half a schema cannot carry: that the model is the one who
        // writes it.
        let fragment = browser.promptFragment ?? ""
        #expect(fragment.lowercased().contains("write it yourself"))
    }
}
