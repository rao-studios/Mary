//
//  AmbientSurfaceObserverTests.swift
//  BonniePluginTests
//
//  Pins the tier-0 wiring against injected stores: the target ladder
//  (browsers IN for the surface, Mary and system chrome out), the two
//  publications from one walk, the browser carve-out that keeps
//  `BrowserContextWatcher` the only writer of a browser's affordance scope,
//  one-slate-at-a-time retraction, and the skip-when-unchanged rule.
//

import CoreGraphics
import Foundation
import XCTest
@testable import MaryAdapters

final class AmbientSurfaceObserverTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func context(
        pid: pid_t = 7, bundleID: String, appName: String = "Example",
        buttonLabel: String = "Save", capturedAt: Date? = nil
    ) -> AXAmbientContext {
        let ids = AXIDVendor()
        let button = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: buttonLabel,
            frame: CGRect(x: 10, y: 10, width: 80, height: 24),
            category: .interactive)
        let root = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", category: .container, children: [button])
        let window = AXSnapshotTestSupport.window(
            ids, title: "Document",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), root: root)
        var snapshot = AXSnapshotTestSupport.app(
            [window], pid: pid, bundleID: bundleID, appName: appName)
        snapshot.capturedAt = capturedAt ?? epoch
        return AXAmbientContext(
            snapshot: snapshot,
            scope: .all, limit: AXElementRoster.publishedLimit,
            observersCovered: nil, observersTotal: nil)
    }

    private func observer(
        store: AmbientContextStore,
        index: AmbientElementIndexStore,
        front: (pid: pid_t, bundleID: String)?,
        trusted: Bool = true,
        capture: (@Sendable (pid_t) -> AXAmbientContext?)? = nil
    ) -> AmbientSurfaceObserver {
        let bundleID = front?.bundleID ?? "com.example.app"
        let resolved = capture ?? { pid in
            self.context(pid: pid, bundleID: bundleID)
        }
        return AmbientSurfaceObserver(
            store: store, elementIndex: index,
            capture: resolved,
            frontmost: { front },
            trusted: { trusted })
    }

    private func slate(
        _ index: AmbientElementIndexStore, _ place: AmbientPlace
    ) -> [String] {
        index.index(for: .affordances(in: place))?
            .records.map { $0.name ?? "" } ?? []
    }

    /// A frontmost signal a test can move, so ONE observer instance sees an
    /// application switch — which is what the retraction rule is about.
    private final class FrontmostBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (pid: pid_t, bundleID: String)?
        init(_ value: (pid: pid_t, bundleID: String)?) { self.value = value }
        func set(_ next: (pid: pid_t, bundleID: String)?) {
            lock.lock(); defer { lock.unlock() }
            value = next
        }
        func get() -> (pid: pid_t, bundleID: String)? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    // MARK: - The target ladder

    func testUntrustedAccessibilityReadsNothing() {
        let observer = observer(
            store: AmbientContextStore(), index: AmbientElementIndexStore(),
            front: (7, "com.example.app"), trusted: false)
        XCTAssertNil(observer.target())
    }

    func testBonnieItselfIsNeverTheTarget() throws {
        let own = try XCTUnwrap(
            Bundle.main.bundleIdentifier, "no host bundle id in this test runner")
        let observer = observer(
            store: AmbientContextStore(), index: AmbientElementIndexStore(),
            front: (7, own))
        XCTAssertNil(observer.target())
    }

    func testSystemChromeIsExcluded() {
        for prefix in WorkspaceFocusTracker.leadExcludedBundlePrefixes {
            let observer = observer(
                store: AmbientContextStore(), index: AmbientElementIndexStore(),
                front: (7, prefix))
            XCTAssertNil(observer.target(), "\(prefix) must not be read")
        }
    }

    /// A BROWSER IS A BROWSER BECAUSE A PACKAGE SAYS SO. No bundle id is
    /// compiled in, so this installs the registration that makes one — which
    /// is also what makes the test honest: it exercises the road a real
    /// browser travels rather than a shortcut only one product had.
    func testBrowsersAreValidSurfaceTargets() {
        Self.withBrowserRoster {
            let observer = observer(
                store: AmbientContextStore(), index: AmbientElementIndexStore(),
                front: (7, Self.browserBundleID))
            let target = observer.target()
            XCTAssertNotNil(target)
            XCTAssertTrue(AmbientPlaceResolver.isBrowser(bundleID: target?.bundleID ?? ""))
        }
    }

    static let browserBundleID = "com.example.browser"

    /// One registration that realizes `browsing`, scoped to this task tree.
    static func withBrowserRoster(_ body: () -> Void) {
        let registration = ApplicationRegistration(
            id: "browser",
            profile: ApplicationProfile(
                id: "browser", title: "Browser", summary: "A fixture that browses.",
                abilities: [.browsing],
                applicationIdentifiers: [browserBundleID]),
            bundleIdentifiers: [browserBundleID],
            worldClass: .perceptionOnly,
            displayName: "Browser")
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([registration]), operation: body)
    }

    // MARK: - The two publications

    func testOnePollPublishesSurfaceAndSlate() {
        let store = AmbientContextStore()
        let index = AmbientElementIndexStore()
        let observer = observer(
            store: store, index: index, front: (7, "com.example.app"))
        observer.pollOnce(at: epoch)

        let place = AmbientPlaceResolver.applicationPlace(forBundleID: "com.example.app")
        let surface = store.surface(place: place, at: epoch)
        XCTAssertEqual(surface?.application.name, "Example")
        XCTAssertEqual(surface?.activeWindow?.title, "Document")
        XCTAssertEqual(surface?.elements.first?.label, "Save")
        XCTAssertEqual(slate(index, place), ["Save"])
    }

    func testABrowserPublishesItsSurfaceButNeverAffordances() {
        Self.withBrowserRoster {
            let store = AmbientContextStore()
            let index = AmbientElementIndexStore()
            let observer = observer(
                store: store, index: index, front: (7, Self.browserBundleID))
            observer.pollOnce(at: epoch)

            let place = AmbientPlaceResolver.applicationPlace(
                forBundleID: Self.browserBundleID)
            XCTAssertNotNil(store.surface(place: place, at: epoch))
            XCTAssertTrue(slate(index, place).isEmpty)
        }
    }

    func testSwitchingApplicationsRetractsThePreviousSlate() {
        let store = AmbientContextStore()
        let index = AmbientElementIndexStore()
        let front = FrontmostBox((7, "com.example.first"))
        let observer = AmbientSurfaceObserver(
            store: store, elementIndex: index,
            capture: { pid in
                let bundleID = front.get()?.bundleID ?? "com.example.first"
                return self.context(
                    pid: pid, bundleID: bundleID,
                    buttonLabel: bundleID == "com.example.first" ? "Save" : "Publish")
            },
            frontmost: { front.get() },
            trusted: { true })

        observer.pollOnce(at: epoch)
        let firstPlace = AmbientPlaceResolver
            .applicationPlace(forBundleID: "com.example.first")
        XCTAssertEqual(slate(index, firstPlace), ["Save"])

        front.set((9, "com.example.second"))
        observer.pollOnce(at: epoch.addingTimeInterval(10))
        let secondPlace = AmbientPlaceResolver
            .applicationPlace(forBundleID: "com.example.second")
        XCTAssertEqual(slate(index, secondPlace), ["Publish"])
        XCTAssertTrue(
            slate(index, firstPlace).isEmpty,
            "the previous application's slate must be retracted, not left live")
    }

    func testNoTargetRetractsTheSlateAndLeavesSurfacesToExpire() {
        let store = AmbientContextStore()
        let index = AmbientElementIndexStore()
        let front = FrontmostBox((7, "com.example.app"))
        let observer = AmbientSurfaceObserver(
            store: store, elementIndex: index,
            capture: { pid in self.context(pid: pid, bundleID: "com.example.app") },
            frontmost: { front.get() },
            trusted: { true })
        observer.pollOnce(at: epoch)
        let place = AmbientPlaceResolver.applicationPlace(forBundleID: "com.example.app")
        XCTAssertEqual(slate(index, place), ["Save"])

        front.set(nil)
        observer.pollOnce(at: epoch.addingTimeInterval(1))
        XCTAssertTrue(slate(index, place).isEmpty)
        // The surface is NOT retracted — drop-at-expiry is the tier's honesty.
        XCTAssertNotNil(store.surface(place: place, at: epoch.addingTimeInterval(1)))
    }

    // MARK: - Skip when unchanged

    func testUnchangedScreenStillRefreshesTheSurfaceStamp() {
        let store = AmbientContextStore()
        let index = AmbientElementIndexStore()
        var captureDate = epoch
        let observer = AmbientSurfaceObserver(
            store: store, elementIndex: index,
            capture: { pid in
                self.context(
                    pid: pid, bundleID: "com.example.app", capturedAt: captureDate)
            },
            frontmost: { (7, "com.example.app") },
            trusted: { true })
        observer.pollOnce(at: epoch)
        captureDate = epoch.addingTimeInterval(10)
        observer.pollOnce(at: captureDate)

        let place = AmbientPlaceResolver.applicationPlace(forBundleID: "com.example.app")
        XCTAssertEqual(
            store.surface(place: place, at: captureDate)?.capturedAt, captureDate,
            "an unchanged screen must still re-stamp its surface, or it expires")
        XCTAssertEqual(slate(index, place), ["Save"])
    }

    func testChangedScreenRepublishesTheSlate() {
        let store = AmbientContextStore()
        let index = AmbientElementIndexStore()
        var label = "Save"
        let observer = AmbientSurfaceObserver(
            store: store, elementIndex: index,
            capture: { pid in
                self.context(pid: pid, bundleID: "com.example.app", buttonLabel: label)
            },
            frontmost: { (7, "com.example.app") },
            trusted: { true })
        observer.pollOnce(at: epoch)
        label = "Publish"
        observer.pollOnce(at: epoch.addingTimeInterval(10))

        let place = AmbientPlaceResolver.applicationPlace(forBundleID: "com.example.app")
        XCTAssertEqual(slate(index, place), ["Publish"])
    }
}
