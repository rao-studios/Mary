import Foundation
import XCTest
@testable import MaryPlugin

final class CodingAgentDelegationTests: XCTestCase {

    func testBriefNeverNamesACompiledProduct() {
        let brief = CodingAgentDelegation.delegationBrief(
            task: "add a guard",
            context: .init(
                filePath: "Sources/App.swift",
                editorName: "Front Editor",
                selectedSymbolName: "run",
                selectedLine: 12,
                windowText: "func run() {}",
                selectedRange: 0..<12),
            workdir: "/tmp/proj")
        XCTAssertTrue(brief.contains("Task from a live voice pair-coding conversation"))
        XCTAssertTrue(brief.contains("authorized project root"))
        let banned = ["textedit", "scrivener", "keynote", "xcode", "sketch", "safari"]
        let lower = brief.lowercased()
        for name in banned {
            XCTAssertFalse(lower.contains(name), "brief names \(name)")
        }
    }

    func testPromptFragmentIsGeneric() {
        let fragment = CodingAgentAdapter().promptFragment ?? ""
        XCTAssertFalse(fragment.isEmpty)
        let banned = ["textedit", "scrivener", "keynote", "xcode", "sketch", "safari"]
        let lower = fragment.lowercased()
        for name in banned {
            XCTAssertFalse(lower.contains(name), "promptFragment names \(name)")
        }
        XCTAssertTrue(fragment.contains("delegate_coding"))
        XCTAssertTrue(fragment.contains("self-contained"))
    }
}

final class CodingAgentSessionDeliveryTests: XCTestCase {

    private struct FakeBackend: CodingAgentBackend {
        func isPrepared() async -> Bool { true }
        func prepare(modelID: String) async throws {}
        func downloadProgress() async -> Double { 1 }
        func run(
            brief: String, workdir: String, delivery: CodingAgentDelivery
        ) async throws -> CodingAgentRun {
            try await Task.sleep(nanoseconds: 80_000_000)
            return CodingAgentRun(sessionID: "s1", summary: "changed \(brief)", ok: true)
        }
        func resume(
            sessionID: String, message: String, workdir: String
        ) async throws -> CodingAgentRun {
            CodingAgentRun(sessionID: sessionID, summary: "resumed \(message)", ok: true)
        }
        func cancel(sessionID: String) async {}
    }

    func testInactiveUntilABackendIsInstalled() async {
        let sessions = CodingAgentSessions()
        let outcome = await sessions.start(
            task: "fix it", workdir: "/tmp", brief: "fix it", delivery: .awaited)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.summary.lowercased().contains("settings"))
    }

    func testBackgroundReturnsImmediatelyAndAwaitedWaits() async {
        let sessions = CodingAgentSessions()
        await sessions.install(backend: FakeBackend())
        let started = Date()
        let background = await sessions.start(
            task: "background", workdir: "/tmp", brief: "background", delivery: .background)
        XCTAssertTrue(background.ok)
        XCTAssertTrue(background.deferred)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)

        let awaited = await sessions.start(
            task: "awaited", workdir: "/tmp", brief: "awaited", delivery: .awaited)
        XCTAssertTrue(awaited.ok)
        XCTAssertTrue(awaited.summary.contains("completed"))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.08)
    }
}
