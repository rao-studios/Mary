//
//  MaryRuntime+BrainInstall.swift
//  MaryRuntime
//
//  THE COMPOSITION ROOT — where the compiled providers, the installed
//  packages and the brain are joined into one running system.
//
//  IT IS SHORT, AND THAT IS THE POINT. Its predecessor was five hundred lines
//  of enumeration: twenty-two application integrations behind eight support
//  lanes, each with a Settings toggle keyed on the application's name, five
//  named watchers threaded into a nine-field focus context, and a per-lane
//  reconciliation for the ones that could be imported. Every application Mary
//  learned cost a line here.
//
//  Here the adapters are generic and the applications are data, so there is
//  nothing to enumerate. What is left is the ORDER, which is the one thing a
//  composition root genuinely owns:
//
//    1. Install the seams the layers below reach UP through — the ambient
//       layer's application index, the passage lane's backing resolver, the
//       capability index. Each is an inversion: a lower layer that needs an
//       answer only a higher one has.
//    2. Load the package graph, and refuse to publish a half-swapped roster.
//    3. Reconcile what the packages declared into the registries that serve
//       them.
//    4. Hand the brain its providers and its dispatcher.
//    5. Activate the observers.
//
//  A HALF-SWAPPED ROSTER IS THE FAILURE THIS GUARDS. If the package graph
//  fails to validate, the previously running one keeps BOTH halves — compiled
//  providers and package snapshot. Publishing new compiled providers beside an
//  old snapshot would produce a registry no validation pass ever admitted.
//

import AppKit
import Foundation
import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryTotem
import os

extension MaryRuntime {

    package static func installBrainConfiguration(
        projects: [String: String] = [:]
    ) async {
        projectRootsBox.withLock { $0 = Array(Set(projects.values)).sorted() }
        let hadBrainConfiguration = brainConfigurationInstalledBox.withLock { $0 }

        let adapters = MaryAdapterCatalog.adapters()
        let observers = MaryAdapterCatalog.observers()

        // 1. THE SEAMS, INSTALLED BEFORE ANYTHING READS THEM.
        //
        // Each of these is an inversion: MaryAmbient sits below MaryPlugin
        // and MaryBrain, and needs answers only they have — which
        // applications exist, where a place's prose lives, what words map to
        // which ability. A direct call would be an upward edge and the
        // layering test would refuse it; a provider seam is the same
        // information arriving by injection.
        ProseSurfaceSupport.shared.installBackingResolver()
        AmbientCapabilityBridge.install()

        // 2. THE PACKAGE GRAPH.
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: observers),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])

        // A FAILED RECONFIGURATION CHANGES NOTHING. Initial boot has no
        // previous runtime to preserve, so it installs the compiled providers
        // and an empty snapshot while the library watches for a corrected
        // graph — which is how a broken package leaves Mary working rather
        // than mute.
        guard load.activated || !hadBrainConfiguration else { return }

        // 3. RECONCILE WHAT THE PACKAGES DECLARED.
        let profiles = adapters.map(\.applicationProfile)
            + load.snapshot.plugins.applicationProfiles
        nativeApplicationProfilesBox.withLock { $0 = adapters.map(\.applicationProfile) }
        applicationProfilesBox.withLock { $0 = profiles }
        // THE JOINED ROSTER, not the compiled half. A package's application
        // is not a compiled provider, so a roster built from adapters alone
        // answers nil for every taught application — and every read one of
        // their Skills produced would be dropped by the guard downstream.
        AmbientApplicationBridge.install(profiles: profiles)
        // AND THE PROSE SURFACES, which is what makes a declared editor
        // readable and writable at all. Re-installed on every activation
        // because importing or editing a package changes the answer.
        ProseSurfaceSupport.shared.reconcile(
            proseSurfaceRegistrations(from: load.snapshot))
        // AND THE CORPORA. Same reconcile, same reason: which applications
        // Mary can learn the shape of is a fact about the installed packages.
        CorpusSupport.shared.reconcile(corpusRegistrations(from: load.snapshot))
        installCorpusPipeline()
        // AND THE TRANSPORTS, on the same activation and for the same reason:
        // a package that stops declaring a player must stop having one.
        MediaSurfaceSupport.shared.reconcile(
            mediaSurfaceRegistrations(from: load.snapshot))
        // AND THE BROWSERS. The fourth surface, reconciled with the rest —
        // and the one whose absence is most visible, because with no declared
        // browser the place resolver knows of no browsers at all and every
        // web page on screen is an unrecognized application.
        BrowserSurfaceSupport.shared.reconcile(
            browserSurfaceRegistrations(from: load.snapshot))
        // AND THE WEB CANVASES — declared places that are not applications,
        // so they are read off the PACKAGE rather than off its plugin.
        WebCanvasSupport.shared.reconcile(
            webCanvasRegistrations(from: load.snapshot))

        // 4. THE BRAIN'S PROVIDERS.
        let deps = FocusResolutionContext(observers: observers)
        focusSubjectBox.withLock { $0 = { resolveFocus(deps: deps).subject } }

        await brain.setSystemPromptProvider {
            systemPromptText(plugins: adapters, projects: projects, deps: deps)
        }
        await brain.setTurnContextPreparer {
            for observer in observers where !observer.ambientSenses.isEmpty {
                await observer.refreshAmbientContext()
            }
            // A DECLARED PERCEPTION IS REFRESHED HERE TOO, for the same reason
            // the observers above are: the dispatch gate asks what Mary
            // observes RIGHT NOW, and a reading taken any earlier than the
            // turn that uses it has already begun going stale.
            publishPlayerTransportPerception()
        }
        await brain.setSeerInstructionsProvider { pass in
            seerInstructionsText(pass: pass, deps: deps)
        }
        await brain.setReferentResolver { act in
            // THE SAME LEAD THE PROMPT DESCRIBED. Resolving "that one"
            // against a different place than the one the model was just told
            // about is the whole class of bug the single focus decision
            // exists to prevent.
            ReferenceFocus.decide(
                utterance: AmbientContextStore.shared.utterance(),
                act: act,
                rosters: adapters.compactMap(\.containerRoster),
                lead: resolveFocus(deps: deps).leadPlace)
        }
        await brain.setReferenceCorrector { previous in
            ReferenceFocus.applyCorrection(
                to: previous, rosters: adapters.compactMap(\.containerRoster))
        }
        await brain.setDepositSubjectProvider { focusSubject() }
        await brain.setDispatcher(
            AbilityRuntime(
                plugins: adapters,
                focusProvider: { resolveFocus(deps: deps).leadOwner },
                behavior: brainWiring.behavior
            ) {
                AbilityExecutionContext(projects: projects)
            })

        // 5. THE SENSES, LAST. An observer that starts polling before the
        // roster is installed publishes facts under a place nothing yet
        // recognizes, and they are dropped in silence.
        for observer in observers { await observer.activate() }

        brainConfigurationInstalledBox.withLock { $0 = true }
    }

    /// Every prose surface the admitted packages declare.
    ///
    /// A DECLARATION BECOMES A REGISTRATION HERE and nowhere else, so the set
    /// the passage verbs can reach is exactly the set the graph admitted —
    /// never a stale copy from the last activation.
    /// The corpus declarations, in the same shape and for the same reason as
    /// the prose registrations below.
    package static func corpusRegistrations(
        from snapshot: AbilityRuntimeSnapshot
    ) -> [CorpusRegistration] {
        snapshot.records.compactMap { record -> CorpusRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  let corpus = plugin.corpus
            else { return nil }
            return CorpusRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                displayName: plugin.application.title,
                schema: corpus)
        }
    }

    /// `package` so the behavior probe can install the SAME registrations the
    /// app does. A probe that hand-built its own would be measuring a fixture.
    /// The declared transports in one activation's package graph.
    ///
    /// `proseSurfaceRegistrations`' twin, kept beside it rather than folded
    /// into one generic walk: the two blocks are independent, a package may
    /// declare either or both, and a single function returning a pair would
    /// make every caller take what it did not ask for.
    package static func mediaSurfaceRegistrations(
        from snapshot: AbilityRuntimeSnapshot
    ) -> [MediaSurfaceRegistration] {
        snapshot.records.compactMap { record -> MediaSurfaceRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  let surface = plugin.mediaSurface
            else { return nil }
            return MediaSurfaceRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                displayName: plugin.application.title,
                schema: surface)
        }
    }

    package static func browserSurfaceRegistrations(
        from snapshot: AbilityRuntimeSnapshot
    ) -> [BrowserSurfaceRegistration] {
        snapshot.records.compactMap { record -> BrowserSurfaceRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  let surface = plugin.browserSurface
            else { return nil }
            return BrowserSurfaceRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                displayName: plugin.application.title,
                schema: surface)
        }
    }

    package static func webCanvasRegistrations(
        from snapshot: AbilityRuntimeSnapshot
    ) -> [WebCanvasRegistration] {
        snapshot.records.compactMap { record -> WebCanvasRegistration? in
            guard record.validation.isValid, let canvas = record.package.webCanvas
            else { return nil }
            return WebCanvasRegistration(
                canvasID: record.package.ability.id.rawValue,
                displayName: record.package.ability.title,
                schema: canvas)
        }
    }

    package static func proseSurfaceRegistrations(
        from snapshot: AbilityRuntimeSnapshot
    ) -> [ProseSurfaceRegistration] {
        snapshot.records.compactMap { record -> ProseSurfaceRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  let surface = plugin.proseSurface
            else { return nil }
            return ProseSurfaceRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                displayName: plugin.application.title,
                schema: surface)
        }
    }
}
