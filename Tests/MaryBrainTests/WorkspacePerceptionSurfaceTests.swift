//
//  WorkspacePerceptionSurfaceTests.swift
//  MaryBrainTests
//
//  A WORKSPACE CLAIM IS HONOURED FOR EVERY OBSERVATION SURFACE, or this
//  fails — and it failed silently for three of the four until a live pass.
//
//  THE DEFECT, which is the reason this file exists rather than a line in
//  some other suite: two gates ask the same question and only one of them was
//  ever updated. `PluginValidator` refuses a workspace perception claim from
//  a package declaring no observation surface, and it was widened as each
//  lane landed — prose, then media, then corpus, then browser.
//  `PluginCompiler.perception` asks the same question at compilation and went
//  on checking `proseSurface` alone.
//
//  NOTHING FAILS WHEN THEY DISAGREE. The package is admitted, its workspace
//  claim is quietly downgraded to `.perceptionOnly`, `observesDocuments`
//  stays false, and the place reports `hasEyes == false` for an application
//  that plainly has them. The consequence is not an error anywhere: the
//  application is simply never treated as somewhere the user is working, so
//  the reference ladder skips it, the focus arbiter ignores it, and every
//  symptom is something else being chosen instead.
//
//  Found by `mary-web-probe lane` — a live pass over the shipped
//  configuration — after every unit test, the package probe and the manifest
//  guard were green. It had been true of the media and corpus lanes since
//  they landed.
//

import MaryAmbient
import MaryFoundation
import Testing
@testable import MaryBrain

@Suite struct WorkspacePerceptionSurfaceTests {

    /// A minimal application plugin claiming workspace perception, carrying
    /// exactly one surface — or none.
    private func plugin(
        prose: Bool = false, media: Bool = false,
        corpus: Bool = false, browser: Bool = false
    ) -> PluginSchema {
        PluginSchema(
            id: "probe",
            title: "Probe",
            application: PluginApplicationSchema(
                id: "probe",
                title: "Probe",
                bundleIdentifiers: ["com.example.probe"],
                perception: PluginApplicationPerceptionSchema(kind: .workspace)),
            adapter: PluginAdapterSchema(
                id: "probe.managed-ui", title: "Probe", engine: .macUI,
                permissions: [.accessibility]),
            operations: [],
            realizations: [],
            proseSurface: prose ? Self.proseSurface : nil,
            mediaSurface: media ? Self.mediaSurface : nil,
            corpus: corpus ? Self.corpus : nil,
            browserSurface: browser ? Self.browserSurface : nil)
    }

    private static let proseSurface = PluginProseSurfaceSchema(
        handlePrefix: "P", editorRoles: [.textArea],
        documentNoun: PluginProseDocumentNoun(singular: "note", plural: "notes"))
    private static let mediaSurface = PluginMediaSurfaceSchema(
        transportLabel: "Transport", playingLabel: "Pause", pausedLabel: "Play")
    private static let corpus = PluginCorpusSchema(include: ["swift"], notation: "swift")
    private static let browserSurface = PluginBrowserSurfaceSchema(
        tabStripRole: "AXTabGroup",
        tabNameAttribute: .description,
        selectionSignal: .selectedAttribute)

    /// EVERY SURFACE EARNS EYES. Parameterized rather than four functions so
    /// that adding a fifth surface and forgetting this file produces one
    /// obvious hole rather than a passing suite.
    @Test(arguments: ["prose", "media", "corpus", "browser"])
    func aWorkspaceClaimBackedByAnySurfaceKeepsItsEyes(surface: String) {
        let schema = switch surface {
        case "prose": plugin(prose: true)
        case "media": plugin(media: true)
        case "corpus": plugin(corpus: true)
        default: plugin(browser: true)
        }
        let perception = PluginCompiler.perception(
            from: schema.application.perception,
            declaresObservationSurface: schema.proseSurface != nil
                || schema.mediaSurface != nil
                || schema.corpus != nil
                || schema.browserSurface != nil)

        #expect(
            perception?.kind == .workspace,
            "a \(surface) surface should keep the workspace claim it declared")
        #expect(
            perception?.observesDocuments == true,
            "a \(surface) surface should give the place eyes")
    }

    /// AND A CLAIM WITH NOTHING BEHIND IT IS STILL REFUSED. The gate is not
    /// merely widened: a package that declares no surface at all must go on
    /// being downgraded, or the validator's rule means nothing at runtime.
    @Test func aWorkspaceClaimWithNoSurfaceIsStillDowngraded() {
        let perception = PluginCompiler.perception(
            from: plugin().application.perception,
            declaresObservationSurface: false)
        #expect(perception?.kind == .perceptionOnly)
        #expect(perception?.observesDocuments == false)
    }

    /// A package asking only for `perceptionOnly` gets it either way — it is
    /// claiming the generic Accessibility read, not eyes on a workspace.
    @Test func aPerceptionOnlyClaimIsUnaffectedBySurfaces() {
        let schema = PluginApplicationPerceptionSchema(kind: .perceptionOnly)
        for declares in [true, false] {
            let perception = PluginCompiler.perception(
                from: schema, declaresObservationSurface: declares)
            #expect(perception?.kind == .perceptionOnly)
            #expect(perception?.observesDocuments == false)
        }
    }
}
