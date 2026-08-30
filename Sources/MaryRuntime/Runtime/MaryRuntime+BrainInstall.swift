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
import MaryFoundation
import MaryTotem
import os

extension MaryRuntime {

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
                    try await seerVision.describe(
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
                        world: .applications,
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
        // Faculties, not applications — reachable on a turn led by any taught app.
        let adapters = MaryAdapterCatalog.adapters()
            + [AffordancePlugin(), looking, CodingAgentAdapter()]
        let observers = MaryAdapterCatalog.observers()

        // 1. Seams first — inversions so MaryAmbient does not call up.
        ProseSurfaceSupport.shared.installBackingResolver()
        AmbientCapabilityBridge.install()

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
        // Prose surfaces — re-installed every activation (import/edit changes the set).
        ProseSurfaceSupport.shared.reconcile(
            proseSurfaceRegistrations(from: load.snapshot))
        // Code surfaces — same reconcile; buffer coordinates as of last activation.
        CodeSurfaceSupport.shared.reconcile(
            codeSurfaceRegistrations(from: load.snapshot))
        // Corpora — one roster for style crawl and project lane (lane filters on `structure`).
        CorpusSupport.shared.reconcile(corpusRegistrations(from: load.snapshot))
        registerCodingStyleProducer(profiles: profiles, snapshot: load.snapshot)
        installCorpusPipeline()
        // Transports — a package that stops declaring a player must stop having one.
        MediaSurfaceSupport.shared.reconcile(
            mediaSurfaceRegistrations(from: load.snapshot))

        // 4. Brain providers.
        let deps = FocusResolutionContext(observers: observers)
        focusSubjectBox.withLock { $0 = { resolveFocus(deps: deps).subject } }

        await brain.setSystemPromptProvider {
            systemPromptText(plugins: adapters, projects: projects, deps: deps)
        }
        await brain.setTurnContextPreparer {
            for observer in observers where !observer.ambientSenses.isEmpty {
                await observer.refreshAmbientContext()
            }
            // Declared perception — dispatch asks what Mary observes now.
            publishPlayerTransportPerception()
        }
        await brain.setSeerInstructionsProvider { pass in
            seerInstructionsText(pass: pass, deps: deps)
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
                behavior: brainWiring.behavior
            ) {
                AbilityExecutionContext(projects: projects)
            })
        await brain.setOrdinarySkillTimeout(skillRunTimeoutBox.withLock { $0 })

        // 5. Senses last — polling before roster publishes facts nobody recognizes.
        for observer in observers { await observer.activate() }

        brainConfigurationInstalledBox.withLock { $0 = true }
        startCodingFollowUpBridge()
        startLifeLoopIfNeeded()
    }

    /// Ability-keyed style learning for taught apps that realize coding.
    private static func registerCodingStyleProducer(
        profiles: [ApplicationProfile],
        snapshot: AbilityRuntimeSnapshot
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
        from snapshot: AbilityRuntimeSnapshot
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

    /// Declared transports in this activation. Twin of proseSurfaceRegistrations.
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
                bundleIdentifierPrefix: plugin.application.bundleIdentifierPrefix,
                displayName: plugin.application.title,
                schema: surface)
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

    /// Read-only sibling of proseSurfaceRegistrations.
    package static func codeSurfaceRegistrations(
        from snapshot: AbilityRuntimeSnapshot
    ) -> [CodeSurfaceRegistration] {
        snapshot.records.compactMap { record -> CodeSurfaceRegistration? in
            guard record.validation.isValid,
                  let plugin = record.package.plugin,
                  let surface = plugin.codeSurface
            else { return nil }
            return CodeSurfaceRegistration(
                applicationID: plugin.application.id,
                bundleIdentifiers: plugin.application.bundleIdentifiers,
                bundleIdentifierPrefix: plugin.application.bundleIdentifierPrefix,
                displayName: plugin.application.title,
                schema: surface)
        }
    }
}
