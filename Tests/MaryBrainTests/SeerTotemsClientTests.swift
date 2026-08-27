//
//  SeerTotemsClientTests.swift
//  MaryBrainTests
//
//  The fleet route's wire shape and typed failures over a scripted transport
//  — no live Seer. The date fixtures pin BOTH encodings the client accepts:
//  deferredToDate seconds (what Seer's default JSONEncoder emits today) and
//  ISO8601 (the tolerated server-side change).
//

import XCTest
@testable import MaryBrain

// MARK: - Scripted seam

private final class ScriptedGETTransport: SeerGETTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [Result<(Int, Data), Error>]
    private(set) var requests: [URLRequest] = []

    init(_ attempts: [Result<(Int, Data), Error>]) {
        self.attempts = attempts
    }

    func get(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        lock.lock()
        requests.append(request)
        let attempt = attempts.isEmpty
            ? Result<(Int, Data), Error>.success((599, Data()))
            : attempts.removeFirst()
        lock.unlock()
        let (status, body) = try attempt.get()
        return (status, body)
    }
}

private func makeClient(
    attempts: [Result<(Int, Data), Error>]
) -> (SeerTotemsClient, ScriptedGETTransport) {
    let transport = ScriptedGETTransport(attempts)
    let client = SeerTotemsClient(
        baseURL: URL(string: "http://127.0.0.1:8080")!,
        transport: transport)
    return (client, transport)
}

private func ok(_ body: String) -> Result<(Int, Data), Error> {
    .success((200, Data(body.utf8)))
}

/// Two nodes: one live with stats, one registered-but-quiet with the stats
/// fan-out having come back empty. `last_seen` is deferredToDate seconds.
private let numericFleetBody = """
{
  "mothership_id": "mother-1",
  "total_document_count": 5200,
  "total_group_count": 320,
  "enabled": true,
  "nodes": [
    {
      "totem_id": "node-a",
      "host": "127.0.0.1",
      "grpc_port": 9090,
      "http_port": 8081,
      "last_seen": 777000000.5,
      "is_active": true,
      "accepting_storage": true,
      "stats": {
        "document_count": 5200,
        "group_count": 320,
        "owner_count": 1,
        "available_document_count": 5100
      }
    },
    {
      "totem_id": "node-b",
      "host": "127.0.0.1",
      "grpc_port": 9092,
      "http_port": 8082,
      "last_seen": 777000100,
      "is_active": false,
      "accepting_storage": false
    }
  ]
}
"""

// MARK: - Tests

final class SeerTotemsClientTests: XCTestCase {

    func testFleetGetsTheOpenTotemsRoute() async throws {
        let (client, transport) = makeClient(attempts: [ok(numericFleetBody)])
        _ = try await client.fleet()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/totems")
        XCTAssertEqual(request.httpMethod, "GET")
        // The open router takes no bearer; sending one anyway would hide a
        // regression back onto the session dependency.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.timeoutInterval, 5)
    }

    func testNumericLastSeenFleetDecodes() async throws {
        let (client, _) = makeClient(attempts: [ok(numericFleetBody)])
        let fleet = try await client.fleet()

        XCTAssertEqual(fleet.mothershipID, "mother-1")
        XCTAssertEqual(fleet.totalDocumentCount, 5200)
        XCTAssertEqual(fleet.totalGroupCount, 320)
        XCTAssertTrue(fleet.enabled)
        XCTAssertEqual(fleet.nodes.count, 2)

        let live = try XCTUnwrap(fleet.nodes.first)
        XCTAssertEqual(live.id, "node-a")
        XCTAssertEqual(live.host, "127.0.0.1")
        XCTAssertEqual(live.grpcPort, 9090)
        XCTAssertEqual(live.httpPort, 8081)
        XCTAssertEqual(live.lastSeen, Date(timeIntervalSinceReferenceDate: 777000000.5))
        XCTAssertTrue(live.isActive)
        XCTAssertTrue(live.acceptingStorage)
        let stats = try XCTUnwrap(live.stats)
        XCTAssertEqual(stats.documentCount, 5200)
        XCTAssertEqual(stats.groupCount, 320)
        XCTAssertEqual(stats.ownerCount, 1)
        XCTAssertEqual(stats.availableDocumentCount, 5100)
    }

    func testMissingStatsDecodesAsNil() async throws {
        let (client, _) = makeClient(attempts: [ok(numericFleetBody)])
        let fleet = try await client.fleet()

        let quiet = try XCTUnwrap(fleet.nodes.last)
        XCTAssertEqual(quiet.id, "node-b")
        XCTAssertFalse(quiet.isActive)
        XCTAssertFalse(quiet.acceptingStorage)
        XCTAssertNil(quiet.stats)
    }

    func testISO8601LastSeenDecodesViaTheFallback() async throws {
        let body = """
        {
          "mothership_id": "mother-1",
          "total_document_count": 0,
          "total_group_count": 0,
          "enabled": false,
          "nodes": [
            {
              "totem_id": "node-a",
              "host": "127.0.0.1",
              "grpc_port": 9090,
              "http_port": 8081,
              "last_seen": "2026-08-16T12:00:00Z",
              "is_active": true,
              "accepting_storage": true
            }
          ]
        }
        """
        let (client, _) = makeClient(attempts: [ok(body)])
        let fleet = try await client.fleet()
        XCTAssertFalse(fleet.enabled)
        let expected = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        XCTAssertEqual(fleet.nodes.first?.lastSeen, expected)
    }

    func testServerFailureThrowsTypedHTTPError() async {
        let (client, _) = makeClient(attempts: [.success((503, Data()))])
        do {
            _ = try await client.fleet()
            XCTFail("expected a throw")
        } catch let error as SeerTotemsError {
            XCTAssertEqual(error, .http(503))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testConnectionFailureThrowsUnreachable() async {
        let (client, _) = makeClient(
            attempts: [.failure(URLError(.cannotConnectToHost))])
        do {
            _ = try await client.fleet()
            XCTFail("expected a throw")
        } catch let error as SeerTotemsError {
            guard case .unreachable = error else {
                return XCTFail("wrong case: \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testGarbageBodyThrowsUndecodable() async {
        let (client, _) = makeClient(attempts: [ok("not json")])
        do {
            _ = try await client.fleet()
            XCTFail("expected a throw")
        } catch let error as SeerTotemsError {
            guard case .undecodable = error else {
                return XCTFail("wrong case: \(error)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
