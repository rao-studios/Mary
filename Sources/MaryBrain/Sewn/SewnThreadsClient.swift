//
//  SewnThreadsClient.swift
//  MaryBrain
//
//  WHAT: Fleet as Sewn sees it — `/v1/threads` on the open router.
//  IN:   Threads pane (before sign-in)
//  OUT:  node liveness / counts
//  PIN:  No SewnSession — a dead account must not read as a dead cluster.
//
import Foundation

/// Injectable GET seam, the read-only sibling of `SewnVisionTransport`.
public protocol SewnGETTransport: Sendable {
    func get(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public enum SewnThreadsError: LocalizedError, Equatable {
    case http(Int)
    case unreachable(String)
    case undecodable(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "Sewn threads failed (\(status))."
        case .unreachable(let reason): return "Sewn is unreachable: \(reason)"
        case .undecodable(let reason): return "Sewn threads answer was undecodable: \(reason)"
        }
    }
}

/// Per-node storage counts. Optional on `ThreadNodeInfo` because Sewn's stats
/// fan-out can miss a node that is registered but not answering — a node with
/// no stats is still a node worth showing.
public struct ThreadNodeStats: Sendable, Equatable {
    public var documentCount: Int
    public var groupCount: Int
    public var ownerCount: Int
    public var availableDocumentCount: Int

    public init(
        documentCount: Int,
        groupCount: Int,
        ownerCount: Int,
        availableDocumentCount: Int
    ) {
        self.documentCount = documentCount
        self.groupCount = groupCount
        self.ownerCount = ownerCount
        self.availableDocumentCount = availableDocumentCount
    }
}

public struct ThreadNodeInfo: Sendable, Equatable, Identifiable {
    /// The node's thread id — the same identity Mary mints for its own node,
    /// so the pane can diff the fleet against the local configuration.
    public var id: String
    public var host: String
    public var grpcPort: Int
    public var httpPort: Int
    public var lastSeen: Date
    public var isActive: Bool
    public var acceptingStorage: Bool
    public var stats: ThreadNodeStats?

    public init(
        id: String,
        host: String,
        grpcPort: Int,
        httpPort: Int,
        lastSeen: Date,
        isActive: Bool,
        acceptingStorage: Bool,
        stats: ThreadNodeStats? = nil
    ) {
        self.id = id
        self.host = host
        self.grpcPort = grpcPort
        self.httpPort = httpPort
        self.lastSeen = lastSeen
        self.isActive = isActive
        self.acceptingStorage = acceptingStorage
        self.stats = stats
    }
}

public struct ThreadFleetSnapshot: Sendable, Equatable {
    public var mothershipID: String
    public var totalDocumentCount: Int
    public var totalGroupCount: Int
    /// Sewn answers `enabled: false` when zero nodes are registered — the
    /// honest "no fleet" as distinct from "fleet unreachable" (a throw).
    public var enabled: Bool
    public var nodes: [ThreadNodeInfo]

    public init(
        mothershipID: String,
        totalDocumentCount: Int,
        totalGroupCount: Int,
        enabled: Bool,
        nodes: [ThreadNodeInfo]
    ) {
        self.mothershipID = mothershipID
        self.totalDocumentCount = totalDocumentCount
        self.totalGroupCount = totalGroupCount
        self.enabled = enabled
        self.nodes = nodes
    }
}

public actor SewnThreadsClient {

    private var baseURL: URL
    private let transport: any SewnGETTransport

    public init(
        baseURL: URL,
        transport: any SewnGETTransport = URLSessionGETTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func configure(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// One fleet snapshot. The pane polls this on a ~5 s loop, so the
    /// request deadline matches the cadence: a hung call must fail before
    /// the next tick rather than stack behind it.
    public func fleet() async throws -> ThreadFleetSnapshot {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/threads"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let status: Int
        let body: Data
        do {
            (status, body) = try await transport.get(request)
        } catch {
            throw SewnThreadsError.unreachable(error.localizedDescription)
        }
        guard status == 200 else {
            throw SewnThreadsError.http(status)
        }

        let wire: WireFleet
        do {
            wire = try Self.decode(body)
        } catch {
            throw SewnThreadsError.undecodable(error.localizedDescription)
        }
        return ThreadFleetSnapshot(
            mothershipID: wire.mothershipID,
            totalDocumentCount: wire.totalDocumentCount,
            totalGroupCount: wire.totalGroupCount,
            enabled: wire.enabled,
            nodes: wire.nodes.map { node in
                ThreadNodeInfo(
                    id: node.threadID,
                    host: node.host,
                    grpcPort: node.grpcPort,
                    httpPort: node.httpPort,
                    lastSeen: node.lastSeen,
                    isActive: node.isActive,
                    acceptingStorage: node.acceptingStorage,
                    stats: node.stats.map {
                        ThreadNodeStats(
                            documentCount: $0.documentCount,
                            groupCount: $0.groupCount,
                            ownerCount: $0.ownerCount,
                            availableDocumentCount: $0.availableDocumentCount)
                    })
            })
    }

    /// Sewn hands the route's response straight to Hummingbird's default JSONEncoder, so `last_seen` arrives as deferredToDate seconds.
    private static func decode(_ body: Data) throws -> WireFleet {
        do {
            return try JSONDecoder().decode(WireFleet.self, from: body)
        } catch {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WireFleet.self, from: body)
        }
    }

    // MARK: - Wire (mirrors Sewn's Routes/Thread.swift response structs)

    private struct WireFleet: Decodable {
        let mothershipID: String
        let totalDocumentCount: Int
        let totalGroupCount: Int
        let nodes: [WireNode]
        let enabled: Bool

        enum CodingKeys: String, CodingKey {
            case mothershipID = "mothership_id"
            case totalDocumentCount = "total_document_count"
            case totalGroupCount = "total_group_count"
            case nodes
            case enabled
        }
    }

    private struct WireNode: Decodable {
        let threadID: String
        let host: String
        let grpcPort: Int
        let httpPort: Int
        let lastSeen: Date
        let isActive: Bool
        let acceptingStorage: Bool
        let stats: WireStats?

        enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case host
            case grpcPort = "grpc_port"
            case httpPort = "http_port"
            case lastSeen = "last_seen"
            case isActive = "is_active"
            case acceptingStorage = "accepting_storage"
            case stats
        }
    }

    private struct WireStats: Decodable {
        let documentCount: Int
        let groupCount: Int
        let ownerCount: Int
        let availableDocumentCount: Int

        enum CodingKeys: String, CodingKey {
            case documentCount = "document_count"
            case groupCount = "group_count"
            case ownerCount = "owner_count"
            case availableDocumentCount = "available_document_count"
        }
    }
}

// MARK: - URLSession transport

public struct URLSessionGETTransport: SewnGETTransport {
    /// A small dedicated session — never `URLSession.shared` (its resource timeout is seven days) and not `StreamingHTTP.session` (fleet polls must not touch the chat…
    /// PIN: A small dedicated session — never `URLSession.shared` (its resource timeout is seven days) and not…
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func get(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await Self.session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
