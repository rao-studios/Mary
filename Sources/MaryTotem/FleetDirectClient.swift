//
//  FleetDirectClient.swift
//  MaryTotem
//
//  WHAT: One-shot gRPC against Fleet's FleetLoRA service (:9093).
//  OUT:  FleetLoRASlot / FleetTrainProgress. Brain never imports this package.
//        Runtime maps slots onto Life.
//

import Conduit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public struct FleetLoRASlot: Sendable, Equatable, Identifiable {
    public var abilityID: String
    public var generation: Int
    public var pairCount: Int
    public var trainedAt: Date?
    public var ready: Bool
    public var artifactPath: String
    public var cid: String
    public var modelID: String
    public var schemaJSON: Data
    public var training: Bool

    public var id: String { abilityID }

    public init(
        abilityID: String,
        generation: Int,
        pairCount: Int,
        trainedAt: Date?,
        ready: Bool,
        artifactPath: String,
        cid: String,
        modelID: String,
        schemaJSON: Data,
        training: Bool
    ) {
        self.abilityID = abilityID
        self.generation = generation
        self.pairCount = pairCount
        self.trainedAt = trainedAt
        self.ready = ready
        self.artifactPath = artifactPath
        self.cid = cid
        self.modelID = modelID
        self.schemaJSON = schemaJSON
        self.training = training
    }
}

public struct FleetTrainProgress: Sendable, Equatable {
    public var stage: String
    public var iteration: Int
    public var loss: Float
    public var message: String
    public var slot: FleetLoRASlot?

    public init(
        stage: String, iteration: Int, loss: Float, message: String, slot: FleetLoRASlot?
    ) {
        self.stage = stage
        self.iteration = iteration
        self.loss = loss
        self.message = message
        self.slot = slot
    }
}

/// One gated completion, as Fleet answered it.
public struct FleetCompletion: Sendable, Equatable {
    public var outputJSON: String
    public var rawText: String
    public var forcedFraction: Double
    public var promptTokens: Int
    public var cid: String

    public init(
        outputJSON: String, rawText: String, forcedFraction: Double,
        promptTokens: Int, cid: String
    ) {
        self.outputJSON = outputJSON
        self.rawText = rawText
        self.forcedFraction = forcedFraction
        self.promptTokens = promptTokens
        self.cid = cid
    }
}

public actor FleetDirectClient {
    private let host: String
    private let port: Int

    public init(host: String = "127.0.0.1", port: Int = 9093) {
        self.host = host
        self.port = port
    }

    public func listAdapters(totemID: String) async throws -> [FleetLoRASlot] {
        var request = Fleet_V1_ListAdaptersRequest()
        request.totemID = totemID
        return try await withStub(timeout: .seconds(15)) { stub, options in
            let response = try await stub.listAdapters(request, options: options)
            return response.slots.map(Self.slot(from:))
        }
    }

    public func adapterStatus(totemID: String, abilityID: String) async throws -> FleetLoRASlot {
        var request = Fleet_V1_AdapterStatusRequest()
        request.totemID = totemID
        request.abilityID = abilityID
        return try await withStub(timeout: .seconds(15)) { stub, options in
            Self.slot(from: try await stub.adapterStatus(request, options: options))
        }
    }

    /// One gated completion through a ready slot — the Life engine's round.
    /// Fleet holds the weights and the schema; Mary sends the input document.
    public func complete(
        totemID: String,
        abilityID: String,
        cid: String,
        inputJSON: String
    ) async throws -> FleetCompletion {
        var request = Fleet_V1_CompleteRequest()
        request.totemID = totemID
        request.abilityID = abilityID
        request.cid = cid
        request.inputJson = inputJSON
        // Generous — a cold slot loads a base model — but finite, so a wedged
        // server cannot pin an idle pulse forever.
        return try await withStub(timeout: .seconds(180)) { stub, options in
            let response = try await stub.complete(request, options: options)
            return FleetCompletion(
                outputJSON: response.outputJson,
                rawText: response.rawText,
                forcedFraction: response.forcedFraction,
                promptTokens: Int(response.promptTokens),
                cid: response.cid)
        }
    }

    /// Empty `pairs` is the production path: Fleet ExportCorpus from Totem
    /// using `ownerID`, `groupIDs`, and `documentIDPrefix`.
    public func train(
        totemID: String,
        abilityID: String,
        modelID: String,
        pairs: [(inputJSON: String, outputJSON: String)] = [],
        ownerID: String,
        groupIDs: [String],
        documentIDPrefix: String = "mary-behavior-"
    ) -> AsyncThrowingStream<FleetTrainProgress, Error> {
        let host = self.host
        let port = self.port
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = Fleet_V1_TrainRequest()
                    request.totemID = totemID
                    request.abilityID = abilityID
                    request.modelID = modelID
                    request.ownerID = ownerID
                    request.groupIds = groupIDs
                    request.documentIDPrefix = documentIDPrefix
                    request.pairs = pairs.map { pair in
                        var item = Fleet_V1_TrainingPair()
                        item.inputJson = pair.inputJSON
                        item.outputJson = pair.outputJSON
                        return item
                    }
                    let transport: HTTP2ClientTransport.Posix = try .http2NIOPosix(
                        target: .ipv4(host: host, port: port),
                        transportSecurity: .plaintext
                    )
                    var options = GRPCCore.CallOptions.defaults
                    options.timeout = .seconds(60 * 30)
                    try await withGRPCClient(transport: transport) { client in
                        let stub = Fleet_V1_FleetLoRA.Client(wrapping: client)
                        try await stub.train(request, options: options) { response in
                            for try await message in response.messages {
                                continuation.yield(Self.progress(from: message))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeTransport() throws -> HTTP2ClientTransport.Posix {
        try .http2NIOPosix(
            target: .ipv4(host: host, port: port),
            transportSecurity: .plaintext
        )
    }

    private func withStub<T: Sendable>(
        timeout: Duration,
        _ body: @Sendable @escaping (
            Fleet_V1_FleetLoRA.Client<HTTP2ClientTransport.Posix>, GRPCCore.CallOptions
        ) async throws -> T
    ) async throws -> T {
        var options = GRPCCore.CallOptions.defaults
        options.timeout = timeout
        return try await withGRPCClient(transport: try makeTransport()) { client in
            try await body(Fleet_V1_FleetLoRA.Client(wrapping: client), options)
        }
    }

    static func slot(from proto: Fleet_V1_LoRASlot) -> FleetLoRASlot {
        FleetLoRASlot(
            abilityID: proto.abilityID,
            generation: Int(proto.generation),
            pairCount: Int(proto.pairCount),
            trainedAt: proto.trainedAtUnix == 0
                ? nil : Date(timeIntervalSince1970: TimeInterval(proto.trainedAtUnix)),
            ready: proto.ready,
            artifactPath: proto.artifactPath,
            cid: proto.cid,
            modelID: proto.modelID,
            schemaJSON: proto.schemaJson,
            training: proto.training)
    }

    static func progress(from proto: Fleet_V1_TrainProgress) -> FleetTrainProgress {
        FleetTrainProgress(
            stage: proto.stage,
            iteration: Int(proto.iteration),
            loss: proto.loss,
            message: proto.message,
            slot: proto.slot.abilityID.isEmpty && proto.slot.cid.isEmpty
                ? nil : slot(from: proto.slot))
    }
}
