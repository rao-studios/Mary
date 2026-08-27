//
//  SeerTotemsClient.swift
//  MaryBrain
//
//  The fleet as Seer sees it: which totem nodes are registered with the
//  mothership, whether each is alive and accepting storage, and per-node
//  document/group counts. One bounded GET against `/v1/totems`, which sits
//  on Seer's OPEN router — registered before AuthMiddleware — so unlike
//  every other Seer client here there is deliberately no SeerSession: the
//  Totems pane must be able to see the fleet before anyone signs in, and a
//  dead account must not read as a dead cluster.
//

import Foundation

/// Injectable GET seam, the read-only sibling of `SeerVisionTransport`.
public protocol SeerGETTransport: Sendable {
    func get(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public enum SeerTotemsError: LocalizedError, Equatable {
    case http(Int)
    case unreachable(String)
    case undecodable(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "Seer totems failed (\(status))."
        case .unreachable(let reason): return "Seer is unreachable: \(reason)"
        case .undecodable(let reason): return "Seer totems answer was undecodable: \(reason)"
        }
    }
}

/// Per-node storage counts. Optional on `TotemNodeInfo` because Seer's stats
/// fan-out can miss a node that is registered but not answering — a node with
/// no stats is still a node worth showing.
public struct TotemNodeStats: Sendable, Equatable {
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

public struct TotemNodeInfo: Sendable, Equatable, Identifiable {
    /// The node's totem id — the same identity Mary mints for its own node,
    /// so the pane can diff the fleet against the local configuration.
    public var id: String
    public var host: String
    public var grpcPort: Int
    public var httpPort: Int
    public var lastSeen: Date
    public var isActive: Bool
    public var acceptingStorage: Bool
    public var stats: TotemNodeStats?

    public init(
        id: String,
        host: String,
        grpcPort: Int,
        httpPort: Int,
        lastSeen: Date,
        isActive: Bool,
        acceptingStorage: Bool,
        stats: TotemNodeStats? = nil
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

public struct TotemFleetSnapshot: Sendable, Equatable {
    public var mothershipID: String
    public var totalDocumentCount: Int
    public var totalGroupCount: Int
    /// Seer answers `enabled: false` when zero nodes are registered — the
    /// honest "no fleet" as distinct from "fleet unreachable" (a throw).
    public var enabled: Bool
    public var nodes: [TotemNodeInfo]

    public init(
        mothershipID: String,
        totalDocumentCount: Int,
        totalGroupCount: Int,
        enabled: Bool,
        nodes: [TotemNodeInfo]
    ) {
        self.mothershipID = mothershipID
        self.totalDocumentCount = totalDocumentCount
        self.totalGroupCount = totalGroupCount
        self.enabled = enabled
        self.nodes = nodes
    }
}

public actor SeerTotemsClient {

    private var baseURL: URL
    private let transport: any SeerGETTransport

    public init(
        baseURL: URL,
        transport: any SeerGETTransport = URLSessionGETTransport()
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
    public func fleet() async throws -> TotemFleetSnapshot {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/totems"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let status: Int
        let body: Data
        do {
            (status, body) = try await transport.get(request)
        } catch {
            throw SeerTotemsError.unreachable(error.localizedDescription)
        }
        guard status == 200 else {
            throw SeerTotemsError.http(status)
        }

        let wire: WireFleet
        do {
            wire = try Self.decode(body)
        } catch {
            throw SeerTotemsError.undecodable(error.localizedDescription)
        }
        return TotemFleetSnapshot(
            mothershipID: wire.mothershipID,
            totalDocumentCount: wire.totalDocumentCount,
            totalGroupCount: wire.totalGroupCount,
            enabled: wire.enabled,
            nodes: wire.nodes.map { node in
                TotemNodeInfo(
                    id: node.totemID,
                    host: node.host,
                    grpcPort: node.grpcPort,
                    httpPort: node.httpPort,
                    lastSeen: node.lastSeen,
                    isActive: node.isActive,
                    acceptingStorage: node.acceptingStorage,
                    stats: node.stats.map {
                        TotemNodeStats(
                            documentCount: $0.documentCount,
                            groupCount: $0.groupCount,
                            ownerCount: $0.ownerCount,
                            availableDocumentCount: $0.availableDocumentCount)
                    })
            })
    }

    /// Seer hands the route's response straight to Hummingbird's default
    /// JSONEncoder, so `last_seen` arrives as deferredToDate seconds. Decode
    /// with the matching default strategy first, then retry the whole
    /// document as ISO8601 — a server-side switch to the other common
    /// encoding should degrade to nothing, not blind the pane to the fleet.
    private static func decode(_ body: Data) throws -> WireFleet {
        do {
            return try JSONDecoder().decode(WireFleet.self, from: body)
        } catch {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WireFleet.self, from: body)
        }
    }

    // MARK: - Wire (mirrors Seer's Routes/Totem.swift response structs)

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
        let totemID: String
        let host: String
        let grpcPort: Int
        let httpPort: Int
        let lastSeen: Date
        let isActive: Bool
        let acceptingStorage: Bool
        let stats: WireStats?

        enum CodingKeys: String, CodingKey {
            case totemID = "totem_id"
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

public struct URLSessionGETTransport: SeerGETTransport {
    /// A small dedicated session — never `URLSession.shared` (its resource
    /// timeout is seven days) and not `StreamingHTTP.session` (fleet polls
    /// must not touch the chat lanes' idle window). The request carries its
    /// own 5 s deadline; the resource cap is the backstop behind it.
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
