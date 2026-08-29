//
//  BrowserSurfaceSupport.swift
//  MaryPlugin
//
//  THE ROSTER OF DECLARED BROWSERS — the third of the surface registries.
//
//  Reconciled wholesale on every package activation, for the same reason as
//  its two siblings: a package that stops declaring a browser must stop
//  having one, and a merge would leave a stale declaration answering for a
//  browser that no longer claims it.
//
//  RESOLUTION IS THE ONE PLACE THIS DIFFERS FROM THE PROSE AND MEDIA LANES,
//  and it differs because the browser is ONE PLACE holding several
//  applications. A player lane resolves "the running one"; a browser lane
//  cannot, because two browsers running is ordinary rather than exceptional.
//  So it defers to `BrowserTargetResolver` — the ladder that already knows a
//  name outranks frontmost and that two equal candidates refuse — and only
//  adds the half the ladder cannot know: which of them declared a strip.
//

import AppKit
import Foundation
import MaryAmbient
import MaryFoundation
import os

public final class BrowserSurfaceSupport: @unchecked Sendable {

    public static let shared = BrowserSurfaceSupport()

    private let box = OSAllocatedUnfairLock<[String: BrowserSurfaceRegistration]>(
        initialState: [:])

    public init() {}

    public func reconcile(_ registrations: [BrowserSurfaceRegistration]) {
        let map = Dictionary(
            registrations.map { ($0.applicationID, $0) },
            uniquingKeysWith: { first, _ in first })
        box.withLock { $0 = map }
    }

    public func all() -> [BrowserSurfaceRegistration] {
        box.withLock { Array($0.values) }.sorted { $0.applicationID < $1.applicationID }
    }

    public func registration(applicationID: String) -> BrowserSurfaceRegistration? {
        box.withLock { $0[applicationID] }
    }

    public func registration(bundleID: String) -> BrowserSurfaceRegistration? {
        box.withLock { map in map.values.first { $0.owns(bundleID: bundleID) } }
    }

    /// The registration behind a place. The browser workspace is ONE place
    /// shared by every browser, so a place alone cannot name which — that is
    /// `resolve` below, and a caller that reached for this one when it meant
    /// that one would drive whichever browser sorted first.
    public func registration(place: AmbientPlace) -> BrowserSurfaceRegistration? {
        guard case .application(let id) = place else { return nil }
        return registration(applicationID: id) ?? registration(bundleID: id)
    }

    /// Which browser to drive, and which process of it.
    ///
    /// The ladder decides WHICH browser (a name the user said, then the pin,
    /// then frontmost, then evidence, then the only visible one); this only
    /// filters the roster to browsers that actually declared a strip, so a
    /// browser Mary can see but has no package for cannot be chosen and then
    /// failed against.
    public func resolve(
        _ named: String? = nil,
        pinned: BrowserTarget? = nil,
        evidencedBundleID: String? = nil
    ) -> (BrowserSurfaceRegistration, BrowserTarget)? {
        let declared = all()
        guard !declared.isEmpty else { return nil }

        let candidates = BrowserTargetResolver.runningBrowsers().filter { candidate in
            declared.contains { $0.owns(bundleID: candidate.bundleID) }
        }
        let resolution = BrowserTargetResolver.resolve(
            named: named, pinned: pinned, evidencedBundleID: evidencedBundleID,
            among: candidates)
        guard let target = resolution.target,
              let registration = declared.first(where: { $0.owns(bundleID: target.bundleID) })
        else { return nil }
        return (registration, target)
    }

    /// The same resolution, permitted to OPEN one when none is running.
    ///
    /// Separate from `resolve` rather than a flag on it, and the separation is
    /// the safeguard: this one is `async` and can put a window on the user's
    /// screen, so a caller has to reach for it deliberately. Only destination
    /// verbs do — `open_location` and `compose_in_web_canvas`. See
    /// `BrowserLaunch`'s header for why reading verbs must not.
    ///
    /// REUSE BEFORE LAUNCH is structural here: the ordinary ladder runs first
    /// and returns whatever it finds, so this can only ever fire on a machine
    /// with no declared browser running at all.
    public func resolveOrLaunch(
        _ named: String? = nil,
        pinned: BrowserTarget? = nil,
        evidencedBundleID: String? = nil
    ) async -> (BrowserSurfaceRegistration, BrowserTarget)? {
        if let resolved = resolve(named, pinned: pinned, evidencedBundleID: evidencedBundleID) {
            return resolved
        }
        let declared = all()
        let plan = BrowserLaunch.plan(
            named: named,
            declared: declared.map {
                BrowserLaunch.Declared(
                    bundleIdentifiers: $0.bundleIdentifiers, displayName: $0.displayName)
            },
            runningBundleIDs: BrowserTargetResolver.runningBrowsers()
                .filter(\.isRegularApplication).map(\.bundleID))
        guard case .launch(let bundleID, let displayName) = plan else { return nil }
        guard let target = await BrowserLaunch.launch(
            bundleID: bundleID, displayName: displayName)
        else { return nil }
        // BACK THROUGH THE ROSTER, never straight to the caller. The launched
        // process must map to the registration that claimed it, or the lane
        // would drive a browser using another browser's declared coordinates.
        guard let registration = declared.first(where: { $0.owns(bundleID: target.bundleID) })
        else { return nil }
        return (registration, target)
    }

    /// Every declared browser currently running, for a caller that must name
    /// the rivals in a refusal rather than merely report that there were some.
    ///
    /// REGULAR APPLICATIONS ONLY, AND DEDUPLICATED — and the first live run
    /// needed both. `runningBrowsers` reports `isRegularApplication` as a
    /// FIELD rather than filtering on it, because the ladder wants helpers
    /// visible in order to reject them; a caller that forgets to filter gets
    /// every XPC helper too. Their bundle ids prefix-match their browser's
    /// (`com.google.Chrome.helper`, and `com.apple.Safari` is genuinely a
    /// prefix of `com.apple.SafariPlatformSupport.Helper`), so the refusal
    /// read "Google Chrome and Google Chrome are both open — which one?"
    public func runningDisplayNames() -> [String] {
        let declared = all()
        var seen: Set<String> = []
        return BrowserTargetResolver.runningBrowsers()
            .filter(\.isRegularApplication)
            .compactMap { candidate in
                declared.first { $0.owns(bundleID: candidate.bundleID) }?.displayName
            }
            .filter { seen.insert($0).inserted }
            .sorted()
    }
}
