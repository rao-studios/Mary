import Foundation
import XCTest
@testable import MaryPlugin

final class CodingAgentWorkspaceTests: XCTestCase {

    func testResolveRefusesPathsOutsideTheRoot() {
        let root = NSTemporaryDirectory() + "mary-coding-jail/"
        XCTAssertThrowsError(try CodingAgentWorkspace.resolve("../etc/passwd", workdir: root))
        XCTAssertThrowsError(try CodingAgentWorkspace.resolve("/etc/passwd", workdir: root))
    }

    func testWriteAndReadStayInsideTheRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mary-coding-jail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrote = try CodingAgentWorkspace.perform(
            name: "write_file",
            arguments: ["path": "src/Hello.swift", "contents": "let x = 1\n"],
            workdir: root.path)
        XCTAssertTrue(wrote.contains("Hello.swift"))

        let text = try CodingAgentWorkspace.perform(
            name: "read_file",
            arguments: ["path": "src/Hello.swift"],
            workdir: root.path)
        XCTAssertTrue(text.contains("let x = 1"))

        let listing = try CodingAgentWorkspace.perform(
            name: "list_dir",
            arguments: ["path": "src"],
            workdir: root.path)
        XCTAssertTrue(listing.contains("Hello.swift"))
    }

    func testApplySearchReplacePatch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mary-coding-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.swift")
        try "func f() { return 1 }\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try CodingAgentWorkspace.perform(
            name: "apply_patch",
            arguments: [
                "path": "a.swift",
                "patch": "<<<<<<< SEARCH\nfunc f() { return 1 }\n=======\nfunc f() { return 2 }\n>>>>>>> REPLACE",
            ],
            workdir: root.path)
        XCTAssertTrue(result.contains("Patched"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "func f() { return 2 }\n")
    }
}
