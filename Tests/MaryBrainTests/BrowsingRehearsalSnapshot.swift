//
//  BrowsingRehearsalSnapshot.swift
//  MaryBrainTests
//
//  WHAT: The one snapshot every browsing rehearsal measures against — built the
//        way Mary builds it, not by hand.
//  OUT:  BrowsingTripRoutingTests, BrowsingGapCensusTests
//  PIN:  A HAND-BUILT SNAPSHOT HAS NO APPLICATIONS IN IT. `AbilityRuntime.Snapshot`
//        defaults its `plugins` to empty, and the calibration suites had always
//        assembled one from records and indexes alone — so `applicationProfiles`
//        was empty, every "with Chrome in front" stage resolved to NO target
//        classes, and thirteen routing findings were measured on an empty stage.
//        The census's own header caught it: "PROFILES (0)". The library's
//        `configureAndLoad` is the production path — it runs the plugin compiler
//        AND attaches the semantic indexes from the real vectorizer — and it is
//        what the probe already uses. So a rehearsal loads exactly what a turn
//        loads, once, and shares it.
//        ONCE, BECAUSE THE LIBRARY IS PROCESS-WIDE. Two suites each activating it
//        would reload the graph under each other; a single lazy load is the whole
//        of the isolation these gated suites need.
//

import Foundation
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

enum BrowsingRehearsalSnapshot {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MARY_EMBEDDING_CALIBRATION"] == "1"
    }

    private static let loaded: AbilityRuntime.Snapshot? = {
        guard enabled else { return nil }
        let adapters = MaryAdapterCatalog.adapters()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: MaryAdapterCatalog.observers()),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])
        // NO VECTORIZER, NO MEASUREMENT. A snapshot without the semantic skill
        // index would rehearse lexically and report a different router.
        guard load.activated, load.snapshot.semanticSkillIndex != nil else { return nil }
        return load.snapshot
    }()

    /// The production snapshot, or nil to abstain — never a fake.
    static func load() -> AbilityRuntime.Snapshot? { loaded }

    /// The target classes a registered application puts on the stage. "browser"
    /// is the place every browser collapses to; the corpus is Chrome-only.
    static func targetClasses(front: String, in snapshot: AbilityRuntime.Snapshot) -> Set<String> {
        let wanted = front == "browser" ? "chrome" : front
        let profile = snapshot.plugins.applicationProfiles.first {
            $0.id.caseInsensitiveCompare(wanted) == .orderedSame
        }
        return Set(profile?.targetClasses ?? [])
    }
}
