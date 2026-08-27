import Foundation
import XCTest

final class PluginRuntimePurityTests: XCTestCase {

    static let brainRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MaryBrain", isDirectory: true)

    /// Imported application packages must reach exactly one Mary-owned
    /// native interpreter. These names are the former executable-source lane.
    func testBrainSourcesContainNoDynamicScriptRuntime() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MaryBrain", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil)
        else { return XCTFail("Could not enumerate MaryBrain sources") }
        let sourceURLs = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let source = try sourceURLs
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        for forbidden in [
            "PluginAppScriptExecutor",
            "PluginScriptHarness",
            "PackageScriptConsentStore",
            "AbilityRuntimeProbeService",
            "javaScriptRaw(",
            "\"-l\", \"JavaScript\"",
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "Found forbidden Dynamic script runtime surface: \(forbidden)")
        }
    }

    /// THE INTERPRETER ITSELF MAY NOT POST INPUT. Every synthetic keystroke a
    /// package's recipe causes goes through `MaryHands`, and nowhere else.
    ///
    /// A SOURCE-TEXT TEST, deliberately, because the property is about what
    /// the code is ALLOWED to reach rather than about what any run of it
    /// does. A behavioural test passes right up until somebody adds one
    /// convenient `CGEvent` in an error path, and the whole value of a single
    /// boundary is that there is no second place to look.
    func testTheInterpreterPostsNoInputOfItsOwn() throws {
        let executionRoot = Self.brainRoot
            .appendingPathComponent("Abilities/Plugins", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: executionRoot, includingPropertiesForKeys: nil)
        else { return XCTFail("Could not enumerate the execution sources") }
        let sources = try enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "MaryHands.swift" }
            .map { (try String(contentsOf: $0, encoding: .utf8), $0.lastPathComponent) }

        for (source, name) in sources {
            for forbidden in [
                "CGEvent(", ".post(tap:", "postToPid(",
                "CGWarpMouseCursorPosition", "CGDisplayMoveCursorToPoint",
            ] {
                XCTAssertFalse(
                    source.contains(forbidden),
                    "\(name) posts input outside MaryHands: \(forbidden)")
            }
        }
    }

    /// AND THE HANDS THEMSELVES REACH ONLY THE COMPILED FLOOR — the shared
    /// key and typing primitives — rather than building events inline.
    ///
    /// The point is not that `CGEvent` is dangerous; it is that a second
    /// place that knows how to synthesize a keystroke is a second place that
    /// has to get the modifier flags, the event tap and the release right.
    /// One of those places already exists and is tested.
    func testTheHandsDelegateToTheSharedInputPrimitives() throws {
        let hands = try String(
            contentsOf: Self.brainRoot.appendingPathComponent(
                "Abilities/Plugins/Execution/MaryHands.swift"),
            encoding: .utf8)
        XCTAssertTrue(hands.contains("KeyChordPress.press"))
        XCTAssertTrue(hands.contains("KeyboardTyper.typeIntoSelection"))
        XCTAssertFalse(
            hands.contains("CGEvent("),
            "MaryHands builds its own events instead of using the shared primitives")
    }

    /// THE STAGE IS TAKEN ONCE, BY THE TRANSACTION, AND VERIFIED.
    ///
    /// A hands function that activated on its own would let a five-step
    /// recipe bring a window forward five times; worse, an activation that is
    /// requested and not CHECKED means the keystrokes land wherever focus
    /// actually is. Both halves are asserted: the executor activates, and it
    /// does so through the verifying path.
    func testTheTransactionTakesTheStageAndVerifiesIt() throws {
        let executor = try String(
            contentsOf: Self.brainRoot.appendingPathComponent(
                "Abilities/Plugins/Execution/PluginManagedUIExecutor.swift"),
            encoding: .utf8)
        let hands = try String(
            contentsOf: Self.brainRoot.appendingPathComponent(
                "Abilities/Plugins/Execution/MaryHands.swift"),
            encoding: .utf8)
        XCTAssertTrue(executor.contains("VerifiedActivation.bringForward"))
        XCTAssertFalse(
            executor.contains(".activate(options:"),
            "the transaction activates without verifying it took")
        XCTAssertFalse(
            hands.contains("VerifiedActivation"),
            "the hands take the stage; only the transaction may")
    }

    /// THE POINTER FAMILY IS REFUSED AT COMPILE TIME, before the stage is
    /// taken — a recipe that cannot run must not first steal the user's focus
    /// to find out.
    func testPointerStepsAreRefusedBeforeTheStageIsTaken() throws {
        let executor = try String(
            contentsOf: Self.brainRoot.appendingPathComponent(
                "Abilities/Plugins/Execution/PluginManagedUIExecutor.swift"),
            encoding: .utf8)
        let compileIndex = try XCTUnwrap(
            executor.range(of: "static func compile(")).lowerBound
        let activateIndex = try XCTUnwrap(
            executor.range(of: "VerifiedActivation.bringForward")).lowerBound
        let refusalIndex = try XCTUnwrap(
            executor.range(of: ".pointerUnavailable(")).lowerBound
        XCTAssertTrue(
            refusalIndex > compileIndex,
            "the pointer refusal is not inside compile()")
        // The transaction runs compile FIRST; the source order of the call is
        // what the run order follows.
        let compileCall = try XCTUnwrap(
            executor.range(of: "Self.compile(operation.steps")).lowerBound
        XCTAssertTrue(
            compileCall < activateIndex,
            "the recipe is compiled after the stage is taken")
    }

    func testOnlyApplicationLocatorCanReadReleaseVerification() throws {
        let brainRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MaryBrain", isDirectory: true)
        let locator = brainRoot
            .appendingPathComponent(
                "Abilities/Plugins/Providers/PluginApplicationLocator.swift")
            .standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: brainRoot,
            includingPropertiesForKeys: nil)
        else { return XCTFail("Could not enumerate MaryBrain sources") }

        let sourceURLs = enumerator.compactMap { $0 as? URL }
            .filter {
                $0.pathExtension == "swift"
                    && $0.standardizedFileURL != locator
            }
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for forbidden in [
                "supportedReleases",
                "releaseIsVerified",
                "observedRelease",
            ] {
                XCTAssertFalse(
                    source.contains(forbidden),
                    "MaryBrain runtime reads presentation-only release metadata \(forbidden) in \(sourceURL.lastPathComponent)")
            }
        }
    }
}
