//
//  AXFrameSchemaTests.swift
//  BonnieFoundationTests
//
//  Pins `AXFrame`/`AXElementRecord` as plain, portable schema: round-trip
//  through the house encoder settings, deterministic (sorted) key order,
//  ISO-8601 date stamping, and — the one behavior that matters for this
//  type's whole reason to exist — that decoding tolerates an unknown key
//  rather than rejecting it like a `.mary` package would.
//

import XCTest
@testable import MaryFoundation

final class AXFrameSchemaTests: XCTestCase {

    private func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func sample(capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> AXFrame {
        AXFrame(
            space: .axGlobalTopLeft,
            rect: .init(x: 659, y: 139, width: 23, height: 23),
            center: .init(x: 670.5, y: 150.5),
            inWindow: .init(x: 100, y: 100, width: 23, height: 23),
            screen: .init(index: 0, rect: .init(x: 0, y: 0, width: 1920, height: 1080)),
            isClipped: false,
            capturedAt: capturedAt)
    }

    // MARK: - Round-trip

    func testFrameRoundTripsThroughJSON() throws {
        let original = sample()
        let data = try encoder().encode(original)
        let decoded = try decoder().decode(AXFrame.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testFrameWithNilOptionalsRoundTrips() throws {
        let original = AXFrame(
            space: .axGlobalTopLeft,
            rect: .init(x: 0, y: 0, width: 10, height: 10),
            center: .init(x: 5, y: 5),
            capturedAt: Date(timeIntervalSince1970: 0))
        let data = try encoder().encode(original)
        let decoded = try decoder().decode(AXFrame.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertNil(decoded.inWindow)
        XCTAssertNil(decoded.screen)
    }

    func testElementRecordRoundTripsThroughJSON() throws {
        let original = AXElementRecord(
            identity: "axbutton|go back",
            ordinal: 1,
            role: "AXButton",
            subrole: nil,
            label: "Go Back",
            kind: "button",
            containerTrail: ["Mary X-Ray"],
            isEnabled: true,
            isFocused: false,
            appName: "Google Chrome",
            pid: 12235,
            windowTitle: "Mary X-Ray — Google Chrome — Ritesh",
            frame: sample())
        let data = try encoder().encode(original)
        let decoded = try decoder().decode(AXElementRecord.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Deterministic key order

    func testEncodedKeysAreSorted() throws {
        let json = String(data: try encoder().encode(sample()), encoding: .utf8)!
        // A crude but honest check: every top-level key in alphabetical
        // order relative to its neighbors' first appearance.
        let expectedOrder = ["capturedAt", "center", "inWindow", "isClipped", "rect", "screen", "space"]
        var lastIndex = -1
        for key in expectedOrder {
            guard let range = json.range(of: "\"\(key)\"") else {
                XCTFail("missing key \(key) in \(json)")
                continue
            }
            let index = json.distance(from: json.startIndex, to: range.lowerBound)
            XCTAssertGreaterThan(index, lastIndex, "\(key) out of sorted order")
            lastIndex = index
        }
    }

    func testEncodingIsByteIdenticalAcrossTwoRuns() throws {
        let sample = sample()
        let first = try encoder().encode(sample)
        let second = try encoder().encode(sample)
        XCTAssertEqual(first, second)
    }

    // MARK: - Date stamping

    func testCapturedAtRoundTripsToTheSecond() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_123)
        let frame = sample(capturedAt: stamp)
        let decoded = try decoder().decode(AXFrame.self, from: try encoder().encode(frame))
        XCTAssertEqual(
            decoded.capturedAt.timeIntervalSince1970.rounded(),
            stamp.timeIntervalSince1970.rounded())
    }

    // MARK: - Tolerant of the unknown — the whole point of NOT using StrictDecoding

    func testDecodingIgnoresAnUnknownKey() throws {
        let json = """
        {"space":"axGlobalTopLeft",
         "rect":{"x":0,"y":0,"width":10,"height":10},
         "center":{"x":5,"y":5},
         "isClipped":false,
         "capturedAt":"2023-11-14T22:13:20Z",
         "fromANewerBuild":"ignored, not rejected"}
        """
        let decoded = try decoder().decode(AXFrame.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rect.width, 10)
    }
}
