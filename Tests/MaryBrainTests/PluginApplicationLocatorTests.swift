import MaryFoundation
import Foundation
import XCTest
@testable import MaryAdapters
@testable import MaryBrain
@testable import MaryAmbient

final class PluginApplicationLocatorTests: XCTestCase {
    @MainActor
    func testRunningIdentityWinsBeforeAnyInstalledLookup() {
        let calls = LookupCalls()
        let firstID = "com.example.canvas"
        let runningID = "com.example.canvas.beta"
        let locator = PluginApplicationLocator(
            runningApplications: { identifier in
                calls.recordRunning(identifier)
                switch identifier {
                case firstID:
                    // A resolver result cannot substitute a different bundle
                    // identity for the exact identifier being queried.
                    return [.init(
                        bundleIdentifier: "com.example.different",
                        localizedName: "Wrong application",
                        processIdentifier: 11)]
                case runningID:
                    return [.init(
                        bundleIdentifier: runningID,
                        localizedName: "Canvas Beta",
                        bundleURL: URL(fileURLWithPath: "/Applications/Canvas Beta.app"),
                        processIdentifier: 42)]
                default:
                    return []
                }
            },
            installedApplicationURL: { identifier in
                calls.recordInstalled(identifier)
                return URL(fileURLWithPath: "/Applications/Idle.app")
            })

        let resolution = locator.resolve(.init(
            id: "canvas",
            title: "Canvas",
            bundleIdentifiers: [firstID, runningID],
            bundleNames: ["Canvas.app", "Canvas Beta.app"]))

        XCTAssertEqual(resolution.status, .running)
        XCTAssertEqual(resolution.displayName, "Canvas Beta")
        XCTAssertEqual(resolution.matchedBundleIdentifier, runningID)
        XCTAssertEqual(resolution.processIdentifier, 42)
        XCTAssertEqual(
            resolution.installedURL?.path,
            "/Applications/Canvas Beta.app")
        XCTAssertEqual(calls.running, [firstID, runningID])
        XCTAssertEqual(calls.installed, [])
    }

    @MainActor
    func testMultipleExactProcessesForOneBundleIdentityAreAmbiguous() {
        let calls = LookupCalls()
        let bundleIdentifier = "com.example.canvas"
        let locator = PluginApplicationLocator(
            runningApplications: { identifier in
                calls.recordRunning(identifier)
                return [
                    .init(
                        bundleIdentifier: identifier,
                        localizedName: "First Canvas",
                        bundleURL: URL(fileURLWithPath: "/Applications/First Canvas.app"),
                        shortVersion: "1.0",
                        bundleVersion: "1",
                        processIdentifier: 41),
                    .init(
                        bundleIdentifier: identifier,
                        localizedName: "Second Canvas",
                        bundleURL: URL(fileURLWithPath: "/Applications/Second Canvas.app"),
                        shortVersion: "2.0",
                        bundleVersion: "2",
                        processIdentifier: 42),
                ]
            },
            installedApplicationURL: { identifier in
                calls.recordInstalled(identifier)
                return URL(fileURLWithPath: "/Applications/Canvas.app")
            })

        let resolution = locator.resolve(.init(
            id: "canvas",
            title: "Declared Canvas",
            bundleIdentifiers: [bundleIdentifier],
            supportedReleases: [.init(
                shortVersion: "2.0",
                bundleVersion: "2")]))

        XCTAssertEqual(resolution.status, .ambiguous)
        XCTAssertEqual(resolution.displayName, "Declared Canvas")
        XCTAssertNil(resolution.matchedBundleIdentifier)
        XCTAssertNil(resolution.processIdentifier)
        XCTAssertNil(resolution.installedURL)
        XCTAssertEqual(calls.running, [bundleIdentifier])
        XCTAssertEqual(calls.installed, [])
    }

    @MainActor
    func testProcessesAcrossDeclaredBundleIdentitiesAreAmbiguous() {
        let calls = LookupCalls()
        let firstID = "com.example.canvas"
        let secondID = "com.example.canvas.beta"
        let locator = PluginApplicationLocator(
            runningApplications: { identifier in
                calls.recordRunning(identifier)
                switch identifier {
                case firstID:
                    return [.init(
                        bundleIdentifier: firstID,
                        processIdentifier: 51)]
                case secondID:
                    return [.init(
                        bundleIdentifier: secondID,
                        processIdentifier: 52)]
                default:
                    return []
                }
            },
            installedApplicationURL: { identifier in
                calls.recordInstalled(identifier)
                return nil
            })

        let resolution = locator.resolve(.init(
            id: "canvas",
            title: "Canvas",
            bundleIdentifiers: [firstID, secondID]))

        XCTAssertEqual(resolution.status, .ambiguous)
        XCTAssertNil(resolution.matchedBundleIdentifier)
        XCTAssertNil(resolution.processIdentifier)
        XCTAssertEqual(calls.running, [firstID, secondID])
        XCTAssertEqual(calls.installed, [])
    }

    @MainActor
    func testRepeatedObservationOfOnePIDStillResolvesExactly() {
        let bundleIdentifier = "com.example.canvas"
        let application = PluginRunningApplication(
            bundleIdentifier: bundleIdentifier,
            localizedName: "Canvas",
            processIdentifier: 61)
        let locator = PluginApplicationLocator(
            runningApplications: { _ in [application, application] },
            installedApplicationURL: { _ in nil })

        let resolution = locator.resolve(.init(
            id: "canvas",
            title: "Canvas",
            bundleIdentifiers: [bundleIdentifier]))

        XCTAssertEqual(resolution.status, .running)
        XCTAssertEqual(resolution.matchedBundleIdentifier, bundleIdentifier)
        XCTAssertEqual(resolution.processIdentifier, 61)
    }

    @MainActor
    func testRunningReleaseRequiresBothExactBundleMetadataValues() {
        let bundleIdentifier = "com.example.canvas"
        let expected = PluginApplicationReleaseSchema(
            shortVersion: "2025.3.4",
            bundleVersion: "221297")
        let application = PluginApplicationSchema(
            id: "canvas",
            title: "Canvas",
            bundleIdentifiers: [bundleIdentifier],
            supportedReleases: [expected])
        let compatible = PluginApplicationLocator(
            runningApplications: { _ in [.init(
                bundleIdentifier: bundleIdentifier,
                localizedName: "Canvas",
                bundleURL: URL(fileURLWithPath: "/Applications/Canvas.app"),
                shortVersion: expected.shortVersion,
                bundleVersion: expected.bundleVersion,
                processIdentifier: 62)] },
            installedApplicationURL: { _ in nil })

        let exact = compatible.resolve(application)

        XCTAssertEqual(exact.status, .running)
        XCTAssertEqual(exact.processIdentifier, 62)

        for (shortVersion, bundleVersion) in [
            (Optional("2025.3.5"), Optional("221297")),
            (Optional("2025.3.4"), Optional("221298")),
            (nil, Optional("221297")),
            (Optional("2025.3.4"), nil),
        ] {
            let incompatible = PluginApplicationLocator(
                runningApplications: { _ in [.init(
                    bundleIdentifier: bundleIdentifier,
                    localizedName: "Canvas",
                    bundleURL: URL(fileURLWithPath: "/Applications/Canvas.app"),
                    shortVersion: shortVersion,
                    bundleVersion: bundleVersion,
                    processIdentifier: 63)] },
                installedApplicationURL: { _ in
                    XCTFail("A running exact identity must remain authoritative")
                    return nil
                })

            let resolution = incompatible.resolve(application)

            // THE TARGET SURVIVES THE DRIFT. This used to assert the opposite —
            // a target-free `.incompatibleRelease` — and that is precisely the
            // behaviour that made every Chrome operation refuse the week Chrome
            // auto-updated past the declared tuple. An unrecognised build is
            // reported, not withheld: the PID, the bundle id and the URL all
            // still cross, and `releaseIsVerified` carries the fact.
            XCTAssertEqual(resolution.status, .running)
            XCTAssertEqual(resolution.processIdentifier, 63)
            XCTAssertEqual(resolution.matchedBundleIdentifier, bundleIdentifier)
            XCTAssertFalse(resolution.releaseIsVerified)
        }
    }

    /// A package that declares NO releases has made no claim, so nothing about
    /// it is unverified — the flag must not read "drifted" for every plugin
    /// that simply never pinned a build.
    @MainActor
    func testUndeclaredReleasesAreVerifiedRatherThanUnverified() {
        let bundleIdentifier = "com.example.canvas"
        let application = PluginApplicationSchema(
            id: "canvas",
            title: "Canvas",
            bundleIdentifiers: [bundleIdentifier])
        let locator = PluginApplicationLocator(
            runningApplications: { _ in [.init(
                bundleIdentifier: bundleIdentifier,
                localizedName: "Canvas",
                bundleURL: URL(fileURLWithPath: "/Applications/Canvas.app"),
                shortVersion: "9.9",
                bundleVersion: "999",
                processIdentifier: 71)] },
            installedApplicationURL: { _ in nil })

        let resolution = locator.resolve(application)

        XCTAssertEqual(resolution.status, .running)
        XCTAssertTrue(resolution.releaseIsVerified)
    }

    @MainActor
    func testInstalledResolutionKeepsDeclaredOrderAndReportsDrift()
    {
        let firstID = "com.example.canvas"
        let secondID = "com.example.canvas.store"
        let firstURL = URL(fileURLWithPath: "/Applications/Canvas Legacy.app")
        let secondURL = URL(fileURLWithPath: "/Applications/Canvas Current.app")
        let expected = PluginApplicationReleaseSchema(
            shortVersion: "5.0",
            bundleVersion: "500")
        let application = PluginApplicationSchema(
            id: "canvas",
            title: "Canvas",
            bundleIdentifiers: [firstID, secondID],
            supportedReleases: [expected])
        let calls = LookupCalls()
        let locator = PluginApplicationLocator(
            runningApplications: { _ in [] },
            installedApplicationURL: { identifier in
                calls.recordInstalled(identifier)
                return identifier == firstID ? firstURL : secondURL
            },
            applicationRelease: { url in
                url == secondURL
                    ? expected
                    : .init(shortVersion: "4.0", bundleVersion: "400")
            })

        // DECLARED ORDER IS THE AUTHOR'S PREFERENCE, and the release tuple is
        // no longer a tiebreak. This used to skip the first installed identity
        // because its build was unrecognised and silently prefer the second —
        // so a stale tuple could quietly redirect Mary from the stable build
        // to a beta. The first declared identity wins; drift is reported.
        let compatible = locator.resolve(application)

        XCTAssertEqual(compatible.status, .installed)
        XCTAssertEqual(compatible.matchedBundleIdentifier, firstID)
        XCTAssertEqual(compatible.installedURL, firstURL)
        XCTAssertFalse(compatible.releaseIsVerified)
        XCTAssertEqual(calls.installed, [firstID])

        // An unreadable Info.plist is unverified, and still a target.
        let unreadable = PluginApplicationLocator(
            runningApplications: { _ in [] },
            installedApplicationURL: { _ in firstURL },
            applicationRelease: { _ in nil })
            .resolve(application)
        XCTAssertEqual(unreadable.status, .installed)
        XCTAssertEqual(unreadable.matchedBundleIdentifier, firstID)
        XCTAssertEqual(unreadable.installedURL, firstURL)
        XCTAssertFalse(unreadable.releaseIsVerified)
    }

    @MainActor
    func testDefaultReleaseReaderUsesTheResolvedBundleURLInfoPlist() throws {
        let bundleIdentifier = "com.example.exact-release-fixture"
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let release = PluginApplicationReleaseSchema(
            shortVersion: "7.2.1",
            bundleVersion: "70201")
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleName": "Exact Release Fixture",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": release.shortVersion,
                "CFBundleVersion": release.bundleVersion,
            ],
            format: .xml,
            options: 0)
        try infoData.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic)
        let locator = PluginApplicationLocator(
            runningApplications: { _ in [] },
            installedApplicationURL: { _ in bundleURL })

        let resolution = locator.resolve(.init(
            id: "fixture",
            title: "Fixture",
            bundleIdentifiers: [bundleIdentifier],
            supportedReleases: [release]))

        XCTAssertEqual(resolution.status, .installed)
        XCTAssertEqual(resolution.matchedBundleIdentifier, bundleIdentifier)
        XCTAssertEqual(resolution.installedURL, bundleURL)
    }

    @MainActor
    func testInstalledResolutionUsesExactBundleIdentifiersInDeclaredOrder() {
        let calls = LookupCalls()
        let firstID = "com.example.canvas"
        let installedID = "com.example.canvas.store"
        let locator = PluginApplicationLocator(
            runningApplications: { identifier in
                calls.recordRunning(identifier)
                return []
            },
            installedApplicationURL: { identifier in
                calls.recordInstalled(identifier)
                guard identifier == installedID else { return nil }
                // LaunchServices owns location discovery. A valid app may live
                // outside the system-wide /Applications directory.
                return URL(fileURLWithPath: "/Users/fixture/Applications/Fixture Design.app")
            })

        let resolution = locator.resolve(.init(
            id: "canvas",
            title: "Canvas declaration",
            bundleIdentifiers: [firstID, installedID],
            bundleNames: ["Canvas.app"]))

        XCTAssertEqual(resolution.status, .installed)
        XCTAssertEqual(resolution.displayName, "Fixture Design")
        XCTAssertEqual(resolution.matchedBundleIdentifier, installedID)
        XCTAssertNil(resolution.processIdentifier)
        XCTAssertEqual(
            resolution.installedURL?.path,
            "/Users/fixture/Applications/Fixture Design.app")
        XCTAssertEqual(calls.running, [firstID, installedID])
        XCTAssertEqual(calls.installed, [firstID, installedID])
    }

    @MainActor
    func testMissingApplicationUsesDeclaredBundleNameWithoutLaunching() {
        let calls = LookupCalls()
        let locator = PluginApplicationLocator(
            runningApplications: { identifier in
                calls.recordRunning(identifier)
                return []
            },
            installedApplicationURL: { identifier in
                calls.recordInstalled(identifier)
                return nil
            })

        let resolution = locator.resolve(.init(
            id: "mystery-canvas",
            title: "Fallback title",
            bundleIdentifiers: ["com.example.mystery-canvas"],
            bundleNames: ["Mystery Canvas.app"]))

        XCTAssertEqual(resolution.status, .notFound)
        XCTAssertEqual(resolution.displayName, "Mystery Canvas")
        XCTAssertNil(resolution.matchedBundleIdentifier)
        XCTAssertNil(resolution.installedURL)
        XCTAssertNil(resolution.processIdentifier)
        XCTAssertEqual(calls.running, ["com.example.mystery-canvas"])
        XCTAssertEqual(calls.installed, ["com.example.mystery-canvas"])
    }

    func testExecutorRefusesAmbiguousProcessBeforeAccessibilityStageAndInput() async {
        let calls = LookupCalls()
        let bundleIdentifier = "com.example.canvas"
        let operation = PluginOperationSchema(
            operation: "noop",
            title: "No-op",
            summary: "A fixture that must never reach Remote Hands.",
            steps: [],
            postconditions: [],
            timeoutSeconds: 1)
        let plugin = PluginSchema(
            id: "canvas",
            title: "Canvas",
            application: .init(
                id: "canvas",
                title: "Canvas",
                bundleIdentifiers: [bundleIdentifier]),
            adapter: .init(id: "canvas.ui", title: "Canvas UI"),
            operations: [operation],
            realizations: [])
        let executor = PluginManagedUIExecutor(applicationLocator: .init(
            runningApplications: { identifier in
                calls.recordRunning(identifier)
                return [
                    .init(
                        bundleIdentifier: identifier,
                        processIdentifier: 71),
                    .init(
                        bundleIdentifier: identifier,
                        processIdentifier: 72),
                ]
            },
            installedApplicationURL: { identifier in
                calls.recordInstalled(identifier)
                return nil
            }))

        let outcome = await executor.execute(
            plugin: plugin,
            operation: operation,
            arguments: [:],
            context: .init(projects: [:]))

        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.status, .failed)
        // THE SENTENCE IS SPOKEN, so it is asserted as one. Its predecessor
        // said Mary "did not choose a foreground or input target", which is
        // an accurate description of the code and a useless thing to hear:
        // what the person needs to know is that two copies are open.
        XCTAssertEqual(
            outcome.summary,
            "More than one running Canvas matches this Ability, so I couldn't tell which one you meant.")
        XCTAssertEqual(calls.running, [bundleIdentifier])
        XCTAssertEqual(calls.installed, [])
    }

    /// RELEASE METADATA STOPS BEFORE EXECUTION.
    ///
    /// This test used to assert that a version mismatch refused the operation
    /// before Accessibility, stage or input were touched — and that assertion
    /// was the bug, not a safeguard: `chrome.mary` pinned one Chrome build,
    /// Chrome auto-updated past it, and every Chrome operation (`scrollPage`
    /// included) died on a version string with nothing attempted.
    ///
    /// Whatever genuinely stops the operation gets to speak for itself. The
    /// version comparison belongs to Ability Explorer presentation and must
    /// not enter the command outcome at all. What stops this fixture recipe on
    /// any given machine (Accessibility or its deliberately nonexistent PID)
    /// is not this test's business.
    func testExecutorOutcomeIsIdenticalWhenOnlyReleaseVerificationDiffers()
        async {
        let calls = LookupCalls()
        let bundleIdentifier = "com.example.canvas"
        let operation = PluginOperationSchema(
            operation: "noop",
            title: "No-op",
            summary: "A fixture that must never reach Remote Hands.",
            steps: [],
            postconditions: [],
            timeoutSeconds: 1)
        let verifiedPlugin = PluginSchema(
            id: "canvas",
            title: "Canvas",
            application: .init(
                id: "canvas",
                title: "Canvas",
                bundleIdentifiers: [bundleIdentifier],
                supportedReleases: [.init(
                    shortVersion: "1.0",
                    bundleVersion: "100")]),
            adapter: .init(id: "canvas.ui", title: "Canvas UI"),
            operations: [operation],
            realizations: [])
        var driftedPlugin = verifiedPlugin
        driftedPlugin.application.supportedReleases = [.init(
            shortVersion: "2.0",
            bundleVersion: "200")]
        let executor = PluginManagedUIExecutor(applicationLocator: .init(
            runningApplications: { identifier in
                calls.recordRunning(identifier)
                return [.init(
                    bundleIdentifier: identifier,
                    localizedName: "Canvas",
                    shortVersion: "1.0",
                    bundleVersion: "100",
                    processIdentifier: 73)]
            },
            installedApplicationURL: { identifier in
                calls.recordInstalled(identifier)
                return nil
            }))

        let verifiedOutcome = await executor.execute(
            plugin: verifiedPlugin,
            operation: operation,
            arguments: [:],
            context: .init(projects: [:]))
        let driftedOutcome = await executor.execute(
            plugin: driftedPlugin,
            operation: operation,
            arguments: [:],
            context: .init(projects: [:]))

        XCTAssertEqual(driftedOutcome.ok, verifiedOutcome.ok)
        XCTAssertEqual(driftedOutcome.status, verifiedOutcome.status)
        XCTAssertEqual(driftedOutcome.summary, verifiedOutcome.summary)
        XCTAssertFalse(
            driftedOutcome.summary.contains("is not supported by this Ability"),
            "release drift must no longer refuse the operation")
        XCTAssertFalse(
            driftedOutcome.summary.contains("verified against"),
            "release provenance must remain out of command outcomes: \(driftedOutcome.summary)")
        XCTAssertFalse(
            driftedOutcome.summary.contains("running 1.0"),
            "the observed build belongs only in Ability Explorer: \(driftedOutcome.summary)")
        XCTAssertEqual(calls.running, [bundleIdentifier, bundleIdentifier])
        XCTAssertEqual(calls.installed, [])
    }
}

private final class LookupCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var runningStorage: [String] = []
    private var installedStorage: [String] = []

    var running: [String] {
        lock.lock()
        defer { lock.unlock() }
        return runningStorage
    }

    var installed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return installedStorage
    }

    func recordRunning(_ identifier: String) {
        lock.lock()
        runningStorage.append(identifier)
        lock.unlock()
    }

    func recordInstalled(_ identifier: String) {
        lock.lock()
        installedStorage.append(identifier)
        lock.unlock()
    }
}
