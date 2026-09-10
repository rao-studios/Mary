//
//  MaryRuntime+BrainInstall.swift
//  MaryRuntime
//
//  WHAT: Composition root — compiled providers + packages + brain.
//  OUT:  seams → package graph → registries → brain providers → observers
//  PIN:  Failed reconfiguration keeps both halves. Never publish new
//        compiled providers beside an old snapshot.
//

import AppKit
import Foundation
import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryComputerUse
import MaryFoundation
import MaryThread
import os

extension MaryRuntime {

    /// The turn's context preparer, timed. Same channel as the turn clock, which
    /// cannot see inside the preparer: nothing is marked before the turn's first
    /// `roster`, so every Accessibility walk it performs lands in one number.
    static let preparerLog = Logger(subsystem: "nyc.rao.mary", category: "turns")

    package static func installBrainConfiguration(
        projects: [String: String] = [:]
    ) async {
        projectRootsBox.withLock { $0 = Array(Set(projects.values)).sorted() }
        let hadBrainConfiguration = brainConfigurationInstalledBox.withLock { $0 }

        let looking = LookingPlugin { query in
            await ScreenLookFaculty.look(
                query: query,
                capture: {
                    do {
                        let view = try await ScreenRegionCapture.captureFocusRegion(hint: query)
                        return ScreenLookFaculty.Sight(
                            appTitle: view.appTitle,
                            bundleID: view.bundleID,
                            windowTitle: view.windowTitle,
                            provenanceLabel: view.provenance.spokenLabel,
                            imageData: view.imageData,
                            mediaType: view.mediaType)
                    } catch let failure as ScreenRegionCapture.Failure {
                        switch failure {
                        case .accessibilityDenied, .screenRecordingUnavailable:
                            PermissionsCenter.promptLookingConsents()
                        case .nothingFrontmost, .windowUnavailable:
                            break
                        }
                        throw failure
                    }
                },
                describe: { sight, direction in
                    try await sewnVision.describe(
                        imageData: sight.imageData,
                        mediaType: sight.mediaType,
                        appTitle: sight.appTitle,
                        windowTitle: sight.windowTitle,
                        query: direction)
                },
                home: { sight, description in
                    guard let bundleID = sight.bundleID else { return false }
                    let place = AmbientPlaceResolver.applicationPlace(forBundleID: bundleID)
                    WorkspaceFocusTracker.shared.noteGlance(place: place)
                    let spoken = sight.windowTitle.map { "\(sight.appTitle) — \($0)" }
                        ?? sight.appTitle
                    guard let fact = AmbientBridge.readFact(
                        attention: .applications,
                        application: place.application,
                        phrase: sight.windowTitle ?? sight.appTitle,
                        summary: "Looked at \(spoken) (\(sight.provenanceLabel)): \(description)",
                        document: nil,
                        passageHandle: nil)
                    else { return false }
                    AmbientContextStore.shared.register(fact)
                    return true
                })
        }
        // THE CANVAS'S FLAGSHIP: shaders composed through Sewn, shown on
        // Mary's own windows. The composer is the brain's; the plugin is not.
        let dance = DancePlugin(compose: SewnShaderComposer(
            complete: sewnComplete,
            recentLines: { await brain.recentSpokenLines(limit: 6) }))
        // Faculties, not applications — reachable on a turn led by any taught app.
        let adapters = MaryAdapterCatalog.adapters()
            + [AffordancePlugin(), looking, CodingAgentAdapter(), dance]
        let observers = MaryAdapterCatalog.observers()

        // 1. Seams first — inversions so MaryAmbient does not call up.
        ProseSurfaceSupport.shared.installBackingResolver()
        AmbientCapabilityBridge.install()
        // Routing habits are personal memory. MaryBrain cannot name Thread
        // (it does not depend on MaryThread), so the runtime hands it a backend.
        RoutingHabitMemoryProvider.install { ThreadRoutingHabitMemory() }
        // Which application this person reaches for, per discipline — same
        // inversion, same reason.
        ApplicationHabitMemoryProvider.install { ThreadApplicationHabitMemory() }

        // 2. Package graph.
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: observers),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])

        // Failed reconfiguration changes nothing. Initial boot installs providers + empty snapshot.
        guard load.activated || !hadBrainConfiguration else { return }

        // 3. Reconcile what the packages declared.
        let profiles = adapters.map(\.applicationProfile)
            + load.snapshot.plugins.applicationProfiles
        nativeApplicationProfilesBox.withLock { $0 = adapters.map(\.applicationProfile) }
        applicationProfilesBox.withLock { $0 = profiles }
        // Joined roster, not compiled adapters alone — taught apps would answer nil.
        AmbientApplicationBridge.install(profiles: profiles)
        // Habits — restored per activation, not per launch only, so a newly
        // installed discipline gets its ledger too. Detached: a ranking that
        // has not arrived yet falls back to declared preference, which is
        // exactly the cold-start answer.
        let restoredDisciplines = load.snapshot.disciplines
        if ApplicationHabitMemoryProvider.isInstalled, !restoredDisciplines.isEmpty {
            Task.detached {
                await ApplicationHabitLedger.shared.restore(
                    disciplines: restoredDisciplines)
            }
        }
        // Prose surfaces — re-installed every activation (import/edit changes the set).
        ProseSurfaceSupport.shared.reconcile(
            load.snapshot.proseSurfaceRegistrations())
        // Code surfaces — same reconcile; buffer coordinates as of last activation.
        CodeSurfaceSupport.shared.reconcile(
            load.snapshot.codeSurfaceRegistrations())
        // Corpora — one roster for style crawl and project lane (lane filters on `structure`).
        CorpusSupport.shared.reconcile(corpusRegistrations(from: load.snapshot))
        // Awareness — the applications that asked to be followed, with the
        // project grammar awareness walks. Derived from the graph, like every
        // roster above it; adding an application adds no line here.
        AwarenessSupport.shared.reconcile(awarenessRegistrations(from: load.snapshot))
        registerCodingStyleProducer(profiles: profiles, snapshot: load.snapshot)
        installCorpusPipeline()
        // Transports — a package that stops declaring a player must stop having one.
        MediaSurfaceSupport.shared.reconcile(
            load.snapshot.mediaSurfaceRegistrations())
        // Browsers — the shell coordinates each one publishes. Without this the browsing
        // adapter answers "there's no browser running" for a browser plainly running.
        WebSurfaceSupport.shared.reconcile(
            load.snapshot.webSurfaceRegistrations())

        // 4. Brain providers.
        let deps = FocusResolutionContext(observers: observers)
        focusSubjectBox.withLock { $0 = { resolveFocus(deps: deps).subject } }
        // The idle engine reads the world through the same focus stack the
        // prompt does — installed here because this is where `deps` lives.
        lifeWorldBox.withLock { $0 = { at in idleWorld(deps: deps, at: at) } }

        await brain.setSystemPromptProvider {
            systemPromptText(plugins: adapters, projects: projects, deps: deps)
        }
        await brain.setTurnContextPreparer {
            // TIMED, BECAUSE THE TURN CLOCK CANNOT SEE IN HERE. Nothing is
            // marked before the turn's first `roster`, so this whole block —
            // every observer's Accessibility walk — lands in one cumulative
            // number. Measured: 22.9s of a 27.3s turn, with no way to say which
            // reader owned it.
            let observersStarted = DispatchTime.now()
            for observer in observers where !observer.ambientSenses.isEmpty {
                let started = DispatchTime.now()
                await observer.refreshAmbientContext()
                let ms = (DispatchTime.now().uptimeNanoseconds
                    &- started.uptimeNanoseconds) / 1_000_000
                if ms >= 50 {
                    preparerLog.info(
                        "preparer — observer \(observer.id, privacy: .public) \(ms, privacy: .public)ms")
                }
            }
            let observersMs = (DispatchTime.now().uptimeNanoseconds
                &- observersStarted.uptimeNanoseconds) / 1_000_000
            // Declared perceptions — dispatch asks what Mary observes now. In MaryBrain
            // so the bench publishes the same two (see TurnPerceptionPublisher).
            let perceptionsStarted = DispatchTime.now()
            await TurnPerceptionPublisher.publishAll(adapters: adapters)
            let perceptionsMs = (DispatchTime.now().uptimeNanoseconds
                &- perceptionsStarted.uptimeNanoseconds) / 1_000_000
            preparerLog.info(
                """
                preparer — observers \(observersMs, privacy: .public)ms · \
                perceptions \(perceptionsMs, privacy: .public)ms
                """)
        }
        await brain.setSewnInstructionsProvider { pass in
            sewnInstructionsText(pass: pass, deps: deps)
        }
        await brain.setReferentResolver { act in
            // Same lead the prompt described — resolveFocus, not a second guess.
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
                // THE PINNED RUNG, FILLED. The tracker's pin is the one user
                // gesture that already changes routing; the provider ladder
                // declared a place for it and was handed nil.
                pinnedProvider: { WorkspaceFocusTracker.shared.pinned()?.applicationID },
                behavior: brainWiring.behavior
            ) {
                AbilityExecutionContext(projects: projects)
            })
        await brain.setOrdinarySkillTimeout(skillRunTimeoutBox.withLock { $0 })

        // 5. Senses last — polling before roster publishes facts nobody recognizes.
        for observer in observers { await observer.activate() }

        brainConfigurationInstalledBox.withLock { $0 = true }
        startCodingFollowUpBridge()
        // The idle engine gets the SAME dispatcher the turn loop uses — one
        // authorization path, whether the model asked or Mary did.
        await startLifeEngine(
            dispatcher: await brain.currentDispatcher(),
            mode: lifeModeBox.withLock { $0 })
    }

    /// Ability-keyed style learning for taught apps that realize coding.
    private static func registerCodingStyleProducer(
        profiles: [ApplicationProfile],
        snapshot: AbilityRuntime.Snapshot
    ) {
        let applications = profiles
            .filter { $0.abilities.contains(.coding) }
            .map(\.id)
            .sorted()
        guard !applications.isEmpty else { return }
        let languages = Set(
            corpusRegistrations(from: snapshot)
                .filter { applications.contains($0.applicationID) }
                .map(\.schema.notation)
                .filter { !$0.isEmpty }
        ).sorted()
        StyleProducerRegistry.shared.register(StyleProducer(
            ability: .coding,
            applications: applications,
            languages: languages,
            heading: "How this person writes code"))
    }

    /// Corpora the admitted graph will learn from. Expertise binds a live app;
    /// discipline may own the walk grammar. No expertise in front → not crawled.
    package static func corpusRegistrations(
        from snapshot: AbilityRuntime.Snapshot
    ) -> [CorpusRegistration] {
        let activated = Dictionary(
            uniqueKeysWithValues: snapshot.records
                .filter(\.validation.isValid)
                .map { ($0.package.package.id, $0.package) })
        return snapshot.records.compactMap { record -> CorpusRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  !plugin.application.bundleIdentifiers.isEmpty
            else { return nil }
            let required = record.package.dependencies.filter { !$0.optional }
            guard required.allSatisfy({ activated[$0.packageID] != nil }) else {
                return nil
            }
            guard let schema = plugin.corpus
                    ?? Self.inheritedCorpus(for: record.package, activated: activated)
            else { return nil }
            return CorpusRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                displayName: plugin.application.title,
                schema: schema)
        }
    }

    /// Applications that DECLARED a dependency on the awareness discipline.
    ///
    /// Optionality is deliberately not consulted: an application asking to be
    /// followed is an application asking to be followed, and `optional: true`
    /// only says it still loads when awareness is not installed — the same
    /// shape `window-management` has had since the first package. What IS
    /// consulted is whether awareness actually activated: an edge to a package
    /// that is not in this snapshot registers nothing.
    package static func awarenessRegistrations(
        from snapshot: AbilityRuntime.Snapshot
    ) -> [AwarenessRegistration] {
        let activated = Dictionary(
            uniqueKeysWithValues: snapshot.records
                .filter(\.validation.isValid)
                .map { ($0.package.package.id, $0.package) })
        guard activated.values.contains(where: { $0.ability.id == .awareness }) else {
            return []
        }
        return snapshot.records.compactMap { record -> AwarenessRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  !plugin.application.bundleIdentifiers.isEmpty
            else { return nil }
            // A required dependency that did not activate means this package is
            // not really installed — `corpusRegistrations`' own gate.
            let required = record.package.dependencies.filter { !$0.optional }
            guard required.allSatisfy({ activated[$0.packageID] != nil }) else {
                return nil
            }
            guard record.package.dependencies.contains(where: {
                activated[$0.packageID]?.ability.id == .awareness
            }) else { return nil }
            // A PAGE IS FOLLOWED WITHOUT A CORPUS, whatever a discipline
            // dependency would otherwise have donated. `browsing.mary` declares
            // none today, but inheritance is a graph rule and a future donor
            // must not be able to point a project crawl at the web.
            // PIN: THE RULE IS THE TYPE'S NOW. `.page` carries no corpus, so
            // the `isPage ? nil : …` guard this line used to need cannot be
            // forgotten here or in the snapshot's own derivation.
            // PIN: THE PAGE HALF ALSO EXISTS ON THE SNAPSHOT, as
            // `awarenessPageRegistrations()`, so a bench that cannot link
            // MaryRuntime still follows a page. This derivation stays the whole
            // answer for the app — it is the one that consults inheritance.
            let surface: AwarenessRegistration.Surface = plugin.webSurface != nil
                ? .page
                : .document(corpus: plugin.corpus
                    ?? Self.inheritedCorpus(for: record.package, activated: activated))
            return AwarenessRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                bundleIdentifierPrefix: plugin.application.bundleIdentifierPrefix,
                displayName: plugin.application.title,
                surface: surface,
                hasCodeSurface: plugin.codeSurface != nil,
                hasProseSurface: plugin.proseSurface != nil)
        }
    }

    /// Walk grammar from an activated discipline dependency, if this package declared none.
    private static func inheritedCorpus(
        for package: MaryAbilityPackage,
        activated: [PackageID: MaryAbilityPackage]
    ) -> PluginCorpusSchema? {
        for dependency in package.dependencies {
            guard let donor = activated[dependency.packageID],
                  donor.paradigm == .discipline
            else { continue }
            if let corpus = donor.corpus ?? donor.plugin?.corpus {
                return corpus
            }
        }
        return nil
    }
}
